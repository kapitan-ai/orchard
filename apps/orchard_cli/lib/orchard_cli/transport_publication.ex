defmodule OrchardCLI.TransportPublication do
  @moduledoc """
  Port client for the `orchard-transport-publish` host helper.

  The helper validates support-root ancestry and the public directory, holds the
  publisher lock, creates the private stage, and publishes or rolls back the
  local-CA certificate and endpoint metadata by descriptor identity. See
  `SPEC.md` §10.7 and ADR 0036.
  """

  @helper "orchard-transport-publish"
  @protocol_version "1"
  @prepare_timeout_ms 120_000
  @step_timeout_ms 60_000

  @enforce_keys [:port, :public, :endpoint]
  defstruct [:port, :public, :endpoint]

  @type presence :: :absent | :existing
  @type t :: %__MODULE__{port: port(), public: presence(), endpoint: presence()}
  @type failure :: %{
          code: String.t(),
          errno: String.t(),
          subject: String.t(),
          detail: String.t()
        }
  @type error :: {:helper_unavailable, String.t()} | {:helper_failed, String.t()} | failure()

  @doc """
  Starts the helper and prepares publication under `support_root`.

  Options: `:executable` overrides the staged helper path, `:wrapper` is an argv
  prefix that execs the helper as its final argument, and `:env` adds helper
  environment variables.
  """
  @spec prepare(String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def prepare(support_root, opts \\ []) when is_binary(support_root) do
    with {:ok, executable} <- resolve_executable(opts),
         {:ok, port} <- open_port(executable, opts) do
      case request(port, "PREPARE\n" <> support_root, @prepare_timeout_ms) do
        {:ok, "PREPARED " <> rest} -> prepared(port, rest)
        {:ok, other} -> protocol_failure(port, other)
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Stages and publishes the CA certificate (or `nil`) and endpoint metadata bytes.

  Returns operator warnings for retained private-stage residue. Any error ends the helper.
  """
  @spec publish(t(), binary() | nil, binary()) :: {:ok, [String.t()]} | {:error, error()}
  def publish(%__MODULE__{port: port}, ca_bytes, endpoint_bytes)
      when (is_binary(ca_bytes) or is_nil(ca_bytes)) and is_binary(endpoint_bytes) do
    ca = ca_bytes || ""

    frame =
      IO.iodata_to_binary([
        "PUBLISH\n",
        <<byte_size(ca)::32>>,
        ca,
        <<byte_size(endpoint_bytes)::32>>,
        endpoint_bytes
      ])

    expect(port, frame, "PUBLISHED")
  end

  @doc "Restores the previous endpoint metadata while the published inode is still in place."
  @spec rollback(t()) :: {:ok, [String.t()]} | {:error, error()}
  def rollback(%__MODULE__{port: port}), do: expect(port, "ROLLBACK", "ROLLED_BACK")

  @doc "Ends a published or rolled-back publication and releases the publisher lock."
  @spec commit(t()) :: :ok | {:error, error()}
  def commit(%__MODULE__{port: port}), do: finish(port, "COMMIT", "COMMITTED")

  @doc "Removes the unpublished private stage and releases the publisher lock."
  @spec abort(t()) :: :ok | {:error, error()}
  def abort(%__MODULE__{port: port}), do: finish(port, "ABORT", "ABORTED")

  @doc "Formats a helper error as an operator-facing message."
  @spec format_error(error()) :: String.t()
  def format_error({:helper_unavailable, path}) do
    "transport publication helper is unavailable at #{path}. " <>
      "Build and stage it with the explicit native-helper builder before enabling local HTTPS."
  end

  def format_error({:helper_failed, reason}),
    do: "transport publication helper failed: #{reason}"

  def format_error(%{code: code, errno: errno, subject: subject, detail: detail}) do
    [describe(subject, code), errno_suffix(errno), detail_suffix(detail)]
    |> IO.iodata_to_binary()
  end

  defp describe(subject, "writable"), do: "#{subject_label(subject)} is group/world writable"

  defp describe(subject, "unsafe_owner"),
    do: "#{subject_label(subject)} is not owned by the expected Orchard service owner"

  defp describe(subject, "not_private"),
    do: "#{subject_label(subject)} is accessible to group or other users; expected mode 0700"

  defp describe(subject, "symlink"), do: "#{subject_label(subject)} is a symlink"
  defp describe(subject, "not_directory"), do: "#{subject_label(subject)} is not a directory"
  defp describe(subject, "not_regular"), do: "#{subject_label(subject)} is not a regular file"
  defp describe(subject, "missing"), do: "#{subject_label(subject)} does not exist"
  defp describe(subject, "setgid"), do: "#{subject_label(subject)} has the setgid bit set"

  defp describe(subject, "special_mode"),
    do: "#{subject_label(subject)} has setuid, setgid, or sticky bits set"

  defp describe(subject, "acl_present"),
    do: "#{subject_label(subject)} carries an extended or default ACL"

  defp describe(subject, "acl_inspection_failed"),
    do: "ACL inspection failed for #{subject_label(subject)}"

  defp describe(subject, "filesystem_unqualified"),
    do: "#{subject_label(subject)} is not on a qualified local filesystem"

  defp describe(subject, "filesystem_inspection_failed"),
    do: "filesystem inspection failed for #{subject_label(subject)}"

  defp describe(subject, "ownership_ignored"),
    do: "#{subject_label(subject)} is on a mount that ignores ownership"

  defp describe(subject, "cross_device"),
    do: "#{subject_label(subject)} is on a different device from the support root"

  defp describe(subject, "identity_mismatch"),
    do: "#{subject_label(subject)} changed identity during publication"

  defp describe(subject, "postcheck_failed"),
    do: "#{subject_label(subject)} failed post-create validation"

  defp describe(subject, "retained"), do: "#{subject_label(subject)} retained foreign entries"
  defp describe(subject, code), do: "#{subject_label(subject)}: #{String.replace(code, "_", " ")}"

  defp subject_label("support_root"), do: "support root"
  defp subject_label("config"), do: "Orchard config directory"
  defp subject_label("controller_env"), do: "controller.env"
  defp subject_label("tls"), do: "TLS directory"
  defp subject_label("tls_source"), do: "TLS source file"
  defp subject_label("ancestor"), do: "support-root ancestor"
  defp subject_label("public"), do: "public endpoint directory"
  defp subject_label("ca"), do: "published CA certificate"
  defp subject_label("endpoint"), do: "published endpoint metadata"
  defp subject_label("stage"), do: "private publication stage"
  defp subject_label("publication"), do: "public artifact publication"
  defp subject_label("rollback"), do: "endpoint metadata rollback"
  defp subject_label("cleanup"), do: "publication cleanup"
  defp subject_label("lock"), do: "publisher lock"
  defp subject_label(other), do: "transport publication #{other}"

  defp errno_suffix("-"), do: ""
  defp errno_suffix(errno), do: " (#{errno})"

  defp detail_suffix(""), do: ""
  defp detail_suffix(detail), do: ": #{detail}"

  defp resolve_executable(opts) do
    path = Keyword.get_lazy(opts, :executable, &default_executable/0)

    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> {:ok, path}
      _other -> {:error, {:helper_unavailable, path}}
    end
  end

  defp default_executable do
    case :code.priv_dir(:orchard_cli) do
      {:error, _reason} -> @helper
      priv -> Path.join(List.to_string(priv), @helper)
    end
  end

  defp open_port(executable, opts) do
    {program, args} =
      case Keyword.get(opts, :wrapper, []) do
        [] -> {executable, ["--protocol", @protocol_version]}
        [wrapper | prefix] -> {wrapper, prefix ++ [executable, "--protocol", @protocol_version]}
      end

    env =
      opts
      |> Keyword.get(:env, [])
      |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

    {:ok,
     Port.open({:spawn_executable, program}, [
       :binary,
       :exit_status,
       :use_stdio,
       {:packet, 4},
       {:args, args},
       {:env, env}
     ])}
  rescue
    error in ErlangError -> {:error, {:helper_failed, Exception.message(error)}}
  end

  defp prepared(port, rest) do
    with [public, endpoint, _stage] <- String.split(rest, " "),
         {:ok, public} <- presence(public),
         {:ok, endpoint} <- presence(endpoint) do
      {:ok, %__MODULE__{port: port, public: public, endpoint: endpoint}}
    else
      _other -> protocol_failure(port, "PREPARED " <> rest)
    end
  end

  defp presence("absent"), do: {:ok, :absent}
  defp presence("existing"), do: {:ok, :existing}
  defp presence(_other), do: :error

  defp expect(port, frame, expected) do
    case request(port, frame, @step_timeout_ms) do
      {:ok, ^expected} -> {:ok, []}
      {:ok, ^expected <> " cleanup_retained=" <> stage} -> {:ok, [retained_warning(stage)]}
      {:ok, other} -> protocol_failure(port, other)
      {:error, _reason} = error -> error
    end
  end

  defp retained_warning(stage) do
    "Warning: private publication stage #{stage} held unexpected entries and was retained " <>
      "in the support root; inspect and remove it manually."
  end

  defp finish(port, frame, expected) do
    case expect(port, frame, expected) do
      {:ok, []} ->
        await_exit(port)
        :ok

      {:ok, _warnings} ->
        protocol_failure(port, expected)

      {:error, _reason} = error ->
        error
    end
  end

  defp request(port, frame, timeout) do
    Port.command(port, frame)

    receive do
      {^port, {:data, "OK " <> reply}} ->
        {:ok, reply}

      {^port, {:data, "ERR " <> reply}} ->
        await_exit(port)
        {:error, parse_failure(reply)}

      {^port, {:data, other}} ->
        protocol_failure(port, other)

      {^port, {:exit_status, status}} ->
        {:error, {:helper_failed, "exited with status #{status}"}}
    after
      timeout ->
        close(port)
        {:error, {:helper_failed, "timed out"}}
    end
  rescue
    ArgumentError -> {:error, {:helper_failed, "port closed"}}
  end

  defp parse_failure(reply) do
    case String.split(reply, " ", parts: 4) do
      [code, errno, subject, detail] ->
        %{code: code, errno: errno, subject: subject, detail: detail}

      [code, errno, subject] ->
        %{code: code, errno: errno, subject: subject, detail: ""}

      _other ->
        {:helper_failed, "malformed error reply"}
    end
  end

  defp protocol_failure(port, reply) do
    close(port)
    {:error, {:helper_failed, "unexpected reply #{inspect(reply)}"}}
  end

  defp await_exit(port) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @step_timeout_ms -> close(port)
    end
  end

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
