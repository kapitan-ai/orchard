defmodule Orchard.Node.WorkerCapabilityEvidenceTest do
  use ExUnit.Case, async: true

  alias Orchard.Node.Worker.V1.{WorkerCapabilities, WorkerCapabilityProfile}
  alias Orchard.Node.WorkerCapabilityEvidence, as: Evidence

  @received_at_ms 1_000
  @custody {4242, {:process_identity, "test"}}
  @incarnation "0123456789abcdef0123456789abcdef"
  @window [freshness_window_ms: 15_000]

  describe "classify/3 receipt classification (design D2-D5)" do
    test "nil envelope is absent" do
      snapshot = Evidence.classify(nil, @received_at_ms, @custody)

      assert snapshot == %{
               classification: :absent,
               envelope: nil,
               received_at_ms: @received_at_ms,
               custody: @custody,
               service_incarnation: nil,
               detail: nil
             }
    end

    test "well-formed envelope is valid and retains the incarnation" do
      envelope = envelope()
      snapshot = Evidence.classify(envelope, @received_at_ms, @custody)

      assert snapshot.classification == :valid
      assert snapshot.envelope == envelope
      assert snapshot.custody == @custody
      assert snapshot.service_incarnation == @incarnation
      assert snapshot.detail == nil
    end

    test "protocol_minor 0 is valid" do
      assert classify(envelope(protocol_minor: 0)).classification == :valid
    end

    test "empty profiles list is valid" do
      assert classify(envelope(profiles: [])).classification == :valid
    end

    test "zero protocol_major is malformed" do
      assert_malformed(envelope(protocol_major: 0), "protocol_major")
    end

    test "empty provider_id is malformed" do
      assert_malformed(envelope(provider_id: ""), "provider_id")
    end

    test "uppercase provider_id violates token grammar" do
      assert_malformed(envelope(provider_id: "MLX"), "provider_id")
    end

    test "provider_version longer than 128 bytes is malformed" do
      assert_malformed(
        envelope(provider_version: String.duplicate("1", 129)),
        "provider_version"
      )
    end

    test "provider_version of exactly 128 printable bytes is valid" do
      assert classify(envelope(provider_version: String.duplicate("1", 128))).classification ==
               :valid
    end

    test "empty implementation_version is malformed" do
      assert_malformed(envelope(implementation_version: ""), "implementation_version")
    end

    test "non-printable implementation_version is malformed" do
      assert_malformed(envelope(implementation_version: "0.1\t0"), "implementation_version")
    end

    test "service_incarnation that is not a token is malformed" do
      assert_malformed(envelope(service_incarnation: "has space"), "service_incarnation")
    end

    test "more than 64 profiles is malformed" do
      profiles = for n <- 1..65, do: profile(profile_id: "p#{n}", max_concurrency: n)

      assert_malformed(envelope(profiles: profiles), "profiles")
    end

    test "profile with empty profile_id is malformed" do
      assert_malformed(
        envelope(profiles: [profile(profile_id: "")]),
        "profiles[0].profile_id"
      )
    end

    test "profile scalar dimension with bad grammar is malformed with its field path" do
      assert_malformed(
        envelope(profiles: [profile(), profile(profile_id: "b", acceleration: "Metal")]),
        "profiles[1].acceleration"
      )
    end

    test "empty memory_semantics is malformed" do
      assert_malformed(
        envelope(profiles: [profile(memory_semantics: "")]),
        "profiles[0].memory_semantics"
      )
    end

    test "zero max_concurrency is malformed" do
      assert_malformed(
        envelope(profiles: [profile(max_concurrency: 0)]),
        "profiles[0].max_concurrency"
      )
    end

    test "more than 64 runtime_features is malformed" do
      features = for n <- 10..74, do: "f#{n}"

      assert_malformed(
        envelope(profiles: [profile(runtime_features: features)]),
        "profiles[0].runtime_features"
      )
    end

    test "unsorted runtime_features is malformed" do
      assert_malformed(
        envelope(profiles: [profile(runtime_features: ["streaming", "prompt_token_ids"])]),
        "profiles[0].runtime_features"
      )
    end

    test "duplicated runtime_features is malformed" do
      assert_malformed(
        envelope(profiles: [profile(runtime_features: ["streaming", "streaming"])]),
        "profiles[0].runtime_features"
      )
    end

    test "cache_capabilities entry that is not a token is malformed" do
      assert_malformed(
        envelope(profiles: [profile(cache_capabilities: ["Prefix"])]),
        "profiles[0].cache_capabilities"
      )
    end

    test "duplicate profile_id is duplicate_or_conflicting" do
      snapshot =
        classify(envelope(profiles: [profile(), profile(max_concurrency: 1)]))

      assert snapshot.classification == :duplicate_or_conflicting
      assert snapshot.detail == "profiles.profile_id"
      assert snapshot.service_incarnation == nil
    end

    test "duplicate canonical tuple under a different profile_id is duplicate_or_conflicting" do
      snapshot = classify(envelope(profiles: [profile(), profile(profile_id: "alias")]))

      assert snapshot.classification == :duplicate_or_conflicting
      assert snapshot.detail == "profiles.canonical_tuple"
    end

    test "protocol_major 2 is incompatible" do
      snapshot = classify(envelope(protocol_major: 2))

      assert snapshot.classification == :incompatible
      assert snapshot.detail == "protocol_major"
      assert snapshot.service_incarnation == nil
    end

    test "malformed wins over duplicate and incompatible" do
      snapshot =
        classify(
          envelope(
            protocol_major: 2,
            provider_id: "",
            profiles: [profile(), profile()]
          )
        )

      assert snapshot.classification == :malformed
    end

    test "duplicate_or_conflicting wins over incompatible" do
      snapshot = classify(envelope(protocol_major: 2, profiles: [profile(), profile()]))

      assert snapshot.classification == :duplicate_or_conflicting
    end
  end

  describe "canonical_tuple/1 (design D4)" do
    test "normalizes set fields to sorted unique lists" do
      tuple =
        Evidence.canonical_tuple(
          profile(
            runtime_features: ["streaming", "prompt_token_ids", "streaming"],
            cache_capabilities: ["prefix_cache"]
          )
        )

      assert tuple ==
               {"safetensors", "metal", "apple_gpu_0", "unified", 4,
                ["prompt_token_ids", "streaming"], ["prefix_cache"]}
    end
  end

  describe "known_vocabulary/0 and supported_protocol_major/0" do
    test "seeded with the MLX worker values" do
      assert Evidence.known_vocabulary() == %{
               artifact_format: ["safetensors"],
               acceleration: ["metal"],
               device_binding: ["apple_gpu_0"],
               memory_semantics: ["unified"]
             }

      assert Evidence.supported_protocol_major() == 1
    end
  end

  describe "evaluate/4 precedence (design D5)" do
    test "nil snapshot is absent" do
      assert Evidence.evaluate(nil, query(), @received_at_ms, @window) == :absent
    end

    test "absent snapshot is absent regardless of freshness" do
      snapshot = Evidence.classify(nil, @received_at_ms, @custody)

      assert Evidence.evaluate(snapshot, query(), @received_at_ms + 100_000, @window) == :absent
    end

    test "stale is reported before a retained malformed verdict" do
      snapshot = classify(envelope(protocol_major: 0))

      assert Evidence.evaluate(snapshot, query(), @received_at_ms + 15_001, @window) == :stale
      assert Evidence.evaluate(snapshot, query(), @received_at_ms + 15_000, @window) == :malformed
    end

    test "stale is reported for a valid snapshot past the window" do
      snapshot = classify(envelope())

      assert Evidence.evaluate(snapshot, query(), @received_at_ms + 15_001, @window) == :stale
    end

    test "freshness window is taken from opts" do
      snapshot = classify(envelope())

      now_ms = @received_at_ms + 500

      assert Evidence.evaluate(snapshot, query(), now_ms, freshness_window_ms: 100) == :stale

      assert {:supported, _profile_id, _incarnation} =
               Evidence.evaluate(snapshot, query(), @received_at_ms + 500,
                 freshness_window_ms: 1_000
               )
    end

    test "fresh malformed, duplicate_or_conflicting, and incompatible pass through" do
      assert evaluate(envelope(protocol_major: 0), query()) == :malformed

      assert evaluate(envelope(profiles: [profile(), profile()]), query()) ==
               :duplicate_or_conflicting

      assert evaluate(envelope(protocol_major: 2), query()) == :incompatible
    end

    test "exact match proves the profile_id and service_incarnation" do
      assert evaluate(envelope(), query()) ==
               {:supported, "mlx-metal-unified-default", @incarnation}
    end

    test "first matching profile in wire order wins" do
      assert evaluate(envelope(), query(runtime_features: ["streaming"])) ==
               {:supported, "mlx-metal-unified-default", @incarnation}
    end

    test "min_concurrency selects a profile with enough capacity" do
      profiles = [profile(profile_id: "serial", max_concurrency: 1), profile()]

      assert evaluate(envelope(profiles: profiles), query(min_concurrency: 4)) ==
               {:supported, "mlx-metal-unified-default", @incarnation}
    end

    test "min_concurrency beyond every profile is unsupported" do
      assert evaluate(envelope(), query(min_concurrency: 8)) == :unsupported
    end

    test "empty profiles list is unsupported" do
      assert evaluate(envelope(profiles: []), query()) == :unsupported
    end

    test "unrecognised vocabulary on an otherwise matching profile is unknown" do
      profiles = [profile(profile_id: "cuda", acceleration: "cuda")]

      assert evaluate(envelope(profiles: profiles), query(acceleration: "cuda")) == :unknown
    end

    test "unrecognised vocabulary is unknown even when the query names a known value" do
      profiles = [profile(profile_id: "cuda", acceleration: "cuda")]

      assert evaluate(envelope(profiles: profiles), query()) == :unknown
    end

    test "unrecognised vocabulary that also fails a known dimension is unsupported" do
      profiles = [profile(profile_id: "cuda", acceleration: "cuda")]

      assert evaluate(
               envelope(profiles: profiles),
               query(acceleration: "cuda", device_binding: "apple_gpu_1")
             ) == :unsupported
    end

    test "unrecognised vocabulary that also lacks capacity is unsupported" do
      profiles = [profile(profile_id: "cuda", acceleration: "cuda", max_concurrency: 1)]

      assert evaluate(
               envelope(profiles: profiles),
               query(acceleration: "cuda", min_concurrency: 2)
             ) == :unsupported
    end

    test "features and caches are not combined across profiles" do
      profiles = [
        profile(profile_id: "a", runtime_features: ["prompt_token_ids"], cache_capabilities: []),
        profile(profile_id: "b", runtime_features: [], cache_capabilities: ["prefix_cache"])
      ]

      query = query(runtime_features: ["prompt_token_ids"], cache_capabilities: ["prefix_cache"])

      assert evaluate(envelope(profiles: profiles), query) == :unsupported

      assert evaluate(envelope(profiles: profiles), query(runtime_features: ["prompt_token_ids"])) ==
               {:supported, "a", @incarnation}
    end
  end

  defp classify(envelope), do: Evidence.classify(envelope, @received_at_ms, @custody)

  defp evaluate(envelope, query) do
    Evidence.evaluate(classify(envelope), query, @received_at_ms + 1, @window)
  end

  defp assert_malformed(envelope, detail) do
    snapshot = classify(envelope)

    assert snapshot.classification == :malformed
    assert snapshot.envelope == nil
    assert snapshot.service_incarnation == nil
    assert snapshot.detail == detail
    assert snapshot.service_incarnation == nil
  end

  defp query(overrides \\ []) do
    Map.merge(
      %{
        artifact_format: "safetensors",
        acceleration: "metal",
        device_binding: "apple_gpu_0",
        memory_semantics: "unified"
      },
      Map.new(overrides)
    )
  end

  defp envelope(overrides \\ []) do
    struct!(
      %WorkerCapabilities{
        protocol_major: 1,
        protocol_minor: 1,
        provider_id: "mlx",
        provider_version: "0.31.2",
        implementation_version: "0.1.0",
        service_incarnation: @incarnation,
        profiles: [profile()]
      },
      overrides
    )
  end

  defp profile(overrides \\ []) do
    struct!(
      %WorkerCapabilityProfile{
        profile_id: "mlx-metal-unified-default",
        artifact_format: "safetensors",
        acceleration: "metal",
        device_binding: "apple_gpu_0",
        memory_semantics: "unified",
        max_concurrency: 4,
        runtime_features: ["prompt_token_ids", "streaming"],
        cache_capabilities: ["prefix_cache"]
      },
      overrides
    )
  end
end

defmodule Orchard.Node.WorkerCapabilitiesFreshnessWindowConfigTest do
  use ExUnit.Case, async: false

  alias Orchard.Node

  setup do
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    on_exit(fn ->
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
    end)

    %{previous_runtime: previous_runtime}
  end

  test "defaults to 15_000 when the key is nil or missing", %{previous_runtime: previous_runtime} do
    assert previous_runtime[:worker_capabilities_freshness_window_ms] == 15_000

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.put(previous_runtime, :worker_capabilities_freshness_window_ms, nil)
    )

    assert Node.worker_capabilities_freshness_window_ms() == 15_000

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.delete(previous_runtime, :worker_capabilities_freshness_window_ms)
    )

    assert Node.worker_capabilities_freshness_window_ms() == 15_000
  end

  test "honors a runtime override", %{previous_runtime: previous_runtime} do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.put(previous_runtime, :worker_capabilities_freshness_window_ms, 2_500)
    )

    assert Node.worker_capabilities_freshness_window_ms() == 2_500
  end

  test "rejects a non-positive override", %{previous_runtime: previous_runtime} do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.put(previous_runtime, :worker_capabilities_freshness_window_ms, 0)
    )

    assert_raise RuntimeError, ~r/worker_capabilities_freshness_window_ms/, fn ->
      Node.worker_capabilities_freshness_window_ms()
    end
  end
end
