defmodule Orchard.Node.WorkerLaunchPolicy do
  @moduledoc """
  Per-model Worker launch policy.

  An optional JSON file, named by `ORCHARD_WORKER_MODEL_OVERRIDES_FILE`, maps
  an exact `model_id@version` to Worker settings. `resolve/3` applies the
  global Worker settings, then that model's override, and returns one fixed,
  versioned keyword list of launch options for the Worker. Strict-prefix
  checkpoints can be enabled only here, so other models on the Node keep the
  global settings.

  File format:

      {"version": 1,
       "models": [{"model_id": "org/model", "version": "v1",
                   "prefix_cache_mode": "strict_prefix",
                   "generation_mode": "stream",
                   "memory_budget_mode": "observe",
                   "strict_prefix": {"slots": 1, "slot_bytes": 1024,
                                     "budget_bytes": 1024}}]}

  A strict-prefix policy is refused unless the backend is `mlx`, generation
  mode is `stream` and memory-budget mode is `observe`. The resolver never
  rewrites a setting to make a policy valid.
  """

  alias Orchard.Cluster.V1.ModelRef

  @policy_version 1
  @file_version 1
  @strict_prefix_mode "strict_prefix"
  @entry_keys ~w(model_id version prefix_cache_mode generation_mode memory_budget_mode strict_prefix)
  @strict_keys ~w(slots slot_bytes budget_bytes reply_marker)
  @modes [
    {"prefix_cache_mode", :prefix_cache_mode, ~w(disabled kv trie strict_prefix)},
    {"generation_mode", :generation_mode, ~w(stream batch)},
    {"memory_budget_mode", :memory_budget_mode, ~w(disabled observe enforce)}
  ]
  @max_slots 8
  @uint64_max 18_446_744_073_709_551_615
  # Launch option to Worker CLI flag. The adapter writes exactly these.
  @strict_prefix_flags [
    strict_prefix_slots: "--strict-prefix-slots",
    strict_prefix_slot_bytes: "--strict-prefix-slot-bytes",
    strict_prefix_budget_bytes: "--strict-prefix-budget-bytes",
    strict_prefix_reply_marker: "--strict-prefix-reply-marker"
  ]
  @strict_option_keys Keyword.keys(@strict_prefix_flags)

  @type overrides :: %{optional({String.t(), String.t()}) => keyword()}

  @doc "Version of the resolved launch policy, recorded in every resolved option list."
  @spec policy_version() :: pos_integer()
  def policy_version, do: @policy_version

  @doc "Strict-prefix launch options and the Worker CLI flag each one becomes."
  @spec strict_prefix_flags() :: [{atom(), String.t()}]
  def strict_prefix_flags, do: @strict_prefix_flags

  @doc """
  Reads and validates the per-model settings file. `nil` or an empty path
  means no overrides.
  """
  @spec load(String.t() | nil) :: {:ok, overrides()} | {:error, String.t()}
  def load(path) when path in [nil, ""], do: {:ok, %{}}

  def load(path) when is_binary(path) do
    with {:ok, body} <- read(path),
         {:ok, document} <- decode(body),
         {:ok, entries} <- entries(document) do
      collect(entries, %{})
    end
  end

  @doc """
  Resolves the launch options for one model: global settings, then the exact
  model override. Returns an error when the result is not a valid policy.
  """
  @spec resolve(ModelRef.t(), overrides(), keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def resolve(%ModelRef{model_id: model_id, version: version}, overrides, globals) do
    override = Map.get(overrides, {model_id, version}, [])

    options =
      globals
      |> Keyword.merge(override)
      |> Keyword.put(:launch_policy_version, @policy_version)

    with :ok <- validate_override_backend(override, globals[:backend]),
         :ok <- validate_options(options) do
      {:ok, options}
    else
      {:error, message} -> {:error, "#{model_id}@#{version}: #{message}"}
    end
  end

  # Other backends, such as the TensorFold experiment, own Node-wide Worker
  # settings and check them at boot, so per-model overrides would bypass them.
  defp validate_override_backend([], _backend), do: :ok
  defp validate_override_backend(_override, "mlx"), do: :ok

  defp validate_override_backend(_override, backend),
    do: {:error, "per-model overrides require the mlx backend, got #{inspect(backend)}"}

  @doc "Resolves every override against the global settings, returning the first error."
  @spec validate_all(overrides(), keyword()) :: :ok | {:error, String.t()}
  def validate_all(overrides, globals) do
    overrides
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {model_id, version} ->
      case resolve(%ModelRef{model_id: model_id, version: version}, overrides, globals) do
        {:ok, _options} -> nil
        {:error, _message} = error -> error
      end
    end)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(body) do
    {:ok, :json.decode(body)}
  rescue
    _error -> {:error, "file is not valid JSON"}
  end

  defp entries(%{"version" => @file_version, "models" => models} = document)
       when is_list(models) do
    case Map.keys(document) -- ["version", "models"] do
      [] -> {:ok, models}
      unknown -> {:error, "unknown top-level keys #{inspect(Enum.sort(unknown))}"}
    end
  end

  defp entries(%{"version" => version}) when version != @file_version,
    do: {:error, "unsupported file version #{inspect(version)}, expected #{@file_version}"}

  defp entries(_document),
    do: {:error, ~s(expected {"version": #{@file_version}, "models": [...]})}

  defp collect([], acc), do: {:ok, acc}

  defp collect([entry | rest], acc) do
    with {:ok, key, options} <- parse_entry(entry),
         :ok <- unique(key, acc) do
      collect(rest, Map.put(acc, key, options))
    end
  end

  defp unique({model_id, version} = key, acc) do
    if Map.has_key?(acc, key),
      do: {:error, "duplicate entry for #{model_id}@#{version}"},
      else: :ok
  end

  defp parse_entry(%{"model_id" => model_id, "version" => version} = entry)
       when is_binary(model_id) and model_id != "" and is_binary(version) and version != "" do
    with :ok <- known_keys(entry, @entry_keys, "#{model_id}@#{version}"),
         {:ok, modes} <- parse_modes(entry, "#{model_id}@#{version}"),
         {:ok, strict} <- parse_strict(entry["strict_prefix"], "#{model_id}@#{version}") do
      {:ok, {model_id, version}, modes ++ strict}
    end
  end

  defp parse_entry(_entry),
    do: {:error, "each model entry needs a non-empty model_id and version"}

  defp known_keys(map, allowed, where) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, "#{where}: unknown keys #{inspect(Enum.sort(unknown))}"}
    end
  end

  defp parse_modes(entry, where) do
    Enum.reduce_while(@modes, {:ok, []}, fn mode, {:ok, acc} ->
      case parse_mode(entry, mode, where) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, option} -> {:cont, {:ok, [option | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp parse_mode(entry, {key, option, allowed}, where) do
    case Map.fetch(entry, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) -> mode_value(value, key, option, allowed, where)
      {:ok, _value} -> {:error, "#{where}: #{key} must be one of #{Enum.join(allowed, "|")}"}
    end
  end

  defp mode_value(value, key, option, allowed, where) do
    if value in allowed,
      do: {:ok, {option, value}},
      else: {:error, "#{where}: #{key} must be one of #{Enum.join(allowed, "|")}"}
  end

  defp parse_strict(nil, _where), do: {:ok, []}

  defp parse_strict(strict, where) when is_map(strict) do
    with :ok <- known_keys(strict, @strict_keys, "#{where} strict_prefix"),
         {:ok, slots} <- strict_int(strict, "slots", 1..@max_slots, where),
         {:ok, slot_bytes} <- strict_int(strict, "slot_bytes", 1..@uint64_max, where),
         {:ok, budget_bytes} <- strict_int(strict, "budget_bytes", 1..@uint64_max, where),
         {:ok, reply_marker} <- strict_marker(strict, where) do
      {:ok,
       Enum.reject(
         [
           strict_prefix_slots: slots,
           strict_prefix_slot_bytes: slot_bytes,
           strict_prefix_budget_bytes: budget_bytes,
           strict_prefix_reply_marker: reply_marker
         ],
         fn {_key, value} -> is_nil(value) end
       )}
    end
  end

  defp parse_strict(_strict, where), do: {:error, "#{where}: strict_prefix must be an object"}

  defp strict_int(strict, key, range, where) do
    case Map.get(strict, key) do
      nil -> {:ok, nil}
      value when is_integer(value) -> in_range(value, range, key, where)
      _value -> {:error, "#{where}: strict_prefix.#{key} must be an integer"}
    end
  end

  defp in_range(value, first..last//_step, key, where) do
    if value >= first and value <= last,
      do: {:ok, value},
      else: {:error, "#{where}: strict_prefix.#{key} must be between #{first} and #{last}"}
  end

  defp strict_marker(strict, where) do
    case Map.get(strict, "reply_marker") do
      nil -> {:ok, nil}
      marker when is_binary(marker) and marker != "" -> marker_without_nul(marker, where)
      _marker -> {:error, "#{where}: strict_prefix.reply_marker must be a non-empty string"}
    end
  end

  # A NUL byte cannot be passed as a Worker argument.
  defp marker_without_nul(marker, where) do
    if String.contains?(marker, <<0>>),
      do: {:error, "#{where}: strict_prefix.reply_marker must not contain a NUL byte"},
      else: {:ok, marker}
  end

  defp validate_options(options) do
    if options[:prefix_cache_mode] == @strict_prefix_mode,
      do: validate_strict(options),
      else: validate_not_strict(options)
  end

  # Models without strict-prefix settings keep today's behavior: the Worker
  # CLI still refuses its own invalid combinations, as before.
  defp validate_not_strict(options) do
    if Enum.any?(@strict_option_keys, &Keyword.has_key?(options, &1)),
      do: {:error, "strict_prefix settings require prefix_cache_mode strict_prefix"},
      else: :ok
  end

  defp validate_strict(options) do
    slots = Keyword.get(options, :strict_prefix_slots, 1)
    slot_bytes = options[:strict_prefix_slot_bytes]
    budget_bytes = options[:strict_prefix_budget_bytes]

    cond do
      options[:backend] != "mlx" ->
        {:error, "strict_prefix requires the mlx backend, got #{inspect(options[:backend])}"}

      options[:generation_mode] != "stream" ->
        {:error, "strict_prefix requires generation_mode stream"}

      options[:memory_budget_mode] != "observe" ->
        {:error, "strict_prefix requires memory_budget_mode observe"}

      is_nil(slot_bytes) or is_nil(budget_bytes) ->
        {:error, "strict_prefix requires strict_prefix.slot_bytes and strict_prefix.budget_bytes"}

      slots * slot_bytes > budget_bytes ->
        {:error, "strict_prefix budget_bytes cannot hold #{slots} slots of #{slot_bytes} bytes"}

      true ->
        :ok
    end
  end
end
