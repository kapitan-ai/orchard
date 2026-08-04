defmodule Orchard.API.SentryCrashCaptureTest do
  use Orchard.ConnCase, async: false

  @moduletag :db

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.API.RequestContext
  alias Orchard.API.SentryContextBoundary
  alias Orchard.Governance
  alias Orchard.Licensing
  alias Orchard.Repo
  alias Orchard.SentryContext
  alias Orchard.SentryLogger
  alias Orchard.SentryRelease

  alias __MODULE__.{
    BackgroundCrash,
    BackgroundCrashProcess,
    ControlledCrash,
    CrashingRequestProcess
  }

  defmodule ControlledCrash do
    defexception message: "controlled request-process crash"
  end

  defmodule BackgroundCrash do
    defexception message: "controlled background-process crash"
  end

  defmodule BackgroundCrashProcess do
    use GenServer

    def start, do: GenServer.start(__MODULE__, nil)
    def crash(pid), do: GenServer.cast(pid, :crash)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast(:crash, state) do
      SentryContext.clear_all()
      raise BackgroundCrash, message: "controlled background-process crash: #{inspect(state)}"
    end
  end

  defmodule CrashingRequestProcess do
    use GenServer

    def start(opts), do: GenServer.start(__MODULE__, opts)
    def crash(pid), do: GenServer.cast(pid, :crash)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_cast(:crash, opts) do
      token = :persistent_term.get(Keyword.fetch!(opts, :token_ref))
      SentryContext.clear_all()

      conn =
        :get
        |> Plug.Test.conn("/v1/models")
        |> SentryContextBoundary.call([])
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> RequestContext.call([])

      if conn.halted do
        raise "request context halted before controlled Sentry crash"
      end

      raise ControlledCrash
    end
  end

  setup do
    previous_sentry = snapshot_sentry_env()
    previous_enrichment = Application.get_env(:orchard_shared, :sentry_enrichment)
    previous_handler = :logger.get_handler_config(Sentry.LoggerHandler)

    remove_sentry_handler()
    SentryContext.clear_all()
    SentryContext.clear_cached_license_status()

    sentry_identity =
      SentryRelease.identity("orchard_controller", "0.5.0-dev",
        build_sha: "abcdef1234567890",
        build_date: "2026-07-30",
        build_channel: "internal"
      )

    Application.put_env(:sentry, :dsn, "https://public@example.invalid/1")
    Application.put_env(:sentry, :before_send, {Orchard.SentryFilter, :filter})
    Application.put_env(:sentry, :release, sentry_identity.release)
    Application.put_env(:sentry, :tags, sentry_identity.tags)
    Application.put_env(:sentry, :send_result, :none)
    Application.put_env(:sentry, :test_mode, true)
    persist_sentry_config()

    Application.put_env(:orchard_shared, :sentry_enrichment,
      enabled?: true,
      controller_enabled?: true,
      node_agent_enabled?: false,
      telemetry_breadcrumbs_enabled?: false,
      hash_secret: "controller-sentry-crash-test-secret"
    )

    :ok = Sentry.Test.start_collecting_sentry_reports()
    :ok = SentryLogger.install_handler()
    _flushed_reports = Sentry.Test.pop_sentry_reports()

    license_status = %Licensing{
      state: :valid,
      message: "License bundle is valid.",
      bundle_path: "/tmp/orchard-license.json",
      license_id: "lic_controller_sentry_crash_test",
      machine_id: "mach_controller_sentry_crash_test",
      licensee: "Controller Sentry Crash Test",
      max_machines: 2,
      metadata: %{program: "eval", reference: "phase-6"}
    }

    SentryContext.cache_license_status(license_status)

    on_exit(fn ->
      remove_sentry_handler()
      restore_sentry_env(previous_sentry)
      restore_enrichment(previous_enrichment)
      restore_sentry_handler(previous_handler)
      SentryContext.clear_all()
      SentryContext.clear_cached_license_status()
    end)

    %{license_status: license_status, sentry_identity: sentry_identity}
  end

  test "logger-captured request-process crash preserves safe controller Sentry context" do
    %{api_key: api_key, token: token, tenant: tenant} =
      create_api_key_with_token!("sentry-crash-capture")

    token_ref = {__MODULE__, make_ref()}
    :persistent_term.put(token_ref, token)
    on_exit(fn -> :persistent_term.erase(token_ref) end)

    {:ok, pid} =
      CrashingRequestProcess.start(token_ref: token_ref)

    Sandbox.allow(Repo, self(), pid)
    :ok = Sentry.Test.allow_sentry_reports(self(), pid)

    ref = Process.monitor(pid)
    CrashingRequestProcess.crash(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, {%ControlledCrash{}, _stack}}, 5_000

    event = pop_crash_report(ControlledCrash)

    assert event.source == :logger
    assert event.original_exception.__struct__ == ControlledCrash

    assert event.tags.orchard_app == "controller"
    assert event.tags.orchard_surface == "api"
    assert event.tags.orchard_license_state == "valid"
    assert event.tags.orchard_tracking_program == "eval"
    assert event.tags.orchard_tracking_reference == "phase-6"

    assert event.extra.orchard_license_state == "valid"
    assert event.extra.orchard_license_id == "lic_controller_sentry_crash_test"
    assert event.extra.orchard_tracking_program == "eval"
    assert event.extra.orchard_tracking_reference == "phase-6"
    assert event.extra.orchard_api_key_hash == SentryContext.hash_id(api_key.id)
    assert event.extra.orchard_principal_hash == SentryContext.hash_id(tenant.id)
    assert event.extra.orchard_tenant_hash == SentryContext.hash_id(tenant.id)

    assert [%{message: "auth.success", level: :info, data: %{auth_mechanism: "bearer"}}] =
             event.breadcrumbs

    refute event.extra.orchard_api_key_hash == "[Filtered]"
    refute inspect(event) =~ token
    refute inspect(event) =~ api_key.token_prefix

    {payload, envelope} = serialized_filtered_event(event)

    assert payload["extra"]["orchard_license_id"] == "lic_controller_sentry_crash_test"
    assert payload["extra"]["orchard_api_key_hash"] == SentryContext.hash_id(api_key.id)
    assert payload["extra"]["orchard_principal_hash"] == SentryContext.hash_id(tenant.id)
    assert payload["tags"]["orchard_tracking_reference"] == "phase-6"
    assert [breadcrumb] = payload["breadcrumbs"]
    assert breadcrumb["data"] == %{"auth_mechanism" => "bearer"}
    refute envelope =~ token
    refute envelope =~ api_key.token_prefix
    refute envelope =~ "/Users/"
  end

  test "logger-captured background crash retains static controller identity", %{
    sentry_identity: identity
  } do
    {:ok, pid} = BackgroundCrashProcess.start()
    :ok = Sentry.Test.allow_sentry_reports(self(), pid)

    ref = Process.monitor(pid)
    BackgroundCrashProcess.crash(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, {%BackgroundCrash{}, _stack}}, 5_000

    event = pop_crash_report(BackgroundCrash)

    assert event.source == :logger
    assert event.release == identity.release
    assert event.tags.orchard_app == "controller"
    assert event.tags.orchard_version == "0.5.0-dev"
    assert event.tags.orchard_build_channel == "internal"
    assert event.tags.build_sha == "abcdef1234567890"
    assert event.tags.build_date == "2026-07-30"
    assert event.request.method == nil
    assert event.user == %{}

    {payload, envelope} = serialized_filtered_event(event)

    assert payload["release"] == identity.release
    assert payload["tags"]["orchard_app"] == "controller"
    assert get_in(payload, ["exception", Access.at(0), "value"]) == "[Filtered]"
    refute envelope =~ "controlled background-process crash"
    refute envelope =~ "/Users/"
  end

  defp create_api_key_with_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_key(tenant.id, %{name: "Primary"})

    %{tenant: tenant, api_key: api_key, token: token}
  end

  defp pop_crash_report(exception_module, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    events = Sentry.Test.pop_sentry_reports()
    event = Enum.find(events, &crash_event?(&1, exception_module))

    cond do
      event ->
        event

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(25)
        pop_crash_report(exception_module, deadline)

      events == [] ->
        flunk("crashing process reached :DOWN but no Sentry event was collected")

      true ->
        flunk("Sentry reports were collected, but none matched #{inspect(exception_module)}")
    end
  end

  defp crash_event?(event, exception_module) do
    match?(%{__struct__: ^exception_module}, event.original_exception)
  end

  defp serialized_filtered_event(event) do
    filtered = Orchard.SentryFilter.filter(event)
    {:ok, envelope} = filtered |> Sentry.Envelope.from_event() |> Sentry.Envelope.to_binary()
    [_envelope_header, _item_header, event_json | _rest] = String.split(envelope, "\n")
    {Jason.decode!(event_json), envelope}
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

  defp restore_enrichment(nil), do: Application.delete_env(:orchard_shared, :sentry_enrichment)

  defp restore_enrichment(config),
    do: Application.put_env(:orchard_shared, :sentry_enrichment, config)

  defp remove_sentry_handler do
    case :logger.remove_handler(Sentry.LoggerHandler) do
      :ok -> remove_sentry_handler()
      {:error, :not_found} -> :ok
      {:error, {:not_found, Sentry.LoggerHandler}} -> :ok
    end
  end

  defp restore_sentry_handler({:ok, %{id: id, module: module} = handler_config}) do
    config = Map.drop(handler_config, [:id, :module])

    case :logger.add_handler(id, module, config) do
      :ok -> :ok
      {:error, {:already_exist, ^id}} -> :ok
      {:error, {:already_exists, ^id}} -> :ok
    end
  end

  defp restore_sentry_handler(_not_found), do: :ok
end
