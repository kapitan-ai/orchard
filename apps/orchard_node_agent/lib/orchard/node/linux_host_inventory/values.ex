defmodule Orchard.Node.LinuxHostInventory.Values do
  @moduledoc """
  Bounded value parsing and evidence provenance shared by the Linux host
  inventory sections.

  Oversized or invalid text is never truncated into a plausible value; callers
  receive `:invalid` and record partial or error evidence instead.
  """

  alias Orchard.Cluster.V1.HostEvidence
  alias Orchard.RuntimeEndpoint.HostInventory, as: InventoryBound

  @uint32_max 4_294_967_295
  @uint64_max 18_446_744_073_709_551_615

  @type state :: :observed | :absent | :partial | :error

  @doc "Builds bounded provenance for one observation section."
  @spec evidence(state(), String.t(), non_neg_integer(), String.t() | atom()) :: HostEvidence.t()
  def evidence(state, source, now_ms, error_code \\ "") do
    %HostEvidence{
      state: evidence_state(state),
      source: source,
      observed_at_unix_ms: now_ms,
      error_code: code(error_code)
    }
  end

  @doc "Evidence state for a failed probe: missing inputs are absent, the rest are errors."
  @spec failure_state(atom()) :: :absent | :error
  def failure_state(reason) when reason in [:missing_tool, :enoent, :guardian_unavailable],
    do: :absent

  def failure_state(_reason), do: :error

  @doc "Accepts bounded valid UTF-8 text; `nil` is empty and anything else is invalid."
  @spec text(term()) :: {:ok, String.t()} | :invalid
  def text(nil), do: {:ok, ""}

  def text(value) when is_binary(value) do
    if byte_size(value) <= InventoryBound.max_string_bytes() and String.valid?(value),
      do: {:ok, value},
      else: :invalid
  end

  def text(_value), do: :invalid

  @doc "Bounds every value in `raw`, returning the texts and whether any was invalid."
  @spec texts(%{atom() => term()}) :: {%{atom() => String.t()}, boolean()}
  def texts(raw) do
    Enum.reduce(raw, {%{}, false}, fn {key, value}, {texts, invalid?} ->
      case text(value) do
        {:ok, bounded} -> {Map.put(texts, key, bounded), invalid?}
        :invalid -> {Map.put(texts, key, ""), true}
      end
    end)
  end

  @doc "Parses a non-negative integer without accepting trailing data."
  @spec non_negative_integer(term()) :: non_neg_integer() | nil
  def non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  def non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  def non_negative_integer(_value), do: nil

  @doc "Parses an unsigned 32-bit integer."
  @spec uint32(term()) :: non_neg_integer() | nil
  def uint32(value), do: at_most(non_negative_integer(value), @uint32_max)

  @doc "Parses an unsigned 64-bit integer."
  @spec uint64(term()) :: non_neg_integer() | nil
  def uint64(value), do: at_most(non_negative_integer(value), @uint64_max)

  @doc "Multiplies two unsigned 32-bit values, or `nil` on overflow or absence."
  @spec multiply_uint32(non_neg_integer() | nil, non_neg_integer() | nil) ::
          non_neg_integer() | nil
  def multiply_uint32(a, b) when is_integer(a) and is_integer(b), do: at_most(a * b, @uint32_max)
  def multiply_uint32(_a, _b), do: nil

  defp at_most(value, maximum) when is_integer(value) and value <= maximum, do: value
  defp at_most(_value, _maximum), do: nil

  defp code(value) when is_atom(value), do: Atom.to_string(value)
  defp code(value) when is_binary(value), do: value

  defp evidence_state(:observed), do: :HOST_EVIDENCE_STATE_OBSERVED
  defp evidence_state(:absent), do: :HOST_EVIDENCE_STATE_ABSENT
  defp evidence_state(:partial), do: :HOST_EVIDENCE_STATE_PARTIAL
  defp evidence_state(:error), do: :HOST_EVIDENCE_STATE_ERROR
end
