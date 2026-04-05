defmodule OrchardShared do
  @moduledoc """
  Shared Orchard types and helpers that can be reused across releases.
  """

  @spec version() :: String.t()
  def version do
    case Application.spec(:orchard_shared, :vsn) do
      nil -> "dev"
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      vsn -> to_string(vsn)
    end
  end
end
