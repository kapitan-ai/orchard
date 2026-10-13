defmodule Orchard.RuntimeEndpoint.RevokedCookie do
  @moduledoc """
  Supplies one unpredictable, process-local cookie for peers whose authority ended.

  Reusing one value bounds atom creation while ensuring an obsolete grant cookie
  cannot authenticate a replacement Distribution connection.
  """

  @persistent_key {__MODULE__, :value}

  @spec value() :: atom()
  def value do
    case :persistent_term.get(@persistent_key, :missing) do
      :missing -> initialize()
      cookie -> cookie
    end
  end

  defp initialize do
    lock = {@persistent_key, self()}

    :global.trans(
      lock,
      fn ->
        case :persistent_term.get(@persistent_key, :missing) do
          :missing ->
            encoded = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
            cookie = String.to_atom("orchard_revoked_#{encoded}")
            :persistent_term.put(@persistent_key, cookie)
            cookie

          cookie ->
            cookie
        end
      end,
      [node()]
    )
  end
end
