defmodule Orchard.RuntimeTransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_config Path.expand("../../../config/runtime.exs", __DIR__)

  setup do
    env_snapshot =
      System.get_env()
      |> Enum.filter(fn {key, _value} -> config_env_key?(key) end)
      |> Map.new()

    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "orchard-runtime-transport-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      clear_config_env!()
      Enum.each(env_snapshot, fn {key, value} -> System.put_env(key, value) end)
      File.rm_rf(tmp_root)
    end)

    {:ok, support_root: tmp_root}
  end

  test "OpenSpec task 2.10 production config supplies a protected NodeTrust root", %{
    support_root: support_root
  } do
    config = read_controller_config!(support_root, %{})

    assert config[:node_trust] == [
             root: Path.join([support_root, "config", "node-trust"])
           ]

    override_root = Path.join(support_root, "custom-node-trust")

    overridden =
      read_controller_config!(support_root, %{"ORCHARD_NODE_TRUST_ROOT" => override_root})

    assert overridden[:node_trust] == [root: override_root]
  end

  test "SPEC.md §7.5.0 production grants configure an explicit private control listener", %{
    support_root: support_root
  } do
    authorization_root = Path.join(support_root, "beam-authorization-root")
    manifest_path = Path.join(support_root, "controller-launch.json")

    config =
      read_controller_config!(support_root, %{
        "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
        "ORCHARD_BEAM_NODE_NAME" =>
          "orchard_controller_aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa@10.0.0.10",
        "ORCHARD_BEAM_PEER_GRANTS_ENABLED" => "true",
        "ORCHARD_BEAM_PEER_GRANT_MODE" => "distributed",
        "ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST" => manifest_path,
        "ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST" => "10.0.0.10",
        "ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT" => "50072",
        "ORCHARD_CONTROLLER_MEMBERSHIP_HOST" => "10.0.0.10",
        "ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH" => authorization_root
      })

    assert config[:beam_peer_grants] == [
             enabled: true,
             mode: :distributed,
             authorization_root_path: authorization_root,
             manifest_path: manifest_path,
             cookie_file: nil,
             static_targets: [],
             control_listener: [host: "10.0.0.10", port: 50_072]
           ]

    assert config[:runtime_endpoint][:beam][:cookie_file] == nil
  end

  test "SPEC.md §7.5.0 production grants require an explicit launch mode", %{
    support_root: support_root
  } do
    assert_raise RuntimeError, ~r/ORCHARD_BEAM_PEER_GRANT_MODE is required/, fn ->
      read_controller_config!(support_root, %{
        "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
        "ORCHARD_BEAM_NODE_NAME" =>
          "orchard_controller_aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa@10.0.0.10",
        "ORCHARD_BEAM_PEER_GRANTS_ENABLED" => "true",
        "ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST" => "10.0.0.10",
        "ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT" => "50072",
        "ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH" =>
          Path.join(support_root, "beam-authorization-root")
      })
    end
  end

  test "SPEC.md §7.5.0 distributed Controller grants require a launch manifest", %{
    support_root: support_root
  } do
    assert_raise RuntimeError,
                 ~r/ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST is required in distributed mode/,
                 fn ->
                   read_controller_config!(support_root, %{
                     "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
                     "ORCHARD_BEAM_NODE_NAME" =>
                       "orchard_controller_aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa@10.0.0.10",
                     "ORCHARD_BEAM_PEER_GRANTS_ENABLED" => "true",
                     "ORCHARD_BEAM_PEER_GRANT_MODE" => "distributed",
                     "ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST" => "10.0.0.10",
                     "ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT" => "50072",
                     "ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH" =>
                       Path.join(support_root, "beam-authorization-root")
                   })
                 end
  end

  test "SPEC.md §7.5.0 production grants reject a public control host at config time", %{
    support_root: support_root
  } do
    assert_raise RuntimeError,
                 ~r/ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST must be a private non-loopback IPv4 address/,
                 fn ->
                   read_controller_config!(support_root, %{
                     "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
                     "ORCHARD_BEAM_NODE_NAME" =>
                       "orchard_controller_aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa@10.0.0.10",
                     "ORCHARD_BEAM_PEER_GRANTS_ENABLED" => "true",
                     "ORCHARD_BEAM_PEER_GRANT_MODE" => "distributed",
                     "ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST" =>
                       Path.join(support_root, "controller-launch.json"),
                     "ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST" => "203.0.113.10",
                     "ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT" => "50072",
                     "ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH" =>
                       Path.join(support_root, "beam-authorization-root")
                   })
                 end
  end

  test "SPEC.md §8.3 gRPC Controllers publish a local-only membership identity", %{
    support_root: support_root
  } do
    config = read_controller_config!(support_root, %{})

    assert config[:controller_membership][:private_ipv4] == "127.0.0.1"
    assert config[:controller_membership][:scope] == :local_only

    assert config[:controller_membership][:authorization_root_path] ==
             Path.join([support_root, "support", "beam-authorization-root"])
  end

  test "SPEC.md §8.3 single-host BEAM Controllers classify loopback membership as local-only", %{
    support_root: support_root
  } do
    config =
      read_controller_config!(support_root, %{
        "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
        "ORCHARD_BEAM_NODE_NAME" => "orchard_controller@127.0.0.1",
        "ORCHARD_RUNTIME_ENDPOINT_TARGETS" => "orchard_node_agent@127.0.0.1"
      })

    assert config[:controller_membership][:private_ipv4] == "127.0.0.1"
    assert config[:controller_membership][:scope] == :local_only
  end

  test "SPEC.md §8.3 remote BEAM Controllers classify a private membership host", %{
    support_root: support_root
  } do
    config =
      read_controller_config!(support_root, %{
        "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
        "ORCHARD_BEAM_NODE_NAME" => "orchard_controller@10.0.0.10",
        "ORCHARD_RUNTIME_ENDPOINT_TARGETS" => "orchard_node_agent@10.0.0.11"
      })

    assert config[:controller_membership][:private_ipv4] == "10.0.0.10"
    assert config[:controller_membership][:scope] == :remote_beam
  end

  test "SPEC.md §8.3 membership identity ignores the peer-grant control listener host", %{
    support_root: support_root
  } do
    grant_env = %{
      "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
      "ORCHARD_BEAM_NODE_NAME" => "orchard_controller_aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa@10.0.0.10",
      "ORCHARD_BEAM_PEER_GRANTS_ENABLED" => "true",
      "ORCHARD_BEAM_PEER_GRANT_MODE" => "distributed",
      "ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST" => Path.join(support_root, "launch.json"),
      "ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST" => "10.0.0.99",
      "ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT" => "50072",
      "ORCHARD_CONTROLLER_MEMBERSHIP_HOST" => "10.0.0.10",
      "ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH" => Path.join(support_root, "beam-authorization-root")
    }

    granted = read_controller_config!(support_root, grant_env)

    ungranted =
      read_controller_config!(support_root, %{
        "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
        "ORCHARD_BEAM_NODE_NAME" =>
          "orchard_controller_aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa@10.0.0.10",
        "ORCHARD_RUNTIME_ENDPOINT_TARGETS" => "orchard_node_agent@10.0.0.11",
        "ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH" =>
          Path.join(support_root, "beam-authorization-root")
      })

    assert granted[:beam_peer_grants][:control_listener][:host] == "10.0.0.99"
    assert granted[:controller_membership] == ungranted[:controller_membership]
    assert granted[:controller_membership][:private_ipv4] == "10.0.0.10"
  end

  test "SPEC.md §8.3 grant-control Controllers publish the same identity as the launch phase", %{
    support_root: support_root
  } do
    grant_control_env = %{
      "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
      "ORCHARD_BEAM_PEER_GRANTS_ENABLED" => "true",
      "ORCHARD_BEAM_PEER_GRANT_MODE" => "grant_control",
      "ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST" => "10.0.0.99",
      "ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT" => "50072",
      "ORCHARD_CONTROLLER_MEMBERSHIP_HOST" => "10.0.0.10",
      "ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH" => Path.join(support_root, "beam-authorization-root")
    }

    config = read_controller_config!(support_root, grant_control_env)

    assert config[:controller_membership][:private_ipv4] == "10.0.0.10"
    assert config[:controller_membership][:scope] == :remote_beam

    distributed =
      read_controller_config!(
        support_root,
        Map.merge(grant_control_env, %{
          "ORCHARD_BEAM_PEER_GRANT_MODE" => "distributed",
          "ORCHARD_BEAM_NODE_NAME" =>
            "orchard_controller_aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa@10.0.0.10",
          "ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST" => Path.join(support_root, "launch.json")
        })
      )

    assert distributed[:controller_membership] == config[:controller_membership]
  end

  test "SPEC.md §8.3 peer-grant Controllers reject an unset or loopback membership host", %{
    support_root: support_root
  } do
    grant_env = %{
      "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
      "ORCHARD_BEAM_PEER_GRANTS_ENABLED" => "true",
      "ORCHARD_BEAM_PEER_GRANT_MODE" => "grant_control",
      "ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST" => "10.0.0.99",
      "ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT" => "50072",
      "ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH" => Path.join(support_root, "beam-authorization-root")
    }

    assert_raise RuntimeError,
                 ~r/ORCHARD_CONTROLLER_MEMBERSHIP_HOST is required when BEAM Peer Grants are enabled/,
                 fn -> read_controller_config!(support_root, grant_env) end

    assert_raise RuntimeError,
                 ~r/ORCHARD_CONTROLLER_MEMBERSHIP_HOST must be a private non-loopback IPv4 address/,
                 fn ->
                   read_controller_config!(
                     support_root,
                     Map.put(grant_env, "ORCHARD_CONTROLLER_MEMBERSHIP_HOST", "127.0.0.1")
                   )
                 end
  end

  test "SPEC.md §8.3 a membership host that contradicts the BEAM node name fails closed", %{
    support_root: support_root
  } do
    assert_raise RuntimeError,
                 ~r/ORCHARD_CONTROLLER_MEMBERSHIP_HOST "10.0.0.20" must match the ORCHARD_BEAM_NODE_NAME host "10.0.0.10"/,
                 fn ->
                   read_controller_config!(support_root, %{
                     "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
                     "ORCHARD_BEAM_NODE_NAME" => "orchard_controller@10.0.0.10",
                     "ORCHARD_RUNTIME_ENDPOINT_TARGETS" => "orchard_node_agent@10.0.0.11",
                     "ORCHARD_CONTROLLER_MEMBERSHIP_HOST" => "10.0.0.20"
                   })
                 end
  end

  test "SPEC.md §8.3 a public membership BEAM host fails closed at config time", %{
    support_root: support_root
  } do
    assert_raise RuntimeError,
                 ~r/ORCHARD_BEAM_NODE_NAME Controller membership host must be a private IPv4 address/,
                 fn ->
                   read_controller_config!(support_root, %{
                     "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "beam",
                     "ORCHARD_BEAM_NODE_NAME" => "orchard_controller@203.0.113.10",
                     "ORCHARD_RUNTIME_ENDPOINT_TARGETS" => "orchard_node_agent@10.0.0.11"
                   })
                 end
  end

  test "SPEC 10.7: ORCHARD_TRANSPORT_MODE=plain_http_localhost wins over legacy TLS envs", %{
    support_root: support_root
  } do
    output =
      capture_io(:stderr, fn ->
        config =
          read_controller_config!(support_root, %{
            "ORCHARD_TRANSPORT_MODE" => "plain_http_localhost",
            "ORCHARD_TLS_DISABLED" => "false",
            "ORCHARD_TLS_CERTFILE" => "/missing/conflicting.crt",
            "ORCHARD_TLS_KEYFILE" => "/missing/conflicting.key"
          })

        endpoint = Keyword.fetch!(config, Orchard.API.Endpoint)

        assert config[:transport_mode] == :plain_http_localhost
        assert config[:transport_cert_source] == :unknown
        assert config[:transport_degraded] == true
        assert endpoint[:http] == [ip: {127, 0, 0, 1}, port: 4000]
        assert endpoint[:https] == nil
      end)

    assert output =~ "ORCHARD_TRANSPORT_MODE=plain_http_localhost"
    assert output =~ "new transport mode wins"
  end

  test "SPEC 10.7: reverse_proxy uses an HTTP backend with public URL config", %{
    support_root: support_root
  } do
    install_generated_local_ca!(support_root)

    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "reverse_proxy",
        "ORCHARD_PUBLIC_HOST" => "orchard.example.test",
        "PORT" => "4010"
      })

    endpoint = Keyword.fetch!(config, Orchard.API.Endpoint)

    assert config[:transport_mode] == :reverse_proxy
    assert config[:transport_cert_source] == :unknown
    assert config[:transport_degraded] == false
    assert endpoint[:http] == [ip: {127, 0, 0, 1}, port: 4010]
    assert endpoint[:https] == nil
    assert endpoint[:url] == [host: "orchard.example.test", port: 443, scheme: "https"]
    assert endpoint[:check_origin] == ["https://orchard.example.test"]
    assert endpoint[:trusted_proxies] == [{{127, 0, 0, 1}, 32}, {{0, 0, 0, 0, 0, 0, 0, 1}, 128}]
  end

  test "SPEC 10.7: reverse_proxy rejects invalid public port", %{
    support_root: support_root
  } do
    assert_raise RuntimeError, ~r/ORCHARD_PUBLIC_PORT must be a TCP port/, fn ->
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "reverse_proxy",
        "ORCHARD_PUBLIC_PORT" => "65536"
      })
    end
  end

  test "SPEC 10.7: reverse_proxy uses ORCHARD_PUBLIC_PORT in public URL config", %{
    support_root: support_root
  } do
    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "reverse_proxy",
        "ORCHARD_PUBLIC_HOST" => "orchard.example.test",
        "ORCHARD_PUBLIC_PORT" => "9443"
      })

    endpoint = Keyword.fetch!(config, Orchard.API.Endpoint)

    assert endpoint[:url] == [host: "orchard.example.test", port: 9443, scheme: "https"]
    assert endpoint[:check_origin] == ["https://orchard.example.test:9443"]
  end

  test "SPEC 10.7: reverse_proxy accepts explicit trusted proxy CIDRs", %{
    support_root: support_root
  } do
    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "reverse_proxy",
        "ORCHARD_TRUSTED_PROXIES" => "10.0.0.0/24, 2001:db8::/32"
      })

    endpoint = Keyword.fetch!(config, Orchard.API.Endpoint)

    assert endpoint[:trusted_proxies] == [
             {{10, 0, 0, 0}, 24},
             {{8193, 3512, 0, 0, 0, 0, 0, 0}, 32}
           ]
  end

  test "SPEC 10.7: reverse_proxy explicit empty trusted proxy list fails closed", %{
    support_root: support_root
  } do
    assert_raise RuntimeError, ~r/ORCHARD_TRUSTED_PROXIES must contain at least one CIDR/, fn ->
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "reverse_proxy",
        "ORCHARD_API_BIND_IP" => "0.0.0.0",
        "ORCHARD_TRUSTED_PROXIES" => ", ,"
      })
    end
  end

  test "SPEC 10.7: reverse_proxy malformed trusted proxy CIDR fails closed", %{
    support_root: support_root
  } do
    assert_raise RuntimeError, ~r/ORCHARD_TRUSTED_PROXIES contains invalid CIDR/, fn ->
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "reverse_proxy",
        "ORCHARD_TRUSTED_PROXIES" => "10.0.0.0/not-a-prefix"
      })
    end
  end

  test "SPEC 10.7: reverse_proxy non-loopback bind requires explicit trusted proxies", %{
    support_root: support_root
  } do
    assert_raise RuntimeError, ~r/ORCHARD_TRUSTED_PROXIES must be set/, fn ->
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "reverse_proxy",
        "ORCHARD_API_BIND_IP" => "0.0.0.0"
      })
    end
  end

  test "SPEC 10.7: reverse_proxy allows non-loopback bind with explicit trusted proxies", %{
    support_root: support_root
  } do
    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "reverse_proxy",
        "ORCHARD_API_BIND_IP" => "0.0.0.0",
        "ORCHARD_TRUSTED_PROXIES" => "10.0.0.0/24"
      })

    endpoint = Keyword.fetch!(config, Orchard.API.Endpoint)

    assert endpoint[:http] == [ip: {0, 0, 0, 0}, port: 4000]
    assert endpoint[:trusted_proxies] == [{{10, 0, 0, 0}, 24}]
  end

  test "SPEC 10.7: direct_https cert/key overrides set transport_cert_source operator_provided",
       %{
         support_root: support_root
       } do
    tls_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "operator.crt")
    keyfile = Path.join(tls_dir, "operator.key")
    generate_self_signed_cert!(certfile, keyfile)

    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https",
        "ORCHARD_TLS_CERTFILE" => certfile,
        "ORCHARD_TLS_KEYFILE" => keyfile
      })

    endpoint = Keyword.fetch!(config, Orchard.API.Endpoint)

    assert config[:transport_mode] == :direct_https
    assert config[:transport_cert_source] == :operator_provided
    assert config[:transport_degraded] == false
    assert endpoint[:https][:certfile] == certfile
    assert endpoint[:https][:keyfile] == keyfile
  end

  test "SPEC 10.7: direct_https rejects mismatched certificate and private key", %{
    support_root: support_root
  } do
    tls_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "operator.crt")
    matching_keyfile = Path.join(tls_dir, "operator.key")
    mismatched_certfile = Path.join(tls_dir, "other.crt")
    mismatched_keyfile = Path.join(tls_dir, "other.key")

    generate_self_signed_cert!(certfile, matching_keyfile)
    generate_self_signed_cert!(mismatched_certfile, mismatched_keyfile)

    assert_raise RuntimeError, ~r/TLS certificate and private key do not match/, fn ->
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https",
        "ORCHARD_TLS_CERTFILE" => certfile,
        "ORCHARD_TLS_KEYFILE" => mismatched_keyfile
      })
    end
  end

  test "SPEC 10.7: direct_https rejects expired certificate", %{support_root: support_root} do
    tls_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "operator.crt")
    keyfile = Path.join(tls_dir, "operator.key")

    generate_self_signed_cert!(certfile, keyfile)
    rewrite_certificate_not_after!(certfile, "200101000000Z")

    assert_raise RuntimeError, ~r/TLS certificate has expired/, fn ->
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https",
        "ORCHARD_TLS_CERTFILE" => certfile,
        "ORCHARD_TLS_KEYFILE" => keyfile
      })
    end
  end

  test "SPEC 10.7: direct_https rejects encrypted private key", %{support_root: support_root} do
    tls_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "operator.crt")
    keyfile = Path.join(tls_dir, "operator-encrypted.key")

    generate_self_signed_cert_with_encrypted_key!(certfile, keyfile)

    assert_raise RuntimeError, ~r/TLS private key is encrypted/, fn ->
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https",
        "ORCHARD_TLS_CERTFILE" => certfile,
        "ORCHARD_TLS_KEYFILE" => keyfile
      })
    end
  end

  test "SPEC 10.7: direct_https rejects malformed configured CA certificate", %{
    support_root: support_root
  } do
    tls_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "operator.crt")
    keyfile = Path.join(tls_dir, "operator.key")
    cacertfile = Path.join(tls_dir, "ca.crt")

    generate_self_signed_cert!(certfile, keyfile)
    File.write!(cacertfile, "not a PEM certificate\n")

    assert_raise RuntimeError,
                 ~r/TLS CA certificate file contains no certificate PEM entry/,
                 fn ->
                   read_controller_config!(support_root, %{
                     "ORCHARD_TRANSPORT_MODE" => "direct_https",
                     "ORCHARD_TLS_CERTFILE" => certfile,
                     "ORCHARD_TLS_KEYFILE" => keyfile,
                     "ORCHARD_TLS_CACERTFILE" => cacertfile
                   })
                 end
  end

  test "SPEC 10.7: direct_https explicit default paths with generated-local metadata sets operator_provided",
       %{
         support_root: support_root
       } do
    install_generated_local_ca!(support_root)

    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")

    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https",
        "ORCHARD_TLS_CERTFILE" => certfile,
        "ORCHARD_TLS_KEYFILE" => keyfile
      })

    assert config[:transport_mode] == :direct_https
    assert config[:transport_cert_source] == :operator_provided
  end

  test "SPEC 10.7: direct_https ignores malformed or nested generated-local metadata",
       %{
         support_root: support_root
       } do
    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")
    cacertfile = Path.join(tls_dir, "ca.crt")
    meta_path = Path.join(tls_dir, ".orchard-tls-meta.json")

    for metadata <- [
          "not-json",
          ~s({"source":"generated_local_ca",}),
          Jason.encode!(%{"nested" => %{"source" => "generated_local_ca"}})
        ] do
      generate_self_signed_cert!(certfile, keyfile)
      File.cp!(certfile, cacertfile)
      File.write!(meta_path, metadata)

      config =
        read_controller_config!(support_root, %{
          "ORCHARD_TRANSPORT_MODE" => "direct_https"
        })

      assert config[:transport_mode] == :direct_https
      assert config[:transport_cert_source] == :unknown
    end
  end

  test "SPEC 10.7: direct_https rejects whitespace-only configured CA certificate path", %{
    support_root: support_root
  } do
    tls_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "operator.crt")
    keyfile = Path.join(tls_dir, "operator.key")

    generate_self_signed_cert!(certfile, keyfile)

    assert_raise RuntimeError, ~r/ORCHARD_TLS_CACERTFILE must not be empty/, fn ->
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https",
        "ORCHARD_TLS_CERTFILE" => certfile,
        "ORCHARD_TLS_KEYFILE" => keyfile,
        "ORCHARD_TLS_CACERTFILE" => "   "
      })
    end
  end

  test "SPEC 10.7: direct_https rejects empty configured CA certificate path", %{
    support_root: support_root
  } do
    tls_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "operator.crt")
    keyfile = Path.join(tls_dir, "operator.key")

    generate_self_signed_cert!(certfile, keyfile)

    assert_raise RuntimeError, ~r/ORCHARD_TLS_CACERTFILE must not be empty/, fn ->
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https",
        "ORCHARD_TLS_CERTFILE" => certfile,
        "ORCHARD_TLS_KEYFILE" => keyfile,
        "ORCHARD_TLS_CACERTFILE" => ""
      })
    end
  end

  test "SPEC 10.7: direct_https rejects generated-local CA override",
       %{
         support_root: support_root
       } do
    tls_dir = Path.join([support_root, "config", "tls"])
    external_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")
    cacertfile = Path.join(tls_dir, "ca.crt")
    operator_ca = Path.join(external_dir, "operator-ca.crt")
    meta_path = Path.join(tls_dir, ".orchard-tls-meta.json")

    generate_self_signed_cert!(certfile, keyfile)
    File.cp!(certfile, cacertfile)
    File.mkdir_p!(external_dir)
    File.cp!(certfile, operator_ca)
    File.write!(meta_path, Jason.encode!(%{"source" => "generated_local_ca"}))

    assert_raise RuntimeError,
                 ~r/ORCHARD_TLS_CACERTFILE cannot override generated-local CA publication/,
                 fn ->
                   read_controller_config!(support_root, %{
                     "ORCHARD_TRANSPORT_MODE" => "direct_https",
                     "ORCHARD_TLS_CACERTFILE" => operator_ca
                   })
                 end
  end

  test "SPEC 10.7: direct_https allows generated-local default CA path override",
       %{
         support_root: support_root
       } do
    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")
    cacertfile = Path.join(tls_dir, "ca.crt")
    meta_path = Path.join(tls_dir, ".orchard-tls-meta.json")

    generate_self_signed_cert!(certfile, keyfile)
    File.cp!(certfile, cacertfile)
    File.write!(meta_path, Jason.encode!(%{"source" => "generated_local_ca"}))

    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https",
        "ORCHARD_TLS_CACERTFILE" => Path.join([tls_dir, "..", "tls", "ca.crt"])
      })

    assert config[:transport_cert_source] == :generated_local_ca
  end

  test "SPEC 10.7: direct_https generated-local metadata sets transport_cert_source generated_local_ca",
       %{
         support_root: support_root
       } do
    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")
    cacertfile = Path.join(tls_dir, "ca.crt")
    meta_path = Path.join(tls_dir, ".orchard-tls-meta.json")

    generate_self_signed_cert!(certfile, keyfile)
    File.cp!(certfile, cacertfile)
    File.write!(meta_path, Jason.encode!(%{"source" => "generated_local_ca"}))

    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https"
      })

    assert config[:transport_mode] == :direct_https
    assert config[:transport_cert_source] == :generated_local_ca
  end

  test "SPEC 10.7: legacy ORCHARD_TLS_DISABLED=true maps to plain_http_localhost", %{
    support_root: support_root
  } do
    install_generated_local_ca!(support_root)

    output =
      capture_io(:stderr, fn ->
        config = read_controller_config!(support_root, %{"ORCHARD_TLS_DISABLED" => "true"})

        assert config[:transport_mode] == :plain_http_localhost
        assert config[:transport_cert_source] == :unknown
        assert config[:transport_degraded] == true
      end)

    assert output =~ "ORCHARD_TLS_DISABLED is deprecated"
  end

  test "SPEC 10.7: legacy ORCHARD_TLS_DISABLED=false maps to direct_https", %{
    support_root: support_root
  } do
    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")
    generate_self_signed_cert!(certfile, keyfile)

    output =
      capture_io(:stderr, fn ->
        config = read_controller_config!(support_root, %{"ORCHARD_TLS_DISABLED" => "false"})

        assert config[:transport_mode] == :direct_https
        assert config[:transport_cert_source] == :unknown
        assert config[:transport_degraded] == false
      end)

    assert output =~ "ORCHARD_TLS_DISABLED=false is deprecated"
  end

  test "SPEC 10.7: legacy cert/key overrides map to direct_https operator_provided", %{
    support_root: support_root
  } do
    tls_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "legacy.crt")
    keyfile = Path.join(tls_dir, "legacy.key")
    generate_self_signed_cert!(certfile, keyfile)

    output =
      capture_io(:stderr, fn ->
        config =
          read_controller_config!(support_root, %{
            "ORCHARD_TLS_CERTFILE" => certfile,
            "ORCHARD_TLS_KEYFILE" => keyfile
          })

        assert config[:transport_mode] == :direct_https
        assert config[:transport_cert_source] == :operator_provided
        assert config[:transport_degraded] == false
      end)

    assert output =~ "ORCHARD_TLS_CERTFILE/ORCHARD_TLS_KEYFILE are deprecated transport shims"
  end

  test "SPEC 10.7: invalid transport mode fails closed", %{support_root: support_root} do
    assert_raise RuntimeError, ~r/ORCHARD_TRANSPORT_MODE must be/, fn ->
      read_controller_config!(support_root, %{"ORCHARD_TRANSPORT_MODE" => "https"})
    end
  end

  defp read_controller_config!(support_root, overrides) do
    base = %{
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/orchard_config_eval",
      "MIX_RELEASE_NAME" => nil,
      "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "grpc",
      "ORCHARD_SUPPORT_ROOT" => support_root,
      "RELEASE_NAME" => "orchard_controller",
      "SECRET_KEY_BASE" => String.duplicate("runtime-secret", 8)
    }

    clear_config_env!()

    base
    |> Map.merge(overrides)
    |> Enum.each(fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    @runtime_config
    |> Config.Reader.read!(env: :prod)
    |> Keyword.fetch!(:orchard_controller)
  end

  defp install_generated_local_ca!(support_root) do
    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")
    cacertfile = Path.join(tls_dir, "ca.crt")
    meta_path = Path.join(tls_dir, ".orchard-tls-meta.json")

    generate_self_signed_cert!(certfile, keyfile)
    File.cp!(certfile, cacertfile)
    File.write!(meta_path, Jason.encode!(%{"source" => "generated_local_ca"}))
  end

  defp generate_self_signed_cert!(certfile, keyfile) do
    openssl =
      System.find_executable("openssl") || flunk("openssl is required for TLS config tests")

    File.mkdir_p!(Path.dirname(certfile))
    File.mkdir_p!(Path.dirname(keyfile))

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
          "/CN=localhost"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp generate_self_signed_cert_with_encrypted_key!(certfile, keyfile) do
    openssl =
      System.find_executable("openssl") || flunk("openssl is required for TLS config tests")

    File.mkdir_p!(Path.dirname(certfile))
    File.mkdir_p!(Path.dirname(keyfile))

    {output, status} =
      System.cmd(
        openssl,
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-keyout",
          keyfile,
          "-passout",
          "pass:orchard-test",
          "-out",
          certfile,
          "-days",
          "365",
          "-subj",
          "/CN=localhost"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp rewrite_certificate_not_after!(certfile, replacement_utc_time) do
    [{:Certificate, cert_der, :not_encrypted}] =
      certfile
      |> File.read!()
      |> :public_key.pem_decode()

    otp_cert = :public_key.pkix_decode_cert(cert_der, :otp)
    validity = otp_cert |> elem(1) |> elem(5)
    {:utcTime, not_after_chars} = elem(validity, 2)
    not_after = List.to_string(not_after_chars)

    rewritten_der = :binary.replace(cert_der, not_after, replacement_utc_time, [:global])
    File.write!(certfile, :public_key.pem_encode([{:Certificate, rewritten_der, :not_encrypted}]))
  end

  defp clear_config_env! do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&config_env_key?/1)
    |> Enum.each(&System.delete_env/1)
  end

  defp config_env_key?(key) do
    key in ["DATABASE_URL", "MIX_RELEASE_NAME", "PORT", "RELEASE_NAME", "SECRET_KEY_BASE"] or
      String.starts_with?(key, "ORCHARD_")
  end
end
