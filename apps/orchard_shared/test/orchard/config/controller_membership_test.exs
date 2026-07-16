defmodule Orchard.Config.ControllerMembershipTest do
  use ExUnit.Case, async: true

  alias Orchard.Config.ControllerMembership

  describe "identity!/3" do
    test "SPEC.md §8.3 every resolved identity carries an explicit membership scope" do
      for {transport, node_name, opts} <- [
            {:grpc, nil, []},
            {:beam, nil, []},
            {:beam, "orchard_controller@127.0.0.1", []},
            {:beam, "orchard_controller@10.0.0.10", []},
            {:grpc, nil, [membership_host: "192.168.1.5"]},
            {:beam, "orchard_controller@172.16.0.4", [membership_host: "172.16.0.4"]}
          ] do
        assert {host, scope} = ControllerMembership.identity!(transport, node_name, opts)
        assert is_binary(host)
        assert scope in [:local_only, :remote_beam]
      end
    end

    test "prefers the explicit membership host over the BEAM node name host" do
      assert ControllerMembership.identity!(:grpc, nil, membership_host: "10.0.0.10") ==
               {"10.0.0.10", :remote_beam}
    end

    test "requires an explicit membership host when peer grants are enabled" do
      assert_raise RuntimeError,
                   ~r/ORCHARD_CONTROLLER_MEMBERSHIP_HOST is required when BEAM Peer Grants are enabled/,
                   fn ->
                     ControllerMembership.identity!(
                       :beam,
                       "orchard_controller@10.0.0.10",
                       peer_grants_enabled?: true
                     )
                   end
    end

    test "rejects a loopback membership host when peer grants are enabled" do
      assert_raise RuntimeError,
                   ~r/must be a private non-loopback IPv4 address when BEAM Peer Grants are enabled/,
                   fn ->
                     ControllerMembership.identity!(:beam, nil,
                       membership_host: "127.0.0.1",
                       peer_grants_enabled?: true
                     )
                   end
    end

    test "rejects a membership host that disagrees with the BEAM node name host" do
      assert_raise RuntimeError,
                   ~r/must match the ORCHARD_BEAM_NODE_NAME host/,
                   fn ->
                     ControllerMembership.identity!(
                       :beam,
                       "orchard_controller_00112233445566778899aabbccddeeff@10.0.0.10",
                       membership_host: "10.0.0.20",
                       peer_grants_enabled?: true
                     )
                   end
    end

    test "accepts a membership host that matches the distributed BEAM node name host" do
      assert ControllerMembership.identity!(
               :beam,
               "orchard_controller_00112233445566778899aabbccddeeff@10.0.0.10",
               membership_host: "10.0.0.10",
               peer_grants_enabled?: true
             ) == {"10.0.0.10", :remote_beam}
    end

    test "rejects a public explicit membership host" do
      assert_raise RuntimeError,
                   ~r/Controller membership host must be a private IPv4 address/,
                   fn ->
                     ControllerMembership.identity!(:beam, nil, membership_host: "203.0.113.10")
                   end
    end

    test "classifies a BEAM controller without a node name as local-only" do
      assert ControllerMembership.identity!(:beam, nil) ==
               {"127.0.0.1", :local_only}
    end

    test "classifies gRPC source dev as a stable local-only membership host" do
      assert ControllerMembership.identity!(:grpc, "orchard_controller@10.0.0.10") ==
               {"127.0.0.1", :local_only}
    end

    test "classifies the default loopback BEAM host as local-only" do
      assert ControllerMembership.identity!(:beam, "orchard_controller@127.0.0.1") ==
               {"127.0.0.1", :local_only}
    end

    test "classifies a private BEAM host as remote membership" do
      assert ControllerMembership.identity!(:beam, "orchard_controller@10.0.0.10") ==
               {"10.0.0.10", :remote_beam}
    end

    test "rejects a public BEAM membership host" do
      assert_raise RuntimeError,
                   ~r/Controller membership host must be a private IPv4 address/,
                   fn ->
                     ControllerMembership.identity!(
                       :beam,
                       "orchard_controller@203.0.113.10"
                     )
                   end
    end
  end
end
