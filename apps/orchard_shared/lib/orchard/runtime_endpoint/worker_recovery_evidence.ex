defmodule Orchard.RuntimeEndpoint.WorkerRecoveryEvidence do
  @moduledoc "Bounded transport projection of exact-placement recovery evidence (SPEC §12.2)."
  alias Orchard.RuntimeEndpoint.{ModelRef, Placement}

  @doc "Attaches retained recovery records without representing absent workers as loaded."
  @spec attach([Placement.t()], [map()]) :: [Placement.t()]
  def attach(loaded, records) do
    projected =
      Enum.flat_map(records, fn record ->
        with {:ok, ref} <- ModelRef.new(value(record, :model_ref)),
             json when is_binary(json) and byte_size(json) > 0 <-
               value(record, :worker_recovery_json) do
          evidence = decode(json)

          [
            Placement.new(%{
              model_ref: ref,
              state: placement_state(evidence),
              worker_recovery: evidence
            })
          ]
        else
          _ -> []
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
            _ -> %{"invalid" => "duplicate"}
          end

        %{placement | worker_recovery: evidence}
      end)

    mapped ++ Enum.reject(projected, &MapSet.member?(loaded_keys, key(&1.model_ref)))
  end

  @doc "Decodes only a bounded object; eligibility validation belongs to the consumer."
  @spec decode(term()) :: map() | nil
  def decode(json) when is_binary(json) and byte_size(json) <= 4096 do
    case Jason.decode(json) do
      {:ok, %{} = evidence} -> evidence
      _ -> nil
    end
  end

  def decode(_), do: nil

  @doc "Retains only bounded non-content recovery fields for durable observation payloads."
  @spec normalize(term()) :: map() | nil
  def normalize(evidence) when is_map(evidence) do
    key = value(evidence, :key)

    if is_map(key) do
      projection =
        Map.new(
          [:epoch, :owner_epoch, :revision, :state, :hydrated, :eligible, :reason],
          fn field -> {Atom.to_string(field), value(evidence, field)} end
        )

      exact_key =
        Map.new([:node_id, :model_id, :version], fn field ->
          {Atom.to_string(field), value(key, field)}
        end)

      projection = Map.put(projection, "key", exact_key)

      with true <- Enum.all?(Map.values(exact_key), &(is_binary(&1) and byte_size(&1) in 1..256)),
           {:ok, json} <- Jason.encode(projection),
           true <- byte_size(json) <= 4096,
           decoded = Jason.decode!(json),
           true <- valid_fields?(decoded) do
        decoded
      else
        _ -> nil
      end
    end
  end

  def normalize(_evidence), do: nil

  defp valid_fields?(record) do
    bounded_token?(record["epoch"], 128) and valid_owner_epoch?(record["owner_epoch"]) and
      valid_revision?(record["revision"]) and valid_policy?(record)
  end

  defp valid_owner_epoch?(nil), do: true
  defp valid_owner_epoch?(epoch), do: bounded_token?(epoch, 128)

  defp valid_revision?(revision), do: is_integer(revision) and revision >= 0

  defp valid_policy?(record) do
    record["state"] in ~w(armed backoff restarting open recovery_required) and
      is_boolean(record["hydrated"]) and is_boolean(record["eligible"]) and
      valid_reason?(record["reason"])
  end

  defp valid_reason?(reason) do
    reason in [
      nil,
      "worker_restart_backoff",
      "worker_restart_in_progress",
      "placement_crash_breaker_open",
      "placement_recovery_required"
    ]
  end

  defp bounded_token?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max

  defp placement_state(%{"state" => state}) when state in ~w(backoff open recovery_required),
    do: :failed

  defp placement_state(%{"state" => "restarting"}), do: :loading
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

  defp value(_, _), do: nil
end
