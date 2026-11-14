defmodule Orchard.Tokenizer.HelperProcess do
  @moduledoc "Launches tokenizer rendering and preflight with a private cwd and environment."

  alias Orchard.Tokenizer.{HelperOutputCollector, HelperRequestTransport}

  @doc "Runs a helper through private request transport with bounded output collection."
  @spec run(String.t(), Path.t(), binary(), pos_integer(), pos_integer(), [
          {String.t(), String.t()}
        ]) ::
          HelperOutputCollector.collect_result()
          | {:error,
             :unavailable | {:request_transport_failed, HelperRequestTransport.failure_reason()}}
  def run(prefix, executable_path, request_json, timeout_ms, max_stdout_bytes, helper_env \\ []) do
    HelperRequestTransport.with_secure_request_file(prefix, request_json, fn request_path ->
      work_dir = Path.join(Path.dirname(request_path), "work")

      with :ok <- File.mkdir(work_dir),
           :ok <- File.chmod(work_dir, 0o700) do
        port =
          Port.open(
            {:spawn_executable, ~c"/usr/bin/env"},
            [
              :binary,
              :exit_status,
              :use_stdio,
              {:cd, work_dir},
              {:env,
               Enum.map(System.get_env(), fn {key, _value} -> {to_charlist(key), false} end)},
              {:args,
               ["-i"] ++
                 renderer_environment(work_dir, helper_env) ++
                 [
                   "/bin/sh",
                   "-c",
                   ~s(exec "$1" < "$2"),
                   prefix,
                   executable_path,
                   request_path
                 ]}
            ]
          )

        HelperOutputCollector.collect(port, timeout_ms, max_stdout_bytes)
      else
        {:error, _reason} -> {:error, :unavailable}
      end
    end)
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  defp renderer_environment(work_dir, helper_env) do
    uv_dir =
      case System.find_executable("uv") do
        nil -> []
        path -> [Path.dirname(path)]
      end

    version = System.get_env("UV_PYTHON", "") |> String.replace_prefix("cpython@", "")

    python_name =
      case Regex.run(~r/^(\d+)\.(\d+)/, version) do
        [_version, major, minor] -> "python#{major}.#{minor}"
        nil -> "python3"
      end

    python =
      case System.find_executable(python_name) do
        nil -> []
        path -> [{"UV_PYTHON", path}]
      end

    [
      {"PATH", Enum.join(["/usr/bin", "/bin"] ++ uv_dir, ":")},
      {"HOME", work_dir},
      {"UV_NO_MANAGED_PYTHON", "1"}
    ]
    |> Kernel.++(python ++ helper_env)
    |> Enum.map(fn {key, value} -> key <> "=" <> value end)
  end
end
