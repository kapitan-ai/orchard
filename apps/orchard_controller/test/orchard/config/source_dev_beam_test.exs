Code.require_file(Path.expand("../../../../../config/source_dev_beam.exs", __DIR__))

defmodule Orchard.Config.SourceDevBeamTest do
  use ExUnit.Case, async: true

  alias Orchard.Config.SourceDevBeam

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

    test "rejects IPv6 local controller hosts" do
      targets =
        SourceDevBeam.controller_beam_targets!(
          "orchard_node_agent@127.0.0.1",
          "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
        )

      assert_raise RuntimeError, ~r/requires IPv4-literal local controller host/, fn ->
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

  describe "controller_membership_identity!/2" do
    test "classifies gRPC source dev as a stable local-only membership host" do
      assert SourceDevBeam.controller_membership_identity!(:grpc, "orchard_controller@10.0.0.10") ==
               {"127.0.0.1", :local_only}
    end

    test "classifies the default loopback BEAM host as local-only" do
      assert SourceDevBeam.controller_membership_identity!(:beam, "orchard_controller@127.0.0.1") ==
               {"127.0.0.1", :local_only}
    end

    test "classifies a private BEAM host as remote membership" do
      assert SourceDevBeam.controller_membership_identity!(:beam, "orchard_controller@10.0.0.10") ==
               {"10.0.0.10", :remote_beam}
    end

    test "rejects a public BEAM membership host" do
      assert_raise RuntimeError,
                   ~r/Controller membership host must be a private IPv4 address/,
                   fn ->
                     SourceDevBeam.controller_membership_identity!(
                       :beam,
                       "orchard_controller@203.0.113.10"
                     )
                   end
    end
  end
end
