defmodule OrchardShared do
  @moduledoc """
  Shared Orchard types and helpers that can be reused across releases.
  """

  @spec version() :: String.t()
  def version, do: "0.1.0"
end
