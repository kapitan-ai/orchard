defmodule OrchardCLI.LifecycleSystem do
  @moduledoc false

  alias Orchard.ManagedNodeAgent.LifecycleState
  alias OrchardCLI.LifecycleNative

  @support_root "/Library/Application Support/Orchard/support"
  @lock_path Path.join(@support_root, ".app-lifecycle.lock")
  @start_state_path Path.join(@support_root, ".managed-node-agent-start-state.json")
  @evidence_dir Path.join(@support_root, ".managed-node-agent-lifecycle-evidence")
  @max_evidence_records 1_024
  @max_document_bytes 1_048_576

  @spec with_lock((LifecycleNative.lock() -> result)) :: result | {:error, term()}
        when result: var
  def with_lock(callback) do
    with :ok <- ensure_trusted_directory(@support_root) do
      LifecycleNative.with_lock(@lock_path, callback)
    end
  end

  @spec lock_valid(LifecycleNative.lock()) :: :ok | {:error, term()}
  def lock_valid(lock), do: LifecycleNative.lock_valid(lock)

  @spec owner_identity() :: {:ok, map()} | {:error, term()}
  def owner_identity, do: LifecycleNative.process_identity(System.pid())

  @spec read_start_state() :: {:ok, map()} | {:error, term()}
  def read_start_state do
    case read_json(@start_state_path) do
      {:ok, document} -> normalize_start_state(document)
      error -> error
    end
  end

  @spec read_evidence() :: {:ok, [map()]} | {:error, term()}
  def read_evidence do
    case File.ls(@evidence_dir) do
      {:ok, entries} -> read_evidence_entries(entries)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:evidence_directory, reason}}
    end
  end

  @spec write_start_state(LifecycleNative.lock(), map()) :: :ok | {:error, term()}
  def write_start_state(lock, state) do
    with :ok <- LifecycleState.validate_start_state(state) do
      publish_json(lock, @start_state_path, state)
    end
  end

  @spec write_evidence(LifecycleNative.lock(), map()) :: :ok | {:error, term()}
  def write_evidence(lock, %{operation_id: operation_id} = evidence) do
    with :ok <- LifecycleState.validate_evidence(evidence),
         true <-
           Regex.match?(
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
             operation_id
           ) do
      publish_json(lock, Path.join(@evidence_dir, operation_id <> ".json"), evidence)
    else
      false -> {:error, :invalid_operation_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec disable_job(LifecycleNative.lock(), map()) :: :ok | {:error, term()}
  def disable_job(lock, service), do: LifecycleNative.disable_job(lock, service.label)

  @spec job_disabled?(map()) :: boolean() | {:error, term()}
  def job_disabled?(service) do
    case launchctl(["print-disabled", "system"]) do
      {output, 0} ->
        case disabled_state(output, service.label) do
          :disabled -> true
          state when state in [:enabled, :missing] -> false
          :ambiguous -> {:error, :ambiguous_disablement_state}
        end

      {output, code} ->
        {:error, {:disablement_observation_failed, code, summary(output)}}
    end
  end

  @doc "Parses one service's persistent disabled state from launchctl output."
  @spec disabled_state(String.t(), String.t()) :: :disabled | :enabled | :missing | :ambiguous
  def disabled_state(output, label) do
    pattern = ~r/"#{Regex.escape(label)}"\s*=>\s*([^,;\n}]+)/

    matches =
      pattern
      |> Regex.scan(output, capture: :all_but_first)
      |> Enum.map(fn [state] -> String.trim(state) end)

    case matches do
      ["true"] -> :disabled
      ["false"] -> :enabled
      [] -> :missing
      _matches -> :ambiguous
    end
  end

  @spec job_state(map()) :: :loaded | :unloaded | {:unknown, term()}
  def job_state(service) do
    case launchctl(["print", "system/#{service.label}"]) do
      {_output, 0} ->
        :loaded

      {output, 113} ->
        if(not_found?(output), do: :unloaded, else: {:unknown, {113, summary(output)}})

      {output, code} ->
        {:unknown, {code, summary(output)}}
    end
  end

  @spec process_snapshot(map()) :: {:ok, [map()]} | {:error, term()}
  def process_snapshot(service) do
    case launchctl(["print", "system/#{service.label}"]) do
      {output, 0} ->
        case job_pid(output) do
          pid when is_integer(pid) -> LifecycleNative.process_snapshot(pid)
          :missing -> LifecycleNative.process_snapshot()
          :ambiguous -> {:error, :ambiguous_launchd_pid}
        end

      {output, 113} ->
        if not_found?(output),
          do: LifecycleNative.process_snapshot(),
          else: {:error, {:launchd_pid_observation_failed, 113, summary(output)}}

      {output, code} ->
        {:error, {:launchd_pid_observation_failed, code, summary(output)}}
    end
  end

  @doc "Parses one service's PID from launchctl print output."
  @spec job_pid(String.t()) :: pos_integer() | :missing | :ambiguous
  def job_pid(output) do
    case Regex.scan(~r/^\s*pid\s*=\s*(\d+)\s*$/m, output, capture: :all_but_first) do
      [[pid]] ->
        case Integer.parse(pid) do
          {value, ""} when value > 1 -> value
          _invalid -> :ambiguous
        end

      [] ->
        :missing

      _matches ->
        :ambiguous
    end
  end

  @spec bootout(LifecycleNative.lock(), map()) :: :ok | {:error, term()}
  def bootout(lock, service) do
    LifecycleNative.bootout(lock, "system/#{service.label}")
  end

  @spec signal_process(LifecycleNative.lock(), map()) :: :ok | {:error, term()}
  def signal_process(lock, identity), do: LifecycleNative.signal_process(lock, identity)

  @spec process_identity_state(map()) :: :alive | :exited | :reused | {:unknown, term()}
  def process_identity_state(identity), do: LifecycleNative.process_identity_state(identity)

  defp read_evidence_entries(entries) when length(entries) > @max_evidence_records,
    do: {:error, :too_many_evidence_records}

  defp read_evidence_entries(entries) do
    result =
      entries
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, records} ->
        case read_evidence_entry(entry) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, reason} -> {:halt, {:error, {:evidence_entry, entry, reason}}}
        end
      end)

    case result do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_evidence_entry(entry) do
    path = Path.join(@evidence_dir, entry)

    with {:ok, contents} <- read_trusted_contents(path) do
      record =
        case Jason.decode(contents) do
          {:ok, decoded} ->
            validate_evidence_entry(decoded, entry, contents)

          {:error, reason} ->
            invalid_evidence_entry(entry, contents, reason)
        end

      {:ok, record}
    end
  end

  defp validate_evidence_entry(decoded, entry, contents) do
    case LifecycleState.validate_evidence(decoded) do
      :ok -> decoded
      {:error, reason} -> invalid_evidence_entry(entry, contents, reason)
    end
  end

  defp invalid_evidence_entry(entry, contents, reason) do
    %{
      operation_id: Path.rootname(entry),
      kind: "unknown",
      phase: "invalid",
      filename: entry,
      sha256: Base.encode16(:crypto.hash(:sha256, contents), case: :lower),
      invalid_reason: inspect(reason)
    }
  end

  defp publish_json(lock, path, document) do
    with :ok <- LifecycleNative.ensure_private_directory(lock, @evidence_dir),
         {:ok, encoded} <- Jason.encode(document),
         true <- byte_size(encoded) <= @max_document_bytes,
         :ok <-
           LifecycleNative.atomic_publish(lock, path, encoded, staging_directory: @evidence_dir) do
      :ok
    else
      false -> {:error, :document_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_json(path) do
    with {:ok, contents} <- read_trusted_contents(path) do
      Jason.decode(contents)
    end
  end

  defp read_trusted_contents(path) do
    with {:ok, stat} <- File.lstat(path),
         :regular <- stat.type,
         true <- stat.size <= @max_document_bytes,
         true <- trusted_owner?(stat),
         true <- Bitwise.band(stat.mode, 0o077) == 0,
         {:ok, contents} <- File.read(path) do
      {:ok, contents}
    else
      {:error, :enoent} -> {:error, :missing}
      false -> {:error, :unsafe_metadata}
      type when is_atom(type) -> {:error, {:unsafe_type, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_start_state(%{
         "schema_version" => 1,
         "eligibility" => %{"state" => state, "generation" => generation},
         "one_shot_authorization" => authorization
       })
       when state in ["suppressed", "one_shot_pending", "enabled"] and is_integer(generation) and
              generation > 0 and (is_map(authorization) or is_nil(authorization)) do
    {:ok,
     %{
       schema_version: 1,
       eligibility: %{state: state, generation: generation},
       one_shot_authorization: authorization
     }}
  end

  defp normalize_start_state(_document), do: {:error, :malformed}

  defp ensure_trusted_directory(path) do
    path
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn component, {:ok, current} ->
      candidate = if component == "/", do: "/", else: Path.join(current, component)

      case File.lstat(candidate) do
        {:ok, stat} ->
          trusted_directory_component(stat, candidate)

        {:error, reason} ->
          {:halt, {:error, {reason, candidate}}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp trusted_directory_component(stat, candidate) do
    if stat.type == :directory and trusted_owner?(stat) and
         Bitwise.band(stat.mode, 0o022) == 0 do
      {:cont, {:ok, candidate}}
    else
      {:halt, {:error, {:unsafe_directory_component, candidate}}}
    end
  end

  defp trusted_owner?(stat), do: stat.uid == 0

  defp launchctl(args), do: LifecycleNative.run_command("/bin/launchctl", args, 5_000)

  defp not_found?(output) do
    String.contains?(output, "Could not find service") or
      String.contains?(output, "service not found")
  end

  defp summary(output) do
    output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil -> "no output"
      line -> line
    end
  end
end
