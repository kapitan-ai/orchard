defmodule Orchard.LicensingTest do
  use ExUnit.Case, async: true

  alias Orchard.Licensing

  @fixture_dir Path.expand("../fixtures/licensing", __DIR__)
  @public_key_hex "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
  @private_key Base.decode16!(String.duplicate("01", 32), case: :mixed)
  @local_node_id "11111111-2222-4333-8444-555555555555"
  @other_node_id "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  @now ~U[2026-04-15 00:00:00Z]

  setup do
    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "orchard-licensing-test",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    bundle_path = Path.join([tmp_dir, "config", "licensing", "current.json"])
    node_identity_path = Path.join([tmp_dir, "data", "node-id"])

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir, bundle_path: bundle_path, node_identity_path: node_identity_path}
  end

  describe "inspect_local/1" do
    test "returns valid for a bundle bound to the local node", ctx do
      copy_fixture!("valid_bound_to_local", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :valid
      assert status.message == "License bundle is valid."
      assert status.bundle_path == ctx.bundle_path
      assert status.fingerprint == @local_node_id
      assert status.local_node_fingerprint == @local_node_id
      assert status.license_id == "lic_valid_local"
      assert status.machine_id == "mach_local"
      assert status.licensee == "Acme Orchard Lab"
      assert status.max_machines == 3
      assert status.expires_at == ~U[2027-04-15 00:00:00Z]
    end

    test "returns missing_bundle when the Orchard-owned bundle is absent", ctx do
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :missing_bundle
      assert status.message == "No local license bundle is installed."
    end

    test "returns invalid_license_signature when the license certificate signature is wrong",
         ctx do
      bundle = load_fixture_bundle!("valid_bound_to_local")

      tampered_bundle = %{
        bundle
        | license_certificate: tamper_signature(bundle.license_certificate)
      }

      write_bundle!(ctx.bundle_path, tampered_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :invalid_license_signature
      assert status.message == "License certificate signature is invalid."
    end

    test "returns invalid_machine_signature when the machine certificate signature is wrong",
         ctx do
      bundle = load_fixture_bundle!("valid_bound_to_local")

      tampered_bundle = %{
        bundle
        | machine_certificate: tamper_signature(bundle.machine_certificate)
      }

      write_bundle!(ctx.bundle_path, tampered_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :invalid_machine_signature
      assert status.message == "Machine certificate signature is invalid."
    end

    test "returns expired when the bundle expiry is in the past", ctx do
      copy_fixture!("expired", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :expired
      assert status.message == "License bundle has expired."
      assert status.expires_at == ~U[2025-04-15 00:00:00Z]
    end

    test "returns not_yet_valid when the bundle validity window starts in the future", ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_future",
          "mach_future",
          "2026-12-01T00:00:00Z",
          "2027-12-01T00:00:00Z"
        )

      write_bundle!(ctx.bundle_path, bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :not_yet_valid
      assert status.message == "License bundle is not yet valid."
    end

    test "returns fingerprint_mismatch when the machine certificate is bound to another node",
         ctx do
      copy_fixture!("valid_bound_to_other_node", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :fingerprint_mismatch

      assert status.message ==
               "Machine certificate fingerprint does not match the local node identity."

      assert status.fingerprint == @other_node_id
      assert status.local_node_fingerprint == @local_node_id
    end

    test "returns identity_missing when the local node identity does not exist", ctx do
      copy_fixture!("valid_bound_to_local", ctx.bundle_path)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :identity_missing
      assert status.message == "Local node identity is missing."
    end

    test "returns malformed_bundle for a malformed Orchard-owned bundle", ctx do
      copy_fixture!("malformed", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_bundle
      assert status.message =~ "Licensing bundle is malformed"
    end

    test "returns malformed_license_certificate for corrupt license certificate text", ctx do
      bundle = load_fixture_bundle!("valid_bound_to_local")
      bad_bundle = %{bundle | license_certificate: malformed_certificate("LICENSE")}

      write_bundle!(ctx.bundle_path, bad_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_license_certificate
    end

    test "returns malformed_machine_certificate for corrupt machine certificate text", ctx do
      bundle = load_fixture_bundle!("valid_bound_to_local")
      bad_bundle = %{bundle | machine_certificate: malformed_certificate("MACHINE")}

      write_bundle!(ctx.bundle_path, bad_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_machine_certificate
    end

    test "returns malformed_license_certificate when the signed envelope JSON is not an object",
         ctx do
      bundle = load_fixture_bundle!("valid_bound_to_local")

      bad_bundle = %{
        bundle
        | license_certificate: non_object_envelope_certificate(bundle.license_certificate)
      }

      write_bundle!(ctx.bundle_path, bad_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_license_certificate
      assert status.message == "certificate envelope must be a JSON object"
    end

    test "returns malformed_machine_certificate when the signed envelope JSON is not an object",
         ctx do
      bundle = load_fixture_bundle!("valid_bound_to_local")

      bad_bundle = %{
        bundle
        | machine_certificate: non_object_envelope_certificate(bundle.machine_certificate)
      }

      write_bundle!(ctx.bundle_path, bad_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_machine_certificate
      assert status.message == "certificate envelope must be a JSON object"
    end

    test "returns malformed_bundle when the strongest cross-artifact identifier does not match",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_bundle_a",
          "mach_bundle_a",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          machine_license_id: "lic_bundle_b"
        )

      write_bundle!(ctx.bundle_path, bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_bundle
      assert status.message =~ "same license identifier"
    end

    test "returns config_error when the Keygen public key is missing", ctx do
      copy_fixture!("valid_bound_to_local", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status =
        Licensing.inspect_local(
          bundle_path: ctx.bundle_path,
          node_identity_path: ctx.node_identity_path,
          keygen_public_key: nil,
          now: @now
        )

      assert status.state == :config_error
      assert status.message == "Keygen public key is not configured."
    end
  end

  describe "install_pair/2" do
    test "validates offline, writes the bundle atomically, and persists mode 0600", ctx do
      bundle = load_fixture_bundle!("valid_bound_to_local")
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert {:ok, %Licensing{} = status} = Licensing.install_pair(bundle, opts(ctx))
      assert status.state == :valid

      assert Jason.decode!(File.read!(ctx.bundle_path)) == %{
               "license_certificate" => bundle.license_certificate,
               "machine_certificate" => bundle.machine_certificate
             }

      assert {:ok, stat} = File.stat(ctx.bundle_path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    test "keeps the last known good bundle when validation fails", ctx do
      original_bundle = load_fixture_bundle!("valid_bound_to_local")
      write_bundle!(ctx.bundle_path, original_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      bad_bundle = %{
        original_bundle
        | license_certificate: tamper_signature(original_bundle.license_certificate)
      }

      original_contents = File.read!(ctx.bundle_path)

      assert {:error, %Licensing{state: :invalid_license_signature}} =
               Licensing.install_pair(bad_bundle, opts(ctx))

      assert File.read!(ctx.bundle_path) == original_contents
    end

    test "keeps the last known good bundle when the atomic write fails", ctx do
      original_bundle = load_fixture_bundle!("valid_bound_to_local")
      write_bundle!(ctx.bundle_path, original_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      replacement_bundle = load_fixture_bundle!("valid_bound_to_local")
      original_contents = File.read!(ctx.bundle_path)
      bundle_dir = Path.dirname(ctx.bundle_path)

      File.chmod!(bundle_dir, 0o500)

      on_exit(fn ->
        if File.dir?(bundle_dir) do
          File.chmod(bundle_dir, 0o700)
        end
      end)

      assert {:error, {:write_failed, reason}} =
               Licensing.install_pair(replacement_bundle, opts(ctx))

      assert reason in [:eacces, :eperm]
      assert File.read!(ctx.bundle_path) == original_contents
    end
  end

  describe "health_summary/1" do
    test "produces a JSON-ready summary map" do
      summary =
        Licensing.health_summary(%Licensing{
          state: :expired,
          message: "License bundle has expired.",
          bundle_path: "/tmp/current.json",
          expires_at: ~U[2025-04-15 00:00:00Z]
        })

      assert summary == %{
               status: "invalid",
               reason: "expired",
               message: "License bundle has expired.",
               expires_at: "2025-04-15T00:00:00Z"
             }
    end

    test "maps missing states to the missing summary status" do
      summary =
        Licensing.health_summary(%Licensing{
          state: :missing_bundle,
          message: "No local license bundle is installed.",
          bundle_path: "/tmp/current.json"
        })

      assert summary == %{
               status: "missing",
               reason: "missing_bundle",
               message: "No local license bundle is installed.",
               expires_at: nil
             }
    end

    test "preserves config_error as a distinct summary reason" do
      summary =
        Licensing.health_summary(%Licensing{
          state: :config_error,
          message: "Keygen public key is not configured.",
          bundle_path: "/tmp/current.json"
        })

      assert summary == %{
               status: "invalid",
               reason: "config_error",
               message: "Keygen public key is not configured.",
               expires_at: nil
             }
    end

    test "preserves read_error as a distinct summary reason" do
      summary =
        Licensing.health_summary(%Licensing{
          state: :read_error,
          message: "Cannot read licensing bundle: :eacces.",
          bundle_path: "/tmp/current.json"
        })

      assert summary == %{
               status: "invalid",
               reason: "read_error",
               message: "Cannot read licensing bundle: :eacces.",
               expires_at: nil
             }
    end
  end

  describe "startup_decision/2" do
    test "allows valid status for all enforcement modes" do
      valid = %Licensing{state: :valid, message: "ok", bundle_path: "/tmp/current.json"}

      assert Licensing.startup_decision(valid, :off) == :allow
      assert Licensing.startup_decision(valid, :warn) == :allow
      assert Licensing.startup_decision(valid, :hard) == :allow
    end

    test "maps non-valid states across enforcement modes" do
      missing = %Licensing{
        state: :missing_bundle,
        message: "No local license bundle is installed.",
        bundle_path: "/tmp/current.json"
      }

      assert Licensing.startup_decision(missing, :off) == :allow

      assert Licensing.startup_decision(missing, :warn) ==
               {:warn, "No local license bundle is installed."}

      assert Licensing.startup_decision(missing, :hard) ==
               {:deny, "No local license bundle is installed."}
    end

    test "raises on unsupported enforcement modes" do
      status = %Licensing{state: :valid, message: "ok", bundle_path: "/tmp/current.json"}

      assert_raise ArgumentError, ~r/unsupported license enforcement mode/, fn ->
        Licensing.startup_decision(status, :sometimes)
      end
    end
  end

  defp opts(ctx, extra \\ []) do
    Keyword.merge(
      [
        bundle_path: ctx.bundle_path,
        node_identity_path: ctx.node_identity_path,
        keygen_public_key: @public_key_hex,
        now: @now
      ],
      extra
    )
  end

  defp load_fixture_bundle!(name) do
    fixture_path(name)
    |> File.read!()
    |> Jason.decode!()
    |> then(fn %{
                 "license_certificate" => license_certificate,
                 "machine_certificate" => machine_certificate
               } ->
      %{license_certificate: license_certificate, machine_certificate: machine_certificate}
    end)
  end

  defp copy_fixture!(name, bundle_path) do
    File.mkdir_p!(Path.dirname(bundle_path))
    File.cp!(fixture_path(name), bundle_path)
  end

  defp fixture_path(name), do: Path.join(@fixture_dir, "#{name}.json")

  defp write_node_identity!(node_identity_path, node_id) do
    File.mkdir_p!(Path.dirname(node_identity_path))
    File.write!(node_identity_path, node_id <> "\n")
  end

  defp write_bundle!(bundle_path, %{license_certificate: license, machine_certificate: machine}) do
    File.mkdir_p!(Path.dirname(bundle_path))

    File.write!(
      bundle_path,
      Jason.encode!(%{"license_certificate" => license, "machine_certificate" => machine},
        pretty: true
      ) <>
        "\n"
    )
  end

  defp malformed_certificate(kind) do
    """
    -----BEGIN #{kind} FILE-----
    definitely-not-base64
    -----END #{kind} FILE-----
    """
  end

  defp non_object_envelope_certificate(certificate, raw_json \\ "[]") do
    normalized =
      certificate
      |> String.replace("\r\n", "\n")
      |> String.trim()

    [header | rest] = String.split(normalized, "\n")
    footer = List.last(rest)
    body = raw_json |> Base.encode64() |> wrap_base64()
    Enum.join([header, body, footer, ""], "\n")
  end

  defp tamper_signature(certificate) do
    {header, footer, envelope} = decode_certificate_envelope(certificate)
    bad_signature = Base.encode64(:binary.copy(<<0>>, 64))
    encode_certificate(header, footer, Map.put(envelope, "sig", bad_signature))
  end

  defp decode_certificate_envelope(certificate) do
    normalized =
      certificate
      |> String.replace("\r\n", "\n")
      |> String.trim()

    [header | rest] = String.split(normalized, "\n")
    footer = List.last(rest)
    body = rest |> Enum.drop(-1) |> Enum.join("")
    envelope = body |> Base.decode64!() |> Jason.decode!()
    {header, footer, envelope}
  end

  defp build_signed_bundle(
         fingerprint,
         license_id,
         machine_id,
         not_before,
         expiry,
         overrides \\ []
       ) do
    machine_license_id = Keyword.get(overrides, :machine_license_id, license_id)
    licensee = Keyword.get(overrides, :licensee, "Acme Orchard Lab")
    max_machines = Keyword.get(overrides, :max_machines, 3)

    license_payload = %{
      "data" => %{
        "type" => "licenses",
        "id" => license_id,
        "attributes" => %{
          "licensee" => licensee,
          "maxMachines" => max_machines,
          "notBefore" => not_before,
          "expiry" => expiry
        }
      }
    }

    machine_payload = %{
      "data" => %{
        "type" => "machines",
        "id" => machine_id,
        "attributes" => %{
          "fingerprint" => fingerprint,
          "notBefore" => not_before,
          "expiry" => expiry
        },
        "relationships" => %{
          "license" => %{
            "data" => %{
              "type" => "licenses",
              "id" => machine_license_id
            }
          }
        }
      }
    }

    %{
      license_certificate: sign_certificate("LICENSE", license_payload),
      machine_certificate: sign_certificate("MACHINE", machine_payload)
    }
  end

  defp sign_certificate(kind, payload) do
    payload_json = Jason.encode!(payload)
    signature = :crypto.sign(:eddsa, :none, payload_json, [@private_key, :ed25519])

    envelope = %{
      "alg" => "ed25519",
      "enc" => "base64",
      "payload" => Base.encode64(payload_json),
      "sig" => Base.encode64(signature)
    }

    header = "-----BEGIN #{kind} FILE-----"
    footer = "-----END #{kind} FILE-----"

    encode_certificate(header, footer, envelope)
  end

  defp encode_certificate(header, footer, envelope) do
    body =
      envelope
      |> Jason.encode!()
      |> Base.encode64()
      |> wrap_base64()

    Enum.join([header, body, footer, ""], "\n")
  end

  defp wrap_base64(encoded) do
    encoded
    |> String.graphemes()
    |> Enum.chunk_every(64)
    |> Enum.map_join("\n", &Enum.join/1)
  end
end
