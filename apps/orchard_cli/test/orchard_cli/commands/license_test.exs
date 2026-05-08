defmodule OrchardCLI.Commands.LicenseTest.NodeIdentitySpy do
  @moduledoc false

  def ensure(path) do
    send(self(), {:node_identity_ensure, path})

    Process.get(
      :node_identity_ensure_response,
      {:ok, "11111111-2222-4333-8444-555555555555", :existing}
    )
  end
end

defmodule OrchardCLI.Commands.LicenseTest.LicensingSpy do
  @moduledoc false

  def install_pair(bundle, opts) do
    send(self(), {:install_pair, bundle, opts})

    Process.get(
      :install_pair_response,
      {:ok,
       %Orchard.Licensing{
         state: :valid,
         message: "License bundle is valid.",
         bundle_path: Keyword.fetch!(opts, :bundle_path),
         fingerprint: "11111111-2222-4333-8444-555555555555",
         local_node_fingerprint: "11111111-2222-4333-8444-555555555555",
         expires_at: ~U[2027-04-15 00:00:00Z],
         license_id: "lic_123",
         machine_id: "mach_123",
         licensee: "Acme Orchard Lab",
         max_machines: 3
       }}
    )
  end

  def inspect_local(opts) do
    send(self(), {:inspect_local, opts})

    Process.get(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: Keyword.fetch!(opts, :bundle_path),
        fingerprint: "11111111-2222-4333-8444-555555555555",
        local_node_fingerprint: "11111111-2222-4333-8444-555555555555",
        expires_at: ~U[2027-04-15 00:00:00Z],
        license_id: "lic_123",
        machine_id: "mach_123",
        licensee: "Acme Orchard Lab",
        max_machines: 3
      }
    )
  end
end

defmodule OrchardCLI.Commands.LicenseTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.License

  @support_root "/tmp/orchard-license-test"
  @shared_support_root "/tmp/orchard-license-shared-config"
  @shared_bundle_path Path.join([@shared_support_root, "config", "licensing", "current.json"])
  @shared_node_identity_path Path.join([@shared_support_root, "data", "node-id"])
  @license_key "TEST-LICENSE-KEY-123"
  @node_id "11111111-2222-4333-8444-555555555555"
  @other_node_id "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  @account_id "orchard-test"
  @public_key "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
  @activation_required_codes ["NO_MACHINES", "NO_MACHINE", "FINGERPRINT_SCOPE_MISMATCH"]
  @activation_required_primary_code "NO_MACHINES"
  @activation_required_detail "fingerprint is not activated (has no associated machines)"
  @admin_token "SECRET_ADMIN_TOKEN"

  setup do
    Process.put(:requests, [])
    Process.delete(:node_identity_ensure_response)
    Process.delete(:install_pair_response)
    Process.delete(:inspect_local_response)
    :ok
  end

  test "group help returns usage" do
    assert {:ok, message} = License.run(["help"], runtime())
    assert message =~ "orchardctl license"
    assert message =~ "activate --key-stdin"
    assert message =~ "status"
    assert message =~ "create"
  end

  test "activate help returns usage" do
    assert {:ok, message} = License.run(["activate", "--help"], runtime())
    assert message =~ "orchardctl license activate"
    assert message =~ "customer-safe Keygen flow"
    assert message =~ "Prefer --key-stdin or --key-file"
    assert message =~ "Legacy/debug only"
    assert message =~ "current environment licensing config"
    refute message =~ "/Library/Application Support/Orchard"
  end

  test "status help returns usage" do
    assert {:ok, message} = License.run(["status", "--help"], runtime())
    assert message =~ "orchardctl license status"
    assert message =~ "without generating a node identity"
    assert message =~ "current environment licensing config"
    refute message =~ "/Library/Application Support/Orchard"
  end

  test "create help returns usage" do
    assert {:ok, message} = License.run(["create", "--help"], runtime())
    assert message =~ "orchardctl license create"
    assert message =~ "ORCHARD_KEYGEN_ADMIN_TOKEN"
    assert message =~ "--dry-run"
  end

  test "activate ensures node identity, extracts certificates, installs the pair, and does not echo the key" do
    runtime = runtime(request: &successful_activate_request/1)

    assert {:ok, message} =
             License.run(["activate", @license_key, "--support-root", @support_root], runtime)

    assert message =~ "License activated"
    assert message =~ @support_root <> "/config/licensing/current.json"
    refute message =~ "Tracking Program:"
    refute message =~ "Tracking Reference:"
    refute message =~ @license_key

    assert_received {:node_identity_ensure, path}
    assert path == Path.join([@support_root, "data", "node-id"])

    assert_received {:install_pair, bundle, opts}

    assert bundle == %{
             license_certificate: "LICENSE_CERTIFICATE",
             machine_certificate: "MACHINE_CERTIFICATE"
           }

    assert opts[:bundle_path] == Path.join([@support_root, "config", "licensing", "current.json"])
    assert opts[:node_identity_path] == Path.join([@support_root, "data", "node-id"])
    assert opts[:keygen_public_key] == @public_key

    requests = recorded_requests()

    assert Enum.map(requests, &request_signature/1) == [
             {:post, validation_url()},
             {:get, machines_url() <> "?limit=100"},
             {:post, machines_url()},
             {:post, license_checkout_url("lic_123")},
             {:post, machine_checkout_url("mach_123")}
           ]

    assert Enum.any?(
             requests,
             &(request_header(&1, "authorization") == "License #{@license_key}")
           )

    refute Enum.any?(requests, &(request_header(&1, "authorization") == "Bearer #{@license_key}"))
  end

  test "activate reads a non-argv key from stdin without echoing the key" do
    runtime =
      runtime(request: &successful_activate_request/1, stdin: fn -> @license_key <> "\n" end)

    assert {:ok, message} =
             License.run(["activate", "--key-stdin", "--support-root", @support_root], runtime)

    assert message =~ "License activated"
    refute message =~ @license_key

    assert Enum.any?(recorded_requests(), fn req ->
             request_header(req, "authorization") == "License #{@license_key}"
           end)
  end

  test "activate reads a non-argv key from a 0600 file" do
    path =
      Path.join(System.tmp_dir!(), "orchard-license-key-#{System.unique_integer([:positive])}")

    File.write!(path, @license_key <> "\n")
    File.chmod!(path, 0o600)

    try do
      assert {:ok, message} =
               License.run(
                 ["activate", "--key-file", path, "--support-root", @support_root],
                 runtime()
               )

      assert message =~ "License activated"
      refute message =~ @license_key

      assert Enum.any?(recorded_requests(), fn req ->
               request_header(req, "authorization") == "License #{@license_key}"
             end)
    after
      File.rm(path)
    end
  end

  test "activate rejects symlink key files without reading the key" do
    target_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-license-key-target-#{System.unique_integer([:positive])}"
      )

    link_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-license-key-link-#{System.unique_integer([:positive])}"
      )

    File.write!(target_path, @license_key <> "\n")
    File.chmod!(target_path, 0o600)
    File.ln_s!(target_path, link_path)

    try do
      assert {:error, message, 1} =
               License.run(
                 ["activate", "--key-file", link_path, "--support-root", @support_root],
                 runtime(request: &unexpected_request/1)
               )

      assert message =~ "must be a regular file"
      refute message =~ @license_key
      assert recorded_requests() == []
    after
      File.rm(link_path)
      File.rm(target_path)
    end
  end

  test "activate rejects key files that are not 0600 without reading the key" do
    path =
      Path.join(System.tmp_dir!(), "orchard-license-key-#{System.unique_integer([:positive])}")

    File.write!(path, @license_key <> "\n")
    File.chmod!(path, 0o644)

    try do
      assert {:error, message, 1} =
               License.run(
                 ["activate", "--key-file", path, "--support-root", @support_root],
                 runtime(request: &unexpected_request/1)
               )

      assert message =~ "must have 0600 permissions"
      refute message =~ @license_key
      assert recorded_requests() == []
    after
      File.rm(path)
    end
  end

  test "activate requires exactly one key source" do
    assert {:error, message, 1} =
             License.run(["activate", @license_key, "--key-stdin"], runtime())

    assert message =~ "expected exactly one license key source"
    refute message =~ @license_key
  end

  test "activate success output renders tracking metadata without echoing the key" do
    Process.put(
      :install_pair_response,
      {:ok,
       %Orchard.Licensing{
         state: :valid,
         message: "License bundle is valid.",
         bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
         fingerprint: @node_id,
         local_node_fingerprint: @node_id,
         expires_at: ~U[2027-04-15 00:00:00Z],
         license_id: "lic_123",
         machine_id: "mach_123",
         metadata: %{program: "aieh", reference: "aieh-2026-001"}
       }}
    )

    assert {:ok, message} =
             License.run(["activate", @license_key, "--support-root", @support_root], runtime())

    assert message =~ "Tracking Program: AIEH"
    assert message =~ "Tracking Reference: aieh-2026-001"
    refute message =~ @license_key
  end

  test "activate skips machine creation when the node fingerprint already exists" do
    runtime = runtime(request: &existing_machine_request/1)

    assert {:ok, _message} = License.run(["activate", @license_key], runtime)

    requests = recorded_requests()

    refute Enum.any?(requests, fn req ->
             request_signature(req) == {:post, machines_url()}
           end)
  end

  test "activate paginates machine lookup and reuses an existing machine on a later page" do
    runtime = runtime(request: &paginated_existing_machine_request/1)

    assert {:ok, _message} = License.run(["activate", @license_key], runtime)

    requests = recorded_requests()

    assert Enum.map(requests, &request_signature/1) == [
             {:post, validation_url()},
             {:get, machines_url() <> "?limit=100"},
             {:get, machines_page_url(2)},
             {:post, license_checkout_url("lic_123")},
             {:post, machine_checkout_url("mach_existing")}
           ]

    refute Enum.any?(requests, fn req ->
             request_signature(req) == {:post, machines_url()}
           end)
  end

  test "activate continues to machine creation for allowlisted NO_MACHINES validate-key responses" do
    runtime = runtime(request: &activation_required_new_machine_request/1)

    assert {:ok, _message} = License.run(["activate", @license_key], runtime)

    assert Enum.map(recorded_requests(), &request_signature/1) == [
             {:post, validation_url()},
             {:get, machines_url() <> "?limit=100"},
             {:post, machines_url()},
             {:post, license_checkout_url("lic_123")},
             {:post, machine_checkout_url("mach_123")}
           ]
  end

  test "activate reuses an existing machine for allowlisted NO_MACHINES validate-key responses" do
    runtime = runtime(request: &activation_required_existing_machine_request/1)

    assert {:ok, _message} = License.run(["activate", @license_key], runtime)

    requests = recorded_requests()

    assert Enum.map(requests, &request_signature/1) == [
             {:post, validation_url()},
             {:get, machines_url() <> "?limit=100"},
             {:post, license_checkout_url("lic_123")},
             {:post, machine_checkout_url("mach_existing")}
           ]

    refute Enum.any?(requests, fn req ->
             request_signature(req) == {:post, machines_url()}
           end)
  end

  test "activate continues to machine creation for NO_MACHINE validate-key responses" do
    runtime = runtime(request: &activation_required_new_machine_request(&1, code: "NO_MACHINE"))

    assert {:ok, _message} = License.run(["activate", @license_key], runtime)

    assert Enum.map(recorded_requests(), &request_signature/1) == [
             {:post, validation_url()},
             {:get, machines_url() <> "?limit=100"},
             {:post, machines_url()},
             {:post, license_checkout_url("lic_123")},
             {:post, machine_checkout_url("mach_123")}
           ]
  end

  test "activate keeps unknown false validate-key codes as terminal failures" do
    unknown_code = "FINGERPRINT_NOT_ACTIVE"
    refute unknown_code in @activation_required_codes

    runtime =
      runtime(
        request: fn req ->
          validate_only_request(req, activation_required_validation_body(code: unknown_code))
        end
      )

    assert {:error, message, 1} = License.run(["activate", @license_key], runtime)
    assert message =~ @activation_required_detail

    assert Enum.map(recorded_requests(), &request_signature/1) == [
             {:post, validation_url()}
           ]
  end

  test "activate treats allowlisted false validate-key responses without data ids as malformed" do
    runtime =
      runtime(
        request: fn req ->
          validate_only_request(req, activation_required_validation_body(license_id: nil))
        end
      )

    assert {:error, message, 1} = License.run(["activate", @license_key], runtime)
    assert message =~ "Malformed response from license validation"

    assert Enum.map(recorded_requests(), &request_signature/1) == [
             {:post, validation_url()}
           ]
  end

  test "activate continues to machine creation for FINGERPRINT_SCOPE_MISMATCH validate-key responses" do
    runtime =
      runtime(
        request: &activation_required_new_machine_request(&1, code: "FINGERPRINT_SCOPE_MISMATCH")
      )

    assert {:ok, _message} = License.run(["activate", @license_key], runtime)

    assert Enum.map(recorded_requests(), &request_signature/1) == [
             {:post, validation_url()},
             {:get, machines_url() <> "?limit=100"},
             {:post, machines_url()},
             {:post, license_checkout_url("lic_123")},
             {:post, machine_checkout_url("mach_123")}
           ]
  end

  test "activate reuses existing machine for FINGERPRINT_SCOPE_MISMATCH validate-key responses" do
    runtime =
      runtime(
        request:
          &activation_required_existing_machine_request(&1, code: "FINGERPRINT_SCOPE_MISMATCH")
      )

    assert {:ok, _message} = License.run(["activate", @license_key], runtime)

    requests = recorded_requests()

    assert Enum.map(requests, &request_signature/1) == [
             {:post, validation_url()},
             {:get, machines_url() <> "?limit=100"},
             {:post, license_checkout_url("lic_123")},
             {:post, machine_checkout_url("mach_existing")}
           ]

    refute Enum.any?(requests, fn req ->
             request_signature(req) == {:post, machines_url()}
           end)
  end

  test "activate treats FINGERPRINT_SCOPE_MISMATCH without license id as malformed" do
    runtime =
      runtime(
        request: fn req ->
          validate_only_request(
            req,
            activation_required_validation_body(
              code: "FINGERPRINT_SCOPE_MISMATCH",
              license_id: nil
            )
          )
        end
      )

    assert {:error, message, 1} = License.run(["activate", @license_key], runtime)
    assert message =~ "Malformed response from license validation"

    assert Enum.map(recorded_requests(), &request_signature/1) == [
             {:post, validation_url()}
           ]
  end

  test "activate redacts the key from provider error details" do
    runtime =
      runtime(
        request: fn req ->
          record_request(req)

          {:ok,
           %{
             status: 404,
             body: %{
               "errors" => [
                 %{
                   "title" => "Not found",
                   "detail" => "license key #{@license_key} is invalid",
                   "code" => "KEY_NOT_FOUND"
                 }
               ]
             }
           }}
        end
      )

    assert {:error, message, 1} = License.run(["activate", @license_key], runtime)
    assert message =~ "[REDACTED]"
    refute message =~ @license_key
  end

  test "activate returns actionable invalid-key error without echoing the key" do
    runtime =
      runtime(
        request: fn req ->
          record_request(req)

          {:ok,
           %{
             status: 404,
             body: %{
               "errors" => [
                 %{
                   "title" => "Not found",
                   "detail" => "license key is invalid",
                   "code" => "KEY_NOT_FOUND"
                 }
               ]
             }
           }}
        end
      )

    assert {:error, message, 1} = License.run(["activate", @license_key], runtime)
    assert message =~ "License validation failed"
    assert message =~ "license key is invalid"
    refute message =~ @license_key
  end

  test "activate returns actionable malformed-provider error without echoing the key" do
    runtime =
      runtime(
        request: fn req ->
          record_request(req)

          case request_signature(req) do
            {:post, url} ->
              if url == validation_url() do
                {:ok, %{status: 200, body: %{"meta" => %{"valid" => true}}}}
              else
                flunk("unexpected request: #{inspect(req)}")
              end

            _other ->
              flunk("unexpected request: #{inspect(req)}")
          end
        end
      )

    assert {:error, message, 1} = License.run(["activate", @license_key], runtime)
    assert message =~ "Malformed response from license validation"
    refute message =~ @license_key
  end

  test "activate returns actionable network error without echoing the key" do
    runtime =
      runtime(
        request: fn req ->
          record_request(req)
          {:error, :econnrefused}
        end
      )

    assert {:error, message, 1} = License.run(["activate", @license_key], runtime)
    assert message =~ "License validation request failed"
    assert message =~ ":econnrefused"
    refute message =~ @license_key
  end

  test "activate uses shipped shared licensing config when runtime shared_config is omitted" do
    runtime =
      runtime(
        request: &successful_activate_request_from_app_config/1,
        shared_config: :application_config
      )

    assert {:ok, message} =
             License.run(["activate", @license_key, "--support-root", @support_root], runtime)

    assert message =~ "License activated"

    assert_received {:install_pair, _bundle, opts}

    assert opts[:keygen_public_key] ==
             Application.fetch_env!(:orchard_shared, :licensing)
             |> Keyword.fetch!(:keygen_public_key)
  end

  test "activate without explicit support root uses shared licensing paths" do
    assert {:ok, _message} = License.run(["activate", @license_key], runtime())

    assert_received {:node_identity_ensure, path}
    assert path == @shared_node_identity_path

    assert_received {:install_pair, _bundle, opts}
    assert opts[:bundle_path] == @shared_bundle_path
    assert opts[:node_identity_path] == @shared_node_identity_path
  end

  test "activate returns config error when account ID is missing" do
    runtime =
      runtime(
        shared_config: fn ->
          [
            bundle_path: @shared_bundle_path,
            node_identity_path: @shared_node_identity_path,
            keygen_public_key: @public_key
          ]
        end
      )

    assert {:error, message, 1} = License.run(["activate", @license_key], runtime)
    assert message =~ "Keygen account ID is not configured"
  end

  test "activate returns actionable identity permission errors" do
    Process.put(:node_identity_ensure_response, {:error, {:write_failed, :eacces}})

    assert {:error, message, 1} = License.run(["activate", @license_key], runtime())
    assert message =~ "Cannot persist node identity file"
    assert message =~ ":eacces"
    refute message =~ @license_key
  end

  test "status inspects the local bundle directly and does not generate a node identity" do
    runtime = runtime()

    assert {:ok, message} = License.run(["status", "--support-root", @support_root], runtime)

    assert message =~ "License status: valid"
    assert message =~ "License bundle is valid."
    assert message =~ @support_root <> "/config/licensing/current.json"
    assert message =~ "Machine certificate fingerprint: #{@node_id}"
    refute message =~ "Tracking Program:"
    refute message =~ "Tracking Reference:"
    refute message =~ "Node fingerprint:"

    assert_received {:inspect_local, opts}
    assert opts[:bundle_path] == Path.join([@support_root, "config", "licensing", "current.json"])
    assert opts[:node_identity_path] == Path.join([@support_root, "data", "node-id"])
    refute_received {:node_identity_ensure, _path}
  end

  test "status output renders tracking metadata with known program labels" do
    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
        fingerprint: @node_id,
        local_node_fingerprint: @node_id,
        expires_at: ~U[2027-04-15 00:00:00Z],
        license_id: "lic_123",
        machine_id: "mach_123",
        metadata: %{program: "100e", reference: "100e-2026-alpha"}
      }
    )

    assert {:ok, message} = License.run(["status", "--support-root", @support_root], runtime())

    assert message =~ "Tracking Program: 100E"
    assert message =~ "Tracking Reference: 100e-2026-alpha"
    refute_received {:node_identity_ensure, _path}
  end

  test "status without explicit support root uses shared licensing paths" do
    assert {:ok, _message} = License.run(["status"], runtime())

    assert_received {:inspect_local, opts}
    assert opts[:bundle_path] == @shared_bundle_path
    assert opts[:node_identity_path] == @shared_node_identity_path
    refute_received {:node_identity_ensure, _path}
  end

  test "status shows both local and machine certificate fingerprints for mismatches" do
    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :fingerprint_mismatch,
        message: "Machine certificate fingerprint does not match the local node identity.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
        fingerprint: @other_node_id,
        local_node_fingerprint: @node_id,
        license_id: "lic_123",
        machine_id: "mach_123"
      }
    )

    assert {:ok, message} = License.run(["status", "--support-root", @support_root], runtime())

    assert message =~ "License status: fingerprint_mismatch"
    assert message =~ "Local node fingerprint: #{@node_id}"
    assert message =~ "Machine certificate fingerprint: #{@other_node_id}"
    refute message =~ "Node fingerprint:"
    refute_received {:node_identity_ensure, _path}
  end

  test "status output for invalid signature omits unsafe identity and tracking details" do
    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :invalid_license_signature,
        message: "License certificate signature is invalid.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
        fingerprint: @node_id,
        local_node_fingerprint: @node_id,
        license_id: "lic_hidden",
        machine_id: "mach_hidden",
        licensee: "Hidden",
        max_machines: 1,
        metadata: %{program: "aieh", reference: "aieh-2026-001"}
      }
    )

    assert {:ok, message} = License.run(["status", "--support-root", @support_root], runtime())

    assert message =~ "License status: invalid_license_signature"
    assert message =~ "Message: License certificate signature is invalid."

    assert message =~
             "Bundle path: #{Path.join([@support_root, "config", "licensing", "current.json"])}"

    refute message =~ "Local node fingerprint"
    refute message =~ "Machine certificate fingerprint"
    refute message =~ "License ID"
    refute message =~ "Machine ID"
    refute message =~ "Licensee"
    refute message =~ "Max machines"
    refute message =~ "Tracking Program"
    refute message =~ "Tracking Reference"
  end

  test "status json valid license emits stable safe schema with tracking" do
    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
        fingerprint: @node_id,
        local_node_fingerprint: @node_id,
        expires_at: ~U[2027-04-15 00:00:00Z],
        license_id: "lic_123",
        machine_id: "mach_123",
        licensee: "Acme Orchard Lab",
        max_machines: 3,
        metadata: %{program: "aieh", reference: "aieh-2026-001"}
      }
    )

    assert {:ok, output} =
             License.run(["status", "--support-root", @support_root, "--json"], runtime())

    assert Jason.decode!(output) == %{
             "state" => "valid",
             "message" => "License bundle is valid.",
             "bundle_path" => Path.join([@support_root, "config", "licensing", "current.json"]),
             "fingerprint" => @node_id,
             "local_node_fingerprint" => @node_id,
             "license_id" => "lic_123",
             "machine_id" => "mach_123",
             "licensee" => "Acme Orchard Lab",
             "max_machines" => 3,
             "expires_at" => "2027-04-15T00:00:00Z",
             "tracking" => %{"program" => "aieh", "reference" => "aieh-2026-001"}
           }

    assert output =~ "{\n"
    assert output =~ "\n  \"state\""
    refute output =~ ": null"
    refute output =~ "LICENSE_CERTIFICATE"
    refute output =~ "MACHINE_CERTIFICATE"
    refute output =~ "admin_token"
    refute output =~ @admin_token
    refute_received {:node_identity_ensure, _path}
  end

  test "status json missing license omits identity fields entirely" do
    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :missing_bundle,
        message: "No local license bundle is installed.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"])
      }
    )

    assert {:ok, output} =
             License.run(["status", "--support-root", @support_root, "--json"], runtime())

    decoded = Jason.decode!(output)

    assert decoded["state"] == "missing"
    assert decoded["reason"] == "missing_bundle"
    assert decoded["message"] == "No local license bundle is installed."
    refute Map.has_key?(decoded, "license_id")
    refute Map.has_key?(decoded, "machine_id")
    refute Map.has_key?(decoded, "licensee")
    refute Map.has_key?(decoded, "max_machines")
    refute Map.has_key?(decoded, "tracking")
    refute output =~ ": null"
  end

  test "status json invalid license omits unsafe identity and fingerprint fields" do
    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :invalid_license_signature,
        message: "License certificate signature is invalid.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
        fingerprint: @node_id,
        local_node_fingerprint: @node_id,
        license_id: "lic_bad_sig",
        machine_id: "mach_bad_sig",
        licensee: "Acme Orchard Lab",
        max_machines: 3,
        metadata: %{program: "aieh", reference: "aieh-2026-001"}
      }
    )

    assert {:ok, output} =
             License.run(["status", "--support-root", @support_root, "--json"], runtime())

    decoded = Jason.decode!(output)

    assert decoded["state"] == "invalid"
    assert decoded["reason"] == "invalid_license_signature"

    for key <- [
          "license_id",
          "machine_id",
          "licensee",
          "max_machines",
          "tracking",
          "fingerprint",
          "local_node_fingerprint"
        ] do
      refute Map.has_key?(decoded, key)
    end

    refute output =~ ": null"
  end

  test "status json omits nil tracking fields and keeps present tracking subkeys" do
    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
        metadata: %{program: nil, reference: nil}
      }
    )

    assert {:ok, output} =
             License.run(["status", "--support-root", @support_root, "--json"], runtime())

    refute Map.has_key?(Jason.decode!(output), "tracking")

    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
        metadata: %{program: "aieh", reference: nil}
      }
    )

    assert {:ok, output} =
             License.run(["status", "--support-root", @support_root, "--json"], runtime())

    assert Jason.decode!(output)["tracking"] == %{"program" => "aieh"}
  end

  test "status json omits tracking when metadata is missing or empty" do
    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
        metadata: nil
      }
    )

    assert {:ok, output} =
             License.run(["status", "--support-root", @support_root, "--json"], runtime())

    refute Map.has_key?(Jason.decode!(output), "tracking")

    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
        metadata: %{}
      }
    )

    assert {:ok, output} =
             License.run(["status", "--support-root", @support_root, "--json"], runtime())

    refute Map.has_key?(Jason.decode!(output), "tracking")
  end

  test "status json omits absent identifiers instead of encoding null" do
    Process.put(
      :inspect_local_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: Path.join([@support_root, "config", "licensing", "current.json"]),
        fingerprint: @node_id,
        local_node_fingerprint: @node_id,
        expires_at: ~U[2027-04-15 00:00:00Z]
      }
    )

    assert {:ok, output} =
             License.run(["status", "--support-root", @support_root, "--json"], runtime())

    decoded = Jason.decode!(output)

    refute Map.has_key?(decoded, "license_id")
    refute Map.has_key?(decoded, "machine_id")
    refute Map.has_key?(decoded, "licensee")
    refute Map.has_key?(decoded, "max_machines")
    refute output =~ ": null"
  end

  test "create dry-run emits JSON API payload with orchard_tracking metadata" do
    assert {:ok, output} =
             License.run(
               [
                 "create",
                 "--policy-id",
                 "pol_123",
                 "--name",
                 "AIEH Trial",
                 "--max-machines",
                 "3",
                 "--expires-at",
                 "2027-04-15T00:00:00Z",
                 "--tracking-program",
                 " AIEH ",
                 "--tracking-reference",
                 " AIEH-2026-001 ",
                 "--dry-run"
               ],
               runtime(request: &unexpected_request/1)
             )

    assert Jason.decode!(output) == %{
             "data" => %{
               "type" => "licenses",
               "attributes" => %{
                 "name" => "AIEH Trial",
                 "maxMachines" => 3,
                 "expiry" => "2027-04-15T00:00:00Z",
                 "metadata" => %{
                   "orchard_tracking" => %{
                     "program" => "aieh",
                     "reference" => "aieh-2026-001"
                   }
                 }
               },
               "relationships" => %{
                 "policy" => %{
                   "data" => %{"type" => "policies", "id" => "pol_123"}
                 }
               }
             }
           }

    assert recorded_requests() == []
  end

  test "create dry-run omits metadata when tracking flags are absent" do
    assert {:ok, output} =
             License.run(
               [
                 "create",
                 "--policy-id",
                 "pol_123",
                 "--name",
                 "Plain Trial",
                 "--dry-run"
               ],
               runtime(request: &unexpected_request/1)
             )

    attributes = get_in(Jason.decode!(output), ["data", "attributes"])

    assert attributes == %{"name" => "Plain Trial"}
    refute Map.has_key?(attributes, "metadata")
    assert recorded_requests() == []
  end

  test "create live mode requires admin token and does not perform network request" do
    runtime =
      runtime(request: &unexpected_request/1)
      |> Map.put(:admin_token, fn _name -> nil end)

    assert {:error, message, 1} =
             License.run(
               ["create", "--policy-id", "pol_123", "--name", "AIEH Trial"],
               runtime
             )

    assert message =~ "ORCHARD_KEYGEN_ADMIN_TOKEN is required"
    refute message =~ @admin_token
    assert recorded_requests() == []
  end

  test "create live mode posts payload with bearer admin token and renders created license" do
    runtime =
      runtime(request: &successful_create_request/1)
      |> Map.put(:admin_token, fn "ORCHARD_KEYGEN_ADMIN_TOKEN" -> @admin_token end)

    assert {:ok, message} =
             License.run(
               [
                 "create",
                 "--policy-id",
                 "pol_123",
                 "--name",
                 "SIP Trial",
                 "--tracking-program",
                 "sip",
                 "--tracking-reference",
                 "sip-2026-001"
               ],
               runtime
             )

    assert message =~ "License created"
    assert message =~ "License ID: lic_created"
    assert message =~ "License key: CREATED-LICENSE-KEY"
    assert message =~ "Tracking Program: SIP"
    assert message =~ "Tracking Reference: sip-2026-001"
    refute message =~ @admin_token

    assert [request] = recorded_requests()
    assert request_signature(request) == {:post, licenses_url()}
    assert request_header(request, "authorization") == "Bearer #{@admin_token}"

    assert get_in(request.body, ["data", "attributes", "metadata"]) == %{
             "orchard_tracking" => %{
               "program" => "sip",
               "reference" => "sip-2026-001"
             }
           }
  end

  test "create live errors redact admin token" do
    runtime =
      runtime(
        request: fn req ->
          record_request(req)
          {:error, {:leaked, @admin_token}}
        end
      )
      |> Map.put(:admin_token, fn "ORCHARD_KEYGEN_ADMIN_TOKEN" -> @admin_token end)

    assert {:error, message, 1} =
             License.run(
               ["create", "--policy-id", "pol_123", "--name", "AIEH Trial"],
               runtime
             )

    refute message =~ @admin_token
    assert message =~ "[REDACTED]"
  end

  defp runtime(overrides \\ []) do
    request = Keyword.get(overrides, :request, &successful_activate_request/1)

    runtime = %{
      request: request,
      read_stdin: Keyword.get(overrides, :stdin, fn -> "" end),
      licensing_impl: OrchardCLI.Commands.LicenseTest.LicensingSpy,
      node_identity_impl: OrchardCLI.Commands.LicenseTest.NodeIdentitySpy
    }

    case Keyword.get(overrides, :shared_config, :default) do
      :application_config ->
        runtime

      :default ->
        Map.put(runtime, :shared_config, &shared_config/0)

      shared_config ->
        Map.put(runtime, :shared_config, shared_config)
    end
  end

  defp shared_config do
    [
      bundle_path: @shared_bundle_path,
      node_identity_path: @shared_node_identity_path,
      keygen_api_base_url: "https://api.keygen.sh",
      keygen_account_id: @account_id,
      keygen_public_key: @public_key
    ]
  end

  defp successful_activate_request(req, opts \\ []) do
    validation_body = Keyword.get(opts, :validation_body, valid_validation_body())

    record_request(req)

    case request_signature(req) do
      {:post, url} ->
        cond do
          url == validation_url() ->
            assert get_in(req, [:body, "meta", "key"]) == @license_key
            assert get_in(req, [:body, "meta", "scope", "fingerprint"]) == @node_id

            {:ok,
             %{
               status: 200,
               body: validation_body
             }}

          url == machines_url() ->
            assert request_header(req, "authorization") == "License #{@license_key}"
            assert get_in(req, [:body, "data", "attributes", "fingerprint"]) == @node_id
            {:ok, %{status: 201, body: %{"data" => %{"id" => "mach_123"}}}}

          url == license_checkout_url("lic_123") ->
            {:ok,
             %{
               status: 200,
               body: %{"data" => %{"attributes" => %{"certificate" => "LICENSE_CERTIFICATE"}}}
             }}

          url == machine_checkout_url("mach_123") ->
            {:ok,
             %{
               status: 200,
               body: %{"data" => %{"attributes" => %{"certificate" => "MACHINE_CERTIFICATE"}}}
             }}

          true ->
            flunk("unexpected request: #{inspect(req)}")
        end

      {:get, url} ->
        if url == machines_url() <> "?limit=100" do
          {:ok, %{status: 200, body: %{"data" => []}}}
        else
          flunk("unexpected request: #{inspect(req)}")
        end
    end
  end

  defp successful_create_request(req) do
    record_request(req)

    case request_signature(req) do
      {:post, url} ->
        if url == licenses_url() do
          assert request_header(req, "authorization") == "Bearer #{@admin_token}"
          assert get_in(req, [:body, "data", "type"]) == "licenses"

          {:ok,
           %{
             status: 201,
             body: %{
               "data" => %{
                 "id" => "lic_created",
                 "type" => "licenses",
                 "attributes" => %{"key" => "CREATED-LICENSE-KEY"}
               }
             }
           }}
        else
          flunk("unexpected request: #{inspect(req)}")
        end

      _other ->
        flunk("unexpected request: #{inspect(req)}")
    end
  end

  defp unexpected_request(req) do
    flunk("unexpected request: #{inspect(req)}")
  end

  defp existing_machine_request(req) do
    machine_lookup_request(req, [
      machine_lookup_page(machines_url() <> "?limit=100", existing_machine_data())
    ])
  end

  defp activation_required_new_machine_request(req, opts \\ []) do
    code = Keyword.get(opts, :code, @activation_required_primary_code)

    successful_activate_request(req,
      validation_body: activation_required_validation_body(code: code)
    )
  end

  defp activation_required_existing_machine_request(req, opts \\ []) do
    code = Keyword.get(opts, :code, @activation_required_primary_code)

    machine_lookup_request(
      req,
      [machine_lookup_page(machines_url() <> "?limit=100", existing_machine_data())],
      activation_required_validation_body(code: code)
    )
  end

  defp paginated_existing_machine_request(req) do
    machine_lookup_request(req, [
      machine_lookup_page(machines_url() <> "?limit=100", [], machines_page_url(2)),
      machine_lookup_page(machines_page_url(2), existing_machine_data(), nil)
    ])
  end

  defp machine_lookup_request(req, pages, validation_body \\ valid_validation_body()) do
    record_request(req)

    case request_signature(req) do
      {:post, url} ->
        machine_lookup_post_response(url, req, validation_body)

      {:get, url} ->
        machine_lookup_get_response(url, pages, req)
    end
  end

  defp machine_lookup_post_response(url, req, validation_body) do
    cond do
      url == validation_url() ->
        {:ok, %{status: 200, body: validation_body}}

      url == license_checkout_url("lic_123") ->
        {:ok,
         %{
           status: 200,
           body: %{"data" => %{"attributes" => %{"certificate" => "LICENSE_CERTIFICATE"}}}
         }}

      url == machine_checkout_url("mach_existing") ->
        {:ok,
         %{
           status: 200,
           body: %{"data" => %{"attributes" => %{"certificate" => "MACHINE_CERTIFICATE"}}}
         }}

      true ->
        flunk("unexpected request: #{inspect(req)}")
    end
  end

  defp machine_lookup_get_response(url, pages, req) do
    case Enum.find(pages, &(Map.fetch!(&1, :url) == url)) do
      nil ->
        flunk("unexpected request: #{inspect(req)}")

      page ->
        {:ok, %{status: 200, body: Map.fetch!(page, :body)}}
    end
  end

  defp machine_lookup_page(url, data, next_url \\ :no_links) do
    %{
      url: url,
      body: machine_lookup_body(data, next_url)
    }
  end

  defp machine_lookup_body(data, :no_links), do: %{"data" => data}

  defp machine_lookup_body(data, next_url) do
    %{
      "data" => data,
      "links" => %{"next" => next_url}
    }
  end

  defp existing_machine_data do
    [%{"id" => "mach_existing", "attributes" => %{"fingerprint" => @node_id}}]
  end

  defp valid_validation_body do
    %{"data" => %{"id" => "lic_123"}, "meta" => %{"valid" => true}}
  end

  defp activation_required_validation_body(opts) do
    code = Keyword.get(opts, :code, @activation_required_primary_code)

    body = %{
      "meta" => %{
        "code" => code,
        "valid" => false,
        "detail" => @activation_required_detail
      }
    }

    case Keyword.get(opts, :license_id, "lic_123") do
      nil -> body
      license_id -> Map.put(body, "data", %{"id" => license_id})
    end
  end

  defp validate_only_request(req, response_body) do
    record_request(req)

    case request_signature(req) do
      {:post, url} ->
        if url == validation_url() do
          assert get_in(req, [:body, "meta", "key"]) == @license_key
          assert get_in(req, [:body, "meta", "scope", "fingerprint"]) == @node_id
          {:ok, %{status: 200, body: response_body}}
        else
          flunk("unexpected request: #{inspect(req)}")
        end

      _other ->
        flunk("unexpected request: #{inspect(req)}")
    end
  end

  defp successful_activate_request_from_app_config(req) do
    account_id =
      Application.fetch_env!(:orchard_shared, :licensing)
      |> Keyword.fetch!(:keygen_account_id)

    record_request(req)

    case request_signature(req) do
      {:post, url} ->
        cond do
          url == validation_url(account_id) ->
            assert get_in(req, [:body, "meta", "key"]) == @license_key
            assert get_in(req, [:body, "meta", "scope", "fingerprint"]) == @node_id

            {:ok,
             %{
               status: 200,
               body: %{"data" => %{"id" => "lic_123"}, "meta" => %{"valid" => true}}
             }}

          url == machines_url(account_id) ->
            assert request_header(req, "authorization") == "License #{@license_key}"
            assert get_in(req, [:body, "data", "attributes", "fingerprint"]) == @node_id
            {:ok, %{status: 201, body: %{"data" => %{"id" => "mach_123"}}}}

          url == license_checkout_url("lic_123", account_id) ->
            {:ok,
             %{
               status: 200,
               body: %{"data" => %{"attributes" => %{"certificate" => "LICENSE_CERTIFICATE"}}}
             }}

          url == machine_checkout_url("mach_123", account_id) ->
            {:ok,
             %{
               status: 200,
               body: %{"data" => %{"attributes" => %{"certificate" => "MACHINE_CERTIFICATE"}}}
             }}

          true ->
            flunk("unexpected request: #{inspect(req)}")
        end

      {:get, url} ->
        if url == machines_url(account_id) <> "?limit=100" do
          {:ok, %{status: 200, body: %{"data" => []}}}
        else
          flunk("unexpected request: #{inspect(req)}")
        end
    end
  end

  defp record_request(req) do
    Process.put(:requests, [req | Process.get(:requests, [])])
  end

  defp recorded_requests do
    Process.get(:requests, []) |> Enum.reverse()
  end

  defp request_signature(req), do: {req.method, req.url}

  defp request_header(req, key) do
    req.headers
    |> Enum.find_value(fn {header, value} -> if String.downcase(header) == key, do: value end)
  end

  defp validation_url(account_id \\ @account_id) do
    "https://api.keygen.sh/v1/accounts/#{account_id}/licenses/actions/validate-key"
  end

  defp licenses_url(account_id \\ @account_id) do
    "https://api.keygen.sh/v1/accounts/#{account_id}/licenses"
  end

  defp machines_url(account_id \\ @account_id) do
    "https://api.keygen.sh/v1/accounts/#{account_id}/machines"
  end

  defp machines_page_url(page_number, account_id \\ @account_id) do
    machines_url(account_id) <> "?limit=100&page[number]=#{page_number}"
  end

  defp license_checkout_url(license_id, account_id \\ @account_id) do
    "https://api.keygen.sh/v1/accounts/#{account_id}/licenses/#{license_id}/actions/check-out"
  end

  defp machine_checkout_url(fingerprint, account_id \\ @account_id) do
    "https://api.keygen.sh/v1/accounts/#{account_id}/machines/#{fingerprint}/actions/check-out"
  end
end
