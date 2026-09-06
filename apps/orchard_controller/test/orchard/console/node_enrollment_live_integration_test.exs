defmodule OrchardConsole.NodeEnrollmentLiveIntegrationTest do
  use Orchard.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Orchard.EndpointMetadata
  alias Orchard.Governance.AuditLog
  alias Orchard.NodeEnrollments
  alias Orchard.Nodes.Enrollment
  alias Orchard.Nodes.Node
  alias Orchard.NodeTrust
  alias Orchard.NodeTrust.PKI
  alias Orchard.Repo

  @moduletag :db
  @moduletag :live

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-console-node-enrollment-#{System.unique_integer([:positive])}"
      )

    trust_root = Path.join(root, "node-trust")
    support_root = Path.join(root, "support")

    previous = %{
      console: Application.get_env(:orchard_controller, :console, []),
      control_plane: Application.get_env(:orchard_controller, :control_plane),
      node_trust: Application.get_env(:orchard_controller, :node_trust),
      support_root: System.get_env("ORCHARD_SUPPORT_ROOT")
    }

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    System.put_env("ORCHARD_SUPPORT_ROOT", support_root)
    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_trust, root: trust_root)

    Application.put_env(
      :orchard_controller,
      :console,
      previous.console
      |> Keyword.delete(:node_enrollment_bundle_issuer_impl)
      |> Keyword.delete(:node_enrollments_impl)
      |> Keyword.put(:refresh_interval_ms, 60_000)
    )

    on_exit(fn ->
      File.rm_rf!(root)
      restore_env("ORCHARD_SUPPORT_ROOT", previous.support_root)
      restore_app_env(:orchard_controller, :console, previous.console)
      restore_app_env(:orchard_controller, :control_plane, previous.control_plane)
      restore_app_env(:orchard_controller, :node_trust, previous.node_trust)
    end)

    assert {:ok, _trust} =
             NodeTrust.initialize(root: trust_root, actor_id: "console-test-operator")

    configure_https_endpoint!(support_root)
    {:ok, support_root: support_root}
  end

  test "Console publishes the real canonical builder bytes without persisting a secret", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "console-real-builder-node",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    assert_push_event(view, "node_enrollment_bundle", %{
      "contents" => contents,
      "enrollment_id" => enrollment_id,
      "filename" => "orchard-console-real-builder-node-enrollment.json"
    })

    bundle = Jason.decode!(contents)

    assert bundle["version"] == 1
    assert bundle["enrollment_id"] == enrollment_id
    assert String.starts_with?(bundle["token"], "orch_enr_")
    assert bundle["controller"]["https_endpoint"] == "https://controller.orchard.test:443"

    assert {:ok, pending} = NodeEnrollments.fetch(enrollment_id)
    assert pending.state == :pending_publication
    assert pending.audit_metadata == %{"initial_pool_id" => "general", "surface" => "console"}
    refute inspect(pending) =~ bundle["token"]

    audit_payloads =
      Repo.all(
        from(audit in AuditLog,
          where: audit.target_id == ^enrollment_id,
          select: audit.payload
        )
      )

    refute inspect(audit_payloads) =~ bundle["token"]

    render_hook(view, "node_enrollment_bundle_downloaded", %{
      "enrollment_id" => enrollment_id
    })

    assert {:ok, issued} = NodeEnrollments.fetch(enrollment_id)
    assert issued.state == :issued
  end

  test "real bundle builder accepts an RSA operator HTTPS trust anchor", %{
    support_root: support_root
  } do
    https_ca_path = Path.join([support_root, "public", "ca.crt"])
    generate_rsa_self_signed_certificate!(https_ca_path)

    assert {:ok, issued} =
             Orchard.NodeEnrollmentBundle.issue(%{
               display_name: "rsa-operator-ca-node",
               expiry_seconds: 3_600,
               pool_id: "general",
               surface: "console"
             })

    bundle = Jason.decode!(issued.contents)

    assert bundle["controller"]["https_trust_anchor_pem"] == File.read!(https_ca_path)

    assert bundle["controller"]["https_trust_spki_sha256"] =~
             ~r/^sha256-[A-Za-z0-9_-]{43}$/
  end

  test "shared builder rejects an enrollment file above the orchardctl limit and reconciles it",
       %{
         support_root: support_root
       } do
    https_ca_path = Path.join([support_root, "public", "ca.crt"])
    File.write!(https_ca_path, File.read!(https_ca_path) <> String.duplicate(" ", 65_536))

    assert {:error,
            {:bundle_publication_failed, failed_enrollment_id, :output_failed, :bundle_too_large}} =
             Orchard.NodeEnrollmentBundle.issue(%{
               display_name: "oversized-enrollment-node",
               expiry_seconds: 3_600,
               pool_id: "general",
               surface: "console"
             })

    node = Repo.get_by!(Node, display_name: "oversized-enrollment-node")
    enrollment = Repo.get_by!(Enrollment, node_id: node.id)

    assert enrollment.id == failed_enrollment_id
    assert enrollment.state == :output_failed

    failure_audit =
      Repo.one!(
        from(audit in AuditLog,
          where:
            audit.target_id == ^enrollment.id and
              audit.action == "node_enrollment.output_failed",
          select: audit.payload
        )
      )

    assert failure_audit["reason"] == "bundle_too_large"

    {:ok, view, _html} = live(build_conn(), "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    html =
      view
      |> form("#node-enrollment-form",
        enrollment: %{
          display_name: "oversized-console-enrollment-node",
          expiry_seconds: "3600",
          pool_id: "general"
        }
      )
      |> render_submit()

    console_node = Repo.get_by!(Node, display_name: "oversized-console-enrollment-node")
    console_enrollment = Repo.get_by!(Enrollment, node_id: console_node.id)

    assert_patch(view, "/console/nodes/new/#{console_enrollment.id}")
    assert html =~ "This enrollment can no longer register a node"
    assert html =~ "new enrollment needs a distinct Node name"
    assert console_enrollment.state == :output_failed
  end

  defp configure_https_endpoint!(support_root) do
    assert {:ok, %{ca_certificate_pem: https_ca_pem}} =
             PKI.generate(
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               DateTime.utc_now()
             )

    https_ca_path = Path.join([support_root, "public", "ca.crt"])
    File.mkdir_p!(Path.dirname(https_ca_path))
    File.write!(https_ca_path, https_ca_pem)

    assert :ok =
             EndpointMetadata.write(%{
               transport_mode: "direct_https",
               public_host: "controller.orchard.test",
               api_https_port: 443,
               plain_http_port: nil,
               api_bind_ip: "0.0.0.0",
               ca_certfile: https_ca_path,
               generated_by: "console-node-enrollment-test"
             })
  end

  defp generate_rsa_self_signed_certificate!(certfile) do
    openssl =
      System.find_executable("openssl") ||
        flunk("openssl is required for Node Enrollment bundle integration tests")

    keyfile = Path.rootname(certfile) <> ".key"

    {output, status} =
      System.cmd(
        openssl,
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          keyfile,
          "-out",
          certfile,
          "-days",
          "365",
          "-subj",
          "/CN=controller.orchard.test"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
