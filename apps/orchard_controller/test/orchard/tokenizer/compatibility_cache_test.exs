defmodule Orchard.Tokenizer.CompatibilityCacheTest do
  use ExUnit.Case, async: false

  alias Orchard.Tokenizer.CompatibilityCache

  setup do
    CompatibilityCache.clear()
    :ok
  end

  test "get/2 returns :unknown when key is missing" do
    assert :unknown = CompatibilityCache.get("bundle-a", "catalog-a")
  end

  test "put_compatible/3 round-trips compatible verdict" do
    assert :ok =
             CompatibilityCache.put_compatible("bundle-a", "catalog-a", %{
               template_compatible: true
             })

    assert {:compatible, %{template_compatible: true}} =
             CompatibilityCache.get("bundle-a", "catalog-a")
  end

  test "put_compatible/3 preserves sentinel preflight metadata" do
    assert :ok =
             CompatibilityCache.put_compatible("bundle-a", "catalog-a", %{
               template_compatible: true,
               sentinel_preflight_validated: true
             })

    assert {:compatible, %{template_compatible: true, sentinel_preflight_validated: true}} =
             CompatibilityCache.get("bundle-a", "catalog-a")
  end

  test "put_incompatible/3 round-trips incompatible verdict" do
    reason = %{category: "safe_tokenization_incompatible_template"}
    assert :ok = CompatibilityCache.put_incompatible("bundle-a", "catalog-a", reason)

    assert {:incompatible, ^reason} = CompatibilityCache.get("bundle-a", "catalog-a")
  end

  test "put_compatible_if_safe/3 seeds only unknown or compatible-positive verdicts" do
    assert :ok =
             CompatibilityCache.put_compatible_if_safe("bundle-a", "catalog-a", %{
               template_compatible: true,
               sentinel_preflight_validated: true
             })

    assert {:compatible, %{template_compatible: true, sentinel_preflight_validated: true}} =
             CompatibilityCache.get("bundle-a", "catalog-a")

    assert :ok =
             CompatibilityCache.put_compatible("bundle-b", "catalog-b", %{
               template_compatible: true
             })

    assert :ok =
             CompatibilityCache.put_compatible_if_safe("bundle-b", "catalog-b", %{
               template_compatible: true,
               sentinel_preflight_validated: true
             })

    assert {:compatible, %{template_compatible: true, sentinel_preflight_validated: true}} =
             CompatibilityCache.get("bundle-b", "catalog-b")
  end

  test "put_compatible_if_safe/3 preserves incompatible and template-incompatible verdicts" do
    reason = %{"category" => "dual_render_mismatch"}

    assert :ok = CompatibilityCache.put_incompatible("bundle-a", "catalog-a", reason)

    assert :ok =
             CompatibilityCache.put_compatible_if_safe("bundle-a", "catalog-a", %{
               template_compatible: true,
               sentinel_preflight_validated: true
             })

    assert {:incompatible, ^reason} = CompatibilityCache.get("bundle-a", "catalog-a")

    assert :ok =
             CompatibilityCache.put_compatible("bundle-b", "catalog-b", %{
               template_compatible: false
             })

    assert :ok =
             CompatibilityCache.put_compatible_if_safe("bundle-b", "catalog-b", %{
               template_compatible: true,
               sentinel_preflight_validated: true
             })

    assert {:compatible, %{template_compatible: false}} =
             CompatibilityCache.get("bundle-b", "catalog-b")
  end

  test "clear/0 removes all entries" do
    assert :ok =
             CompatibilityCache.put_compatible("bundle-a", "catalog-a", %{
               template_compatible: false
             })

    assert {:compatible, %{template_compatible: false}} =
             CompatibilityCache.get("bundle-a", "catalog-a")

    assert :ok = CompatibilityCache.clear()
    assert :unknown = CompatibilityCache.get("bundle-a", "catalog-a")
  end

  test "concurrent writes and reads remain stable" do
    tasks =
      for index <- 1..50 do
        Task.async(fn ->
          bundle_sha = "bundle-#{index}"
          catalog_sha = "catalog-#{index}"

          assert :ok =
                   CompatibilityCache.put_compatible(bundle_sha, catalog_sha, %{
                     template_compatible: rem(index, 2) == 0
                   })

          CompatibilityCache.get(bundle_sha, catalog_sha)
        end)
      end

    results = Task.await_many(tasks)

    assert length(results) == 50
    assert Enum.all?(results, &match?({:compatible, %{template_compatible: _}}, &1))
  end

  test "external ETS writes are rejected while API writes and reads continue to work" do
    table = :orchard_tokenizer_compatibility_cache
    bundle_sha = "bundle-a"
    catalog_sha = "catalog-a"

    assert :ok =
             CompatibilityCache.put_compatible(bundle_sha, catalog_sha, %{
               template_compatible: true
             })

    assert [{{^bundle_sha, ^catalog_sha}, {:compatible, %{template_compatible: true}}}] =
             :ets.lookup(table, {bundle_sha, catalog_sha})

    assert_raise ArgumentError, fn ->
      :ets.insert(table, {{bundle_sha, catalog_sha}, {:incompatible, %{category: "forged"}}})
    end

    assert {:compatible, %{template_compatible: true}} =
             CompatibilityCache.get(bundle_sha, catalog_sha)
  end
end
