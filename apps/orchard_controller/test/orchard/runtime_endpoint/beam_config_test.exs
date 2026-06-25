defmodule Orchard.RuntimeEndpoint.BeamConfigTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.BeamConfig

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
end
