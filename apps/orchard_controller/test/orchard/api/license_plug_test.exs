defmodule Orchard.API.LicensePlugTest do
  use Orchard.ConnCase, async: false

  @moduletag :db

  alias Orchard.API.Endpoint
  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Licensing.Gate

  @fixture_dir Path.expand("../../../../orchard_shared/test/fixtures/licensing", __DIR__)
  @public_key_hex "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
  @local_node_id "11111111-2222-4333-8444-555555555555"
  @allowed_origin "http://trusted.local:3000"

  setup do
    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "orchard-controller-license-plug-test",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    bundle_path = Path.join([tmp_dir, "config", "licensing", "current.json"])
    node_identity_path = Path.join([tmp_dir, "data", "node-id"])
    previous_licensing = Application.get_env(:orchard_shared, :licensing, [])
    previous_endpoint = Application.get_env(:orchard_controller, Endpoint, [])

    previous_transport_cert_source =
      Application.get_env(:orchard_controller, :transport_cert_source)

    Application.put_env(
      :orchard_shared,
      :licensing,
      Keyword.merge(previous_licensing,
        bundle_path: bundle_path,
        node_identity_path: node_identity_path,
        keygen_public_key: @public_key_hex,
        gate_cache_ttl_seconds: 0
      )
    )

    write_node_identity!(node_identity_path, @local_node_id)
    Gate.refresh()

    on_exit(fn ->
      Gate.refresh()
      Application.put_env(:orchard_shared, :licensing, previous_licensing)
      Application.put_env(:orchard_controller, Endpoint, previous_endpoint)

      Application.put_env(
        :orchard_controller,
        :transport_cert_source,
        previous_transport_cert_source
      )

      File.rm_rf!(tmp_dir)
    end)

    %{bundle_path: bundle_path, tmp_dir: tmp_dir}
  end

  test "hard mode with a missing bundle keeps unauthenticated /v1 routes at 401" do
    put_enforcement_mode(:hard)
    Gate.refresh()

    chat_params = %{
      "model" => "test-model@v1",
      "messages" => [%{"role" => "user", "content" => "hello"}]
    }

    responses_params = %{"model" => "test-model@v1", "input" => "hello"}

    assert_auth_denial(get_models_without_auth())
    assert_auth_denial(post_without_auth("/v1/chat/completions", chat_params))
    assert_auth_denial(post_without_auth("/v1/responses", responses_params))
  end

  test "hard mode with a missing bundle keeps invalid bearer /v1 routes at 401" do
    put_enforcement_mode(:hard)
    Gate.refresh()

    chat_params = %{
      "model" => "test-model@v1",
      "messages" => [%{"role" => "user", "content" => "hello"}]
    }

    responses_params = %{"model" => "test-model@v1", "input" => "hello"}

    assert_auth_denial(get_with_auth("/v1/models", "invalid-token"))
    assert_auth_denial(post_with_auth("/v1/chat/completions", chat_params, "invalid-token"))
    assert_auth_denial(post_with_auth("/v1/responses", responses_params, "invalid-token"))
  end

  test "hard mode with a missing bundle denies authenticated /v1/models callers" do
    put_enforcement_mode(:hard)
    Gate.refresh()

    conn = get_with_auth("/v1/models", default_api_token!())

    assert_license_denial(conn, "license_required", "requires an activated license")
  end

  test "hard mode with a missing bundle denies authenticated /v1/chat/completions callers" do
    put_enforcement_mode(:hard)
    Gate.refresh()

    conn =
      post_with_auth(
        "/v1/chat/completions",
        %{
          "model" => "test-model@v1",
          "messages" => [%{"role" => "user", "content" => "hello"}]
        },
        default_api_token!()
      )

    assert_license_denial(conn, "license_required", "requires an activated license")
  end

  test "hard mode with a missing bundle denies authenticated /v1/responses callers" do
    put_enforcement_mode(:hard)
    Gate.refresh()

    conn =
      post_with_auth(
        "/v1/responses",
        %{"model" => "test-model@v1", "input" => "hello"},
        default_api_token!()
      )

    assert_license_denial(conn, "license_required", "requires an activated license")
  end

  test "hard mode keeps health endpoints exempt from license denial" do
    put_enforcement_mode(:hard)
    Gate.refresh()

    live_conn = get_without_auth("/health/live")
    ready_conn = get_without_auth("/health/ready")

    assert live_conn.status == 200
    assert Jason.decode!(live_conn.resp_body) == %{"status" => "ok"}

    assert ready_conn.status != 403
    refute ready_conn.resp_body =~ "permission_error"
  end

  test "hard mode keeps /ca.crt exempt from license denial", %{tmp_dir: tmp_dir} do
    put_enforcement_mode(:hard)
    Gate.refresh()

    ca_path = Path.join(tmp_dir, "ca.crt")
    metadata_path = Path.join(tmp_dir, "ca-metadata.json")

    File.write!(ca_path, "-----BEGIN CERTIFICATE-----\nMIIBfake...\n-----END CERTIFICATE-----\n")
    File.write!(metadata_path, Jason.encode!(%{"source" => "generated_local_ca"}))
    Application.put_env(:orchard_controller, :transport_cert_source, :generated_local_ca)
    put_ca_config(ca_path, metadata_path)

    conn = get_without_auth("/ca.crt", [{"accept", "text/html"}])

    assert conn.status == 200
    refute conn.resp_body =~ "permission_error"
  end

  test "hard mode keeps /console exempt from license denial" do
    put_enforcement_mode(:hard)
    Gate.refresh()
    start_supervised!(Endpoint)

    conn =
      :get
      |> build_conn("/console")
      |> put_req_header("accept", "text/html")
      |> Endpoint.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    refute conn.resp_body =~ "permission_error"
  end

  test "hard mode with an expired bundle denies with a stable code", %{bundle_path: bundle_path} do
    put_enforcement_mode(:hard)
    copy_fixture!("expired", bundle_path)
    Gate.refresh()

    conn = get_with_auth("/v1/models", default_api_token!())

    assert_license_denial(conn, "license_expired", "license has expired")
  end

  test "hard mode with an invalid signature denies with a stable code", %{
    bundle_path: bundle_path
  } do
    put_enforcement_mode(:hard)

    "valid_bound_to_local"
    |> load_fixture_bundle!()
    |> Map.update!("license_certificate", &replace_signature/1)
    |> write_bundle!(bundle_path)

    Gate.refresh()

    conn = get_with_auth("/v1/models", default_api_token!())

    assert_license_denial(conn, "license_invalid_signature", "failed signature validation")
  end

  test "hard mode with a malformed bundle denies with a stable code", %{bundle_path: bundle_path} do
    put_enforcement_mode(:hard)
    copy_fixture!("malformed", bundle_path)
    Gate.refresh()

    conn = get_with_auth("/v1/models", default_api_token!())

    assert_license_denial(conn, "license_malformed", "unreadable or malformed")
  end

  test "hard mode with a machine mismatch denies with a stable code", %{bundle_path: bundle_path} do
    put_enforcement_mode(:hard)
    copy_fixture!("valid_bound_to_other_node", bundle_path)
    Gate.refresh()

    conn = get_with_auth("/v1/models", default_api_token!())

    assert_license_denial(conn, "license_machine_mismatch", "bound to a different machine")
  end

  test "endpoint CORS preflight remains available in hard mode" do
    put_enforcement_mode(:hard)
    put_cors_origins([@allowed_origin])
    Gate.refresh()
    start_supervised!(Endpoint)

    conn =
      :options
      |> build_conn("/v1/chat/completions")
      |> put_req_header("origin", @allowed_origin)
      |> put_req_header("access-control-request-method", "POST")
      |> Endpoint.call([])

    assert conn.status == 204
    assert conn.halted
    assert get_resp_header(conn, "access-control-allow-origin") == [@allowed_origin]
    assert get_resp_header(conn, "access-control-allow-methods") == ["GET,POST,OPTIONS"]
  end

  test "off mode never denies without a local bundle" do
    put_enforcement_mode(:off)
    Gate.refresh()

    conn = get_models_without_auth()

    assert conn.status == 401
    assert error_body(conn)["code"] == "invalid_api_key"
  end

  test "warn mode never denies without a local bundle" do
    put_enforcement_mode(:warn)
    Gate.refresh()

    conn = get_models_without_auth()

    assert conn.status == 401
    assert error_body(conn)["code"] == "invalid_api_key"
  end

  defp get_models_without_auth do
    get_without_auth("/v1/models")
  end

  defp get_without_auth(path, headers \\ [{"accept", "application/json"}]) do
    request(:get, path, nil, headers)
  end

  defp get_with_auth(path, token, headers \\ [{"accept", "application/json"}]) do
    request(:get, path, nil, [{"authorization", "Bearer #{token}"} | headers])
  end

  defp post_without_auth(path, params, headers \\ [{"accept", "application/json"}]) do
    request(:post, path, params, headers)
  end

  defp post_with_auth(path, params, token, headers \\ [{"accept", "application/json"}]) do
    request(:post, path, params, [{"authorization", "Bearer #{token}"} | headers])
  end

  defp request(method, path, params, headers) do
    conn = build_conn(method, path, params)

    headers
    |> Enum.reduce(conn, fn {header, value}, acc -> put_req_header(acc, header, value) end)
    |> Router.call(Router.init([]))
  end

  defp assert_license_denial(conn, code, message_fragment) do
    body = error_body(conn)

    assert conn.status == 403
    assert body["code"] == code
    assert body["type"] == "permission_error"
    assert body["message"] =~ message_fragment
    assert String.ends_with?(body["message"], "`orchardctl license status`.")
    refute conn.resp_body =~ "-----BEGIN LICENSE FILE-----"
    refute conn.resp_body =~ "-----BEGIN MACHINE FILE-----"
    refute conn.resp_body =~ "license_certificate"
    refute conn.resp_body =~ "machine_certificate"
  end

  defp assert_auth_denial(conn) do
    body = error_body(conn)

    assert conn.status == 401
    assert body["code"] == "invalid_api_key"
    assert body["type"] == "authentication_error"
  end

  defp default_api_token! do
    slug = "license-plug-auth-#{System.unique_integer([:positive])}"
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})
    {:ok, %{token: token}} = Governance.create_api_key(tenant.id, %{name: "Primary"})
    token
  end

  defp error_body(conn), do: Jason.decode!(conn.resp_body)["error"]

  defp put_enforcement_mode(mode) do
    licensing =
      :orchard_shared
      |> Application.get_env(:licensing, [])
      |> Keyword.put(:enforcement_mode, mode)

    Application.put_env(:orchard_shared, :licensing, licensing)
  end

  defp put_cors_origins(origins) do
    endpoint_config = Application.get_env(:orchard_controller, Endpoint, [])

    Application.put_env(
      :orchard_controller,
      Endpoint,
      Keyword.put(endpoint_config, :cors_origins, origins)
    )
  end

  defp put_ca_config(ca_certfile, metadata_path) do
    endpoint_config = Application.get_env(:orchard_controller, Endpoint, [])

    Application.put_env(
      :orchard_controller,
      Endpoint,
      endpoint_config
      |> Keyword.put(:ca_certfile, ca_certfile)
      |> Keyword.put(:ca_cert_metadata_path, metadata_path)
    )
  end

  defp copy_fixture!(name, bundle_path) do
    File.mkdir_p!(Path.dirname(bundle_path))
    File.cp!(fixture_path(name), bundle_path)
  end

  defp load_fixture_bundle!(name) do
    name
    |> fixture_path()
    |> File.read!()
    |> Jason.decode!()
  end

  defp write_bundle!(bundle, bundle_path) do
    File.mkdir_p!(Path.dirname(bundle_path))
    File.write!(bundle_path, Jason.encode!(bundle, pretty: true) <> "\n")
  end

  defp fixture_path(name), do: Path.join(@fixture_dir, "#{name}.json")

  defp write_node_identity!(node_identity_path, node_id) do
    File.mkdir_p!(Path.dirname(node_identity_path))
    File.write!(node_identity_path, node_id <> "\n")
  end

  defp replace_signature(certificate) do
    {header, footer, envelope} = certificate_envelope(certificate)
    body = envelope |> Map.put("sig", Base.encode64(:binary.copy(<<0>>, 64))) |> Jason.encode!()
    Enum.join([header, body |> Base.encode64() |> wrap64(), footer, ""], "\n")
  end

  defp certificate_envelope(certificate) do
    [header | rest] =
      certificate
      |> String.replace("\r\n", "\n")
      |> String.trim()
      |> String.split("\n")

    footer = List.last(rest)
    envelope = rest |> Enum.drop(-1) |> Enum.join("") |> Base.decode64!() |> Jason.decode!()
    {header, footer, envelope}
  end

  defp wrap64(encoded) do
    encoded
    |> String.graphemes()
    |> Enum.chunk_every(64)
    |> Enum.map_join("\n", &Enum.join/1)
  end
end
