defmodule Orchard.Node.HostInventoryTest do
  # SPEC.md §4.1 and §4.9: the Node publishes bounded observation-only host
  # inventory from an explicitly configured capability provider. Collection
  # never blocks status reads and never creates readiness or authority.
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.{HostCpuObservation, HostEvidence, HostInventoryObservation}
  alias Orchard.Node.HostInventory

  defmodule StaticProvider do
    @behaviour Orchard.Node.HostInventory.Provider

    @impl true
    def observe(opts), do: Keyword.fetch!(opts, :observation)

    @impl true
    def error_observation(now_ms, error_code) do
      %HostInventoryObservation{
        schema_version: 1,
        observed_at_unix_ms: now_ms,
        authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY,
        cpu: %HostCpuObservation{
          evidence: %HostEvidence{state: :HOST_EVIDENCE_STATE_ERROR, error_code: error_code}
        }
      }
    end
  end

  defmodule AgentProvider do
    @behaviour Orchard.Node.HostInventory.Provider

    @impl true
    def observe(opts) do
      architecture = Agent.get(Keyword.fetch!(opts, :source), & &1)

      %HostInventoryObservation{
        schema_version: 1,
        observed_at_unix_ms: 1_789_743_600_000,
        authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY,
        cpu: %HostCpuObservation{architecture: architecture, logical_processor_count: 4}
      }
    end

    @impl true
    defdelegate error_observation(now_ms, error_code), to: StaticProvider
  end

  defmodule HungProvider do
    @behaviour Orchard.Node.HostInventory.Provider

    @impl true
    def observe(_opts), do: Process.sleep(:infinity)

    @impl true
    defdelegate error_observation(now_ms, error_code), to: StaticProvider
  end

  defmodule CrashingProvider do
    @behaviour Orchard.Node.HostInventory.Provider

    @impl true
    def observe(_opts), do: exit(:provider_bug)

    @impl true
    defdelegate error_observation(now_ms, error_code), to: StaticProvider
  end

  test "a failing provider becomes error evidence and the owner survives" do
    name = start_inventory!(provider: CrashingProvider)
    owner = Process.whereis(name)

    assert %HostInventoryObservation{cpu: %{evidence: %{error_code: "provider_failed"}}} =
             eventually(fn -> HostInventory.current(name) end)

    assert Process.alive?(owner)
  end

  test "a hung provider becomes timeout evidence without delaying reads" do
    name = start_inventory!(provider: HungProvider, collection_timeout_ms: 50)

    {micros, nil} = :timer.tc(fn -> HostInventory.current(name) end)
    assert micros < 50_000

    assert %HostInventoryObservation{cpu: %{evidence: %{error_code: "provider_timeout"}}} =
             eventually(fn -> HostInventory.current(name) end)
  end

  test "out-of-bounds provider output is published as error evidence" do
    oversized = put_in(inventory("x86_64").cpu.model_name, String.duplicate("x", 300))
    name = start_inventory!(provider_opts: [observation: oversized])

    assert %HostInventoryObservation{cpu: %{evidence: %{error_code: "inventory_out_of_bounds"}}} =
             eventually(fn -> HostInventory.current(name) end)
  end

  test "a snapshot older than its maximum age is absent" do
    name =
      start_inventory!(
        provider_opts: [observation: inventory("x86_64")],
        refresh_ms: 60_000,
        max_age_ms: 40
      )

    assert eventually(fn -> HostInventory.current(name) end) == inventory("x86_64")
    Process.sleep(80)
    assert HostInventory.current(name) == nil
  end

  test "periodic refresh replaces the snapshot" do
    {:ok, source} = Agent.start_link(fn -> "x86_64" end)

    name =
      start_inventory!(provider: AgentProvider, provider_opts: [source: source], refresh_ms: 20)

    assert eventually(fn -> HostInventory.current(name) end) == inventory("x86_64")
    Agent.update(source, fn _ -> "aarch64" end)

    assert eventually(fn ->
             if HostInventory.current(name) == inventory("aarch64"), do: :replaced
           end) == :replaced
  end

  test "publishes the provider observation as the current snapshot" do
    name = start_inventory!(provider_opts: [observation: inventory("x86_64")])

    assert eventually(fn -> HostInventory.current(name) end) == inventory("x86_64")
  end

  defp start_inventory!(opts) do
    name = :"host_inventory_#{System.unique_integer([:positive])}"

    start_supervised!(
      {HostInventory, Keyword.merge([name: name, provider: StaticProvider], opts)}
    )

    name
  end

  defp inventory(architecture) do
    %HostInventoryObservation{
      schema_version: 1,
      observed_at_unix_ms: 1_789_743_600_000,
      authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY,
      cpu: %HostCpuObservation{architecture: architecture, logical_processor_count: 4}
    }
  end

  defp eventually(fun, attempts \\ 100) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end
end
