defmodule Orchard.API.StreamKeepaliveTest do
  # SPEC.md §5.9: a closed client socket found by a failed keepalive write is a
  # caller disconnect. Nothing is written after the stream closed, errored or
  # reached its terminal.
  use ExUnit.Case, async: true

  alias Orchard.API.InferenceControllerSupport

  defmodule ClosedSocketAdapter do
    @moduledoc false

    alias Plug.Adapters.Test.Conn

    def chunk(_state, _body), do: {:error, :closed}

    defdelegate send_chunked(state, status, headers), to: Conn
  end

  setup do
    conn = Plug.Test.conn(:post, "/v1/chat/completions") |> Plug.Conn.send_chunked(200)
    %{conn: conn, state_key: make_ref()}
  end

  test "an open stream writes one SSE comment and stays open", %{conn: conn, state_key: key} do
    Process.put(key, %{conn: conn, closed: false})

    assert run_keepalive(key) == :ok
    assert %{closed: false, conn: %Plug.Conn{resp_body: ": keepalive\n\n"}} = Process.get(key)
  end

  test "a failed write marks the stream closed and cancels", %{conn: conn, state_key: key} do
    {_adapter, payload} = conn.adapter
    Process.put(key, %{conn: %{conn | adapter: {ClosedSocketAdapter, payload}}, closed: false})

    assert run_keepalive(key) == :cancel
    assert %{closed: true} = Process.get(key)
  end

  test "a closed stream cancels without writing", %{conn: conn, state_key: key} do
    Process.put(key, %{conn: conn, closed: true})

    assert run_keepalive(key) == :cancel
    assert Process.get(key).conn.resp_body in [nil, ""]
  end

  test "a terminal or errored stream writes nothing", %{conn: conn, state_key: key} do
    for state <- [
          %{conn: conn, closed: false, terminal_sent: true},
          %{conn: conn, closed: false, errored: true}
        ] do
      Process.put(key, state)

      assert run_keepalive(key) == :ok
      assert Process.get(key) == state
    end
  end

  test "a cleared stream state writes nothing", %{state_key: key} do
    assert run_keepalive(key) == :ok
    assert Process.get(key) == nil
  end

  defmodule ProbingPlug do
    @moduledoc false
    # Streams like a silent inference request: start SSE, then probe until the
    # keepalive reports a closed socket or the probe budget runs out.

    alias Orchard.API.{InferenceControllerSupport, SSE}

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, conn} = SSE.start(conn)
      state_key = make_ref()
      Process.put(state_key, %{conn: conn, closed: false})

      probe =
        Keyword.fetch!(
          InferenceControllerSupport.stream_keepalive_opts(state_key),
          :keepalive_handler
        )

      send(test_pid, {:probe_result, probe_until_cancel(probe, 1)})
      Process.get(state_key).conn
    end

    defp probe_until_cancel(_probe, 300), do: :never_cancelled

    defp probe_until_cancel(probe, attempt) do
      case probe.() do
        :cancel ->
          {:cancel, attempt}

        :ok ->
          Process.sleep(10)
          probe_until_cancel(probe, attempt + 1)
      end
    end
  end

  test "a closed client socket makes a later keepalive write fail on a real Bandit connection" do
    server =
      start_supervised!(
        {Bandit, plug: {ProbingPlug, self()}, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nhost: localhost\r\n\r\n")
    assert read_until(socket, ": keepalive", "") =~ "text/event-stream"
    :ok = :gen_tcp.close(socket)

    assert_receive {:probe_result, {:cancel, attempt}}, 5_000
    assert attempt > 1
  end

  test "the interval comes from the inference configuration", %{state_key: key} do
    opts = InferenceControllerSupport.stream_keepalive_opts(key)

    assert Keyword.fetch!(opts, :keepalive_interval_ms) ==
             Orchard.Inference.sse_keepalive_interval_ms()
  end

  defp read_until(socket, marker, acc) do
    if String.contains?(acc, marker) do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      read_until(socket, marker, acc <> data)
    end
  end

  defp run_keepalive(state_key) do
    state_key
    |> InferenceControllerSupport.stream_keepalive_opts()
    |> Keyword.fetch!(:keepalive_handler)
    |> then(& &1.())
  end
end
