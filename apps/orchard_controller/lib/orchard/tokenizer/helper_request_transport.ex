defmodule Orchard.Tokenizer.HelperRequestTransport do
  @moduledoc false

  @attempts 16

  @type failure_reason ::
          :invalid_prefix
          | :invalid_request_json
          | :unique_temp_dir_exhausted
          | {:mkdir_failed, File.posix()}
          | {:chmod_failed, File.posix()}
          | {:open_failed, File.posix()}
          | {:write_failed, File.posix()}
          | {:close_failed, File.posix()}

  @spec with_secure_request_file(String.t(), binary(), (Path.t() -> result)) ::
          result | {:error, {:request_transport_failed, failure_reason()}}
        when result: term()
  def with_secure_request_file(prefix, request_json, fun)
      when is_binary(prefix) and prefix != "" and is_binary(request_json) and is_function(fun, 1) do
    case secure_request_dir(prefix) do
      {:ok, request_dir} ->
        try do
          case write_request_file(request_dir, request_json) do
            {:ok, request_path} -> fun.(request_path)
            {:error, reason} -> {:error, {:request_transport_failed, reason}}
          end
        after
          File.rm_rf(request_dir)
        end

      {:error, reason} ->
        {:error, {:request_transport_failed, reason}}
    end
  end

  def with_secure_request_file(_prefix, request_json, fun)
      when is_binary(request_json) and is_function(fun, 1),
      do: {:error, {:request_transport_failed, :invalid_prefix}}

  def with_secure_request_file(_prefix, _request_json, fun) when is_function(fun, 1),
    do: {:error, {:request_transport_failed, :invalid_request_json}}

  defp secure_request_dir(prefix, attempts \\ @attempts)
  defp secure_request_dir(_prefix, 0), do: {:error, :unique_temp_dir_exhausted}

  defp secure_request_dir(prefix, attempts) do
    request_dir = Path.join(System.tmp_dir!(), "#{prefix}-#{random_temp_suffix()}")

    case File.mkdir(request_dir) do
      :ok -> chmod_secure_request_dir(request_dir)
      {:error, :eexist} -> secure_request_dir(prefix, attempts - 1)
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp chmod_secure_request_dir(request_dir) do
    case File.chmod(request_dir, 0o700) do
      :ok ->
        {:ok, request_dir}

      {:error, reason} ->
        File.rm_rf(request_dir)
        {:error, {:chmod_failed, reason}}
    end
  end

  defp random_temp_suffix do
    :crypto.strong_rand_bytes(18)
    |> Base.url_encode64(padding: false)
  end

  defp write_request_file(request_dir, request_json) do
    request_path = Path.join(request_dir, "request.json")

    case File.open(request_path, [:write, :binary, :exclusive]) do
      {:ok, io_device} -> write_request_json(io_device, request_path, request_json)
      {:error, reason} -> {:error, {:open_failed, reason}}
    end
  end

  defp write_request_json(io_device, request_path, request_json) do
    case :file.write(io_device, request_json) do
      :ok ->
        close_request_file(io_device, request_path)

      {:error, reason} ->
        File.close(io_device)
        {:error, {:write_failed, reason}}
    end
  end

  defp close_request_file(io_device, request_path) do
    case File.close(io_device) do
      :ok -> {:ok, request_path}
      {:error, reason} -> {:error, {:close_failed, reason}}
    end
  end
end
