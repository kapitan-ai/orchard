defmodule Orchard.RuntimeEndpoint.BeamConfigTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.{BeamConfig, Target}

  @node_id "550e8400-e29b-41d4-a716-446655440000"
  @controller_node :"orchard_controller@10.0.0.5"

  test "disabled config validates as disabled" do
    assert {:ok, %BeamConfig{enabled: false}} = BeamConfig.validate([], :prod)
  end

  test "validate_enabled fails closed when BEAM distribution is disabled" do
    assert {:error, :beam_distribution_disabled} = BeamConfig.validate_enabled([], :prod)
  end

  test "enabled config requires identity, admission, and network restrictions" do
    assert {:error, {:invalid_beam_distribution_config, errors}} =
             BeamConfig.validate_enabled([enabled: true], :prod)

    assert :missing_node_name in errors
    assert :missing_cookie_file in errors
    assert :missing_admitted_services in errors
    assert :missing_allowed_cidrs in errors
    assert :missing_listen_host in errors
  end

  test "enabled config rejects globally open network settings" do
    assert {:error, {:invalid_beam_distribution_config, errors}} =
             BeamConfig.validate_enabled(
               [
                 enabled: true,
                 node_name: "orchard_controller@controller.local",
                 cookie_file: "/Library/Application Support/Orchard/secrets/beam.cookie",
                 admitted_services: ["orchard_node_agent"],
                 allowed_cidrs: ["0.0.0.0/0"],
                 listen_host: "0.0.0.0"
               ],
               :prod
             )

    assert :global_beam_distribution_cidr in errors
    assert :unrestricted_listen_host in errors
  end

  test "SPEC.md §7.5 enabled config rejects malformed allowed CIDRs" do
    assert {:error, {:invalid_beam_distribution_config, errors}} =
             BeamConfig.validate_enabled(
               [
                 enabled: true,
                 node_name: "orchard_controller@controller.local",
                 cookie_file: "/Library/Application Support/Orchard/secrets/beam.cookie",
                 admitted_services: ["orchard_node_agent"],
                 allowed_cidrs: ["not-a-cidr"],
                 listen_host: "10.0.0.10"
               ],
               :prod
             )

    assert :invalid_allowed_cidr in errors
  end

  test "enabled config validates when identity, admission, and network restrictions are explicit" do
    assert {:ok, config} =
             BeamConfig.validate_enabled(
               [
                 enabled: true,
                 node_name: "orchard_controller@controller.local",
                 cookie_file: "/Library/Application Support/Orchard/secrets/beam.cookie",
                 admitted_services: ["orchard_node_agent"],
                 allowed_cidrs: ["10.0.0.0/24"],
                 listen_host: "10.0.0.10"
               ],
               :prod
             )

    assert config.enabled
    assert config.node_name == "orchard_controller@controller.local"
    assert config.admitted_services == ["orchard_node_agent"]
    assert config.allowed_cidrs == ["10.0.0.0/24"]
  end

  test "SPEC.md §7.5.0 peer-grant config does not require a shared cookie or static target lists" do
    assert {:ok, config} =
             BeamConfig.validate_peer_grant_enabled(
               enabled: true,
               node_name: Atom.to_string(@controller_node),
               cookie_file: nil,
               admitted_services: [],
               allowed_cidrs: [],
               listen_host: "10.0.0.5"
             )

    assert config.enabled
    assert config.authorization_mode == :peer_grant

    target = beam_target("orchard_node_agent_550e8400e29b41d4a716446655440000@10.0.0.42")
    assert :ok = BeamConfig.validate_target(config, target, current_node: @controller_node)
  end

  test "SPEC.md §7.5 target guardrails enforce current node identity" do
    config = enabled_config!()
    target = beam_target("orchard_node_agent@10.0.0.42")

    assert :ok = BeamConfig.validate_target(config, target, current_node: @controller_node)

    assert {:error, :beam_node_identity_mismatch} =
             BeamConfig.validate_target(config, target,
               current_node: :"other_controller@10.0.0.5"
             )
  end

  test "SPEC.md §7.5 target guardrails enforce admitted service membership" do
    config = enabled_config!()
    target = beam_target("external_provider@10.0.0.42")

    assert {:error, :beam_target_service_not_admitted} =
             BeamConfig.validate_target(config, target, current_node: @controller_node)
  end

  test "SPEC.md §7.5 target guardrails enforce allowed CIDR membership" do
    config = enabled_config!()
    target = beam_target("orchard_node_agent@10.1.0.42")

    assert {:error, :beam_target_outside_allowed_cidrs} =
             BeamConfig.validate_target(config, target, current_node: @controller_node)
  end

  defp enabled_config! do
    {:ok, config} =
      BeamConfig.validate_enabled(
        [
          enabled: true,
          node_name: Atom.to_string(@controller_node),
          cookie_file: "/Library/Application Support/Orchard/secrets/beam.cookie",
          admitted_services: ["orchard_node_agent"],
          allowed_cidrs: ["10.0.0.0/24"],
          listen_host: "10.0.0.5"
        ],
        :prod
      )

    config
  end

  defp beam_target(address) do
    Target.normalize(%{
      transport: :beam,
      node_id: @node_id,
      address: address
    })
  end
end
