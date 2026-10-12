defmodule Orchard.RuntimeEndpoint.HostInventory do
  @moduledoc """
  Bounds the additive observation-only host inventory carried on Runtime
  Endpoint status (`SPEC.md` §4.1 and §4.6.1).

  The inventory is volatile evidence. It is not persisted in heartbeat payloads
  and creates no capacity, worker unit, allocation, device binding, readiness,
  or custody fact. An inventory outside these bounds is absent evidence: it is
  dropped whole rather than truncated, so a reader never sees a partial record
  that looks complete.
  """

  alias Orchard.Cluster.V1.{
    AcceleratorObservation,
    AcceleratorProviderObservation,
    AcceleratorRuntimeObservation,
    HostCpuObservation,
    HostDiskObservation,
    HostEvidence,
    HostInventoryObservation,
    HostMemoryObservation,
    HostNetworkAddressObservation,
    HostNetworkInterfaceObservation,
    HostNetworkObservation,
    HostPlatformObservation
  }

  @schema_version 1
  @max_string_bytes 256
  @max_list_entries 64
  @max_encoded_bytes 131_072
  @vendors [:ACCELERATOR_VENDOR_NVIDIA, :ACCELERATOR_VENDOR_AMD]
  @max_field_number 536_870_911
  @uint64_max 18_446_744_073_709_551_615
  @messages [
    AcceleratorObservation,
    AcceleratorProviderObservation,
    AcceleratorRuntimeObservation,
    HostCpuObservation,
    HostDiskObservation,
    HostEvidence,
    HostInventoryObservation,
    HostMemoryObservation,
    HostNetworkAddressObservation,
    HostNetworkInterfaceObservation,
    HostNetworkObservation,
    HostPlatformObservation
  ]

  @doc "Inventory schema version understood by this reader."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Largest UTF-8 byte size of any inventory string."
  @spec max_string_bytes() :: pos_integer()
  def max_string_bytes, do: @max_string_bytes

  @doc "Largest entry count of any inventory list."
  @spec max_list_entries() :: pos_integer()
  def max_list_entries, do: @max_list_entries

  @doc """
  Returns the inventory when it is a bounded observation-only envelope of the
  known schema, otherwise `nil`.
  """
  @spec normalize(term()) :: HostInventoryObservation.t() | nil
  def normalize(
        %HostInventoryObservation{
          schema_version: @schema_version,
          authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY
        } = inventory
      ) do
    if bounded?(inventory) and distinct_vendors?(inventory) and round_trips?(inventory),
      do: inventory
  end

  def normalize(_inventory), do: nil

  defp bounded?(%module{} = message) when module in @messages do
    defined = module.__message_props__().field_props

    unknown_fields?(Map.get(message, :__unknown_fields__, :missing), defined, 0) and
      message
      |> Map.from_struct()
      |> Map.delete(:__unknown_fields__)
      |> Map.values()
      |> Enum.all?(&bounded?/1)
  end

  defp bounded?(value) when is_binary(value),
    do: byte_size(value) <= @max_string_bytes and String.valid?(value)

  defp bounded?(values) when is_list(values), do: bounded_list?(values, 0)

  defp bounded?(value) when is_integer(value), do: value >= 0
  defp bounded?(value) when is_atom(value), do: true
  defp bounded?(_value), do: false

  # Additive fields decoded from a newer writer are kept as protobuf wire tuples
  # whose numbers this message does not define; anything else in that slot is a
  # malformed raw BEAM term.
  defp unknown_fields?([], _defined, _count), do: true

  defp unknown_fields?([field | rest], defined, count) when count < @max_list_entries do
    unknown_field?(field) and not Map.has_key?(defined, elem(field, 0)) and
      unknown_fields?(rest, defined, count + 1)
  end

  defp unknown_fields?(_fields, _defined, _count), do: false

  # Field numbers and varint values outside the protobuf wire ranges would
  # encode into bytes the decoder rejects, so they are malformed here.
  defguardp field_number?(number)
            when is_integer(number) and number in 1..@max_field_number

  defp unknown_field?({number, 0, value})
       when field_number?(number) and is_integer(value) and value in 0..@uint64_max,
       do: true

  defp unknown_field?({number, 2, value}) when field_number?(number) and is_binary(value),
    do: true

  defp unknown_field?({number, 1, <<_::64>>}) when field_number?(number), do: true
  defp unknown_field?({number, 5, <<_::32>>}) when field_number?(number), do: true
  defp unknown_field?(_field), do: false

  # Walks at most the list bound and rejects improper lists from raw BEAM terms.
  defp bounded_list?([], _count), do: true

  defp bounded_list?([value | rest], count) when count < @max_list_entries,
    do: bounded?(value) and bounded_list?(rest, count + 1)

  defp bounded_list?(_values, _count), do: false

  defp distinct_vendors?(%HostInventoryObservation{accelerator_providers: providers})
       when is_list(providers) do
    vendors = Enum.map(providers, &provider_vendor/1)
    Enum.all?(vendors, &(&1 in @vendors)) and vendors == Enum.uniq(vendors)
  end

  defp distinct_vendors?(_inventory), do: false

  defp provider_vendor(%AcceleratorProviderObservation{vendor: vendor}), do: vendor
  defp provider_vendor(_provider), do: nil

  defp round_trips?(inventory) do
    encoded = HostInventoryObservation.encode(inventory)

    byte_size(encoded) <= @max_encoded_bytes and
      HostInventoryObservation.decode(encoded) == inventory
  rescue
    _malformed in [Protobuf.EncodeError, Protobuf.DecodeError] -> false
  end
end
