defmodule Orchard.RuntimeEndpoint.WorkerRecoveryEvidence do
  @moduledoc "Bounded exact-placement recovery evidence for SPEC §12.2 transport boundaries."

  alias Orchard.ClusterManagement.ReasonCodes
  alias Orchard.RuntimeEndpoint.{ModelRef, Placement}

  @states ~w(armed backoff restarting open recovery_required)
  @fields [:key, :epoch, :owner_epoch, :revision, :state, :hydrated, :eligible, :reason]

  @type evidence :: %{
          key: %{node_id: String.t(), model_id: String.t(), version: String.t()},
          epoch: String.t(),
          owner_epoch: String.t() | nil,
          revision: non_neg_integer(),
          state: String.t(),
          hydrated: boolean(),
          eligible: boolean(),
          reason: String.t() | nil
        }

  @doc "Returns the fixed no-execution refusal vocabulary."
  @spec reason_codes() :: [String.t()]
  def reason_codes, do: ReasonCodes.worker_recovery_reason_codes()

  @doc "Recognizes a recovery refusal without accepting arbitrary reason atoms."
  @spec refusal_reason(term()) :: {:ok, atom()} | :error
  def refusal_reason(reason) do
    normalized = ReasonCodes.normalize_code(reason)

    case Enum.find(
           ReasonCodes.worker_recovery_reason_atoms(),
           &(Atom.to_string(&1) == normalized)
         ) do
      nil -> :error
      refusal -> {:ok, refusal}
    end
  end

  @doc "Requires JSON-string state and reason values at API-facing evidence boundaries."
  @spec json_string_values?(term()) :: boolean()
  def json_string_values?(value) when is_map(value) do
    is_binary(value(value, :state)) and
      case value(value, :reason) do
        nil -> true
        reason -> is_binary(reason)
      end
  end

  def json_string_values?(_value), do: false

  @doc "Validates the state, eligibility, and reason triple plus the exact placement key."
  @spec validate(term()) :: {:ok, evidence()} | {:error, :invalid_worker_recovery_evidence}
  def validate(value) when is_map(value) do
    key = value(value, :key)
    state = normalize_state(value(value, :state))
    reason = normalize_reason(value(value, :reason))

    evidence = %{
      key: normalize_key(key),
      epoch: value(value, :epoch),
      owner_epoch: value(value, :owner_epoch),
      revision: value(value, :revision),
      state: state,
      hydrated: value(value, :hydrated),
      eligible: value(value, :eligible),
      reason: reason
    }

    if valid_evidence?(evidence),
      do: {:ok, evidence},
      else: {:error, :invalid_worker_recovery_evidence}
  end

  def validate(_value), do: {:error, :invalid_worker_recovery_evidence}

  @doc "Returns the scheduler-visible eligibility outcome for already validated evidence."
  @spec eligibility(evidence()) :: :ok | {:error, atom()}
  def eligibility(%{state: "armed", eligible: true, reason: nil}), do: :ok

  def eligibility(%{state: state, eligible: false, reason: reason}) do
    case {ReasonCodes.worker_recovery_reason_for_state(state), refusal_reason(reason)} do
      {^reason, {:ok, refusal}} -> {:error, refusal}
      _invalid -> {:error, :worker_recovery_evidence_unavailable}
    end
  end

  def eligibility(_evidence), do: {:error, :worker_recovery_evidence_unavailable}

  @doc "Encodes only validated evidence as a bounded JSON object."
  @spec encode(term()) :: {:ok, String.t()} | {:error, :invalid_worker_recovery_evidence}
  def encode(value) do
    with {:ok, evidence} <- validate(value),
         {:ok, json} <- Jason.encode(stringify(evidence)),
         true <- byte_size(json) <= 4096 do
      {:ok, json}
    else
      _invalid -> {:error, :invalid_worker_recovery_evidence}
    end
  end

  @doc "Decodes a bounded JSON-string evidence value and validates its full triple."
  @spec decode(term()) :: {:ok, evidence()} | {:error, :invalid_worker_recovery_evidence}
  def decode(json) when is_binary(json) and byte_size(json) in 1..4096 do
    case Jason.decode(json) do
      {:ok, %{} = value} -> validate(value)
      _invalid -> {:error, :invalid_worker_recovery_evidence}
    end
  end

  def decode(_json), do: {:error, :invalid_worker_recovery_evidence}

  @doc "Retains only validated, bounded recovery evidence for observations."
  @spec normalize(term()) :: map() | nil
  def normalize(value) do
    case validate(value) do
      {:ok, evidence} -> stringify(evidence)
      {:error, :invalid_worker_recovery_evidence} -> nil
    end
  end

  @doc "Attaches retained recovery records without representing absent workers as loaded."
  @spec attach([Placement.t()], [map()]) :: [Placement.t()]
  def attach(loaded, records) do
    projected =
      Enum.flat_map(records, fn record ->
        with {:ok, ref} <- ModelRef.new(value(record, :model_ref)),
             {:ok, evidence} <- decode(value(record, :worker_recovery_json)) do
          [
            Placement.new(%{
              model_ref: ref,
              state: placement_state(evidence),
              worker_recovery: stringify(evidence)
            })
          ]
        else
          _invalid -> []
        end
      end)

    loaded_keys = MapSet.new(loaded, &key(&1.model_ref))

    mapped =
      Enum.map(loaded, fn placement ->
        matches = Enum.filter(projected, &ModelRef.equal?(&1.model_ref, placement.model_ref))

        evidence =
          case matches do
            [record] -> record.worker_recovery
            [] -> nil
            _conflicting -> %{"invalid" => "duplicate"}
          end

        %{placement | worker_recovery: evidence}
      end)

    mapped ++ Enum.reject(projected, &MapSet.member?(loaded_keys, key(&1.model_ref)))
  end

  defp valid_evidence?(evidence) do
    valid_key?(evidence.key) and bounded_token?(evidence.epoch, 128) and
      valid_owner_epoch?(evidence.owner_epoch) and valid_revision?(evidence.revision) and
      is_boolean(evidence.hydrated) and valid_policy?(evidence)
  end

  defp valid_key?(%{node_id: node_id, model_id: model_id, version: version}) do
    Enum.all?([node_id, model_id, version], &bounded_token?(&1, 256))
  end

  defp valid_key?(_key), do: false

  defp valid_owner_epoch?(nil), do: true
  defp valid_owner_epoch?(epoch), do: bounded_token?(epoch, 128)

  defp valid_revision?(revision), do: is_integer(revision) and revision >= 0

  defp valid_policy?(%{state: "armed", eligible: true, reason: nil}), do: true

  defp valid_policy?(%{state: state, eligible: false, reason: reason}) do
    state in (@states -- ["armed"]) and
      ReasonCodes.worker_recovery_reason_for_state(state) == reason
  end

  defp valid_policy?(_evidence), do: false

  defp normalize_key(key) when is_map(key) do
    %{
      node_id: value(key, :node_id),
      model_id: value(key, :model_id),
      version: value(key, :version)
    }
  end

  defp normalize_key(_key), do: %{}

  defp normalize_state(state) when is_atom(state), do: Atom.to_string(state)
  defp normalize_state(state) when is_binary(state), do: state
  defp normalize_state(_state), do: nil

  defp normalize_reason(nil), do: nil
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(_reason), do: nil

  defp stringify(evidence) do
    Map.new(@fields, fn field ->
      {Atom.to_string(field), stringify_field(field, Map.fetch!(evidence, field))}
    end)
  end

  defp stringify_field(:key, key),
    do: Map.new(key, fn {field, value} -> {Atom.to_string(field), value} end)

  defp stringify_field(_field, value), do: value

  defp bounded_token?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.trim(value) != ""

  defp placement_state(%{state: state}) when state in ["backoff", "open", "recovery_required"],
    do: :failed

  defp placement_state(%{state: "restarting"}), do: :loading
  defp placement_state(_evidence), do: :unknown

  defp key(ref), do: {ref.model_id, ref.version}

  defp value(map, key) when is_map(map) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, value}, {:ok, value}} -> value
      {{:ok, _left}, {:ok, _right}} -> :conflicting
      {{:ok, value}, :error} -> value
      {:error, {:ok, value}} -> value
      {:error, :error} -> nil
    end
  end

  defp value(_map, _key), do: nil
end
