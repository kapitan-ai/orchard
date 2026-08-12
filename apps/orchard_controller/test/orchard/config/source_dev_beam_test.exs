Code.require_file(Path.expand("../../../../../config/source_dev_beam.exs", __DIR__))

defmodule Orchard.Config.SourceDevBeamTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Orchard.Config.SourceDevBeam
  alias Orchard.RuntimeEndpoint.BeamNodeName

  describe "transport!/1" do
    test "defaults unset and blank transport to gRPC" do
      assert SourceDevBeam.transport!(nil) == :grpc
      assert SourceDevBeam.transport!("") == :grpc
      assert SourceDevBeam.transport!("   ") == :grpc
    end

    test "accepts explicit grpc and beam modes" do
      assert SourceDevBeam.transport!("grpc") == :grpc
      assert SourceDevBeam.transport!("beam") == :beam
    end

    test "rejects unknown modes" do
      assert_raise RuntimeError, ~r/ORCHARD_RUNTIME_ENDPOINT_TRANSPORT must be grpc\|beam/, fn ->
        SourceDevBeam.transport!("http")
      end
    end
  end

  describe "address_policy!/1 and host_allowed?/2" do
    test "accepts RFC1918, shared CGNAT boundaries, and loopback by default" do
      policy = SourceDevBeam.address_policy!(nil)

      for host <- [
            "10.0.0.0",
            "10.255.255.255",
            "172.16.0.0",
            "172.31.255.255",
            "192.168.0.0",
            "192.168.255.255",
            "100.64.0.0",
            "100.127.255.255",
            "127.0.0.1"
          ] do
        assert SourceDevBeam.host_allowed?(host, policy), host
      end
    end

    test "config and runtime policy evaluators stay aligned" do
      policy = SourceDevBeam.address_policy!("203.0.113.0/24")

      for host <- [
            "127.0.0.1",
            "10.0.0.1",
            "100.64.0.0",
            "100.127.255.255",
            "203.0.113.10",
            "100.128.0.0",
            "224.0.0.1",
            "255.255.255.255",
            "worker.tailnet.ts.net"
          ] do
        assert SourceDevBeam.host_allowed?(host, policy) ==
                 BeamNodeName.allowed_ipv4?(host, policy)
      end
    end

    test "rejects addresses adjacent to shared CGNAT and public addresses by default" do
      policy = SourceDevBeam.address_policy!("")

      refute SourceDevBeam.host_allowed?("100.63.255.255", policy)
      refute SourceDevBeam.host_allowed?("100.128.0.0", policy)
      refute SourceDevBeam.host_allowed?("203.0.113.10", policy)
    end

    test "accepts hosts inside additive operator CIDRs only" do
      policy =
        SourceDevBeam.address_policy!("203.0.113.0/24, 198.51.100.10/32")

      assert SourceDevBeam.host_allowed?("203.0.113.10", policy)
      assert SourceDevBeam.host_allowed?("198.51.100.10", policy)
      refute SourceDevBeam.host_allowed?("198.51.100.11", policy)
    end

    test "rejects malformed and unrestricted additive CIDRs" do
      for cidr <- ["not-a-cidr", "10.0.0.0/33", "0.0.0.0/0"] do
        assert_raise RuntimeError,
                     ~r/ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS contains invalid IPv4 CIDR #{Regex.escape(inspect(cidr))}/,
                     fn ->
                       SourceDevBeam.address_policy!(cidr)
                     end
      end
    end

    test "rejects invalid host classes even inside an additive CIDR" do
      policy = SourceDevBeam.address_policy!("0.0.0.0/8,224.0.0.0/4,255.255.255.255/32")

      refute SourceDevBeam.host_allowed?("0.0.0.0", policy)
      refute SourceDevBeam.host_allowed?("224.0.0.1", policy)
      refute SourceDevBeam.host_allowed?("255.255.255.255", policy)
      refute SourceDevBeam.host_allowed?("worker.tailnet.ts.net", policy)
      refute SourceDevBeam.host_allowed?("::1", policy)
    end
  end

  test "warns when operator CIDRs expand the shared-cookie network boundary" do
    policy = SourceDevBeam.address_policy!("8.8.8.0/24")

    assert capture_io(:stderr, fn ->
             assert SourceDevBeam.warn_expanded_network(policy) == :ok
           end) =~
             "shared-cookie BEAM may expose EPMD and BEAM Distribution; restrict their ports to configured peers"

    assert capture_io(:stderr, fn ->
             assert SourceDevBeam.warn_expanded_network(SourceDevBeam.address_policy!(nil)) ==
                      :ok
           end) == ""
  end

  describe "validate_node_name!/3" do
    test "accepts CGNAT and operator-authorized Source-dev node names" do
      default_policy = SourceDevBeam.address_policy!(nil)
      custom_policy = SourceDevBeam.address_policy!("203.0.113.0/24")

      assert SourceDevBeam.validate_node_name!(
               :controller,
               "orchard_controller@100.64.1.10",
               default_policy
             ) == "100.64.1.10"

      assert SourceDevBeam.validate_node_name!(
               :node_agent,
               "orchard_node_agent@203.0.113.10",
               custom_policy
             ) == "203.0.113.10"
    end

    test "rejects public, MagicDNS, and role-invalid Source-dev node names" do
      policy = SourceDevBeam.address_policy!(nil)

      assert_raise RuntimeError,
                   ~r/must use same-host loopback, RFC1918, Tailscale CGNAT 100\.64\.0\.0\/10, or ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS/,
                   fn ->
                     SourceDevBeam.validate_node_name!(
                       :node_agent,
                       "orchard_node_agent@203.0.113.10",
                       policy
                     )
                   end

      assert_raise RuntimeError, ~r/host must be an IPv4 literal/, fn ->
        SourceDevBeam.validate_node_name!(
          :node_agent,
          "orchard_node_agent@worker.tailnet.ts.net",
          policy
        )
      end

      assert_raise RuntimeError, ~r/service must be exactly orchard_node_agent/, fn ->
        SourceDevBeam.validate_node_name!(
          :node_agent,
          "other@100.64.1.10",
          policy
        )
      end

      assert_raise RuntimeError,
                   ~r/controller BEAM node service contains invalid characters/,
                   fn ->
                     SourceDevBeam.validate_node_name!(
                       :controller,
                       "orchard_controller x@100.64.1.10",
                       policy
                     )
                   end
    end
  end

  describe "controller_beam_targets!/2" do
    test "parses comma-separated BEAM node-name targets with IPv4-literal hosts" do
      assert SourceDevBeam.controller_beam_targets!(
               " orchard_node_agent@127.0.0.1 , orchard_node_agent@10.0.0.2 ",
               "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
             ) == [
               %{
                 transport: :beam,
                 address: :"orchard_node_agent@127.0.0.1",
                 metadata: %{source_dev: true}
               },
               %{
                 transport: :beam,
                 address: :"orchard_node_agent@10.0.0.2",
                 metadata: %{source_dev: true}
               }
             ]
    end

    test "accepts shared CGNAT targets and rejects public targets by default" do
      assert [%{address: :"orchard_node_agent@100.64.1.10"}] =
               SourceDevBeam.controller_beam_targets!(
                 "orchard_node_agent@100.64.1.10",
                 "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
               )

      assert_raise RuntimeError,
                   ~r/must use same-host loopback, RFC1918, Tailscale CGNAT 100\.64\.0\.0\/10, or ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS/,
                   fn ->
                     SourceDevBeam.controller_beam_targets!(
                       "orchard_node_agent@203.0.113.10",
                       "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
                     )
                   end
    end

    test "accepts a public target through an additive operator CIDR" do
      policy = SourceDevBeam.address_policy!("203.0.113.0/24")

      assert [%{address: :"orchard_node_agent@203.0.113.10"}] =
               SourceDevBeam.controller_beam_targets!(
                 "orchard_node_agent@203.0.113.10",
                 "ORCHARD_RUNTIME_ENDPOINT_TARGETS",
                 policy
               )
    end

    test "bounds legacy BEAM target atom materialization" do
      targets =
        Enum.map_join(1..65, ",", fn octet ->
          "orchard_node_agent@10.0.0.#{octet}"
        end)

      assert_raise RuntimeError, ~r/at most 64 BEAM targets/, fn ->
        SourceDevBeam.controller_beam_targets!(
          targets,
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )
      end
    end

    test "rejects hostname target hosts" do
      assert_raise RuntimeError, ~r/requires IPv4-literal BEAM target hosts/, fn ->
        SourceDevBeam.controller_beam_targets!(
          "orchard_node_agent@worker.local",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )
      end
    end

    test "rejects IPv6 target hosts" do
      assert_raise RuntimeError, ~r/requires IPv4-literal BEAM target hosts/, fn ->
        SourceDevBeam.controller_beam_targets!(
          "orchard_node_agent@::1",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )
      end
    end

    test "rejects unspecified target hosts" do
      assert_raise RuntimeError, ~r/must not use unspecified or wildcard BEAM hosts/, fn ->
        SourceDevBeam.controller_beam_targets!(
          "orchard_node_agent@0.0.0.0",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )
      end

      assert_raise RuntimeError, ~r/requires IPv4-literal BEAM target hosts/, fn ->
        SourceDevBeam.controller_beam_targets!(
          "orchard_node_agent@::",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )
      end
    end

    test "rejects unsupported target services" do
      assert_raise RuntimeError, ~r/unsupported BEAM target service/, fn ->
        SourceDevBeam.controller_beam_targets!(
          "orchard_controller@127.0.0.1",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )
      end
    end

    test "requires at least one target" do
      assert_raise RuntimeError, ~r/at least one BEAM target/, fn ->
        SourceDevBeam.controller_beam_targets!(nil, "ORCHARD_RUNTIME_ENDPOINT_TARGETS")
      end
    end
  end

  describe "validate_transport_role!/2" do
    test "rejects all-in-one BEAM mode" do
      assert_raise RuntimeError, ~r/all_in_one BEAM source-dev mode is not supported/, fn ->
        SourceDevBeam.validate_transport_role!(:beam, :all_in_one)
      end
    end

    test "accepts split-role BEAM mode and all-in-one gRPC mode" do
      assert SourceDevBeam.validate_transport_role!(:beam, :controller) == :ok
      assert SourceDevBeam.validate_transport_role!(:beam, :node_agent) == :ok
      assert SourceDevBeam.validate_transport_role!(:grpc, :all_in_one) == :ok
    end
  end

  describe "beam_guardrail_config!/3" do
    test "derives listen host and allowed CIDRs from source-dev BEAM targets" do
      targets =
        SourceDevBeam.controller_beam_targets!(
          "orchard_node_agent@127.0.0.1,orchard_node_agent@127.0.0.1,orchard_node_agent@10.0.0.2",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )

      assert SourceDevBeam.beam_guardrail_config!(
               "orchard_controller@127.0.0.1",
               "/tmp/orchard-cookie",
               targets
             ) == [
               enabled: true,
               node_name: "orchard_controller@127.0.0.1",
               cookie_file: "/tmp/orchard-cookie",
               listen_host: "127.0.0.1",
               admitted_services: ["orchard_node_agent"],
               allowed_cidrs: ["127.0.0.1/32", "10.0.0.2/32"]
             ]
    end

    test "accepts operator-authorized Controller and target hosts with exact guardrails" do
      policy = SourceDevBeam.address_policy!("203.0.113.0/24")

      targets =
        SourceDevBeam.controller_beam_targets!(
          "orchard_node_agent@203.0.113.20",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS",
          policy
        )

      assert SourceDevBeam.beam_guardrail_config!(
               "orchard_controller@203.0.113.10",
               "/tmp/orchard-cookie",
               targets,
               policy
             )[:allowed_cidrs] == ["203.0.113.20/32"]
    end

    test "rejects IPv6 local controller hosts" do
      targets =
        SourceDevBeam.controller_beam_targets!(
          "orchard_node_agent@127.0.0.1",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )

      assert_raise RuntimeError, ~r/host must be an IPv4 literal/, fn ->
        SourceDevBeam.beam_guardrail_config!(
          "orchard_controller@::1",
          "/tmp/orchard-cookie",
          targets
        )
      end
    end

    test "rejects unspecified local controller hosts" do
      targets =
        SourceDevBeam.controller_beam_targets!(
          "orchard_node_agent@127.0.0.1",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )

      assert_raise RuntimeError, ~r/must not use unspecified or wildcard BEAM hosts/, fn ->
        SourceDevBeam.beam_guardrail_config!(
          "orchard_controller@0.0.0.0",
          "/tmp/orchard-cookie",
          targets
        )
      end
    end

    test "rejects unsupported local controller service" do
      targets =
        SourceDevBeam.controller_beam_targets!(
          "orchard_node_agent@127.0.0.1",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )

      assert_raise RuntimeError,
                   ~r/local controller BEAM node service must start with orchard_controller/,
                   fn ->
                     SourceDevBeam.beam_guardrail_config!(
                       "orchard_node_agent@127.0.0.1",
                       "/tmp/orchard-cookie",
                       targets
                     )
                   end
    end
  end

  describe "peer_grant_guardrail_config!/1" do
    test "derives canonical peer-grant guardrails without a shared cookie or static targets" do
      assert SourceDevBeam.peer_grant_guardrail_config!(
               "orchard_controller_aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa@10.0.0.10"
             ) == [
               enabled: true,
               node_name: "orchard_controller_aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa@10.0.0.10",
               cookie_file: nil,
               listen_host: "10.0.0.10",
               admitted_services: [],
               allowed_cidrs: []
             ]
    end

    test "rejects a legacy Controller service name in peer-grant mode" do
      assert_raise RuntimeError, ~r/peer-grant Controller service must be canonical/, fn ->
        SourceDevBeam.peer_grant_guardrail_config!("orchard_controller@10.0.0.10")
      end
    end
  end
end
