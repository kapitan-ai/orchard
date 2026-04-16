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
    assert message =~ "activate <key>"
    assert message =~ "status"
  end

  test "activate help returns usage" do
    assert {:ok, message} = License.run(["activate", "--help"], runtime())
    assert message =~ "orchardctl license activate"
    assert message =~ "customer-safe Keygen flow"
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

  test "activate ensures node identity, extracts certificates, installs the pair, and does not echo the key" do
    runtime = runtime(request: &successful_activate_request/1)

    assert {:ok, message} =
             License.run(["activate", @license_key, "--support-root", @support_root], runtime)

    assert message =~ "License activated"
    assert message =~ @support_root <> "/config/licensing/current.json"
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
    refute message =~ "Node fingerprint:"

    assert_received {:inspect_local, opts}
    assert opts[:bundle_path] == Path.join([@support_root, "config", "licensing", "current.json"])
    assert opts[:node_identity_path] == Path.join([@support_root, "data", "node-id"])
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

  defp runtime(overrides \\ []) do
    request = Keyword.get(overrides, :request, &successful_activate_request/1)

    runtime = %{
      request: request,
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

  defp successful_activate_request(req) do
    record_request(req)

    case request_signature(req) do
      {:post, url} ->
        cond do
          url == validation_url() ->
            {:ok,
             %{
               status: 200,
               body: %{"data" => %{"id" => "lic_123"}, "meta" => %{"valid" => true}}
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

  defp existing_machine_request(req) do
    machine_lookup_request(req, [
      machine_lookup_page(machines_url() <> "?limit=100", existing_machine_data())
    ])
  end

  defp paginated_existing_machine_request(req) do
    machine_lookup_request(req, [
      machine_lookup_page(machines_url() <> "?limit=100", [], machines_page_url(2)),
      machine_lookup_page(machines_page_url(2), existing_machine_data(), nil)
    ])
  end

  defp machine_lookup_request(req, pages) do
    record_request(req)

    case request_signature(req) do
      {:post, url} ->
        machine_lookup_post_response(url, req)

      {:get, url} ->
        machine_lookup_get_response(url, pages, req)
    end
  end

  defp machine_lookup_post_response(url, req) do
    cond do
      url == validation_url() ->
        {:ok,
         %{status: 200, body: %{"data" => %{"id" => "lic_123"}, "meta" => %{"valid" => true}}}}

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

  defp successful_activate_request_from_app_config(req) do
    account_id =
      Application.fetch_env!(:orchard_shared, :licensing)
      |> Keyword.fetch!(:keygen_account_id)

    record_request(req)

    case request_signature(req) do
      {:post, url} ->
        cond do
          url == validation_url(account_id) ->
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
