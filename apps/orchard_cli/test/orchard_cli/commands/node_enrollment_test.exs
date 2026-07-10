defmodule OrchardCLI.Commands.NodeEnrollmentTest.PublicationFailureOutput do
  @moduledoc false

  @behaviour OrchardCLI.ExclusiveOutput

  alias OrchardCLI.ExclusiveOutput

  def reserve(path), do: ExclusiveOutput.reserve(path)
  def publish(_reservation, _contents), do: {:error, :simulated_publication_failure}
  def release(reservation), do: ExclusiveOutput.release(reservation)
end

defmodule OrchardCLI.Commands.NodeEnrollmentTest.PendingObservationOutput do
  @moduledoc false

  @behaviour OrchardCLI.ExclusiveOutput

  alias Orchard.Nodes.Enrollment
  alias Orchard.Repo
  alias OrchardCLI.ExclusiveOutput

  def reserve(path), do: ExclusiveOutput.reserve(path)

  def publish(reservation, contents) do
    enrollment = Repo.one!(Enrollment)
    send(self(), {:publication_state, enrollment.state})
    ExclusiveOutput.publish(reservation, contents)
  end

  def release(reservation), do: ExclusiveOutput.release(reservation)
end

defmodule OrchardCLI.Commands.NodeEnrollmentTest do
  use ExUnit.Case, async: false

  import Bitwise
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance.AuditLog
  alias Orchard.NodeEnrollments
  alias Orchard.Nodes.{Enrollment, Node}
  alias Orchard.NodeTrust
  alias Orchard.NodeTrust.PKI
  alias Orchard.Repo
  alias OrchardCLI.Commands.NodeEnrollmentTest.PendingObservationOutput
  alias OrchardCLI.Commands.NodeEnrollmentTest.PublicationFailureOutput
  alias OrchardCLI.Commands.Nodes
  alias OrchardCLI.EndpointMetadata

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-enrollment-cli-#{System.unique_integer([:positive])}"
      )

    trust_root = Path.join(root, "node-trust")
    support_root = Path.join(root, "support")

    previous = %{
      control_plane: Application.get_env(:orchard_controller, :control_plane),
      node_trust: Application.get_env(:orchard_controller, :node_trust),
      output_impl: Application.get_env(:orchard_cli, :node_enrollment_output_impl),
      support_root: System.get_env("ORCHARD_SUPPORT_ROOT")
    }

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    System.put_env("ORCHARD_SUPPORT_ROOT", support_root)
    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_trust, root: trust_root)
    Application.delete_env(:orchard_cli, :node_enrollment_output_impl)

    on_exit(fn ->
      File.rm_rf!(root)
      restore_env("ORCHARD_SUPPORT_ROOT", previous.support_root)
      restore_app_env(:orchard_controller, :control_plane, previous.control_plane)
      restore_app_env(:orchard_controller, :node_trust, previous.node_trust)
      restore_app_env(:orchard_cli, :node_enrollment_output_impl, previous.output_impl)
    end)

    assert {:ok, trust} =
             NodeTrust.initialize(root: trust_root, actor_id: "local-test-operator")

    configure_https_endpoint!(support_root)

    {:ok, root: root, trust: trust}
  end

  test "OpenSpec task 2.3 issues one owner-only Node Enrollment bundle through the local Controller command",
       %{root: root, trust: trust} do
    output_path = Path.join(root, "worker-enrollment.json")
    Application.put_env(:orchard_cli, :node_enrollment_output_impl, PendingObservationOutput)

    assert {:ok, message} =
             Nodes.run(["enrollment", "create", "--output", output_path])

    assert_received {:publication_state, :pending_publication}

    assert message =~ "Node Enrollment bundle created"
    refute message =~ "orch_enr_"

    assert {:ok, stat} = File.stat(output_path)
    assert (stat.mode &&& 0o777) == 0o600

    bundle = output_path |> File.read!() |> Jason.decode!()

    assert %{
             "version" => 1,
             "cluster_id" => cluster_id,
             "controller" => %{
               "https_endpoint" => "https://controller.orchard.test:443",
               "https_trust_spki_sha256" => https_trust_spki,
               "id" => controller_id,
               "runtime_trust_spki_sha256" => runtime_trust_spki,
               "uri_san" => controller_uri_san
             },
             "enrollment_id" => enrollment_id,
             "expires_at" => expires_at,
             "issued_at" => issued_at,
             "node_id" => node_id,
             "token" => bootstrap_token
           } = bundle

    assert cluster_id == trust.cluster_id
    assert controller_id == trust.controller_id
    assert runtime_trust_spki == trust.ca_spki_fingerprint
    refute https_trust_spki == runtime_trust_spki
    assert controller_uri_san == trust.controller_uri_san
    assert String.starts_with?(bootstrap_token, "orch_enr_")

    assert {:ok, enrollment} = NodeEnrollments.fetch(enrollment_id)
    assert enrollment.node_id == node_id
    assert enrollment.node.state == :provisioned
    assert enrollment.state == :issued
    assert DateTime.compare(parse_datetime!(issued_at), enrollment.issued_at) == :eq
    assert DateTime.diff(parse_datetime!(expires_at), enrollment.issued_at) == 3_600
    assert enrollment.cluster_id == trust.cluster_id
    assert enrollment.expected_controller_id == trust.controller_id
    assert enrollment.trust_authority_id == trust.trust_authority_id
    assert enrollment.token_hash != bootstrap_token
    assert enrollment.token_prefix != bootstrap_token
    refute inspect(enrollment) =~ bootstrap_token

    audit = issued_audit!(enrollment_id)
    assert audit.payload["node_id"] == node_id
    assert audit.payload["cluster_id"] == trust.cluster_id
    refute inspect(audit.payload) =~ bootstrap_token
  end

  test "OpenSpec task 2.3 refuses an existing output before mutation and never overwrites it", %{
    root: root
  } do
    output_path = Path.join(root, "existing-enrollment.json")
    File.write!(output_path, "operator-owned-existing-content")

    assert {:error, message, 1} =
             Nodes.run(["enrollment", "create", "--output", output_path])

    assert message =~ "output path already exists"
    assert File.read!(output_path) == "operator-owned-existing-content"
    assert_no_enrollment_mutation()
  end

  test "OpenSpec task 2.3 rejects expiry above 24 hours before mutation", %{root: root} do
    output_path = Path.join(root, "too-long-enrollment.json")

    assert {:error, message, 1} =
             Nodes.run([
               "enrollment",
               "create",
               "--output",
               output_path,
               "--expires-in",
               "25h"
             ])

    assert message =~ "up to 24h"
    refute File.exists?(output_path)
    assert_no_enrollment_mutation()
  end

  test "OpenSpec task 2.3 refuses standby and leadership-unproven issuance without mutation",
       %{root: root} do
    identity = "controller-#{System.unique_integer([:positive])}"

    cases = [
      {
        [role: :standby],
        "leader-only"
      },
      {
        [
          role: :leader,
          this_controller_identity: identity,
          control_plane_status_provider: fn ->
            %{advisory_lock_status: :not_held, leader_identity: identity}
          end
        ],
        "leadership could not be proven"
      }
    ]

    cases
    |> Enum.with_index()
    |> Enum.each(fn {{control_plane, expected_message}, index} ->
      output_path = Path.join(root, "non-leader-#{index}.json")
      Application.put_env(:orchard_controller, :control_plane, control_plane)

      assert {:error, message, 1} =
               Nodes.run(["enrollment", "create", "--output", output_path])

      assert message =~ expected_message
      refute File.exists?(output_path)
    end)

    assert_no_enrollment_mutation()
  end

  test "OpenSpec task 2.3 marks a post-commit publication failure without exposing the token", %{
    root: root
  } do
    output_path = Path.join(root, "failed-publication.json")
    Application.put_env(:orchard_cli, :node_enrollment_output_impl, PublicationFailureOutput)

    assert {:error, message, 1} =
             Nodes.run(["enrollment", "create", "--output", output_path])

    assert message =~ "marked output_failed"
    refute message =~ "orch_enr_"
    refute File.exists?(output_path)

    enrollment = Repo.one!(Enrollment)
    assert enrollment.state == :output_failed
    assert %DateTime{} = enrollment.output_failed_at
    assert String.starts_with?(enrollment.token_hash, "sha256$")
    assert String.starts_with?(enrollment.token_prefix, "orch_enr_")
    refute Map.has_key?(enrollment, :bootstrap_token)

    audits =
      Repo.all(
        from(audit in AuditLog,
          where: audit.target_id == ^enrollment.id,
          order_by: [asc: audit.id]
        )
      )

    assert Enum.map(audits, & &1.action) == [
             "node_enrollment.publication_pending",
             "node_enrollment.output_failed"
           ]

    Enum.each(audits, fn audit ->
      refute inspect(audit.payload) =~ "orch_enr_"
      refute Map.has_key?(audit.payload, "token")
    end)
  end

  defp configure_https_endpoint!(support_root) do
    assert {:ok,
            %{
              ca_certificate_pem: https_ca_pem
            }} =
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
               generated_by: "node-enrollment-test"
             })
  end

  defp issued_audit!(enrollment_id) do
    Repo.one!(
      from(audit in AuditLog,
        where:
          audit.scope == "cluster" and
            audit.action == "node_enrollment.issued" and
            audit.target_id == ^enrollment_id
      )
    )
  end

  defp assert_no_enrollment_mutation do
    assert Repo.aggregate(Enrollment, :count, :id) == 0
    assert Repo.aggregate(Node, :count, :id) == 0
  end

  defp parse_datetime!(value) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    datetime
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
