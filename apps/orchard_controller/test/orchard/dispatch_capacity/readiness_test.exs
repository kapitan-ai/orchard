defmodule Orchard.DispatchCapacity.ReadinessTest do
  use ExUnit.Case, async: true

  alias Orchard.DispatchCapacity.{ConformanceFixture, Readiness}

  test "SPEC 4.8 the complete five-consumer build publishes ready" do
    assert Readiness.ready?()
    assert length(Readiness.consumer_manifest()) == 5
  end

  test "SPEC 4.8 the default readiness proof is memoized for the build" do
    assert Readiness.ready?()
    assert :persistent_term.get({Readiness, :default_readiness}) == true
    assert Readiness.ready?()
  end

  test "SPEC 4.8 the readiness proof leaves no fixture link on the caller" do
    Process.flag(:trap_exit, true)
    {:links, before_links} = Process.info(self(), :links)

    assert Readiness.ready?(required_contract_version: Readiness.contract_version())

    {:links, after_links} = Process.info(self(), :links)
    assert after_links == before_links
    refute_receive {:EXIT, _pid, _reason}, 50
  end

  test "SPEC 4.8 missing, incompatible, or fixture-failing builds remain false" do
    [_missing | incomplete] = Readiness.consumer_manifest()

    refute Readiness.ready?(consumer_manifest: incomplete)
    refute Readiness.ready?(required_contract_version: Readiness.contract_version() + 1)
    refute Readiness.ready?(fixture_input: :invalid)

    refute Readiness.ready?(
             fixture_input: %{
               ConformanceFixture.input()
               | controller_accounted_allocation: 999,
                 temporary_legacy_claim_count: 999
             }
           )
  end
end
