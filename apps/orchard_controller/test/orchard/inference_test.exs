defmodule Orchard.InferenceTest do
  use ExUnit.Case, async: false
  import Orchard.TestSupport.RepoHelpers

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.Inference
  alias Orchard.Inference.ChatOrchestrator
  alias Orchard.Models
  alias Orchard.RuntimeEndpoint.Target
  alias Orchard.Scheduler.{MultiNode, SingleNode}
  alias Orchard.Tokenizer.Client

  defmodule FakeTokenizer do
    @behaviour Orchard.Tokenizer.Client

    def tokenize(%CanonicalRequest{} = request, opts) do
      if Keyword.get(opts, :source) == :test do
        {:ok, %{public_id: request.public_id, opts: opts, tokenizer: :fake}}
      else
        send(self(), {:fake_tokenizer_opts, opts})
        {:ok, %{rendered_prompt: "fake", input_token_count: 1, prompt_token_ids: [1]}}
      end
    end
  end

  defmodule FakeScheduler do
    @behaviour Orchard.Scheduler.SingleNode

    def schedule(%CanonicalRequest{} = request) do
      {:ok, %{scheduled_public_id: request.public_id, scheduler: :fake}}
    end
  end

  @config_env_vars [
    "DATABASE_URL",
    "MIX_RELEASE_NAME",
    "ORCHARD_BUNDLE_BUILD_EAGER_PREFLIGHT_ENABLED",
    "ORCHARD_BUNDLE_BUILD_PREFLIGHT_TIMEOUT_MS",
    "ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES",
    "ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE",
    "ORCHARD_SUPPORT_ROOT",
    "ORCHARD_TLS_DISABLED",
    "ORCHARD_TRANSPORT_MODE",
    "RELEASE_NAME",
    "SECRET_KEY_BASE"
  ]

  setup tags do
    if tags[:db], do: Orchard.DataCase.setup_sandbox(tags)

    previous_inference = Application.fetch_env!(:orchard_controller, :inference)

    env_snapshot =
      System.get_env()
      |> Enum.filter(fn {key, _value} -> config_env_key?(key) end)
      |> Map.new()

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous_inference)
      restore_env(env_snapshot)
    end)

    :ok
  end

  test "inference module exposes configured seams and subtree" do
    assert is_pid(Process.whereis(Orchard.Inference))
    assert is_pid(Process.whereis(Orchard.Requests.Supervisor))

    assert Inference.request_supervisor() == Orchard.Requests.Supervisor
    assert Inference.tokenizer_client() == Orchard.Tokenizer.Client
    assert Inference.scheduler() == Orchard.Scheduler.SingleNode
  end

  @tag :db
  test "default scheduler and runtime seam use configured runtime target" do
    request = canonical_request()

    assert {:ok, schedule} = SingleNode.schedule(request)
    assert schedule.strategy == :single_node
    assert schedule.request_id == request.public_id
    assert schedule.runtime_client_target == [host: "127.0.0.1", port: 50_071]
    assert schedule.request_timeout_ms == 5_000
    assert schedule.model_load_timeout_ms == 5_000

    assert Client.mode() == :fake

    assert String.ends_with?(
             Client.executable(),
             "/native/orchard_tokenizer/bin/orchard-tokenizer"
           )
  end

  @tag :db
  test "request preparation passes trusted catalog artifact sha256 to tokenizer opts" do
    bundle_root = Path.expand("../fixtures/bundles/test-model-bundle", __DIR__)
    artifact_sha256 = String.duplicate("d", 64)

    put_inference(tokenizer_mode: :port, tokenizer_client_impl: FakeTokenizer)

    assert {:ok, _model} =
             Models.create_model(%{
               model_id: "cache-authority-model",
               version: "v1",
               artifact_uri: "file://" <> bundle_root,
               artifact_source_uri: "file://" <> bundle_root,
               artifact_sha256: artifact_sha256,
               artifact_size_bytes: 1_024,
               resident_memory_bytes: 2_048,
               kv_cache_bytes_per_token: 16,
               prefill_workspace_bytes_per_token: 8,
               max_context_tokens: 8_192,
               state: :active,
               format: "mlx",
               capabilities: ["chat"],
               tokenizer: %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
               runtime_requirements: %{"adapter" => "mlx_lm"}
             })

    assert {:ok, canonical, _model} =
             ChatOrchestrator.prepare(%{
               "model" => "cache-authority-model@v1",
               "messages" => [%{"role" => "user", "content" => "hello"}]
             })

    assert canonical.input_token_count == 1
    assert_receive {:fake_tokenizer_opts, opts}
    assert Keyword.fetch!(opts, :bundle_sha256) == artifact_sha256
    assert Keyword.fetch!(opts, :bundle_root) == bundle_root
    refute Keyword.fetch!(opts, :manifest).sha256 == artifact_sha256
  end

  test "tokenizer and scheduler seams are injectable" do
    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(Application.fetch_env!(:orchard_controller, :inference),
        tokenizer_client_impl: FakeTokenizer,
        scheduler_impl: FakeScheduler
      )
    )

    request = canonical_request()

    assert {:ok, %{public_id: "req_inference_test", tokenizer: :fake}} =
             Client.tokenize(request, source: :test)

    assert {:ok, %{scheduled_public_id: "req_inference_test", scheduler: :fake}} =
             SingleNode.schedule(request)
  end

  describe "runtime_client_targets/0" do
    test "returns configured plural targets when set" do
      targets = [
        [host: "10.0.0.1", port: 50_061],
        [host: "10.0.0.2", port: 50_062]
      ]

      put_inference(runtime_client_targets: targets)
      assert Inference.runtime_client_targets() == targets
    end

    test "falls back to singular target wrapped in list when plural is empty" do
      put_inference(runtime_client_targets: [])
      assert Inference.runtime_client_targets() == [Inference.runtime_client_target()]
    end

    test "falls back to singular target wrapped in list when plural is nil" do
      put_inference(runtime_client_targets: nil)
      assert Inference.runtime_client_targets() == [Inference.runtime_client_target()]
    end

    test "deduplicates configured plural targets by host and port" do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.2", port: 50_062]
        ]
      )

      assert Inference.runtime_client_targets() == [
               [host: "10.0.0.1", port: 50_061],
               [host: "10.0.0.2", port: 50_062]
             ]
    end

    test "node_freshness_threshold_ms returns configured value" do
      assert Inference.node_freshness_threshold_ms() == 30_000
    end

    test "node_freshness_threshold_ms returns default when not configured" do
      config = Application.fetch_env!(:orchard_controller, :inference)
      clean = Keyword.delete(config, :node_freshness_threshold_ms)
      Application.put_env(:orchard_controller, :inference, clean)
      assert Inference.node_freshness_threshold_ms() == 30_000
    end

    test "node_unreachable_threshold_ms returns configured value" do
      put_inference(node_unreachable_threshold_ms: 20_000)
      assert Inference.node_unreachable_threshold_ms() == 20_000
    end

    test "node_unreachable_threshold_ms returns default when not configured" do
      config = Application.fetch_env!(:orchard_controller, :inference)
      clean = Keyword.delete(config, :node_unreachable_threshold_ms)
      Application.put_env(:orchard_controller, :inference, clean)
      assert Inference.node_unreachable_threshold_ms() == 15_000
    end
  end

  describe "runtime_endpoint_targets/0" do
    test "defaults to gRPC compatibility targets from legacy runtime client config" do
      put_inference(runtime_client_targets: [[host: "10.0.0.1", port: 50_061]])

      assert [%Target{transport: :grpc_compat, address: [host: "10.0.0.1", port: 50_061]}] =
               Inference.runtime_endpoint_targets()
    end

    test "explicit Runtime Endpoint targets opt into BEAM without changing legacy fallback" do
      node_id = "550e8400-e29b-41d4-a716-446655440000"

      put_inference(
        runtime_client_targets: [[host: "10.0.0.1", port: 50_061]],
        runtime_endpoint_targets: [
          %{transport: :beam, node_id: node_id, address: :orchard_node_agent@localhost}
        ]
      )

      assert [
               %Target{
                 transport: :beam,
                 node_id: ^node_id,
                 address: :orchard_node_agent@localhost
               }
             ] = Inference.runtime_endpoint_targets()
    end
  end

  describe "tokenizer_safe_mode/0" do
    test "defaults to :off when not configured" do
      config = Application.fetch_env!(:orchard_controller, :inference)

      Application.put_env(
        :orchard_controller,
        :inference,
        Keyword.delete(config, :tokenizer_safe_mode)
      )

      assert Inference.tokenizer_safe_mode() == :off
    end

    test "accepts off/on/reject from app config" do
      put_inference(tokenizer_safe_mode: :off)
      assert Inference.tokenizer_safe_mode() == :off

      put_inference(tokenizer_safe_mode: :on)
      assert Inference.tokenizer_safe_mode() == :on

      put_inference(tokenizer_safe_mode: :reject)
      assert Inference.tokenizer_safe_mode() == :reject
    end

    test "runtime.exs parses ORCHARD_TOKENIZER_SAFE_MODE" do
      assert read_runtime_controller_inference!(%{"ORCHARD_TOKENIZER_SAFE_MODE" => "off"})[
               :tokenizer_safe_mode
             ] == :off

      assert read_runtime_controller_inference!(%{"ORCHARD_TOKENIZER_SAFE_MODE" => "on"})[
               :tokenizer_safe_mode
             ] == :on

      assert read_runtime_controller_inference!(%{"ORCHARD_TOKENIZER_SAFE_MODE" => "reject"})[
               :tokenizer_safe_mode
             ] == :reject
    end

    test "dev.exs parses ORCHARD_TOKENIZER_SAFE_MODE" do
      assert read_dev_controller_inference!(%{"ORCHARD_TOKENIZER_SAFE_MODE" => "off"})[
               :tokenizer_safe_mode
             ] == :off

      assert read_dev_controller_inference!(%{"ORCHARD_TOKENIZER_SAFE_MODE" => "on"})[
               :tokenizer_safe_mode
             ] == :on

      assert read_dev_controller_inference!(%{"ORCHARD_TOKENIZER_SAFE_MODE" => "reject"})[
               :tokenizer_safe_mode
             ] == :reject
    end

    test "runtime.exs fails loudly for invalid ORCHARD_TOKENIZER_SAFE_MODE" do
      assert_raise RuntimeError, ~r/ORCHARD_TOKENIZER_SAFE_MODE must be off\|on\|reject/, fn ->
        read_runtime_controller_inference!(%{"ORCHARD_TOKENIZER_SAFE_MODE" => "invalid"})
      end
    end

    test "Inference.tokenizer_safe_mode/0 fails loudly for invalid app config" do
      put_inference(tokenizer_safe_mode: :invalid)

      assert_raise ArgumentError,
                   ~r/tokenizer_safe_mode must be :off, :on, or :reject/,
                   fn ->
                     Inference.tokenizer_safe_mode()
                   end
    end
  end

  describe "tokenizer_safe_mode_prefer_capable_workers?/0" do
    test "defaults to false when key is absent" do
      config = Application.fetch_env!(:orchard_controller, :inference)

      Application.put_env(
        :orchard_controller,
        :inference,
        Keyword.delete(config, :tokenizer_safe_mode_prefer_capable)
      )

      refute Inference.tokenizer_safe_mode_prefer_capable_workers?()
    end

    test "returns false when key is explicitly false" do
      put_inference(tokenizer_safe_mode_prefer_capable: false)
      refute Inference.tokenizer_safe_mode_prefer_capable_workers?()
    end

    test "returns true when key is explicitly true" do
      put_inference(tokenizer_safe_mode_prefer_capable: true)
      assert Inference.tokenizer_safe_mode_prefer_capable_workers?()
    end

    test "runtime.exs parses ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE=true" do
      inference =
        read_runtime_controller_inference!(%{
          "ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE" => "true"
        })

      assert Keyword.fetch!(inference, :tokenizer_safe_mode_prefer_capable) == true
    end

    test "runtime.exs defaults ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE to false when unset" do
      inference =
        read_runtime_controller_inference!(%{
          "ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE" => nil
        })

      assert Keyword.fetch!(inference, :tokenizer_safe_mode_prefer_capable) == false
    end

    test "dev.exs parses ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE=true" do
      inference =
        read_dev_controller_inference!(%{
          "ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE" => "true"
        })

      assert Keyword.fetch!(inference, :tokenizer_safe_mode_prefer_capable) == true
    end

    test "dev.exs defaults ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE to false when unset" do
      inference =
        read_dev_controller_inference!(%{
          "ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE" => nil
        })

      assert Keyword.fetch!(inference, :tokenizer_safe_mode_prefer_capable) == false
    end
  end

  describe "cache_affinity_config/0" do
    test "defaults disabled with bounded lookup settings" do
      config = Inference.cache_affinity_config()

      assert config[:enabled] == false
      assert config[:live_fingerprint_match_enabled] == false
      assert config[:max_prefix_bytes] == 8_192
      assert config[:max_age_ms] == 300_000
      assert config[:max_recent_requests] == 32
      refute Inference.cache_affinity_enabled?()
    end

    test "normalizes invalid values without enabling affinity" do
      put_inference(
        cache_affinity: [
          enabled: "true",
          live_fingerprint_match_enabled: true,
          max_prefix_bytes: -1,
          max_age_ms: -1,
          max_recent_requests: 0
        ]
      )

      config = Inference.cache_affinity_config()

      assert config[:enabled] == false
      assert config[:live_fingerprint_match_enabled] == false
      assert config[:max_prefix_bytes] == 8_192
      assert config[:max_age_ms] == 300_000
      assert config[:max_recent_requests] == 32
    end
  end

  describe "prefix_cache_scoring_config/0" do
    test "defaults disabled with a strict timeout" do
      config = Inference.prefix_cache_scoring_config()

      assert config[:enabled] == false
      assert config[:timeout_ms] == 150
      assert config[:ranking_mode] == :observe_only
      assert config[:max_ranking_candidates] == 2
      refute Inference.prefix_cache_scoring_enabled?()
      refute Inference.prefix_cache_scoring_ranking_active?()
      assert Inference.prefix_cache_scoring_ranking_mode() == :observe_only
      assert Inference.prefix_cache_scoring_max_ranking_candidates() == 2
      assert Inference.prefix_cache_scoring_timeout_ms() == 150
    end

    test "enabled scoring is parent-gated by cache_affinity and live fingerprint match" do
      put_inference(prefix_cache_scoring: [enabled: true, timeout_ms: 75])
      refute Inference.prefix_cache_scoring_enabled?()

      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: false],
        prefix_cache_scoring: [enabled: true, timeout_ms: 75]
      )

      refute Inference.prefix_cache_scoring_enabled?()

      put_inference(
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true],
        prefix_cache_scoring: [enabled: true, timeout_ms: 75]
      )

      assert Inference.prefix_cache_scoring_enabled?()
      assert Inference.prefix_cache_scoring_timeout_ms() == 75
    end

    test "ranking mode only activates tie-only mode when parent scoring gates are enabled" do
      put_inference(
        prefix_cache_scoring: [enabled: true, ranking_mode: :tie_only],
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true]
      )

      assert Inference.prefix_cache_scoring_ranking_mode() == :tie_only
      assert Inference.prefix_cache_scoring_ranking_active?()

      put_inference(
        prefix_cache_scoring: [enabled: true, ranking_mode: :observe_only],
        cache_affinity: [enabled: true, live_fingerprint_match_enabled: true]
      )

      refute Inference.prefix_cache_scoring_ranking_active?()
    end

    test "ranking helper accepts atom and string app config values" do
      put_inference(prefix_cache_scoring: [ranking_mode: :tie_only])
      assert Inference.prefix_cache_scoring_ranking_mode() == :tie_only

      put_inference(prefix_cache_scoring: [ranking_mode: "tie_only"])
      assert Inference.prefix_cache_scoring_ranking_mode() == :tie_only

      put_inference(prefix_cache_scoring: [ranking_mode: :observe_only])
      assert Inference.prefix_cache_scoring_ranking_mode() == :observe_only

      put_inference(prefix_cache_scoring: [ranking_mode: "observe_only"])
      assert Inference.prefix_cache_scoring_ranking_mode() == :observe_only
    end

    test "ranking helper falls back to observe_only for non-env invalid app config values" do
      put_inference(prefix_cache_scoring: [ranking_mode: :bogus])

      assert Inference.prefix_cache_scoring_ranking_mode() == :observe_only
      refute Inference.prefix_cache_scoring_ranking_active?()
    end

    test "max ranking candidates helper falls back to default for invalid values and caps at 2" do
      put_inference(prefix_cache_scoring: [max_ranking_candidates: 0])
      assert Inference.prefix_cache_scoring_max_ranking_candidates() == 2

      put_inference(prefix_cache_scoring: [max_ranking_candidates: "abc"])
      assert Inference.prefix_cache_scoring_max_ranking_candidates() == 2

      put_inference(prefix_cache_scoring: [max_ranking_candidates: 1])
      assert Inference.prefix_cache_scoring_max_ranking_candidates() == 1

      put_inference(prefix_cache_scoring: [max_ranking_candidates: 3])
      assert Inference.prefix_cache_scoring_max_ranking_candidates() == 2
    end
  end

  describe "bundle-build safe-tokenization preflight env config" do
    test "runtime.exs parses eager preflight flags" do
      controller_config =
        read_runtime_controller_config!(%{
          "ORCHARD_BUNDLE_BUILD_EAGER_PREFLIGHT_ENABLED" => "false",
          "ORCHARD_BUNDLE_BUILD_PREFLIGHT_TIMEOUT_MS" => "12345"
        })

      assert controller_config[:bundle_build_eager_preflight_enabled] == false
      assert controller_config[:bundle_build_preflight_timeout_ms] == 12_345
    end

    test "runtime.exs parses trust manifest compatibility declarations false" do
      controller_config =
        read_runtime_controller_config!(%{
          "ORCHARD_TRUST_MANIFEST_COMPATIBILITY_DECLARATIONS" => "false"
        })

      assert controller_config[:trust_manifest_compatibility_declarations] == false
    end

    test "runtime.exs fails loudly for invalid trust manifest compatibility env value" do
      assert_raise RuntimeError,
                   ~r/ORCHARD_TRUST_MANIFEST_COMPATIBILITY_DECLARATIONS must be a boolean/,
                   fn ->
                     read_runtime_controller_config!(%{
                       "ORCHARD_TRUST_MANIFEST_COMPATIBILITY_DECLARATIONS" => "maybe"
                     })
                   end
    end

    test "runtime.exs fails loudly for invalid eager preflight env values" do
      assert_raise RuntimeError,
                   ~r/ORCHARD_BUNDLE_BUILD_EAGER_PREFLIGHT_ENABLED must be a boolean/,
                   fn ->
                     read_runtime_controller_config!(%{
                       "ORCHARD_BUNDLE_BUILD_EAGER_PREFLIGHT_ENABLED" => "maybe"
                     })
                   end

      assert_raise RuntimeError,
                   ~r/ORCHARD_BUNDLE_BUILD_PREFLIGHT_TIMEOUT_MS must be > 0/,
                   fn ->
                     read_runtime_controller_config!(%{
                       "ORCHARD_BUNDLE_BUILD_PREFLIGHT_TIMEOUT_MS" => "0"
                     })
                   end
    end
  end

  describe "prefix cache scoring env config" do
    test "runtime.exs parses ranking env and accepts above-cap max candidates" do
      inference =
        read_runtime_controller_inference!(%{
          "ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE" => "tie_only",
          "ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES" => "3"
        })

      scoring = Keyword.fetch!(inference, :prefix_cache_scoring)

      assert scoring[:ranking_mode] == :tie_only
      assert scoring[:max_ranking_candidates] == 3

      Application.put_env(:orchard_controller, :inference, inference)
      assert Inference.prefix_cache_scoring_max_ranking_candidates() == 2

      one_candidate =
        read_runtime_controller_inference!(%{
          "ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE" => "observe_only",
          "ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES" => "1"
        })
        |> Keyword.fetch!(:prefix_cache_scoring)

      assert one_candidate[:ranking_mode] == :observe_only
      assert one_candidate[:max_ranking_candidates] == 1
    end

    test "dev.exs parses ranking env and accepts above-cap max candidates" do
      inference =
        read_dev_controller_inference!(%{
          "ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE" => "tie_only",
          "ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES" => "3"
        })

      scoring = Keyword.fetch!(inference, :prefix_cache_scoring)

      assert scoring[:ranking_mode] == :tie_only
      assert scoring[:max_ranking_candidates] == 3

      Application.put_env(:orchard_controller, :inference, inference)
      assert Inference.prefix_cache_scoring_max_ranking_candidates() == 2

      one_candidate =
        read_dev_controller_inference!(%{
          "ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE" => "observe_only",
          "ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES" => "1"
        })
        |> Keyword.fetch!(:prefix_cache_scoring)

      assert one_candidate[:ranking_mode] == :observe_only
      assert one_candidate[:max_ranking_candidates] == 1
    end

    test "runtime.exs fails loudly for invalid ranking env values" do
      assert_raise RuntimeError,
                   ~r/ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE must be observe_only\|tie_only/,
                   fn ->
                     read_runtime_controller_inference!(%{
                       "ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE" => "bogus"
                     })
                   end
    end

    test "dev.exs fails loudly for invalid ranking env values" do
      assert_raise RuntimeError,
                   ~r/ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE must be observe_only\|tie_only/,
                   fn ->
                     read_dev_controller_inference!(%{
                       "ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE" => "bogus"
                     })
                   end
    end

    test "runtime.exs fails loudly for non-positive and non-integer max candidates" do
      for invalid <- ["0", "-1", "abc"] do
        assert_raise RuntimeError,
                     ~r/ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES|environment variable ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES/,
                     fn ->
                       read_runtime_controller_inference!(%{
                         "ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES" => invalid
                       })
                     end
      end
    end

    test "dev.exs fails loudly for non-positive and non-integer max candidates" do
      for invalid <- ["0", "-1", "abc"] do
        assert_raise RuntimeError,
                     ~r/ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES|environment variable ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES/,
                     fn ->
                       read_dev_controller_inference!(%{
                         "ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES" => invalid
                       })
                     end
      end
    end
  end

  describe "scheduler auto-selection" do
    test "defaults to SingleNode when plural targets are absent" do
      put_inference(runtime_client_targets: [])
      assert Inference.scheduler() == SingleNode
    end

    test "auto-selects MultiNode when plural targets are configured" do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.2", port: 50_062]
        ],
        scheduler_impl: nil
      )

      assert Inference.scheduler() == MultiNode
    end

    test "deduplicated plural targets that collapse to one still use SingleNode" do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.1", port: 50_061]
        ],
        scheduler_impl: nil
      )

      assert Inference.scheduler() == SingleNode
    end

    test "explicit scheduler override wins over auto-selection" do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.1", port: 50_061],
          [host: "10.0.0.2", port: 50_062]
        ],
        scheduler_impl: FakeScheduler
      )

      assert Inference.scheduler() == FakeScheduler
    end
  end

  describe "SingleNode backward compatibility" do
    test "SingleNode.schedule/1 always uses singular target even when plural differs" do
      put_inference(
        runtime_client_targets: [
          [host: "10.0.0.99", port: 50_099],
          [host: "10.0.0.100", port: 50_100]
        ],
        runtime_client_target: [host: "127.0.0.1", port: 50_071],
        scheduler_impl: nil
      )

      request = canonical_request()
      assert Inference.scheduler() == MultiNode
      assert {:ok, schedule} = SingleNode.schedule(request)
      assert schedule.strategy == :single_node
      assert schedule.runtime_client_target == [host: "127.0.0.1", port: 50_071]
    end
  end

  describe "scheduler repo-off fallback" do
    test "SingleNode.schedule/1 returns node_id: nil when Repo is unavailable" do
      request = canonical_request()

      with_repo_unregistered(fn ->
        assert {:ok, schedule} = SingleNode.schedule(request)
        assert schedule.strategy == :single_node
        assert schedule.runtime_client_target == [host: "127.0.0.1", port: 50_071]
        assert schedule.request_timeout_ms == 5_000
        assert schedule.model_load_timeout_ms == 5_000
        assert schedule.node_id == nil
      end)
    end
  end

  defp put_inference(overrides) do
    config = Application.fetch_env!(:orchard_controller, :inference)
    Application.put_env(:orchard_controller, :inference, Keyword.merge(config, overrides))
  end

  defp read_runtime_controller_inference!(overrides) do
    read_runtime_controller_config!(overrides)
    |> Keyword.fetch!(:inference)
  end

  defp read_runtime_controller_config!(overrides) do
    support_root = Path.join(System.tmp_dir!(), "orchard-runtime-config-test")

    base = %{
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/orchard_config_eval",
      "MIX_RELEASE_NAME" => nil,
      "ORCHARD_SUPPORT_ROOT" => support_root,
      "ORCHARD_TRANSPORT_MODE" => "reverse_proxy",
      "RELEASE_NAME" => "orchard_controller",
      "SECRET_KEY_BASE" => String.duplicate("runtime-secret", 8)
    }

    read_config!(runtime_config_path(), :prod, Map.merge(base, overrides))
    |> Keyword.fetch!(:orchard_controller)
  end

  defp read_dev_controller_inference!(overrides) do
    read_config!(dev_config_path(), :dev, overrides)
    |> Keyword.fetch!(:orchard_controller)
    |> Keyword.fetch!(:inference)
  end

  defp read_config!(path, env, env_overrides) do
    clear_config_env!()

    Enum.each(env_overrides, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    Config.Reader.read!(path, env: env)
  end

  defp runtime_config_path do
    Path.expand("../../../../config/runtime.exs", __DIR__)
  end

  defp dev_config_path do
    Path.expand("../../../../config/dev.exs", __DIR__)
  end

  defp restore_env(snapshot) do
    clear_config_env!()
    Enum.each(snapshot, fn {key, value} -> System.put_env(key, value) end)
  end

  defp clear_config_env! do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&config_env_key?/1)
    |> Enum.each(&System.delete_env/1)
  end

  defp config_env_key?(key) do
    key in @config_env_vars or String.starts_with?(key, "ORCHARD_")
  end

  defp canonical_request do
    CanonicalRequest.new(%{
      internal_id: "req_internal_test",
      public_id: "req_inference_test",
      endpoint: :chat_completions,
      tenant_id: "tenant_test",
      model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"}
    })
  end
end
