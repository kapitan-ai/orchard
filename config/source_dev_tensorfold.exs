defmodule Orchard.Config.SourceDevTensorFold do
  @moduledoc false

  # Source-dev wiring for the default-off TensorFold experiment (SPEC.md §7.2.9).
  # Loads operator profile files and keeps the Node's Worker settings within the
  # values the bridge executable accepts. Semantic profile checks (identities,
  # bindings, limits) stay with the Controller, Node and bridge validators.
  # Uses OTP :json because dev.exs may evaluate before Jason is compiled.

  @backend "tensorfold"
  @max_profile_bytes 65_536
  @controller_var "ORCHARD_TENSORFOLD_CONTROLLER_PROFILE_FILE"
  @node_var "ORCHARD_TENSORFOLD_NODE_PROFILE_FILE"
  @worker_var "ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE"

  # The only Worker settings `orchard-worker-tensorfold` accepts.
  @worker_settings [
    worker_prefix_cache_mode: {"ORCHARD_WORKER_PREFIX_CACHE_MODE", "disabled"},
    worker_prefix_cache_max_bytes: {"ORCHARD_WORKER_PREFIX_CACHE_MAX_BYTES", 0},
    worker_generation_mode: {"ORCHARD_WORKER_GENERATION_MODE", "stream"},
    worker_max_concurrent_requests_per_model:
      {"ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL", 1},
    worker_auto_max_concurrent_requests_per_model:
      {"ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL", 1},
    worker_memory_budget_mode: {"ORCHARD_WORKER_MEMORY_BUDGET_MODE", "disabled"},
    worker_memory_budget_utilization: {"ORCHARD_WORKER_MEMORY_BUDGET_UTILIZATION", 0.9},
    worker_memory_budget_overhead_bytes: {"ORCHARD_WORKER_MEMORY_BUDGET_OVERHEAD_BYTES", 0}
  ]
  @max_prefix_cache_entries 4_294_967_295

  @spec backend() :: String.t()
  def backend, do: @backend

  @spec worker_executable(String.t()) :: String.t()
  def worker_executable(repo_root),
    do:
      Path.join([
        repo_root,
        "native",
        "orchard_tensorfold_http",
        "bin",
        "orchard-worker-tensorfold"
      ])

  @doc """
  Defaults for the Node's Worker settings. TensorFold replaces the ordinary
  defaults with the only values its bridge accepts.
  """
  @spec worker_defaults(String.t(), keyword()) :: keyword()
  def worker_defaults(@backend, defaults) do
    Keyword.merge(
      defaults,
      Enum.map(@worker_settings, fn {key, {_var, value}} -> {key, value} end)
    )
  end

  def worker_defaults(_backend, defaults), do: defaults

  @doc """
  Fails when an explicit Worker setting conflicts with the TensorFold bridge.
  """
  @spec validate_worker!(String.t(), keyword()) :: :ok
  def validate_worker!(@backend, settings) do
    for {key, {var, required}} <- @worker_settings do
      actual = Keyword.fetch!(settings, key)

      unless actual == required do
        raise "#{var} must be #{required} when ORCHARD_WORKER_BACKEND=#{@backend}, got: #{inspect(actual)}"
      end
    end

    entries = Keyword.fetch!(settings, :worker_prefix_cache_max_entries)

    unless entries in 1..@max_prefix_cache_entries do
      raise "ORCHARD_WORKER_PREFIX_CACHE_MAX_ENTRIES must be 1..#{@max_prefix_cache_entries} " <>
              "when ORCHARD_WORKER_BACKEND=#{@backend}, got: #{inspect(entries)}"
    end

    :ok
  end

  def validate_worker!(_backend, _settings), do: :ok

  @doc """
  Loads the profiles the source role consumes. Unset variables keep the
  experiment off; inactive roles never open their files.
  """
  @spec profiles!(atom(), String.t(), (String.t() -> String.t() | nil)) :: %{
          controller: map() | nil,
          node: map() | nil,
          worker_profile_file: String.t() | nil
        }
  def profiles!(role, backend, path_for) do
    controller =
      if role in [:controller, :all_in_one], do: maybe_profile!(@controller_var, path_for)

    {node, worker_file} =
      if role in [:node_agent, :all_in_one],
        do: node_profiles!(backend, path_for),
        else: {nil, nil}

    %{controller: controller, node: node, worker_profile_file: worker_file}
  end

  @doc """
  Fails when Controller inference settings would reject or mis-route every
  selected request.
  """
  @spec validate_controller!(map() | nil, keyword()) :: :ok
  def validate_controller!(nil, _inference), do: :ok

  def validate_controller!(profile, inference) do
    unless Keyword.fetch!(inference, :tokenizer_safe_mode) == :off do
      raise "ORCHARD_TOKENIZER_SAFE_MODE must be off when #{@controller_var} is set"
    end

    if inference
       |> Keyword.fetch!(:cache_affinity)
       |> Keyword.fetch!(:live_fingerprint_match_enabled) do
      raise "ORCHARD_CACHE_AFFINITY_LIVE_FINGERPRINT_MATCH_ENABLED must be false when " <>
              "#{@controller_var} is set"
    end

    validate_request_limit!(profile, Keyword.fetch!(inference, :max_request_deadline_ms))
  end

  defp validate_request_limit!(%{"max_request_seconds" => seconds}, deadline_ms) do
    unless is_number(seconds) and seconds > 0 do
      raise "#{@controller_var} max_request_seconds must be a positive number"
    end

    if deadline_ms > seconds * 1000 do
      raise "ORCHARD_MAX_REQUEST_DEADLINE_MS (#{deadline_ms}) must be <= the profile " <>
              "max_request_seconds (#{seconds}) in milliseconds"
    end

    :ok
  end

  defp validate_request_limit!(_profile, _deadline_ms), do: :ok

  defp node_profiles!(@backend, path_for) do
    node = maybe_profile!(@node_var, path_for) || missing!(@node_var)
    worker_path = path_for.(@worker_var) || missing!(@worker_var)
    worker_profile!(worker_path)
    {node, worker_path}
  end

  defp node_profiles!(_backend, path_for) do
    for var <- [@node_var, @worker_var], path_for.(var) do
      raise "#{var} requires ORCHARD_WORKER_BACKEND=#{@backend}"
    end

    {nil, nil}
  end

  defp maybe_profile!(var, path_for) do
    case path_for.(var) do
      nil -> nil
      path -> read_object!(var, path)
    end
  end

  defp worker_profile!(path) do
    case read_object!(@worker_var, path) do
      %{"profile" => %{}, "bounds" => %{}, "native" => %{}} = worker when map_size(worker) == 3 ->
        worker

      _other ->
        raise "#{@worker_var} must contain exactly the profile, bounds and native objects"
    end
  end

  defp missing!(var), do: raise("#{var} is required when ORCHARD_WORKER_BACKEND=#{@backend}")

  defp read_object!(var, path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_profile_bytes + 1)) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @max_profile_bytes ->
        decode_object!(var, bytes)

      {:ok, bytes} when is_binary(bytes) ->
        raise "#{var} exceeds #{@max_profile_bytes} bytes"

      {:ok, :eof} ->
        invalid_json!(var)

      _other ->
        raise "#{var} must name a readable JSON file"
    end
  end

  defp decode_object!(var, bytes) do
    case :json.decode(bytes, :ok, %{null: nil}) do
      {%{} = object, :ok, rest} ->
        if String.trim(rest) == "", do: object, else: invalid_json!(var)

      _other ->
        raise "#{var} must contain a JSON object"
    end
  rescue
    ErlangError -> invalid_json!(var)
    ArgumentError -> invalid_json!(var)
  end

  defp invalid_json!(var), do: raise("#{var} contains invalid JSON")
end
