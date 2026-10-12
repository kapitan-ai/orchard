defmodule Orchard.TestSupport.DispatchDeadline do
  @moduledoc false

  # Lets a stub Runtime Endpoint fire the dispatcher's Request deadline at an exact
  # point in the stream instead of racing wall-clock setup time. The dispatcher arms
  # its deadline with `Process.send_after/3`; the trace captures that private timer
  # message so `fire/1` can deliver it once the stub has queued its events.

  @spec capture(pid()) :: :trace.session()
  def capture(owner \\ self()) do
    forwarder = spawn_link(fn -> forward_timer(owner) end)
    session = :trace.session_create(__MODULE__, forwarder, [])
    1 = :trace.process(session, owner, true, [:call])

    1 =
      :trace.function(
        session,
        {:erlang, :send_after, 4},
        [{[:_, :_, {:dispatch_timeout, :_}, :_], [], []}],
        [:global]
      )

    session
  end

  @doc "Must run in the dispatcher process passed to `capture/1`."
  @spec fire(:trace.session()) :: :ok
  def fire(session) do
    receive do
      {__MODULE__, :armed, timer_ref} ->
        :trace.session_destroy(session)
        send(self(), {:dispatch_timeout, timer_ref})
        :ok
    after
      5_000 -> raise "dispatch deadline timer was not armed"
    end
  end

  defp forward_timer(owner) do
    receive do
      {:trace, ^owner, :call, {:erlang, :send_after, [_time, ^owner, {_tag, timer_ref}, _opts]}} ->
        send(owner, {__MODULE__, :armed, timer_ref})
    end
  end
end
