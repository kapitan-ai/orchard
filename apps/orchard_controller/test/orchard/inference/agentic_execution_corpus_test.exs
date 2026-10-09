defmodule Orchard.Inference.AgenticExecutionCorpusTest do
  use Orchard.ConnCase, async: false

  @moduletag :db
  @moduletag :live

  import Orchard.TestSupport.ModelRequestFixtures
  import Orchard.TestSupport.ToolRegistryTestSupport
  import Orchard.TestSupport.QueueAdmissionAPI, only: [wait_until: 1]

  alias Orchard.{ArtifactBundle, Governance, Node, Repo, Requests}

  alias Orchard.API.Endpoint
  alias Orchard.DispatchCapacity.AllocationAuthority
  alias Orchard.DispatchCapacity.ConformanceFixture
  alias Orchard.Node.ModelManager
  alias Orchard.Node.Status, as: NodeStatus

  alias Orchard.TestSupport.{
    AgenticExecutionClient,
    AgenticExecutionCorpus,
    AgenticExecutionEndpoint
  }

  @corpus AgenticExecutionCorpus.load!()

  # Profile gates that current source does not meet. Each stays a recorded
  # failure; a gate that starts to pass fails the test until it is promoted.
  @known_gaps %{
    "quarantine_before_native_drain" => "#417",
    "no_allocation_reuse_before_native_drain" => "#417",
    "quarantine_requires_verified_reconciliation" => "#417"
  }

  setup do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    inference = Application.fetch_env!(:orchard_controller, :inference)
    # Breaker persistence needs inventory; a provisioned placeholder is not admitted
    # and therefore leaves the real scheduler on its unmanaged compatibility path.
    Repo.insert!(%Orchard.Nodes.Node{
      id: Keyword.fetch!(runtime, :node_id),
      display_name: "corpus-breaker-target",
      state: :provisioned,
      health: :healthy
    })

    path = Path.join([Node.models_root(), "agentic-corpus", "v1"])
    script_root = Path.join(System.tmp_dir!(), "agentic-#{System.unique_integer([:positive])}")
    previous_script = System.get_env("ORCHARD_AGENTIC_SCRIPT")

    on_exit(fn ->
      ModelManager.reset()
      Application.put_env(:orchard_node_agent, :runtime, runtime)
      Application.put_env(:orchard_controller, :inference, inference)
      Application.delete_env(:orchard_controller, :agentic_execution_fixture)
      File.rm_rf!(path)
      File.rm_rf!(script_root)

      if previous_script,
        do: System.put_env("ORCHARD_AGENTIC_SCRIPT", previous_script),
        else: System.delete_env("ORCHARD_AGENTIC_SCRIPT")
    end)

    File.mkdir_p!(script_root)
    System.put_env("ORCHARD_AGENTIC_SCRIPT", Path.join(script_root, "script.json"))
    ModelManager.reset()
    File.mkdir_p!(path)
    :ok = ArtifactBundle.copy_directory(fixture_bundle_path(), path)
    tokenizer = Path.expand("../../fixtures/tokenizer/safe_hf/tokenizer.json", __DIR__)
    File.cp!(tokenizer, Path.join(path, "tokenizer.json"))

    File.write!(
      Path.join(path, "chat_template.jinja"),
      "{{ messages | tojson }}\n{{ tools | tojson }}"
    )

    {:ok, hash} = ArtifactBundle.tree_sha256(path)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(inference,
        tokenizer_mode: :port,
        tokenizer_safe_mode: :reject,
        cache_affinity: [
          enabled: true,
          live_fingerprint_match_enabled: true,
          hmac_secret: "agentic-corpus-fixed-key",
          max_prefix_bytes: 8192
        ],
        runtime_endpoint_client_impl: AgenticExecutionEndpoint
      )
    )

    model =
      create_model!(%{
        model_id: "agentic-corpus",
        version: "v1",
        state: :active,
        artifact_uri: "file://#{path}",
        artifact_source_uri: "file://#{path}",
        artifact_sha256: hash,
        capabilities: ["chat", "tool_calling"]
      })

    {:ok, tenant} = Governance.create_tenant(%{slug: "agentic-corpus", name: "Corpus"})
    {:ok, %{token: token}} = Governance.create_api_key(tenant.id, %{name: "Corpus"})
    grant_model_access!(tenant, model)

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(runtime,
        runtime_adapter_impl: Orchard.Node.WorkerRuntimeAdapter,
        fake_runtime?: false,
        worker_executable: Path.expand("../../support/agentic-worker", __DIR__)
      )
    )

    %{token: token}
  end

  for scenario <- @corpus["cases"], mode <- Map.get(scenario, "modes", @corpus["modes"]) do
    @scenario scenario
    @mode mode
    test "SPEC 7.2.9 corpus #{@scenario["id"]}/#{@mode}", %{token: token} do
      if @scenario["dependency_blocked"] do
        report(@scenario, @mode, [%{assertion: "public_input", status: "dependency_blocked"}])
      else
        first = reported_replay(@scenario, @mode, token)
        second = reported_replay(@scenario, @mode, token)

        assertions =
          first.assertions ++
            AgenticExecutionCorpus.check([{"deterministic_replay", first, second}])

        report(@scenario, @mode, assertions)
        assert Enum.all?(assertions, &(&1.status == "pass")), inspect(assertions)
      end
    end
  end

  test "SPEC 7.2.9 evidence identity detects untracked file corruption and restoration" do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    path = Path.join(String.trim(root), ".agentic-hash-control-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm(path) end)
    clean = input_hash()
    File.write!(path, "baseline")
    added = input_hash()
    refute added == clean
    File.write!(path, "corrupted")
    refute input_hash() == added
    File.rm!(path)
    assert input_hash() == clean
  end

  test "SPEC 7.2.9 independent oracle rejects corrupted text, usage, terminals and JSON" do
    expected = Enum.find(@corpus["cases"], &(&1["id"] == "json-object"))["expected"]

    good = %{
      text: "{\"west\":3,\"east\":[7,false]}",
      calls: [],
      usage: [11, 13, 24],
      finish_reasons: ["stop"],
      public_terminals: 1,
      terminal_last: true
    }

    assert Enum.all?(AgenticExecutionCorpus.compare(good, expected), &(&1.status == "pass"))

    for mutation <- [
          %{text: "{"},
          %{text: "{\"west\":7,\"east\":[3,false]}"},
          %{usage: [13, 11, 24]},
          %{finish_reasons: ["length"]},
          %{public_terminals: 2},
          %{terminal_last: false}
        ] do
      assert Enum.any?(
               AgenticExecutionCorpus.compare(Map.merge(good, mutation), expected),
               &(&1.status == "fail")
             )
    end
  end

  test "SPEC 7.2.9 malformed structured output fails through the public path", %{token: token} do
    scenario = Enum.find(@corpus["cases"], &(&1["id"] == "json-object"))

    for mode <- ["chat_sync", "chat_stream"] do
      corrupted = %{scenario | "events" => [%{"text" => "{"}, List.last(scenario["events"])]}
      result = replay(corrupted, mode, token)
      assert %{assertion: "structured_object", status: "fail"} in result.assertions
      good = replay(scenario, mode, token)
      assert Enum.all?(good.assertions, &(&1.status == "pass"))
    end
  end

  test "SPEC 7.2.9 terminal and content type mutations cannot preserve a passing projection" do
    expected = Enum.find(@corpus["cases"], &(&1["id"] == "typed-text"))["expected"]

    response = %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "content" => [
            %{"type" => "output_text", "text" => "north south-east"}
          ]
        }
      ],
      "usage" => %{"input_tokens" => 11, "output_tokens" => 7, "total_tokens" => 18}
    }

    for {kind, body} <- [
          {"response.completed", response},
          {"response.failed", response},
          {"response.completed", %{response | "status" => "failed"}},
          {"response.completed", %{response | "output" => []}},
          {"response.completed", put_in(response, ["output", Access.at(0), "type"], "reasoning")},
          {"response.completed",
           put_in(response, ["output", Access.at(0), "content", Access.at(0), "text"], "wrong")},
          {"response.completed",
           put_in(
             response,
             ["output", Access.at(0), "content", Access.at(0), "type"],
             "reasoning_text"
           )}
        ] do
      wire =
        "data: " <>
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "north south-east"}) <>
          "\n\n" <>
          "data: " <> Jason.encode!(%{"type" => kind, "response" => body}) <> "\n\n"

      checks =
        AgenticExecutionCorpus.compare(
          AgenticExecutionCorpus.observe(wire, "responses_stream"),
          expected
        )

      assert Enum.all?(checks, &(&1.status == "pass")) ==
               (kind == "response.completed" and body == response)
    end

    failed = %{
      "type" => "response.failed",
      "response" => %{"status" => "failed", "error" => %{"code" => "internal_error"}}
    }

    wire = "data: " <> Jason.encode!(failed) <> "\n\n"
    conn = %{build_conn() | status: 200, resp_body: wire}
    assert public_error(conn, "responses_stream")["code"] == "internal_error"

    extra =
      "data: " <>
        Jason.encode!(%{"type" => "response.completed", "response" => response}) <> "\n\n"

    assert_raise ExUnit.AssertionError, fn ->
      public_error(%{conn | resp_body: extra <> wire}, "responses_stream")
    end
  end

  test "SPEC 7.2.9 continuation detects missing and changed client results", %{token: token} do
    scenario = Enum.find(@corpus["cases"], &(&1["id"] == "multiple-calls"))
    calls = scenario["expected"]["calls"]

    for mode <- @corpus["modes"] do
      for effects <- [[["call_z", 15]], [["call_z", 16], ["call_a", 35]]] do
        result = continue(scenario, calls, effects, mode, token)
        assert %{assertion: "dispatched_history", status: "fail"} in result.assertions
      end

      good = continue(scenario, calls, [["call_z", 15], ["call_a", 35]], mode, token)
      assert Enum.all?(good.assertions, &(&1.status == "pass"))
    end
  end

  test "SPEC 7.2.9 cache identity covers only the configured rendered prefix", %{token: token} do
    scenario = Enum.find(@corpus["cases"], &(&1["id"] == "typed-text"))
    base = replay(scenario, "responses_sync", token)
    hinted = put_in(scenario, ["request", "prompt_cache_key"], "caller-controlled")
    assert replay(hinted, "responses_sync", token).affinity_key == base.affinity_key
    assert base.affinity_key == affinity(base.rendered_prompt, 8192)

    for input <- [
          %{"instructions" => "west"},
          %{"input" => "different"},
          %{"tools" => [function_definition("scale")]},
          %{
            "input" => [
              %{
                "type" => "function_call",
                "call_id" => "call_z",
                "name" => "scale",
                "arguments" => "{\"n\":3}"
              }
            ]
          },
          %{
            "input" => [
              %{
                "type" => "function_call",
                "call_id" => "call_z",
                "name" => "scale",
                "arguments" => "{\"n\":3}"
              },
              %{"type" => "function_call_output", "call_id" => "call_z", "output" => "15"}
            ]
          }
        ] do
      changed = replay(%{scenario | "request" => input}, "responses_sync", token)
      refute changed.affinity_key == base.affinity_key
      assert changed.affinity_key == affinity(changed.rendered_prompt, 8192)
      assert affinity(changed.rendered_prompt, 1) == affinity(base.rendered_prompt, 1)
    end

    calls = [%{"id" => "call_z", "function" => %{"name" => "scale", "arguments" => "{\"n\":3}"}}]

    for bound <- [8192, 1] do
      config = Application.fetch_env!(:orchard_controller, :inference)

      Application.put_env(
        :orchard_controller,
        :inference,
        put_in(config, [:cache_affinity, :max_prefix_bytes], bound)
      )

      [first, second] =
        for value <- [15, 16] do
          request =
            AgenticExecutionClient.continuation(calls, [["call_z", value]], "responses_sync")

          replay(%{scenario | "request" => request}, "responses_sync", token)
        end

      assert first.affinity_key == second.affinity_key == (bound == 1)
      assert first.affinity_key == affinity(first.rendered_prompt, bound)
      assert second.affinity_key == affinity(second.rendered_prompt, bound)
    end
  end

  for mode <- ["chat_stream", "responses_stream"], drain <- [:released, :timeout] do
    @mode mode
    @drain drain
    test "SPEC 7.2.9 public disconnect native drain #{@mode}/#{@drain}", %{token: token} do
      assert_native_drain(@mode, @drain, token)
    end
  end

  defp assert_native_drain(mode, drain, token) do
    config = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(config,
        scheduler_impl: Orchard.TestSupport.AgenticExecutionCapacityScheduler,
        request_timeout_ms: 2_000
      )
    )

    node_id = Application.fetch_env!(:orchard_node_agent, :runtime)[:node_id]

    store = start_supervised!({Orchard.DispatchCapacity.QuarantineStore, name: nil})
    authority = start_supervised!({AllocationAuthority, name: nil, quarantine_store: store})
    script = System.fetch_env!("ORCHARD_AGENTIC_SCRIPT")
    root = Path.rootname(script)
    Enum.each([".cancelled", ".release", ".drained"], &File.rm(root <> &1))

    File.write!(
      script,
      Jason.encode!(%{
        events: [
          %{text: "disconnect-marker"},
          %{wait_for_cancel: true}
        ]
      })
    )

    Application.put_env(:orchard_controller, :agentic_execution_fixture, %{
      owner: self(),
      authority: authority
    })

    chat? = String.starts_with?(mode, "chat")
    params = public_request(%{"request" => %{}}, chat?, true)
    path = if chat?, do: "/v1/chat/completions", else: "/v1/responses"

    task =
      Task.async(fn ->
        conn = Plug.Test.conn(:post, path, params)
        {_, state} = conn.adapter

        %{conn | adapter: {Orchard.TestSupport.AgenticExecutionDisconnect, state}}
        |> put_req_header("authorization", "Bearer #{token}")
        |> Endpoint.call(Endpoint.init([]))
      end)

    assert_receive {:agentic_execution_started, dispatched}, 2_000
    assert wait_until(fn -> File.exists?(root <> ".cancelled") end)
    refute File.exists?(root <> ".drained")
    assert NodeStatus.current().active_request_count == 1
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    assert Task.yield(task, 0) == nil

    single_slot = %{
      ConformanceFixture.input()
      | controller_dispatch_ceiling: {:valid, 1},
        aggregate_active_count: {:valid, 0},
        controller_accounted_allocation: 0
    }

    assert {:error, :dispatch_capacity_unavailable, _} =
             AllocationAuthority.acquire(authority, node_id, "while-held", single_slot)

    if drain == :released, do: File.write!(root <> ".release", "release")
    conn = Task.await(task, 8_000)

    timeout_checks =
      if drain == :timeout do
        refute File.exists?(root <> ".drained")
        quarantined? = node_id in AllocationAuthority.quarantined_nodes(authority)
        node_occupancy = NodeStatus.current().active_request_count

        denied? =
          case AllocationAuthority.acquire(
                 authority,
                 node_id,
                 "after-timeout",
                 single_slot
               ) do
            {:error, :dispatch_capacity_unavailable, denied} ->
              :node_health_unhealthy in denied.reason_codes

            {:ok, claim, _evaluation} ->
              AllocationAuthority.release(authority, claim)
              false
          end

        File.write!(root <> ".release", "release")
        assert wait_until(fn -> File.exists?(root <> ".drained") end)

        AgenticExecutionCorpus.check([
          {"quarantine_before_native_drain", quarantined?, true},
          {"no_allocation_reuse_before_native_drain", denied?, true},
          {"node_occupancy_before_native_drain", node_occupancy, 1},
          {"quarantine_requires_verified_reconciliation",
           node_id in AllocationAuthority.quarantined_nodes(authority), true}
        ])
      else
        []
      end

    assert File.exists?(root <> ".drained")
    assert wait_until(fn -> NodeStatus.current().active_request_count == 0 end)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
    request = Requests.get_request_by_public_id(dispatched.request_id)
    assert request.state == :cancelled
    assert Enum.count(Requests.list_request_events(request), &(&1.state == :cancelled)) == 1
    refute_receive {:agentic_execution_started, _}, 0
    assert_receive {:agentic_runtime_trace, events}

    if drain == :released do
      assert Enum.count(events, &Orchard.InferenceEvent.terminal?/1) == 1

      assert {:ok, claim, _} =
               AllocationAuthority.acquire(authority, node_id, "after-drain", single_slot)

      assert :released = AllocationAuthority.release(authority, claim)
    end

    refute conn.resp_body =~ "[DONE]"
    refute conn.resp_body =~ "response.completed"

    checks =
      AgenticExecutionCorpus.check([
        {"native_cancel_observed", true, true},
        {"node_capacity_held_when_cancel_received", true, true},
        {"managed_allocation_held_when_cancel_received", true, true},
        {"no_retry_after_disconnect", true, true},
        {"no_public_terminal_after_disconnect", true, true}
      ]) ++ timeout_checks

    checks = Enum.map(checks, &mark_known_gap/1)

    report(
      %{
        "id" => "disconnect-native-drain-#{drain}",
        "output_contract" => "cancellation",
        "boundary" => "public-api-native-worker-scripted-capacity-policy"
      },
      mode,
      checks
    )

    {gaps, required} = Enum.split_with(checks, &Map.has_key?(&1, :known_gap))
    assert Enum.all?(required, &(&1.status == "pass")), inspect(checks)
    assert Enum.all?(gaps, &(&1.status == "fail")), "known gap now passes: #{inspect(gaps)}"
  end

  defp mark_known_gap(%{assertion: assertion} = check) do
    case Map.fetch(@known_gaps, assertion) do
      {:ok, issue} -> Map.put(check, :known_gap, issue)
      :error -> check
    end
  end

  test "SPEC 4.6.2 and 7.2.9 affinity cannot bypass capacity or quarantine" do
    alias Orchard.DispatchCapacity.{AllocationAuthority, ConformanceFixture, QuarantineStore}
    alias Orchard.Scheduler.MultiNode

    cold = %{
      node_id: "a",
      loaded_model?: true,
      active_request_count: 0,
      node: %{health: :healthy},
      cache_affinity_match?: false,
      prefix_cache_fingerprint_match?: false
    }

    warm = %{cold | node_id: "z", cache_affinity_match?: true}

    for {id, candidates, opts, expected} <- [
          {"historical-tie", [cold, warm], [], ["z", "a"]},
          {"live-before-historical", [%{cold | prefix_cache_fingerprint_match?: true}, warm],
           [live_fingerprint_match?: true], ["a", "z"]},
          {"health-before-affinity", [cold, %{warm | node: %{health: :degraded}}], [],
           ["a", "z"]},
          {"load-before-affinity", [cold, %{warm | loaded_model?: false}], [], ["a", "z"]},
          {"occupancy-before-affinity", [cold, %{warm | active_request_count: 1}], [],
           ["a", "z"]},
          {"disabled-live-fail-open", [%{cold | prefix_cache_fingerprint_match?: true}, warm], [],
           ["z", "a"]}
        ] do
      checks =
        AgenticExecutionCorpus.check([
          {"candidate_order", Enum.map(MultiNode.rank_candidates(candidates, opts), & &1.node_id),
           expected},
          {"input_order_independent",
           Enum.map(MultiNode.rank_candidates(Enum.reverse(candidates), opts), & &1.node_id),
           expected}
        ])

      report(
        %{"id" => id, "output_contract" => "ranking", "boundary" => "controller-policy"},
        "not_applicable",
        checks
      )

      assert Enum.all?(checks, &(&1.status == "pass"))
    end

    store = start_supervised!({QuarantineStore, name: nil})
    authority = start_supervised!({AllocationAuthority, name: nil, quarantine_store: store})
    node_id = "00000000-0000-4000-a000-000000000019"

    input = %{
      ConformanceFixture.input()
      | controller_dispatch_ceiling: {:valid, 1},
        aggregate_active_count: {:valid, 0},
        controller_accounted_allocation: 0
    }

    assert {:ok, claim, _} = AllocationAuthority.acquire(authority, node_id, "first", input)

    assert {:error, :dispatch_capacity_unavailable, _} =
             AllocationAuthority.acquire(authority, node_id, "second", input)

    assert :ok = AllocationAuthority.quarantine_node(authority, node_id)
    assert :released = AllocationAuthority.release(authority, claim)
    assert AllocationAuthority.claim_count(authority, node_id) == 0

    assert {:error, :dispatch_capacity_unavailable, denied} =
             AllocationAuthority.acquire(authority, node_id, "after-release", input)

    assert :node_health_unhealthy in denied.reason_codes
    stop_supervised!(AllocationAuthority)
    restarted = start_supervised!({AllocationAuthority, name: nil, quarantine_store: store})

    assert {:error, :dispatch_capacity_unavailable, _} =
             AllocationAuthority.acquire(restarted, node_id, "after-restart", input)

    report(
      %{
        "id" => "quarantine-outlives-allocation",
        "output_contract" => "quarantine",
        "boundary" => "controller-policy"
      },
      "not_applicable",
      [%{assertion: "capacity_no_reuse_after_release_or_authority_restart", status: "pass"}]
    )
  end

  test "SPEC 5.8 retry requires every safety gate and never allows attempt three" do
    alias Orchard.Inference.AttemptRetryClassifier, as: Retry

    base =
      Retry.new(%{
        attempt: 1,
        attempt_outcome: :failed,
        output_committed: false,
        caller_status: :live,
        deadline_status: :remaining,
        failure_class: "runtime_failure",
        failure_code: "worker_down",
        model_load_category: nil,
        runtime_retryable: true,
        identity_resolution: :resolved,
        execution_resolution: :terminated,
        capacity_release_outcome: :released
      })

    assert Retry.pre_schedule(base) == :eligible_for_alternate
    assert Retry.finalize_alternate(base, :different_node) == :retried
    assert Retry.finalize_alternate(base, :no_candidate) == :no_alternative_node

    for {field, value, decision} <- [
          {:attempt, 2, :retry_exhausted},
          {:output_committed, true, :output_committed},
          {:caller_status, :cancelled, :cancelled},
          {:deadline_status, :exhausted, :budget_exhausted},
          {:failure_code, "unknown", :not_retryable},
          {:runtime_retryable, false, :not_retryable},
          {:identity_resolution, :unresolved, :identity_unresolved},
          {:execution_resolution, :unresolved, :occupancy_unresolved},
          {:capacity_release_outcome, :unresolved, :occupancy_unresolved}
        ] do
      checks =
        AgenticExecutionCorpus.check([
          {"declined", Retry.pre_schedule(Map.replace!(base, field, value)),
           {:declined, decision}}
        ])

      report(
        %{
          "id" => "retry-gate-#{field}",
          "output_contract" => "retry-policy",
          "boundary" => "controller-policy"
        },
        "not_applicable",
        checks
      )

      assert Enum.all?(checks, &(&1.status == "pass"))
    end
  end

  defp affinity(prompt, bound) do
    prefix = binary_part(prompt, 0, min(byte_size(prompt), bound))

    digest =
      :crypto.mac(:hmac, :sha256, "agentic-corpus-fixed-key", [
        "orchard:v1:cache-affinity:prompt-prefix",
        <<0>>,
        prefix
      ])

    "hmac-sha256:" <> Base.encode16(digest, case: :lower)
  end

  for mode <- @corpus["modes"], exhausted? <- [false, true] do
    @mode mode
    @exhausted exhausted?
    test "SPEC 5.8 managed retry identity #{@mode}/exhausted=#{@exhausted}", %{token: token} do
      alias Orchard.InferenceEvent
      alias Orchard.TestSupport.{AgenticExecutionManagedEndpoint, RetryAPI}

      events =
        if @exhausted do
          RetryAPI.exhausted_retry_events()
        else
          [
            [InferenceEvent.failed("worker_down", "first attempt", true)],
            [
              InferenceEvent.output_text_delta("north south-east"),
              InferenceEvent.completed(
                :finish_reason_stop,
                %InferenceEvent.Usage{input_tokens: 11, output_tokens: 7, total_tokens: 18}
              )
            ]
          ]
        end

      nodes = RetryAPI.configure_retry_nodes!(events)
      inference = Application.fetch_env!(:orchard_controller, :inference)

      Application.put_env(
        :orchard_controller,
        :inference,
        Keyword.put(inference, :runtime_endpoint_client_impl, AgenticExecutionManagedEndpoint)
      )

      chat? = String.starts_with?(@mode, "chat")
      stream? = String.ends_with?(@mode, "stream")
      path = if chat?, do: "/v1/chat/completions", else: "/v1/responses"
      params = public_request(%{"request" => %{}}, chat?, stream?)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(path, params)

      assert_receive {:agentic_managed_identity, first}
      assert_receive {:agentic_managed_identity, second}
      refute_receive {:agentic_managed_identity, _}, 0
      request = Requests.get_request_by_public_id(first.request_id)

      if @exhausted,
        do: RetryAPI.assert_failed_retry!(request, nodes),
        else: RetryAPI.assert_successful_retry!(request, nodes)

      identity_fields = [
        :request_id,
        :model_ref,
        :rendered_prompt_utf8,
        :input_tokens,
        :params,
        :deadline_unix_ms,
        :cache_affinity_fingerprint,
        :prompt_token_ids,
        :artifact_sha256,
        :artifact_source_uri
      ]

      checks =
        AgenticExecutionCorpus.check([
          {"pinned_execution_identity", Map.take(second, identity_fields),
           Map.take(first, identity_fields)},
          {"concrete_model_identity", {first.model_ref.model_id, first.model_ref.version},
           {"agentic-corpus", "v1"}},
          {"one_logical_terminal",
           Enum.count(
             Requests.list_request_events(request),
             &(&1.state in [:completed, :failed, :cancelled, :timed_out, :interrupted])
           ), 1},
          {"first_allocation_released", AllocationAuthority.claim_count(nodes.first.id), 0},
          {"second_allocation_released", AllocationAuthority.claim_count(nodes.second.id), 0}
        ])

      checks =
        if @exhausted do
          error = public_error(conn, @mode)

          checks ++
            AgenticExecutionCorpus.check([
              {"exhausted_public_error", error["code"],
               if(stream?, do: "runtime_unavailable", else: "internal_error")}
            ])
        else
          expected = Enum.find(@corpus["cases"], &(&1["id"] == "typed-text"))["expected"]

          checks ++
            AgenticExecutionCorpus.compare(
              AgenticExecutionCorpus.observe(conn.resp_body, @mode),
              expected
            )
        end

      report(
        %{
          "id" => "managed-retry-exhausted-#{@exhausted}",
          "output_contract" => "retry",
          "boundary" => "public-api-through-scripted-managed-runtime"
        },
        @mode,
        checks
      )

      assert Enum.all?(checks, &(&1.status == "pass")), inspect(checks)
    end
  end

  defp reported_replay(scenario, mode, token) do
    replay(scenario, mode, token)
  rescue
    error in [ExUnit.AssertionError, MatchError, KeyError, ArgumentError] ->
      report(scenario, mode, [%{assertion: "execution_contract", status: "fail"}])
      reraise error, __STACKTRACE__
  end

  defp replay(scenario, mode, token) do
    script = System.fetch_env!("ORCHARD_AGENTIC_SCRIPT")
    File.rm(Path.rootname(script) <> ".request")
    File.rm(Path.rootname(script) <> ".drained")
    File.write!(script, Jason.encode!(%{events: scenario["events"]}))

    Application.put_env(:orchard_controller, :agentic_execution_fixture, %{
      owner: self(),
      events: scenario["events"],
      fault: scenario["fault"]
    })

    stream? = String.ends_with?(mode, "stream")
    chat? = String.starts_with?(mode, "chat")
    path = if chat?, do: "/v1/chat/completions", else: "/v1/responses"
    params = public_request(scenario, chat?, stream?)
    before_ids = MapSet.new(Repo.all(Requests.Request), & &1.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("accept", if(stream?, do: "text/event-stream", else: "application/json"))
      |> post(path, params)

    expected =
      Map.merge(scenario["expected"], @corpus["stream_expectations"][scenario["id"]] || %{})

    case scenario["output_contract"] do
      "failure" ->
        failure_result(conn, expected, mode, before_ids)

      "runtime_failure" ->
        runtime_failure_result(conn, scenario, expected, mode, before_ids)

      "rejection" ->
        assert conn.status == expected["status"]
        error = Jason.decode!(conn.resp_body)["error"]
        assert error["code"] == expected["code"]
        assert error["param"] == expected["param"]
        refute_receive {:agentic_execution_started, _}, 0
        refute_receive {:agentic_runtime_trace, _}, 0
        assert MapSet.new(Repo.all(Requests.Request), & &1.id) == before_ids

        %{
          observation: Map.take(error, ["code", "param"]),
          assertions: [
            %{assertion: "pre_dispatch_rejection_no_runtime_or_logical_terminal", status: "pass"}
          ]
        }

      _success ->
        assert conn.status == 200, conn.resp_body
        assert_receive {:agentic_execution_started, runtime_request}
        assert_receive {:agentic_runtime_trace, events}

        native =
          script |> Path.rootname() |> Kernel.<>(".request") |> File.read!() |> Jason.decode!()

        assert native["rendered_prompt_utf8"] == runtime_request.rendered_prompt_utf8
        assert native["cache_affinity_fingerprint"] == runtime_request.cache_affinity_fingerprint
        assert native["prompt_token_ids"] == runtime_request.prompt_token_ids

        assert Enum.count(events, &Orchard.InferenceEvent.terminal?/1) ==
                 expected["runtime_terminals"]

        assert Orchard.InferenceEvent.terminal?(List.last(events))
        usage = List.last(events).event.usage
        assert [usage.input_tokens, usage.output_tokens, usage.total_tokens] == expected["usage"]
        refute_receive {:agentic_execution_started, _}, 0
        [request] = Enum.reject(Repo.all(Requests.Request), &MapSet.member?(before_ids, &1.id))
        assert Atom.to_string(request.state) == expected["state"]
        terminal_states = [:completed, :failed, :cancelled, :timed_out, :interrupted]

        assert Enum.count(Requests.list_request_events(request), &(&1.state in terminal_states)) ==
                 1

        observed = AgenticExecutionCorpus.observe(conn.resp_body, mode)

        {decisions, effects} =
          AgenticExecutionClient.execute(observed.calls, params["tools"] || [])

        assert decisions == expected["client_decisions"]
        assert effects == expected["side_effects"]
        continuation = continue(scenario, observed.calls, effects, mode, token)

        %{
          observation: observed,
          affinity_key: runtime_request.cache_affinity_fingerprint,
          rendered_prompt: runtime_request.rendered_prompt_utf8,
          continuation: continuation,
          assertions:
            AgenticExecutionCorpus.compare(observed, expected) ++
              AgenticExecutionCorpus.stream_checks(conn.resp_body, mode, expected) ++
              AgenticExecutionCorpus.stream_controls(conn.resp_body, mode, expected) ++
              [
                %{assertion: "logical_terminal_cardinality", status: "pass"},
                %{assertion: "native_transport_request_identity", status: "pass"},
                %{assertion: "runtime_terminal_cardinality_and_exact_usage", status: "pass"},
                %{assertion: "client_decisions_and_effects", status: "pass"}
              ] ++
              Enum.map(Map.get(continuation, :assertions, []), fn assertion ->
                %{assertion | assertion: "continuation/" <> assertion.assertion}
              end)
        }
    end
  end

  defp public_request(scenario, chat?, stream?) do
    input =
      if chat?,
        do: %{"messages" => [%{"role" => "user", "content" => "probe"}]},
        else: %{"input" => "probe"}

    params =
      input
      |> Map.merge(%{"model" => "agentic-corpus@v1", "stream" => stream?})
      |> Map.merge(scenario["request"])

    if chat? and stream?,
      do: Map.put(params, "stream_options", %{"include_usage" => true}),
      else: params
  end

  defp runtime_failure_result(conn, scenario, expected, mode, before_ids) do
    assert_receive {:agentic_execution_started, _}
    assert_receive {:agentic_runtime_trace, events}
    refute_receive {:agentic_execution_started, _}, 0
    [request] = Enum.reject(Repo.all(Requests.Request), &MapSet.member?(before_ids, &1.id))
    steps = Requests.list_request_step_events(request)
    terminal = List.last(steps)
    error = public_error(conn, mode)

    expected_error =
      if String.ends_with?(mode, "stream"),
        do: expected["stream_public_error"] || expected["public_error"],
        else: expected["public_error"]

    worker_loss? = List.last(scenario["events"])["fail"] == "worker_down"

    checks =
      AgenticExecutionCorpus.check([
        {"native_failure_code", List.last(events).event.code,
         List.last(scenario["events"])["fail"]},
        {"native_retryable", List.last(events).event.retryable, true},
        {"public_error", error["code"], expected_error},
        {"retry_decision", terminal.result["retry_decision"], expected["retry_decision"]},
        {"accepted_native_attempt", terminal.result["accepted"], true},
        {"terminated_native_attempt", terminal.result["execution_resolution"], "terminated"},
        {"durable_runtime_retryable", terminal.result["runtime_retryable"], true},
        {"closed_durable_failure_class", terminal.result["failure_class"],
         if(worker_loss?, do: "worker_or_node_loss", else: "runtime_failure")},
        {"closed_durable_failure_code", terminal.result["failure_code"],
         if(worker_loss?, do: "worker_down", else: "internal_error")},
        {"node_breaker_attribution", Repo.exists?(Orchard.CircuitBreakers.Breaker), worker_loss?},
        {"one_attempt", Enum.map(steps, & &1.attempt) |> Enum.uniq(), [1]},
        {"one_logical_terminal",
         Enum.count(Requests.list_request_events(request), &(&1.state == :failed)), 1},
        {"one_runtime_terminal", Enum.count(events, &Orchard.InferenceEvent.terminal?/1), 1},
        {"worker_failure_has_no_usage_evidence", Map.get(List.last(events).event, :usage), nil}
      ])

    %{
      observation: %{error: error["code"], retry_decision: terminal.result["retry_decision"]},
      assertions:
        checks ++
          AgenticExecutionCorpus.failure_stream_checks(
            conn.resp_body,
            mode,
            expected,
            request.public_id
          )
    }
  end

  defp failure_result(conn, expected, mode, before_ids) do
    assert_receive {:agentic_execution_started, _request}
    assert_receive {:agentic_runtime_trace, events}

    assert Enum.count(events, &Orchard.InferenceEvent.terminal?/1) ==
             expected["runtime_terminals"]

    refute_receive {:agentic_execution_started, _}, 0
    [request] = Enum.reject(Repo.all(Requests.Request), &MapSet.member?(before_ids, &1.id))
    assert Atom.to_string(request.state) == expected["state"]
    assert request.error_code == expected["public_error"]
    terminal = List.last(Requests.list_request_step_events(request))
    assert terminal.result["failure_class"] == "terminal_conformance"
    assert Enum.count(Requests.list_request_events(request), &(&1.state == :failed)) == 1

    error = public_error(conn, mode)
    assert error["code"] == expected["public_error"]

    %{
      observation: %{
        error: Map.take(error, ["code", "type"]),
        output_tokens: request.output_tokens,
        output_usage_status: request.output_usage_status,
        attempt_output_tokens: terminal.result["output_tokens"],
        attempt_usage_status: terminal.result["output_usage_status"],
        http_status: conn.status
      },
      assertions:
        AgenticExecutionCorpus.check([
          {"logical_output_count", request.output_tokens, expected["output_tokens"]},
          {"logical_usage_status", to_string(request.output_usage_status),
           expected["output_usage_status"]},
          {"attempt_output_count", terminal.result["output_tokens"], expected["output_tokens"]},
          {"attempt_usage_status", terminal.result["output_usage_status"],
           expected["output_usage_status"]}
        ]) ++
          [%{assertion: "runtime_fault_fails_once", status: "pass"}] ++
          AgenticExecutionCorpus.failure_stream_checks(
            conn.resp_body,
            mode,
            expected,
            request.public_id
          )
    }
  end

  defp public_error(conn, "chat_stream") do
    assert conn.status == 200
    events = AgenticExecutionCorpus.sse(conn.resp_body)
    errors = Enum.filter(events, &(is_map(&1) and Map.has_key?(&1, "error")))
    assert [terminal] = errors
    assert List.last(events) == terminal
    refute :done in events
    terminal["error"]
  end

  defp public_error(conn, "responses_stream") do
    assert conn.status == 200
    events = AgenticExecutionCorpus.sse(conn.resp_body)

    assert [terminal] =
             Enum.filter(events, &(&1["type"] in ["response.completed", "response.failed"]))

    assert terminal["type"] == "response.failed"
    assert terminal["response"]["status"] == "failed"
    assert List.last(events) == terminal
    terminal["response"]["error"]
  end

  defp public_error(conn, _sync) do
    assert conn.status == 500
    Jason.decode!(conn.resp_body)["error"]
  end

  defp continue(%{"continuation" => continuation} = scenario, calls, effects, mode, token) do
    request =
      Map.merge(scenario["request"], AgenticExecutionClient.continuation(calls, effects, mode))

    result = replay(Map.put(continuation, "request", request), mode, token)
    [history, tools] = String.split(String.trim(result.rendered_prompt), "\n")

    history =
      history
      |> Jason.decode!()
      |> Enum.flat_map(fn
        %{"role" => "assistant", "tool_calls" => [_ | _] = calls} = message ->
          Enum.map(calls, &Map.put(message, "tool_calls", [&1]))

        message ->
          [message]
      end)

    assertions =
      AgenticExecutionCorpus.check([
        {"dispatched_history", history, continuation["expected_history"]},
        {"dispatched_tools", Jason.decode!(tools), scenario["request"]["tools"]}
      ])

    %{result | assertions: result.assertions ++ assertions}
  end

  defp continue(_scenario, _calls, _effects, _mode, _token), do: %{}

  defp report(scenario, mode, assertions) do
    if path = System.get_env("ORCHARD_AGENTIC_RESULTS") do
      {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])
      {worktree, 0} = System.cmd("git", ["status", "--porcelain"])

      result = %{
        corpus_version: @corpus["version"],
        orchard_revision: String.trim(revision),
        worktree_dirty: worktree != "",
        input_sha256: input_hash(),
        client_adapter: @corpus["client_adapter"],
        tokenizer_safe_mode: "reject",
        runtime_fixture:
          if(scenario["boundary"] == "public-api-through-scripted-managed-runtime",
            do: "controller-managed-runtime-script/v1",
            else: "native-worker-runtime/scripted-backend/v1"
          ),
        boundary: scenario["boundary"] || "public-api-through-native-worker",
        case: scenario["id"],
        mode: mode,
        output_contract: scenario["output_contract"],
        assertions: assertions
      }

      File.write!(path, Jason.encode!(result) <> "\n", [:append])
    end
  end

  defp input_hash do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    root = String.trim(root)
    {diff, 0} = System.cmd("git", ["diff", "HEAD", "--binary"], cd: root)

    {untracked, 0} =
      System.cmd("git", ["ls-files", "--others", "--exclude-standard", "-z"], cd: root)

    files =
      untracked
      |> String.split(<<0>>, trim: true)
      |> Enum.sort()
      |> Enum.map(fn path -> [path, <<0>>, File.read!(Path.join(root, path)), <<0>>] end)

    :crypto.hash(:sha256, [diff, files, Jason.encode!(@corpus)])
    |> Base.encode16(case: :lower)
  end
end
