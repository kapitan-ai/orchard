defmodule Orchard.RuntimeEndpoint.BeamPeerConnectionLock do
  @moduledoc """
  Serializes exact-peer cookie, connection, and forced-disconnect transitions locally.
  """

  @spec transact(node(), (-> result)) :: result when result: term()
  def transact(peer, fun) when is_atom(peer) and is_function(fun, 0) do
    :global.trans({{__MODULE__, peer}, self()}, fun, [node()])
  end
end
