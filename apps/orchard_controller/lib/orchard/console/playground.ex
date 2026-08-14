defmodule OrchardConsole.Playground do
  @moduledoc """
  Console-facing service seam for the chat playground.

  Wraps `ChatOrchestrator.prepare/2` + `execute/3` into a console-facing
  API with async streaming and operator-safe error normalization.

  The module is injectable via `:playground_impl` in the
  `:orchard_controller, :console` config for testing.

  ## Message Contract

  `start_stream/4` sends structured messages to the owner process:

      {:playground, run_ref, :started, %{request_id: public_id}}
      {:playground, run_ref, :event, %InferenceEvent{}}
      {:playground, run_ref, :finished, {:ok, summary}}
      {:playground, run_ref, :finished, {:error, error_map}}

  The `:started` message is sent after `prepare/2` succeeds and dispatch
  begins. Events stay attempt-local until the dispatched attempt is selected
  for delivery, so the events preceding Output Commitment arrive together, in
  original order, with the committing event; later events are forwarded as they
  arrive. An attempt that never commits output flushes its retained events in
  original order when it resolves.
  `:finished` is always the last message, sent exactly once.
  """

  alias Orchard.Inference.{ChatError, ChatOrchestrator}
  alias Orchard.InferenceEvent
  alias Orchard.Models
  alias OrchardConsole.Runtime

  @type readiness_fact :: :unknown | :present | :missing
  @type placement_state :: :loaded | :none | :unknown

  @type model_option :: %{
          model_id: String.t(),
          version: String.t(),
          catalog_state: :active,
          remote_availability: readiness_fact(),
          placement_state: placement_state(),
          loaded: boolean(),
          inference_ready: boolean(),
          not_ready_reason: String.t() | nil
        }

  @type stream_error :: %{
          phase: :prepare | :execute | :stream,
          type: String.t(),
          code: String.t() | nil,
          message: String.t(),
          param: String.t() | nil
        }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Returns active models for the playground model picker with readiness facts.

  Catalog-active models are always listed. Inference readiness is projected
  from authoritative Runtime Endpoint loaded placements only. Missing or
  unknown readiness facts fail closed as non-ready.
  """
  @spec list_models() :: {:ok, [model_option()]} | {:error, map()}
  def list_models do
    readiness_index = runtime_readiness_index()

    models =
      models_impl().list_active_models()
      |> Enum.map(fn model ->
        project_model_option(
          safe_string(model.model_id),
          safe_string(model.version),
          readiness_index
        )
      end)
      |> Enum.sort_by(&{&1.model_id, &1.version})

    {:ok, models}
  rescue
    _ ->
      {:error,
       %{
         status: :error,
         code: "models_unavailable",
         message: "Active model list unavailable."
       }}
  end

  @doc """
  Returns true when a model option is authoritative inference-ready.
  """
  @spec inference_ready?(term()) :: boolean()
  def inference_ready?(%{inference_ready: true}), do: true
  def inference_ready?(_), do: false

  @doc """
  Finds a projected model option by picker value (`model_id@version`).
  """
  @spec find_model_option([model_option()], String.t()) :: model_option() | nil
  def find_model_option(models, value) when is_list(models) and is_binary(value) do
    Enum.find(models, fn model -> model_value(model) == value end)
  end

  def find_model_option(_models, _value), do: nil

  @doc """
  Canonical picker value for a model option.
  """
  @spec model_value(model_option() | map()) :: String.t()
  def model_value(%{model_id: model_id, version: version})
      when is_binary(model_id) and is_binary(version),
      do: "#{model_id}@#{version}"

  def model_value(_), do: ""

  @doc """
  Starts an async streaming chat run.

  Prepares and executes the chat request in an unlinked task. All results
  are delivered as messages to `owner` tagged with `run_ref`.

  The `owner` pid is passed as the `:caller` option to
  `ChatOrchestrator.execute/3` so the dispatcher cancels the inference
  if the LiveView process exits.

  Returns `{:ok, pid}` immediately.
  """
  @spec start_stream(pid(), term(), map(), keyword()) :: {:ok, pid()}
  def start_stream(owner, run_ref, params, caller_context \\ []) do
    orchestrator = orchestrator_impl()

    Task.start(fn ->
      run_stream(orchestrator, owner, run_ref, params, caller_context)
    end)
  end

  # ===========================================================================
  # Stream task body
  # ===========================================================================

  defp run_stream(orchestrator, owner, run_ref, params, caller_context) do
    case ensure_model_inference_ready(params) do
      :ok ->
        do_run_stream(orchestrator, owner, run_ref, params, caller_context)

      {:error, error} ->
        send(owner, {:playground, run_ref, :finished, {:error, error}})
    end
  rescue
    exception ->
      error = %{
        phase: :execute,
        type: "server_error",
        code: "internal_error",
        message: "Unexpected error: #{Exception.message(exception)}",
        param: nil
      }

      send(owner, {:playground, run_ref, :finished, {:error, error}})
  end

  defp do_run_stream(orchestrator, owner, run_ref, params, caller_context) do
    case orchestrator.prepare(params, caller_context) do
      {:ok, canonical, model} ->
        send(owner, {:playground, run_ref, :started, %{request_id: canonical.public_id}})

        event_handler = fn _request_id, event ->
          bridge_event(owner, run_ref, event)
        end

        case orchestrator.execute(canonical, model,
               event_handler: event_handler,
               caller: owner
             ) do
          {:ok, canonical_result, events} ->
            send(
              owner,
              {:playground, run_ref, :finished,
               {:ok, %{canonical_request: canonical_result, events: events}}}
            )

          {:error, reason} ->
            error = normalize_error(:execute, reason)
            send(owner, {:playground, run_ref, :finished, {:error, error}})
        end

      {:error, reason} ->
        error = normalize_error(:prepare, reason)
        send(owner, {:playground, run_ref, :finished, {:error, error}})
    end
  end

  defp ensure_model_inference_ready(params) when is_map(params) do
    model_value = params |> Map.get("model", "") |> to_string() |> String.trim()

    case list_models() do
      {:ok, models} ->
        case find_model_option(models, model_value) do
          %{inference_ready: true} ->
            :ok

          %{not_ready_reason: reason} = _option
          when is_binary(reason) and reason != "" ->
            {:error, unready_stream_error(reason)}

          %{} ->
            {:error,
             unready_stream_error(
               "Selected model is not inference-ready. Catalog-active is not enough to send."
             )}

          nil ->
            {:error, unready_stream_error("Selected model is not available in the catalog.")}
        end

      {:error, _error} ->
        {:error, unready_stream_error("Active model list unavailable.")}
    end
  end

  defp ensure_model_inference_ready(_params) do
    {:error, unready_stream_error("Selected model is not inference-ready.")}
  end

  defp unready_stream_error(message) do
    %{
      phase: :prepare,
      type: "invalid_request_error",
      code: "model_not_ready",
      message: message,
      param: "model"
    }
  end

  # ===========================================================================
  # Event bridge
  # ===========================================================================

  defp bridge_event(owner, run_ref, %InferenceEvent{} = event) do
    if Process.alive?(owner) do
      send(owner, {:playground, run_ref, :event, event})
      :ok
    else
      :cancel
    end
  end

  # ===========================================================================
  # Error normalization
  # ===========================================================================

  defp normalize_error(:prepare, reason) do
    mapping = reason |> ChatError.from_prepare_reason() |> ChatError.api_mapping()

    %{
      phase: :prepare,
      type: mapping.type,
      code: mapping.code,
      message: mapping.message,
      param: mapping.param
    }
  end

  defp normalize_error(:execute, reason) do
    mapping = reason |> ChatError.from_execute_error() |> ChatError.api_mapping()

    %{
      phase: :execute,
      type: mapping.type,
      code: mapping.code,
      message: mapping.message,
      param: mapping.param
    }
  end

  # ===========================================================================
  # Readiness projection
  # ===========================================================================

  defp project_model_option(model_id, version, readiness_index) do
    key = {model_id, version}

    case readiness_index do
      %{status: status, loaded: loaded_set} when status in [:observed, :partial] ->
        cond do
          MapSet.member?(loaded_set, key) ->
            %{
              model_id: model_id,
              version: version,
              catalog_state: :active,
              remote_availability: :present,
              placement_state: :loaded,
              loaded: true,
              inference_ready: true,
              not_ready_reason: nil
            }

          status == :partial ->
            %{
              model_id: model_id,
              version: version,
              catalog_state: :active,
              remote_availability: :unknown,
              placement_state: :unknown,
              loaded: false,
              inference_ready: false,
              not_ready_reason:
                "Readiness partially observed. Playground cannot confirm a loaded placement for this model."
            }

          true ->
            %{
              model_id: model_id,
              version: version,
              catalog_state: :active,
              remote_availability: :unknown,
              placement_state: :none,
              loaded: false,
              inference_ready: false,
              not_ready_reason:
                "Catalog-active, but no loaded placement on any ready node. Catalog activation is not runtime readiness."
            }
        end

      %{status: :unknown} ->
        %{
          model_id: model_id,
          version: version,
          catalog_state: :active,
          remote_availability: :unknown,
          placement_state: :unknown,
          loaded: false,
          inference_ready: false,
          not_ready_reason:
            "Readiness unknown. Playground cannot confirm a loaded placement for this model."
        }
    end
  end

  defp runtime_readiness_index do
    snapshots = runtime_snapshots()
    successful = Enum.filter(snapshots, &successful_snapshot?/1)

    cond do
      successful == [] ->
        %{status: :unknown}

      length(successful) == length(snapshots) ->
        %{status: :observed, loaded: loaded_identity_set(successful)}

      true ->
        %{status: :partial, loaded: loaded_identity_set(successful)}
    end
  end

  defp runtime_snapshots do
    case runtime_impl().cluster_snapshot() do
      snapshots when is_list(snapshots) -> snapshots
      _other -> []
    end
  rescue
    _ -> []
  catch
    _kind, _reason -> []
  end

  defp successful_snapshot?(snapshot) do
    value(snapshot, :status) in [:ok, "ok"]
  end

  defp loaded_identity_set(snapshots) do
    snapshots
    |> Enum.flat_map(&List.wrap(value(&1, :loaded_models)))
    |> Enum.reduce(MapSet.new(), &put_loaded_identity/2)
  end

  defp put_loaded_identity(model, identities) do
    model_id = safe_string(value(model, :model_id))
    version = safe_string(value(model, :version))

    if model_id == "" or version == "" do
      identities
    else
      MapSet.put(identities, {model_id, version})
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value(_other, _key), do: nil

  # ===========================================================================
  # Config seam
  # ===========================================================================

  defp models_impl do
    console_config()[:playground_models_impl] || Models
  end

  defp orchestrator_impl do
    console_config()[:playground_orchestrator_impl] || ChatOrchestrator
  end

  defp runtime_impl do
    console_config()[:playground_runtime_impl] ||
      console_config()[:runtime_impl] ||
      Runtime
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(_), do: ""
end
