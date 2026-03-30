defmodule Orchard.TestSupport.HuggingFaceReqStub do
  @moduledoc false

  def sample_file_contents do
    %{
      "config.json" => ~s({"model_type":"llama","hidden_size":256}),
      "tokenizer.json" => ~s({"version":"1.0"}),
      "model.safetensors" => "fake-safetensors-weights-data-for-testing"
    }
  end

  def write_files(root, file_contents) do
    Enum.each(file_contents, fn {path, content} ->
      full_path = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
    end)
  end

  def tree_response(file_contents, extras \\ []) do
    Enum.map(file_contents, fn {path, content} ->
      %{
        "type" => "file",
        "oid" => full_hash(content),
        "size" => byte_size(content),
        "path" => path
      }
    end) ++ extras
  end

  def hf_config(stub_name) do
    [
      base_url: "https://huggingface.co",
      api_base_url: "https://huggingface.co/api",
      token: nil,
      retry_attempts: 1,
      connect_timeout_ms: 5_000,
      receive_timeout_ms: 5_000,
      req_options: [plug: {Req.Test, stub_name}]
    ]
  end

  def install(stub_name, file_contents, tree_response, opts \\ []) do
    Req.Test.stub(stub_name, fn conn ->
      dispatch(conn, file_contents, tree_response, opts)
    end)
  end

  def dispatch(conn, file_contents, tree_response, opts \\ []) do
    revision = Keyword.get(opts, :revision, "main")
    unknown_body = Keyword.get(opts, :unknown_body, "")
    on_request = Keyword.get(opts, :on_request)
    route = route(conn)

    maybe_on_request(on_request, conn)

    case route do
      :tree ->
        handle_tree(conn, tree_response, Keyword.get(opts, :tree_handler))

      :head ->
        handle_head(
          conn,
          file_contents,
          revision,
          Keyword.get(opts, :head_handler)
        )

      :download ->
        handle_download(
          conn,
          file_contents,
          revision,
          Keyword.get(opts, :download_handler)
        )

      :unknown ->
        Plug.Conn.send_resp(conn, 404, unknown_body)
    end
  end

  defp route(conn) do
    cond do
      String.contains?(conn.request_path, "/tree/") -> :tree
      conn.method == "HEAD" and String.contains?(conn.request_path, "/resolve/") -> :head
      conn.method == "GET" and String.contains?(conn.request_path, "/resolve/") -> :download
      true -> :unknown
    end
  end

  defp maybe_on_request(nil, _conn), do: :ok
  defp maybe_on_request(on_request, conn), do: on_request.(conn)

  defp handle_tree(conn, tree_response, nil), do: Req.Test.json(conn, tree_response)

  defp handle_tree(conn, tree_response, tree_handler) do
    case tree_handler.(conn, tree_response) do
      :default -> Req.Test.json(conn, tree_response)
      response -> response
    end
  end

  defp handle_head(conn, file_contents, revision, head_handler) do
    file_path = extract_file_path(conn.request_path, revision)
    content = Map.get(file_contents, file_path)

    case maybe_handle_route(head_handler, conn, file_path, content) do
      :default -> respond_head(conn, wrap_content(content))
      response -> response
    end
  end

  defp handle_download(conn, file_contents, revision, download_handler) do
    file_path = extract_file_path(conn.request_path, revision)
    content = Map.get(file_contents, file_path)

    case maybe_handle_route(download_handler, conn, file_path, content) do
      :default -> respond_download(conn, wrap_content(content))
      response -> response
    end
  end

  defp maybe_handle_route(nil, _conn, _file_path, _content), do: :default
  defp maybe_handle_route(handler, conn, file_path, content), do: handler.(conn, file_path, content)

  defp wrap_content(nil), do: :error
  defp wrap_content(content), do: {:ok, content}

  defp respond_head(conn, {:ok, content}) do
    conn
    |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(content)))
    |> Plug.Conn.put_resp_header("etag", "\"#{hash_content(content)}\"")
    |> Plug.Conn.send_resp(200, "")
  end

  defp respond_head(conn, :error), do: Plug.Conn.send_resp(conn, 404, "")

  defp respond_download(conn, {:ok, content}) do
    {status, body} = ranged_body(content, range_header(conn))

    conn
    |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(body)))
    |> Plug.Conn.send_resp(status, body)
  end

  defp respond_download(conn, :error), do: Plug.Conn.send_resp(conn, 404, "")

  def extract_file_path(request_path, revision \\ "main") do
    with [_, remainder] <- String.split(request_path, "/resolve/", parts: 2),
         [encoded_revision, encoded_file_path] <- String.split(remainder, "/", parts: 2),
         ^revision <- URI.decode(encoded_revision) do
      URI.decode(encoded_file_path)
    else
      _ -> ""
    end
  end

  def range_header(conn) do
    Enum.find_value(conn.req_headers, fn
      {"range", value} -> value
      _ -> nil
    end)
  end

  def resume_download(conn, content) do
    case ranged_body(content, range_header(conn)) do
      {status, body} ->
        conn
        |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(body)))
        |> Plug.Conn.send_resp(status, body)
    end
  end

  defp ranged_body(content, "bytes=" <> range_spec) do
    [start_str | _] = String.split(range_spec, "-")
    start = String.to_integer(start_str)
    {206, binary_part(content, start, byte_size(content) - start)}
  end

  defp ranged_body(content, _range_header), do: {200, content}

  def hash_content(content) do
    content
    |> full_hash()
    |> binary_part(0, 16)
  end

  defp full_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
