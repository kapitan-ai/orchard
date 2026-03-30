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

  def dispatch(conn, file_contents, tree_response, opts \\ []) do
    revision = Keyword.get(opts, :revision, "main")
    unknown_body = Keyword.get(opts, :unknown_body, "")

    case route(conn) do
      :tree ->
        Req.Test.json(conn, tree_response)

      :head ->
        respond_head(conn, content_for_request(file_contents, conn.request_path, revision))

      :download ->
        respond_download(conn, content_for_request(file_contents, conn.request_path, revision))

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

  defp content_for_request(file_contents, request_path, revision) do
    case Map.get(file_contents, extract_file_path(request_path, revision)) do
      nil -> :error
      content -> {:ok, content}
    end
  end

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
