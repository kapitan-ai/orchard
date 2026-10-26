defmodule Orchard.RuntimeEndpoint.WorkerRecoveryCheckpoint do
  @moduledoc """
  Bounded wire record for the Node-owned SPEC §12.2 recovery checkpoint.

  Monotonic times are diagnostic values within `epoch`, never Unix timestamps.
  This record contains no model artifacts or Request data.
  """

  @states ~w(armed backoff restarting open recovery_required)
  @phases ~w(resolved loading loaded recovery cleanup operator_terminated)
  @fields ~w(epoch state delay_index crashes stable_since ownership command)
  @ownership_fields ~w(phase incarnation custody)
  @command_fields ~w(id fingerprint action phase outcome)

  @type key :: %{node_id: String.t(), model_id: String.t(), version: String.t()}
  @type t :: %{String.t() => term()}

  @spec validate(term()) :: :ok | {:error, :invalid_checkpoint}
  def validate(record) when is_map(record) do
    valid? =
      valid_envelope?(record) and ownership?(record["ownership"]) and command?(record["command"])

    if valid?, do: :ok, else: {:error, :invalid_checkpoint}
  end

  def validate(_record), do: {:error, :invalid_checkpoint}

  defp valid_envelope?(record) do
    Enum.sort(Map.keys(record)) == Enum.sort(@fields) and token?(record["epoch"]) and
      record["state"] in @states and record["delay_index"] in 0..6 and
      crashes?(record["crashes"]) and valid_stable_since?(record["stable_since"])
  end

  defp valid_stable_since?(nil), do: true
  defp valid_stable_since?(value), do: is_integer(value)

  @spec clean?(t()) :: boolean()
  def clean?(record) do
    record["state"] == "armed" and record["delay_index"] == 0 and
      record["crashes"] == [] and resolved?(record) and
      (is_nil(record["command"]) or record["command"]["phase"] == "completed")
  end

  @spec resolved?(t()) :: boolean()
  def resolved?(record),
    do: get_in(record, ["ownership", "phase"]) in ~w(resolved operator_terminated)

  @spec token?(term()) :: boolean()
  def token?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and String.trim(value) != ""

  @spec fingerprint(term()) :: String.t()
  def fingerprint(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp crashes?(values) when is_list(values),
    do: length(values) <= 5 and Enum.all?(values, &is_integer/1)

  defp crashes?(_values), do: false

  defp ownership?(ownership) when is_map(ownership) do
    Enum.sort(Map.keys(ownership)) == Enum.sort(@ownership_fields) and
      ownership["phase"] in @phases and
      (is_nil(ownership["incarnation"]) or token?(ownership["incarnation"])) and
      (is_nil(ownership["custody"]) or token?(ownership["custody"])) and
      (ownership["phase"] in ~w(resolved operator_terminated) or token?(ownership["incarnation"]))
  end

  defp ownership?(_ownership), do: false

  defp command?(nil), do: true

  defp command?(command) when is_map(command) do
    Enum.sort(Map.keys(command)) == Enum.sort(@command_fields) and
      token?(command["id"]) and token?(command["fingerprint"]) and
      command["action"] in ~w(clear unload reload) and
      command["phase"] in ~w(claimed cleanup loading completed) and
      command["outcome"] in [nil, "ok", "unavailable", "conflict"]
  end

  defp command?(_command), do: false
end
