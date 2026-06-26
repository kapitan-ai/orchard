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
                 address: "orchard_node_agent@127.0.0.1",
                 metadata: %{source_dev: true}
               },
               %{
                 transport: :beam,
                 address: "orchard_node_agent@10.0.0.2",
                 metadata: %{source_dev: true}
               }
             ]
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
end
