defmodule Orchard.LicensingTest do
  use ExUnit.Case, async: true

  alias Orchard.Licensing

  @fixture_dir Path.expand("../fixtures/licensing", __DIR__)
  @public_key_hex "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
  @private_key Base.decode16!(String.duplicate("01", 32), case: :mixed)
  @local_node_id "11111111-2222-4333-8444-555555555555"
  @other_node_id "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  @golden_fixture "keygen_golden"
  @golden_public_key_hex "f1a328edc3d42967e8545c1361d2dc22622fad52aad0dc8e5d3b3cb95d7cb18a"
  @golden_public_key Base.decode16!(@golden_public_key_hex, case: :mixed)
  @golden_fingerprint "19118aa3-33ec-4293-9078-ac28d4a412ef"
  @golden_license_id "39820870-4eb1-4a98-8c04-0fd8a9c69fe3"
  @golden_machine_id "5abda8c3-9ab4-4396-82b4-e285ae7fdb52"
  @golden_expires_at ~U[2026-04-18 00:00:00.000Z]
  @now ~U[2026-04-15 00:00:00Z]
  @license_identity_keys [:license_id, :machine_id, :licensee, :max_machines]

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

  describe "resolve_enforcement_mode/2" do
    test "defaults dev, empty, and nil build channels to off" do
      assert Licensing.resolve_enforcement_mode(nil, "dev") == :off
      assert Licensing.resolve_enforcement_mode(nil, "") == :off
      assert Licensing.resolve_enforcement_mode(nil, "   ") == :off
      assert Licensing.resolve_enforcement_mode(nil, nil) == :off
    end

    test "defaults accepted distributed build channels to hard" do
      assert Licensing.resolve_enforcement_mode(nil, "internal") == :hard
      assert Licensing.resolve_enforcement_mode(nil, "trial") == :hard
      assert Licensing.resolve_enforcement_mode(nil, "pilot") == :hard
      assert Licensing.resolve_enforcement_mode(nil, "release") == :hard
      assert Licensing.resolve_enforcement_mode(nil, " trial ") == :hard
    end

    test "rejects unknown build channels when deriving defaults" do
      assert_raise RuntimeError,
                   ~r/^Invalid Orchard build channel: "staging"\. Accepted channels: dev, internal, trial, pilot, release$/,
                   fn -> Licensing.resolve_enforcement_mode(nil, "staging") end
    end

    test "explicit enforcement overrides build-channel defaults" do
      assert Licensing.resolve_enforcement_mode("warn", "trial") == :warn
      assert Licensing.resolve_enforcement_mode(:off, "trial") == :off
      assert Licensing.resolve_enforcement_mode("hard", "staging") == :hard
      assert Licensing.resolve_enforcement_mode(:warn, "staging") == :warn
    end
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
      assert status.metadata == nil
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

    test "returns valid when the license certificate uses Keygen checkout envelope format", ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_license",
          "mach_keygen_license",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout
        )

      write_bundle!(ctx.bundle_path, bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :valid
      assert status.message == "License bundle is valid."
      assert status.license_id == "lic_keygen_license"
      assert status.machine_id == "mach_keygen_license"
      assert status.fingerprint == @local_node_id
    end

    test "returns valid when the machine certificate uses Keygen checkout envelope format", ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_machine",
          "mach_keygen_machine",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          machine_format: :keygen_checkout
        )

      write_bundle!(ctx.bundle_path, bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :valid
      assert status.message == "License bundle is valid."
      assert status.license_id == "lic_keygen_machine"
      assert status.machine_id == "mach_keygen_machine"
      assert status.fingerprint == @local_node_id
    end

    test "returns invalid_license_signature when a Keygen license certificate signature is tampered",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_sig_bad",
          "mach_keygen_sig_bad",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout
        )

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

    test "returns invalid_machine_signature when a Keygen machine certificate enc payload is tampered",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_enc_bad",
          "mach_keygen_enc_bad",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          machine_format: :keygen_checkout
        )

      tampered_enc =
        %{"data" => %{"type" => "machines", "id" => "tampered"}}
        |> Jason.encode!()
        |> Base.encode64()

      tampered_bundle = %{
        bundle
        | machine_certificate: tamper_enc(bundle.machine_certificate, tampered_enc)
      }

      write_bundle!(ctx.bundle_path, tampered_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :invalid_machine_signature
      assert status.message == "Machine certificate signature is invalid."
    end

    test "returns malformed_license_certificate when a Keygen license certificate is missing enc",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_missing_enc",
          "mach_keygen_missing_enc",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout
        )

      tampered_bundle = %{
        bundle
        | license_certificate: remove_enc(bundle.license_certificate)
      }

      write_bundle!(ctx.bundle_path, tampered_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_license_certificate
      assert status.message == "certificate envelope format is invalid"
    end

    test "returns malformed_machine_certificate when a Keygen machine certificate enc is not a string",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_non_string_enc",
          "mach_keygen_non_string_enc",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          machine_format: :keygen_checkout
        )

      tampered_bundle = %{
        bundle
        | machine_certificate: tamper_enc(bundle.machine_certificate, 123)
      }

      write_bundle!(ctx.bundle_path, tampered_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_machine_certificate
      assert status.message == "payload must be a string"
    end

    test "returns malformed_license_certificate when a Keygen license certificate alg is unsupported",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_bad_alg",
          "mach_keygen_bad_alg",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout,
          machine_format: :keygen_checkout
        )

      tampered_bundle = %{
        bundle
        | license_certificate: tamper_alg(bundle.license_certificate, "ed25519")
      }

      write_bundle!(ctx.bundle_path, tampered_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_license_certificate
      assert status.message == "certificate envelope format is invalid"
    end

    test "returns malformed_machine_certificate when a Keygen machine certificate is missing sig",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_missing_sig",
          "mach_keygen_missing_sig",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout,
          machine_format: :keygen_checkout
        )

      tampered_bundle = %{
        bundle
        | machine_certificate: remove_sig(bundle.machine_certificate)
      }

      write_bundle!(ctx.bundle_path, tampered_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_machine_certificate
      assert status.message == "certificate signature is missing"
    end

    test "returns malformed_license_certificate when a Keygen license certificate sig is not a string",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_non_string_sig",
          "mach_keygen_non_string_sig",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout,
          machine_format: :keygen_checkout
        )

      tampered_bundle = %{
        bundle
        | license_certificate: tamper_sig(bundle.license_certificate, 123)
      }

      write_bundle!(ctx.bundle_path, tampered_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_license_certificate
      assert status.message == "certificate signature is missing"
    end

    test "returns malformed_machine_certificate when a Keygen machine certificate sig is invalid base64",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_bad_sig_base64",
          "mach_keygen_bad_sig_base64",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout,
          machine_format: :keygen_checkout
        )

      tampered_bundle = %{
        bundle
        | machine_certificate: tamper_sig(bundle.machine_certificate, "not_base64!!!")
      }

      write_bundle!(ctx.bundle_path, tampered_bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :malformed_machine_certificate
      assert status.message == "signature is not valid base64"
    end

    test "returns valid for a real captured Keygen certificate pair", ctx do
      copy_fixture!(@golden_fixture, ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @golden_fingerprint)

      status =
        Licensing.inspect_local(opts(ctx, keygen_public_key: @golden_public_key_hex))

      assert status.state == :valid
      assert status.message == "License bundle is valid."
      assert status.bundle_path == ctx.bundle_path
      assert status.fingerprint == @golden_fingerprint
      assert status.local_node_fingerprint == @golden_fingerprint
      assert status.license_id == @golden_license_id
      assert status.machine_id == @golden_machine_id
      assert status.licensee == nil
      assert status.max_machines == 10
      assert status.metadata == nil
      assert status.expires_at == @golden_expires_at
    end

    test "extracts orchard_tracking metadata from an Orchard-canonical license certificate",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_tracking_canonical",
          "mach_tracking_canonical",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          metadata: %{
            "orchard_tracking" => %{
              "program" => " AIEH ",
              "reference" => " AIEH-2026-001 "
            }
          }
        )

      write_bundle!(ctx.bundle_path, bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :valid
      assert status.metadata == %{program: "aieh", reference: "aieh-2026-001"}
    end

    test "extracts observed Keygen checkout tracking metadata key from the signed payload",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_tracking_keygen",
          "mach_tracking_keygen",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout,
          metadata: %{
            "orchardTracking" => %{
              "program" => "100E",
              "reference" => "100E-2026-ALPHA"
            }
          }
        )

      write_bundle!(ctx.bundle_path, bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :valid
      assert status.metadata == %{program: "100e", reference: "100e-2026-alpha"}
    end

    test "ignores non-map certificate metadata without changing license state", ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_tracking_non_map_metadata",
          "mach_tracking_non_map_metadata",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          metadata: "not-a-map"
        )

      write_bundle!(ctx.bundle_path, bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :valid
      assert status.metadata == nil
    end

    test "ignores non-map orchard_tracking blocks without changing license state", ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_tracking_non_map_block",
          "mach_tracking_non_map_block",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          metadata: %{"orchard_tracking" => "not-a-map"}
        )

      write_bundle!(ctx.bundle_path, bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :valid
      assert status.metadata == nil
    end

    test "soft-parses blank and non-string tracking fields without invalidating the bundle",
         ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_tracking_soft_fields",
          "mach_tracking_soft_fields",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          metadata: %{
            "orchard_tracking" => %{
              "program" => "   ",
              "reference" => 123
            }
          }
        )

      write_bundle!(ctx.bundle_path, bundle)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      status = Licensing.inspect_local(opts(ctx))

      assert status.state == :valid
      assert status.metadata == %{program: nil, reference: nil}
    end

    test "real captured Keygen certificates use base64+ed25519 envelopes" do
      bundle = load_fixture_bundle!(@golden_fixture)
      {_, _, license_envelope} = decode_certificate_envelope(bundle.license_certificate)
      {_, _, machine_envelope} = decode_certificate_envelope(bundle.machine_certificate)

      assert_keygen_checkout_envelope!(license_envelope)
      assert_keygen_checkout_envelope!(machine_envelope)
    end

    test "real captured Keygen certificates verify with kind and encoded payload signing input" do
      bundle = load_fixture_bundle!(@golden_fixture)

      assert_keygen_signing_input!(bundle.license_certificate, "license")
      assert_keygen_signing_input!(bundle.machine_certificate, "machine")
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

    test "validates and installs a Keygen checkout bundle pair", ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_install",
          "mach_keygen_install",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout,
          machine_format: :keygen_checkout
        )

      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert {:ok, %Licensing{} = status} = Licensing.install_pair(bundle, opts(ctx))
      assert status.state == :valid
      assert status.license_id == "lic_keygen_install"
      assert status.machine_id == "mach_keygen_install"
      assert status.fingerprint == @local_node_id
      assert status.metadata == nil

      assert Jason.decode!(File.read!(ctx.bundle_path)) == %{
               "license_certificate" => bundle.license_certificate,
               "machine_certificate" => bundle.machine_certificate
             }

      assert {:ok, stat} = File.stat(ctx.bundle_path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    test "returns tracking metadata while persisting only the certificate pair", ctx do
      bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_tracking_install",
          "mach_tracking_install",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout,
          machine_format: :keygen_checkout,
          metadata: %{
            "orchard_tracking" => %{
              "program" => "SIP",
              "reference" => "SIP-2026-001"
            }
          }
        )

      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert {:ok, %Licensing{} = status} = Licensing.install_pair(bundle, opts(ctx))
      assert status.state == :valid
      assert status.metadata == %{program: "sip", reference: "sip-2026-001"}

      assert Jason.decode!(File.read!(ctx.bundle_path)) == %{
               "license_certificate" => bundle.license_certificate,
               "machine_certificate" => bundle.machine_certificate
             }
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

    test "keeps the last known good Keygen bundle when tampered Keygen install fails", ctx do
      original_bundle =
        build_signed_bundle(
          @local_node_id,
          "lic_keygen_keep_good",
          "mach_keygen_keep_good",
          "2026-01-01T00:00:00Z",
          "2027-04-15T00:00:00Z",
          license_format: :keygen_checkout,
          machine_format: :keygen_checkout
        )

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

    test "adds tracking only when metadata is present" do
      summary =
        Licensing.health_summary(%Licensing{
          state: :valid,
          message: "License bundle is valid.",
          bundle_path: "/tmp/current.json",
          expires_at: ~U[2027-04-15 00:00:00Z],
          metadata: %{program: "aieh", reference: "aieh-2026-001"}
        })

      assert summary == %{
               status: "valid",
               reason: nil,
               message: "License bundle is valid.",
               expires_at: "2027-04-15T00:00:00Z",
               tracking: %{program: "aieh", reference: "aieh-2026-001"}
             }
    end

    test "adds license identifiers for valid bundles when present", ctx do
      copy_fixture!("valid_bound_to_local", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      summary =
        ctx
        |> opts()
        |> Licensing.inspect_local()
        |> Licensing.health_summary()

      assert summary.license_id == "lic_valid_local"
      assert summary.machine_id == "mach_local"
      assert summary.licensee == "Acme Orchard Lab"
      assert summary.max_machines == 3
    end

    test "omits license identifiers when a valid bundle has nil identifier fields" do
      summary =
        Licensing.health_summary(%Licensing{
          state: :valid,
          message: "License bundle is valid.",
          bundle_path: "/tmp/current.json"
        })

      for key <- @license_identity_keys do
        refute Map.has_key?(summary, key)
      end
    end

    test "includes license identifiers for signed invalid states" do
      for state <- [:expired, :not_yet_valid, :fingerprint_mismatch] do
        summary =
          Licensing.health_summary(%Licensing{
            state: state,
            message: "Signed but invalid license.",
            bundle_path: "/tmp/current.json",
            license_id: "lic_visible",
            machine_id: "mach_visible",
            licensee: "Acme Orchard Lab",
            max_machines: 3
          })

        assert summary.license_id == "lic_visible"
        assert summary.machine_id == "mach_visible"
        assert summary.licensee == "Acme Orchard Lab"
        assert summary.max_machines == 3
      end
    end

    test "omits license identifiers for missing and unsafe invalid states" do
      for state <- [
            :missing_bundle,
            :invalid_license_signature,
            :malformed_bundle,
            :read_error,
            :config_error
          ] do
        summary =
          Licensing.health_summary(%Licensing{
            state: state,
            message: "License is unavailable.",
            bundle_path: "/tmp/current.json",
            license_id: "lic_hidden",
            machine_id: "mach_hidden",
            licensee: "Hidden",
            max_machines: 1
          })

        for key <- @license_identity_keys do
          refute Map.has_key?(summary, key)
        end
      end
    end

    test "omits tracking for malformed metadata" do
      summary =
        Licensing.health_summary(%Licensing{
          state: :valid,
          message: "License bundle is valid.",
          bundle_path: "/tmp/current.json",
          metadata: "not-a-map"
        })

      refute Map.has_key?(summary, :tracking)
    end
  end

  describe "telemetry_dimensions/1" do
    test "returns stable dimensions with absent tracking fields" do
      dimensions =
        Licensing.telemetry_dimensions(%Licensing{
          state: :missing_bundle,
          message: "No local license bundle is installed.",
          bundle_path: "/tmp/current.json"
        })

      assert dimensions == %{
               license_state: "missing_bundle",
               tracking_program: nil,
               tracking_reference: nil
             }
    end

    test "returns tracking dimensions when metadata is present" do
      dimensions =
        Licensing.telemetry_dimensions(%Licensing{
          state: :valid,
          message: "License bundle is valid.",
          bundle_path: "/tmp/current.json",
          metadata: %{program: "100e", reference: "100e-2026-alpha"}
        })

      assert dimensions == %{
               license_state: "valid",
               tracking_program: "100e",
               tracking_reference: "100e-2026-alpha"
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
    bad_signature = Base.encode64(:binary.copy(<<0>>, 64))
    mutate_certificate_envelope(certificate, &Map.put(&1, "sig", bad_signature))
  end

  defp tamper_alg(certificate, value) do
    mutate_certificate_envelope(certificate, &Map.put(&1, "alg", value))
  end

  defp tamper_sig(certificate, value) do
    mutate_certificate_envelope(certificate, &Map.put(&1, "sig", value))
  end

  defp tamper_enc(certificate, value) do
    mutate_certificate_envelope(certificate, &Map.put(&1, "enc", value))
  end

  defp remove_sig(certificate) do
    mutate_certificate_envelope(certificate, &Map.delete(&1, "sig"))
  end

  defp remove_enc(certificate) do
    mutate_certificate_envelope(certificate, &Map.delete(&1, "enc"))
  end

  defp mutate_certificate_envelope(certificate, mutator) do
    {header, footer, envelope} = decode_certificate_envelope(certificate)
    encode_certificate(header, footer, mutator.(envelope))
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
    metadata = Keyword.get(overrides, :metadata)
    license_format = Keyword.get(overrides, :license_format, :orchard_canonical)
    machine_format = Keyword.get(overrides, :machine_format, :orchard_canonical)

    license_attributes =
      %{
        "licensee" => licensee,
        "maxMachines" => max_machines,
        "notBefore" => not_before,
        "expiry" => expiry
      }
      |> maybe_put_metadata(metadata)

    license_payload = %{
      "data" => %{
        "type" => "licenses",
        "id" => license_id,
        "attributes" => license_attributes
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
      license_certificate:
        if(license_format == :orchard_canonical,
          do: sign_certificate("LICENSE", license_payload),
          else: sign_certificate("LICENSE", license_payload, license_format)
        ),
      machine_certificate:
        if(machine_format == :orchard_canonical,
          do: sign_certificate("MACHINE", machine_payload),
          else: sign_certificate("MACHINE", machine_payload, machine_format)
        )
    }
  end

  defp sign_certificate(kind, payload),
    do: sign_certificate(kind, payload, :orchard_canonical)

  defp maybe_put_metadata(attributes, nil), do: attributes
  defp maybe_put_metadata(attributes, metadata), do: Map.put(attributes, "metadata", metadata)

  defp sign_certificate(kind, payload, format) do
    payload_json = Jason.encode!(payload)

    envelope =
      case format do
        :orchard_canonical ->
          signature = :crypto.sign(:eddsa, :none, payload_json, [@private_key, :ed25519])

          %{
            "alg" => "ed25519",
            "enc" => "base64",
            "payload" => Base.encode64(payload_json),
            "sig" => Base.encode64(signature)
          }

        :keygen_checkout ->
          encoded_payload = Base.encode64(payload_json)
          signing_input = String.downcase(kind) <> "/" <> encoded_payload
          signature = :crypto.sign(:eddsa, :none, signing_input, [@private_key, :ed25519])

          %{
            "alg" => "base64+ed25519",
            "enc" => encoded_payload,
            "sig" => Base.encode64(signature)
          }
      end

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

  defp assert_keygen_checkout_envelope!(envelope) do
    assert envelope["alg"] == "base64+ed25519"
    assert is_binary(envelope["enc"])
    assert is_binary(envelope["sig"])
    refute Map.has_key?(envelope, "payload")
  end

  defp assert_keygen_signing_input!(certificate, kind) do
    {_, _, envelope} = decode_certificate_envelope(certificate)
    encoded_payload = envelope["enc"]
    signature = Base.decode64!(envelope["sig"])
    decoded_payload = Base.decode64!(encoded_payload)

    assert :crypto.verify(
             :eddsa,
             :none,
             kind <> "/" <> encoded_payload,
             signature,
             [@golden_public_key, :ed25519]
           )

    refute :crypto.verify(
             :eddsa,
             :none,
             decoded_payload,
             signature,
             [@golden_public_key, :ed25519]
           )
  end

  defp wrap_base64(encoded) do
    encoded
    |> String.graphemes()
    |> Enum.chunk_every(64)
    |> Enum.map_join("\n", &Enum.join/1)
  end
end
