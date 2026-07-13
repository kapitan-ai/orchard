defmodule Orchard.PrivateIpv4 do
  @moduledoc """
  Shared RFC 1918 private IPv4 range predicate for Controller BEAM peer-grant
  address validation.
  """

  @spec private?(:inet.ip4_address()) :: boolean()
  def private?({10, _b, _c, _d}), do: true
  def private?({172, b, _c, _d}) when b in 16..31, do: true
  def private?({192, 168, _c, _d}), do: true
  def private?(_address), do: false
end
