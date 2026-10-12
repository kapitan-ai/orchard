defmodule Orchard.Inference.EffortProfilesTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.EffortProfiles

  @registry_path Path.expand(
                   "../../../../../native/orchard_tokenizer/src/orchard_tokenizer/effort_profiles.json",
                   __DIR__
                 )

  test "SPEC §3.5 validates the complete production registry before compilation uses it" do
    [profile] = EffortProfiles.load!(@registry_path)
    assert profile["generation_argument"]["value"] == true

    assert profile["efforts"] == %{
             "low" => "low",
             "medium" => "medium",
             "high" => "xhigh",
             "xhigh" => "xhigh"
           }

    assert profile["default_effort"] == "xhigh"
  end

  test "colliding arguments cannot attest low while the template defaults to xhigh" do
    [profile] = EffortProfiles.load!(@registry_path)
    collision = Map.put(profile, "effort_argument", profile["generation_argument"]["key"])

    assert_raise ArgumentError, "invalid rendered effort registry", fn ->
      EffortProfiles.validate!(%{"profiles" => [collision]})
    end
  end

  test "duplicate exact identities never choose the first registration" do
    [profile] = EffortProfiles.load!(@registry_path)
    different_mapping = put_in(profile["efforts"]["low"], "xhigh")

    assert_raise ArgumentError, "invalid rendered effort registry", fn ->
      EffortProfiles.validate!(%{"profiles" => [profile, different_mapping]})
    end
  end

  test "closed registry rejects malformed identities, arguments, and canonical mappings" do
    [profile] = EffortProfiles.load!(@registry_path)

    malformed = [
      Map.put(profile, "unknown", true),
      Map.delete(profile, "render_contract"),
      Map.put(profile, "model_artifact_digest", String.duplicate("A", 64)),
      Map.put(profile, "chat_template_digest", "short"),
      Map.put(profile, "render_contract", "invalid name"),
      Map.put(profile, "render_contract_version", "0"),
      Map.put(profile, "render_contract_version", 1),
      Map.put(profile, "effort_argument", ""),
      put_in(profile["generation_argument"]["key"], "not an identifier"),
      put_in(profile["generation_argument"]["value"], false),
      put_in(profile["generation_argument"]["value"], "true"),
      Map.update!(profile, "generation_argument", &Map.put(&1, "extra", true)),
      Map.put(profile, "efforts", %{}),
      Map.update!(profile, "efforts", &Map.put(&1, "MAX", "max")),
      Map.put(profile, "default_effort", "max"),
      Map.put(profile, "default_effort", nil),
      Map.update!(profile, "efforts", &Map.put(&1, "none", "none")),
      Map.update!(profile, "efforts", &Map.put(&1, String.duplicate("a", 33), "max")),
      put_in(profile["efforts"]["low"], " "),
      put_in(profile["efforts"]["medium"], nil),
      nil
    ]

    for invalid <- malformed do
      assert_raise ArgumentError, "invalid rendered effort registry", fn ->
        EffortProfiles.validate!(%{"profiles" => [invalid]})
      end
    end

    for invalid <- [nil, %{}, %{"profiles" => nil}, %{"profiles" => [], "extra" => true}] do
      assert_raise ArgumentError, "invalid rendered effort registry", fn ->
        EffortProfiles.validate!(invalid)
      end
    end
  end

  test "SPEC §7.2.3 profiles support distinct additional values and supported subsets" do
    [profile] = EffortProfiles.load!(@registry_path)

    for values <- [
          %{"minimal" => "minimal", "max" => "max"},
          %{
            "low" => "low",
            "medium" => "medium",
            "high" => "high",
            "xhigh" => "xhigh",
            "max" => "max"
          }
        ] do
      custom = %{profile | "efforts" => values, "default_effort" => "max"}
      assert [^custom] = EffortProfiles.validate!(%{"profiles" => [custom]})
    end
  end
end
