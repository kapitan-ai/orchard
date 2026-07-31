defmodule Orchard.API.SentryWireDeliveryTest do
  use ExUnit.Case, async: false

  alias __MODULE__.NonExceptionCrashProcess
  alias __MODULE__.Receiver
  alias Orchard.SentryFilter
  alias Orchard.SentryLogger
  alias Orchard.SentryRelease

  defmodule Receiver do
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      {:ok, body, conn} = read_complete_body(conn, "")
      send(Keyword.fetch!(opts, :test_pid), {:sentry_envelope, body})

      status = Keyword.fetch!(opts, :status)
      response = Jason.encode!(%{id: String.duplicate("b", 32)})
      conn |> put_resp_content_type("application/json") |> send_resp(status, response)
    end

    defp read_complete_body(conn, acc) do
      case read_body(conn) do
        {:ok, body, conn} -> {:ok, acc <> body, conn}
        {:more, body, conn} -> read_complete_body(conn, acc <> body)
      end
    end
  end

  defmodule FailureIsolatedPlug do
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      event = Sentry.Event.create_event(message: "controlled rejected Sentry event")
      _result = Sentry.send_event(event, result: :sync, request_retries: [])
      send_resp(conn, 204, "")
    end
  end

  defmodule NonExceptionCrashProcess do
    use GenServer

    @crash_metadata [
      request_id: "req_wire_logger",
      worker_model: "mlx-community/qwen2.5",
      model_backend: "mlx",
      orchard_node_id: "ISSUE114_WIRE_NODE_ID"
    ]

    def start(state), do: GenServer.start(__MODULE__, state)

    @impl GenServer
    def init(state) do
      Logger.metadata(@crash_metadata)
      {:ok, state}
    end

    @impl GenServer
    def handle_cast(:crash, _state), do: exit(:ISSUE114_WIRE_EXIT_REASON)
  end

  setup do
    previous_sentry = snapshot_sentry_env()
    previous_handler = :logger.get_handler_config(Sentry.LoggerHandler)
    remove_sentry_handler()
    Sentry.Context.clear_all()

    on_exit(fn ->
      remove_sentry_handler()
      restore_sentry_env(previous_sentry)
      restore_sentry_handler(previous_handler)
      Sentry.Context.clear_all()
    end)

    :ok
  end

  test "real HTTP delivery contains only approved request, release, and stack diagnostics" do
    port = start_receiver(200)
    identity = configure_sentry(port)

    Sentry.Context.set_request_context(%{
      method: "POST",
      url: "https://orchard.local/v1/responses?token=ISSUE114_WIRE_QUERY",
      query_string: "token=ISSUE114_WIRE_QUERY",
      data: %{
        instructions: "ISSUE114_WIRE_INSTRUCTIONS",
        input: "ISSUE114_WIRE_INPUT",
        tools: [%{name: "ISSUE114_WIRE_TOOL"}],
        tool_choice: "required",
        metadata: %{customer: "ISSUE114_WIRE_CUSTOMER"}
      },
      headers: %{"authorization" => "Bearer ISSUE114_WIRE_HEADER"},
      cookies: %{"session" => "ISSUE114_WIRE_COOKIE"},
      env: %{
        "REMOTE_ADDR" => "192.0.2.42",
        "SERVER_NAME" => "ISSUE114_WIRE_HOST.local"
      }
    })

    Sentry.Context.set_user_context(%{
      username: "ISSUE114_WIRE_USERNAME",
      ip_address: "192.0.2.42"
    })

    event =
      Sentry.Event.create_event(
        exception: RuntimeError.exception("ISSUE114_WIRE_EXCEPTION_CONTEXT"),
        level: :error,
        stacktrace: [
          {Orchard.API.ResponsesController, :create, 2,
           [
             file:
               ~c"/Users/ISSUE114_WIRE_BUILDER/orchard/apps/orchard_controller/lib/orchard/api/responses_controller.ex",
             line: 24
           ]}
        ]
      )

    assert {:ok, _event_id} =
             Sentry.send_event(event, result: :sync, request_retries: [])

    assert_receive {:sentry_envelope, envelope}, 2_000
    payload = envelope_event_payload(envelope)

    assert payload["request"] == %{"method" => "POST"}
    assert payload["release"] == identity.release
    assert payload["environment"] == "issue-114-wire"
    assert payload["server_name"] == "[redacted]"
    assert payload["modules"] in [nil, %{}]

    assert payload["tags"] == %{
             "build_date" => "2026-07-30",
             "build_sha" => "abcdef1234567890",
             "orchard_app" => "controller",
             "orchard_build_channel" => "internal",
             "orchard_version" => "0.5.0-dev"
           }

    assert envelope =~ "apps/orchard_controller/lib/orchard/api/responses_controller.ex"
    refute envelope =~ "ISSUE114_WIRE_"
    refute envelope =~ "/Users/"
    refute envelope =~ "192.0.2.42"
  end

  test "receiver failure is diagnostic and does not change the Plug response" do
    port = start_receiver(500)
    _identity = configure_sentry(port)

    conn =
      :get
      |> Plug.Test.conn("/health/live")
      |> FailureIsolatedPlug.call(FailureIsolatedPlug.init([]))

    assert conn.status == 204
    assert conn.resp_body == ""
    assert Process.alive?(self())
    assert_receive {:sentry_envelope, _envelope}, 2_000
  end

  test "real Logger crash without an exception keeps thread frames and curated metadata" do
    port = start_receiver(200)
    _identity = configure_sentry(port)
    :ok = SentryLogger.install_handler()

    {:ok, pid} = NonExceptionCrashProcess.start("ISSUE114_WIRE_GENSERVER_STATE")
    ref = Process.monitor(pid)
    GenServer.cast(pid, :crash)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

    envelope = await_envelope("req_wire_logger")
    payload = envelope_event_payload(envelope)

    assert payload["exception"] in [nil, []]
    assert payload["message"]["formatted"] == "[Filtered]"
    assert payload["fingerprint"] in [nil, []]

    assert [thread] = payload["threads"]
    assert thread["name"] == nil
    assert thread["state"] == nil
    assert thread["held_locks"] == nil

    frames = get_in(thread, ["stacktrace", "frames"])

    assert Enum.any?(frames, &String.ends_with?(&1["function"] || "", "handle_cast/2"))
    assert Enum.all?(frames, &(&1["context_line"] == nil))

    assert payload["extra"] == %{
             "logger_metadata" => %{
               "request_id" => "req_wire_logger",
               "worker_model" => "mlx-community/qwen2.5",
               "model_backend" => "mlx"
             }
           }

    refute envelope =~ "ISSUE114_WIRE_"
    refute envelope =~ "orchard_node_id"
    refute envelope =~ "logger_level"
    refute envelope =~ "genserver_state"
    refute envelope =~ "/Users/"
  end

  defp await_envelope(expected_marker, attempts \\ 5) do
    assert_receive {:sentry_envelope, envelope}, 5_000

    cond do
      envelope =~ expected_marker -> envelope
      attempts > 1 -> await_envelope(expected_marker, attempts - 1)
      true -> flunk("no delivered envelope contained #{expected_marker}")
    end
  end

  defp remove_sentry_handler do
    case :logger.remove_handler(Sentry.LoggerHandler) do
      :ok -> remove_sentry_handler()
      {:error, :not_found} -> :ok
      {:error, {:not_found, Sentry.LoggerHandler}} -> :ok
    end
  end

  defp restore_sentry_handler({:ok, %{module: module} = config}) do
    :logger.add_handler(Sentry.LoggerHandler, module, config)
  end

  defp restore_sentry_handler(_absent), do: :ok

  defp start_receiver(status) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {Receiver, test_pid: self(), status: status},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp configure_sentry(port) do
    identity =
      SentryRelease.identity("orchard_controller", "0.5.0-dev",
        build_sha: "abcdef1234567890",
        build_date: "2026-07-30",
        build_channel: "internal"
      )

    Application.put_env(:sentry, :dsn, "http://public@127.0.0.1:#{port}/1")
    Application.put_env(:sentry, :environment_name, "issue-114-wire")
    Application.put_env(:sentry, :release, identity.release)
    Application.put_env(:sentry, :tags, identity.tags)
    Application.put_env(:sentry, :before_send, {SentryFilter, :filter})
    Application.put_env(:sentry, :server_name, "[redacted]")
    Application.put_env(:sentry, :send_result, :sync)
    Application.put_env(:sentry, :test_mode, false)
    Application.put_env(:sentry, :dedup_events, false)
    Application.put_env(:sentry, :report_deps, false)
    Application.put_env(:sentry, :send_client_reports, false)
    Application.put_env(:sentry, :enable_logs, false)
    Application.put_env(:sentry, :enable_source_code_context, false)
    Application.put_env(:sentry, :traces_sample_rate, nil)
    Application.put_env(:sentry, :traces_sampler, nil)
    Application.put_env(:sentry, :finch_request_opts, receive_timeout: 1_000)
    persist_sentry_config()
    identity
  end

  defp envelope_event_payload(envelope) do
    [_envelope_header, _item_header, event_json | _rest] = String.split(envelope, "\n")
    Jason.decode!(event_json)
  end

  defp snapshot_sentry_env do
    :sentry
    |> Application.get_all_env()
    |> Map.new()
  end

  defp restore_sentry_env(previous) do
    :sentry
    |> Application.get_all_env()
    |> Keyword.keys()
    |> Enum.each(&Application.delete_env(:sentry, &1))

    Enum.each(previous, fn {key, value} -> Application.put_env(:sentry, key, value) end)
    persist_sentry_config()
  end

  defp persist_sentry_config do
    :sentry
    |> Application.get_all_env()
    |> Sentry.Config.validate!()
    |> Sentry.Config.persist()
  end
end
