defmodule Orchard.Node.HostInventoryConfigTest do
  # SPEC.md §4.9: source-development host inventory is default-off and selects
  # the Linux capability provider only through explicit configuration.
  use ExUnit.Case, async: false

  @dev_config Path.expand("../../../../../config/dev.exs", __DIR__)

  setup do
    snapshot = System.get_env() |> Map.filter(fn {key, _value} -> orchard_key?(key) end)
    on_exit(fn -> restore_env!(snapshot) end)
    :ok
  end

  test "inventory is off unless explicitly enabled" do
    assert host_inventory(%{}) == [provider: nil, provider_opts: [accelerators: []]]
  end

  test "the Linux provider and accelerator vendors are explicit opt-ins" do
    config =
      host_inventory(%{
        "ORCHARD_NODE_HOST_INVENTORY" => "linux",
        "ORCHARD_NODE_HOST_INVENTORY_ACCELERATORS" => "nvidia,amd"
      })

    assert config == [
             provider: Orchard.Node.LinuxHostInventory,
             provider_opts: [accelerators: [:nvidia, :amd]]
           ]
  end

  test "unknown providers and vendors are rejected" do
    assert_raise RuntimeError, ~r/ORCHARD_NODE_HOST_INVENTORY must be/, fn ->
      host_inventory(%{"ORCHARD_NODE_HOST_INVENTORY" => "auto"})
    end

    assert_raise RuntimeError, ~r/ORCHARD_NODE_HOST_INVENTORY_ACCELERATORS/, fn ->
      host_inventory(%{
        "ORCHARD_NODE_HOST_INVENTORY" => "linux",
        "ORCHARD_NODE_HOST_INVENTORY_ACCELERATORS" => "nvidia,intel"
      })
    end
  end

  defp host_inventory(env) do
    clear_env!()

    env
    |> Map.put_new("ORCHARD_SOURCE_DEV_ROLE", "node_agent")
    |> Enum.each(fn {key, value} -> System.put_env(key, value) end)

    @dev_config
    |> Config.Reader.read!(env: :dev)
    |> Keyword.fetch!(:orchard_node_agent)
    |> Keyword.fetch!(:host_inventory)
  end

  defp restore_env!(snapshot) do
    clear_env!()
    Enum.each(snapshot, fn {key, value} -> System.put_env(key, value) end)
  end

  defp clear_env! do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&orchard_key?/1)
    |> Enum.each(&System.delete_env/1)
  end

  defp orchard_key?(key), do: String.starts_with?(key, "ORCHARD_")
end
