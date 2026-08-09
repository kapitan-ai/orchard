defmodule Orchard.API.MetricsControllerTest.RendererStub do
  @moduledoc false

  def render do
    send(Application.fetch_env!(:orchard_controller, :metrics_test_pid), :render_called)

    case Application.fetch_env!(:orchard_controller, :metrics_test_result) do
      :ok -> {:ok, "# TYPE orchard_api_key_auth_failures_total counter\n"}
      :unavailable -> {:error, :unavailable}
    end
  end
end

defmodule Orchard.API.MetricsControllerTest do
  use Orchard.ConnCase, async: false

  @moduletag :db
  @moduletag :live

  alias Orchard.Governance
  alias Orchard.Governance.RoleBinding
  alias Orchard.Repo

  setup do
    ensure_metrics_started()
    previous_renderer = Application.get_env(:orchard_controller, :metrics_renderer)
    previous_pid = Application.get_env(:orchard_controller, :metrics_test_pid)
    previous_result = Application.get_env(:orchard_controller, :metrics_test_result)

    Application.put_env(
      :orchard_controller,
      :metrics_renderer,
      Orchard.API.MetricsControllerTest.RendererStub
    )

    Application.put_env(:orchard_controller, :metrics_test_pid, self())
    Application.put_env(:orchard_controller, :metrics_test_result, :ok)

    on_exit(fn ->
      restore_env(:metrics_renderer, previous_renderer)
      restore_env(:metrics_test_pid, previous_pid)
      restore_env(:metrics_test_result, previous_result)
    end)

    :ok
  end

  test "SPEC.md §9.1 missing credentials return 401 before rendering" do
    auth_ref = attach_metric(:api_key_auth_failures)
    conn = request()

    assert_error(conn, 401, "invalid_api_key")
    assert_no_store(conn)
    refute_received :render_called
    assert_receive {^auth_ref, %{value: 1}, %{}}
    refute_receive {^auth_ref, _measurements, _metadata}
  end

  test "metrics emission timeout does not alter the HTTP authentication result" do
    admission = Process.whereis(Orchard.Metrics.SeriesAdmission)
    :ok = :sys.suspend(admission)

    on_exit(fn ->
      if Process.alive?(admission), do: :sys.resume(admission)
    end)

    conn = request()
    assert_error(conn, 401, "invalid_api_key")
    assert_no_store(conn)
    :ok = :sys.resume(admission)
  end

  test "SPEC.md §9.1 authenticated principal without cluster role returns 403 before rendering" do
    token = service_account_token_without_role!("metrics-forbidden")
    auth_ref = attach_metric(:api_key_auth_failures)
    conn = request(token)

    assert_error(conn, 403, "operator_required")
    assert_no_store(conn)
    refute_received :render_called
    refute_receive {^auth_ref, _measurements, _metadata}
  end

  test "SPEC.md §9.1 cluster operator receives Prometheus exposition on existing listener" do
    token = service_account_token!("metrics-operator", :operator)
    request_ref = attach_metric(:http_requests)
    duration_ref = attach_metric(:http_request_duration)
    conn = request(token)

    assert conn.status == 200

    assert get_resp_header(conn, "content-type") == [
             "text/plain; version=0.0.4; charset=utf-8"
           ]

    assert_no_store(conn)
    assert conn.resp_body =~ "orchard_api_key_auth_failures_total"
    assert_received :render_called

    assert_receive {^request_ref, %{value: 1},
                    %{endpoint: "metrics", method: "GET", status: "success"}}

    assert_receive {^duration_ref, %{value: duration}, %{endpoint: "metrics", status: "success"}}

    assert is_number(duration) and duration >= 0
    refute_receive {^request_ref, _measurements, _metadata}
    refute_receive {^duration_ref, _measurements, _metadata}
  end

  test "SPEC.md §9.1 HTTP labels exclude query values, headers, and raw paths" do
    request_ref = attach_metric(:http_requests)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer sensitive-token")
      |> get("/health/live?api_key=sensitive-query")

    assert conn.status == 200

    assert_receive {^request_ref, %{value: 1},
                    %{endpoint: "health", method: "GET", status: "success"}}

    refute_receive {^request_ref, _measurements, _metadata}
  end

  test "POST metrics route returns explicit no-store 405 after authorization" do
    token = service_account_token!("metrics-post", :operator)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/metrics")

    assert conn.status == 405
    assert conn.resp_body == "method not allowed\n"
    assert get_resp_header(conn, "allow") == ["GET"]
    assert_no_store(conn)
    refute_received :render_called
  end

  test "unmatched metrics subpath returns explicit no-store 404 after authorization" do
    token = service_account_token!("metrics-unmatched", :admin)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/metrics/unmatched")

    assert conn.status == 404
    assert conn.resp_body == "not found\n"
    assert_no_store(conn)
    refute_received :render_called
  end

  test "SPEC.md §9.1 unavailable rendering returns sanitized 503" do
    Application.put_env(:orchard_controller, :metrics_test_result, :unavailable)
    token = service_account_token!("metrics-unavailable", :admin)
    conn = request(token)

    assert conn.status == 503
    assert conn.resp_body == "metrics unavailable\n"
    assert_no_store(conn)
    refute conn.resp_body =~ "Orchard.Metrics"
    assert_received :render_called
  end

  defp request(token \\ nil) do
    conn = build_conn()

    conn =
      if token do
        put_req_header(conn, "authorization", "Bearer #{token}")
      else
        conn
      end

    get(conn, "/metrics")
  end

  defp assert_error(conn, status, code) do
    assert conn.status == status
    assert Jason.decode!(conn.resp_body)["error"]["code"] == code
  end

  defp assert_no_store(conn) do
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  defp service_account_token_without_role!(slug) do
    {_tenant, _api_client, token} = service_account_token_fixture!(slug)
    token
  end

  defp service_account_token!(slug, role) do
    {_tenant, api_client, token} = service_account_token_fixture!(slug)

    case role do
      :admin ->
        {:ok, _binding} = Governance.ensure_cluster_admin_access(api_client)

      :operator ->
        %RoleBinding{}
        |> RoleBinding.changeset(%{
          principal_type: :service_account,
          principal_id: api_client.id,
          role: :operator,
          tenant_scope_id: nil
        })
        |> Repo.insert!()
    end

    token
  end

  defp service_account_token_fixture!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "#{slug}-client",
        owner_contact: "owner@example.com"
      })

    {:ok, %{token: token}} =
      Governance.create_api_client_api_token(api_client, %{name: "Primary"})

    {tenant, api_client, token}
  end

  defp ensure_metrics_started do
    if Process.whereis(Orchard.Metrics.Supervisor) == nil do
      start_supervised!(Orchard.Metrics.Supervisor)
    end
  end

  defp attach_metric(family) do
    owner = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:orchard, :metrics, family],
        fn _event, measurements, metadata, _config ->
          send(owner, {ref, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)
end
