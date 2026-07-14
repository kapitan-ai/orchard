defmodule Orchard.BeamPeerGrantTracerSetup do
  alias Orchard.BeamPeerGrants.Secret
  alias Orchard.NodeEnrollment.PKI, as: EnrollmentPKI
  alias Orchard.NodeTrust.PKI, as: TrustPKI
  alias Orchard.RuntimeEndpoint.{DistributionLaunch, DistributionTLS}
  alias Orchard.TransportTLS.CertificateIdentity

  def run(["--", root, ipv4]), do: run([root, ipv4])

  def run([root, ipv4]) do
    validate_root!(root)
    validate_private_ipv4!(ipv4)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    cluster_id = uuid()
    controller_id = uuid()
    authority_id = uuid()
    generation_id = uuid()
    node_id = uuid()
    enrollment_id = uuid()

    {:ok, trust} =
      TrustPKI.generate(cluster_id, controller_id, authority_id, generation_id, now)

    {:ok, node_csr} = EnrollmentPKI.generate_csr(cluster_id, node_id)

    node_certificate_identity =
      EnrollmentPKI.certificate_identity(enrollment_id, node_csr.csr_fingerprint)

    {:ok, node_certificate} =
      EnrollmentPKI.issue_node_certificate(%{
        ca_certificate_pem: trust.ca_certificate_pem,
        ca_private_key_pem: trust.ca_private_key_pem,
        certificate_identifier: node_certificate_identity.identifier,
        cluster_id: cluster_id,
        csr_pem: node_csr.csr_pem,
        node_id: node_id,
        now: now,
        serial: node_certificate_identity.serial
      })

    forged_node_id = uuid()
    forged_enrollment_id = uuid()
    {:ok, forged_csr} = EnrollmentPKI.generate_csr(cluster_id, forged_node_id)

    forged_certificate_identity =
      EnrollmentPKI.certificate_identity(forged_enrollment_id, forged_csr.csr_fingerprint)

    {:ok, forged_certificate} =
      EnrollmentPKI.issue_node_certificate(%{
        ca_certificate_pem: trust.ca_certificate_pem,
        ca_private_key_pem: trust.ca_private_key_pem,
        certificate_identifier: forged_certificate_identity.identifier,
        cluster_id: cluster_id,
        csr_pem: forged_csr.csr_pem,
        node_id: forged_node_id,
        now: now,
        serial: forged_certificate_identity.serial
      })

    {:ok, controller_certificate} =
      CertificateIdentity.from_pem(trust.controller_certificate_pem)

    {:ok, node_certificate_scope} =
      CertificateIdentity.from_pem(node_certificate.certificate_pem)

    controller_name = canonical_name("orchard_controller_", controller_id, ipv4)
    node_name = canonical_name("orchard_node_agent_", node_id, ipv4)
    authorization_root_id = uuid()
    grant_id = uuid()
    authorization_key = :crypto.strong_rand_bytes(32)

    scope = %{
      beam_authorization_root_id: authorization_root_id,
      cluster_id: cluster_id,
      contract_version: 1,
      controller_beam_name: controller_name,
      controller_certificate_fingerprint_sha256: controller_certificate.fingerprint,
      controller_certificate_identifier: "serial:#{controller_certificate.serial}",
      controller_id: controller_id,
      cutover_at: nil,
      expires_at: grant_expiry(now),
      generation: 1,
      id: grant_id,
      issued_at: now,
      node_beam_name: node_name,
      node_certificate_fingerprint_sha256: node_certificate_scope.fingerprint,
      node_certificate_identifier: node_certificate.certificate_identifier,
      node_id: node_id,
      not_before_at: now,
      purpose: "runtime_endpoint"
    }

    {:ok, grant} = Secret.derive(scope, authorization_key)
    {:ok, wrong_generation} = Secret.derive(%{scope | generation: 2}, authorization_key)

    controller_root = private_directory!(Path.join(root, "controller"))
    node_root = private_directory!(Path.join(root, "node"))
    forged_root = private_directory!(Path.join(root, "forged-controller"))

    controller_identity =
      write_identity!(
        controller_root,
        trust.controller_certificate_pem,
        trust.controller_private_key_pem,
        trust.ca_certificate_pem
      )

    node_identity =
      write_identity!(
        node_root,
        node_certificate.certificate_pem,
        node_csr.private_key_pem,
        trust.ca_certificate_pem
      )

    forged_identity =
      write_identity!(
        forged_root,
        forged_certificate.certificate_pem,
        forged_csr.private_key_pem,
        trust.ca_certificate_pem
      )

    controller_options = Path.join(controller_root, "ssl-dist.conf")
    node_options = Path.join(node_root, "ssl-dist.conf")
    forged_options = Path.join(forged_root, "ssl-dist.conf")

    :ok =
      DistributionTLS.write_options(controller_options, controller_identity, %{
        certificate_fingerprint: node_certificate_scope.fingerprint,
        certificate_serial: node_certificate_scope.serial,
        uri_san: node_certificate.node_uri_san
      })

    :ok =
      DistributionTLS.write_options(node_options, node_identity, %{
        certificate_fingerprint: controller_certificate.fingerprint,
        certificate_serial: controller_certificate.serial,
        uri_san: trust.controller_uri_san
      })

    :ok =
      DistributionTLS.write_options(forged_options, forged_identity, %{
        certificate_fingerprint: node_certificate_scope.fingerprint,
        certificate_serial: node_certificate_scope.serial,
        uri_san: node_certificate.node_uri_san
      })

    launch_scope = scope |> Map.put(:grant_id, grant_id) |> Map.delete(:id)
    controller_launch_manifest = Path.join(controller_root, "launch.json")
    node_launch_manifest = Path.join(node_root, "launch.json")

    :ok =
      DistributionLaunch.write(
        controller_launch_manifest,
        Map.merge(launch_scope, %{
          role: :controller,
          optfile_path: controller_options,
          local_identity_generation_id: generation_id
        })
      )

    :ok =
      DistributionLaunch.write(
        node_launch_manifest,
        Map.merge(launch_scope, %{
          role: :node_agent,
          optfile_path: node_options,
          local_identity_generation_id: enrollment_id
        })
      )

    controller_home = cookie_home!(Path.join(root, "controller-home"))
    node_home = cookie_home!(Path.join(root, "node-home"))
    forged_home = cookie_home!(Path.join(root, "forged-home"))

    grant_path = write_private!(Path.join(root, "active-pair-grant"), grant.encoded_secret)

    wrong_generation_path =
      write_private!(Path.join(root, "wrong-generation-grant"), wrong_generation.encoded_secret)

    manifest = %{
      "CONTROLLER_HOME" => controller_home,
      "CONTROLLER_LAUNCH_MANIFEST" => controller_launch_manifest,
      "CONTROLLER_NAME" => controller_name,
      "CONTROLLER_TLS_OPTIONS" => controller_options,
      "FORGED_HOME" => forged_home,
      "FORGED_TLS_OPTIONS" => forged_options,
      "GRANT_FILE" => grant_path,
      "IP_TUPLE" => ipv4_tuple(ipv4),
      "NODE_HOME" => node_home,
      "NODE_LAUNCH_MANIFEST" => node_launch_manifest,
      "NODE_NAME" => node_name,
      "NODE_TLS_OPTIONS" => node_options,
      "WRONG_GENERATION_FILE" => wrong_generation_path,
      "WRONG_NAME" =>
        "orchard_controller_forged_#{String.replace(controller_id, "-", "")}@#{ipv4}"
    }

    manifest_path = Path.join(root, "manifest.env")

    contents =
      Enum.map_join(manifest, "\n", fn {key, value} -> "#{key}=#{shell_quote(value)}" end)

    write_private!(manifest_path, contents <> "\n")
    IO.puts(manifest_path)
  end

  def run(_args), do: raise("expected ROOT and private IPv4 arguments")

  defp validate_root!(root) do
    stat = File.stat!(root)

    unless stat.type == :directory and Bitwise.band(stat.mode, 0o777) == 0o700 do
      raise "smoke root must be an owner-only directory"
    end
  end

  defp validate_private_ipv4!(ipv4) do
    private =
      case :inet.parse_ipv4_address(String.to_charlist(ipv4)) do
        {:ok, {10, _b, _c, _d}} -> true
        {:ok, {172, b, _c, _d}} when b in 16..31 -> true
        {:ok, {192, 168, _c, _d}} -> true
        _other -> false
      end

    unless private, do: raise("smoke requires a private IPv4 address")
  end

  defp write_identity!(root, certificate, private_key, ca_certificate) do
    %{
      certfile: write_private!(Path.join(root, "certificate.pem"), certificate),
      keyfile: write_private!(Path.join(root, "private-key.pem"), private_key),
      cacertfile: write_private!(Path.join(root, "ca-certificate.pem"), ca_certificate)
    }
  end

  defp cookie_home!(path) do
    private_directory!(path)
    write_private!(Path.join(path, ".erlang.cookie"), random_cookie(), 0o400)
    path
  end

  defp private_directory!(path) do
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp write_private!(path, contents, mode \\ 0o600) do
    File.open!(path, [:write, :exclusive, :binary]) |> File.close()
    File.chmod!(path, 0o600)
    File.write!(path, contents, [:binary])
    File.chmod!(path, mode)
    path
  end

  defp canonical_name(prefix, id, ipv4),
    do: prefix <> String.replace(id, "-", "") <> "@" <> ipv4

  defp ipv4_tuple(ipv4) do
    {:ok, {a, b, c, d}} = :inet.parse_ipv4_address(String.to_charlist(ipv4))
    "{#{a},#{b},#{c},#{d}}"
  end

  defp random_cookie do
    32 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false)
  end

  defp grant_expiry(now) do
    case System.get_env("ORCHARD_BEAM_TRACER_VALIDITY_SECONDS") do
      nil ->
        DateTime.add(now, 30, :day)

      value ->
        case Integer.parse(value) do
          {seconds, ""} when seconds in 1..300 -> DateTime.add(now, seconds, :second)
          _other -> raise "ORCHARD_BEAM_TRACER_VALIDITY_SECONDS must be between 1 and 300"
        end
    end
  end

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.band(c, 0x0FFF) |> Bitwise.bor(0x4000)
    d = Bitwise.band(d, 0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format(~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

Orchard.BeamPeerGrantTracerSetup.run(System.argv())
