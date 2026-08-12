defmodule Orchard.Requests.CapturePolicyTest do
  use ExUnit.Case, async: true

  alias Orchard.Requests.CapturePolicy
  alias Orchard.Requests.{Request, RequestEvent, RequestStepEvent}

  @prompt "private prompt that must not survive metadata capture"
  @response "private response that must not survive metadata capture"
  @arguments ~s({"account":"private-account","amount":42})
  @event_integer_keys ~w(attempt attempt_index sequence turn_index)
  @result_integer_keys ~w(http_status input_tokens output_tokens)
  @schedule_boolean_keys ~w(
    cache_affinity_enabled
    cache_affinity_hint_available
    cache_affinity_selected_match
    fallback_used?
    memory_admission_enabled
    memory_headroom_ok?
    queueing_enabled
    selected_prefix_cache_enabled
    selected_prefix_cache_fingerprint_match
    selected_prefix_cache_score_resident_fingerprint_match
    selected_prefix_cache_warmth_indicator
  )
  @schedule_numeric_keys ~w(
    candidate_count
    contract_version
    model_load_timeout_ms
    queue_wait_ms
    request_timeout_ms
    selected_prefix_cache_entry_count
    selected_prefix_cache_evictions
    selected_prefix_cache_fingerprint_count
    selected_prefix_cache_hits
    selected_prefix_cache_misses
    selected_prefix_cache_score_session_started_unix_ms
    selected_prefix_cache_session_started_unix_ms
    selected_prefix_cache_stores
    selected_prefix_cache_total_bytes
  )
  @schedule_enums ~w(
    cache_affinity_source
    memory_admission_tier
    queue_result
    queue_wait_reason
    selected_cache_tier
    selected_prefix_cache_implementation
    selected_prefix_cache_score_source
    selected_prefix_cache_score_status_code
    selected_prefix_cache_score_tier
    selected_prefix_cache_status_code
    selected_tier
    selection_tier
    strategy
  )

  describe "resolve/2" do
    test "SPEC.md §10.10 store=false narrows full and never widens a Tenant mode" do
      assert CapturePolicy.resolve(:full, false) == :metadata
      assert CapturePolicy.resolve(:metadata, false) == :metadata
      assert CapturePolicy.resolve(:none, false) == :none
      assert CapturePolicy.resolve(:full, true) == :full
    end
  end

  describe "create_attrs/2" do
    test "SPEC.md §10.10 none keeps hashes and operational metadata without content" do
      attrs = CapturePolicy.create_attrs(:none, create_attrs())

      assert attrs.body_hash
      assert attrs.canonical_request == nil
      assert attrs.request_shape == nil
      assert attrs.request_payload == nil

      assert attrs.sampling_params == %{
               "max_output_tokens" => 64,
               "seed" => 7,
               "stop_count" => 1,
               "temperature" => 0.5,
               "top_p" => 0.9
             }

      refute Jason.encode!(attrs) =~ @prompt
      refute Jason.encode!(attrs) =~ "private stop"
    end

    test "SPEC.md §10.10 metadata stores bounded shape without the complete request" do
      attrs = CapturePolicy.create_attrs(:metadata, create_attrs())
      encoded = Jason.encode!(attrs)

      assert attrs.canonical_request == nil
      assert attrs.request_payload == nil
      assert attrs.request_shape["capture_mode"] == "metadata"
      assert attrs.request_shape["input_item_count"] == 1
      assert attrs.request_shape["rendered_prompt"]["graphemes"] == String.length(@prompt)
      assert attrs.request_shape["rendered_prompt"]["sha256"] =~ ~r/^[0-9a-f]{64}$/
      assert attrs.request_shape["preview"] == nil
      refute encoded =~ @prompt
      refute encoded =~ "private stop"
      refute encoded =~ "private metadata"
      refute encoded =~ "private tool description"
    end

    test "SPEC.md §10.10 full preserves the approved request fields" do
      attrs = CapturePolicy.create_attrs(:full, create_attrs())

      assert attrs.canonical_request["rendered_prompt"] == @prompt
      assert attrs.canonical_request["sampling"]["stop"] == ["private stop"]
    end
  end

  describe "terminal_attrs/2" do
    test "none and metadata cannot retain a complete response or raw error text" do
      for mode <- [:none, :metadata] do
        attrs = CapturePolicy.terminal_attrs(mode, terminal_attrs())
        encoded = inspect(attrs)

        assert attrs.response_payload == nil
        assert byte_size(attrs.response_hash) == 32
        assert attrs.error_message == nil
        refute encoded =~ @response
        refute encoded =~ @prompt
      end
    end

    test "metadata preview is optional for short content and non-equivalent for long content" do
      short = CapturePolicy.terminal_attrs(:metadata, terminal_attrs())
      assert short.response_preview == nil

      long_response = String.duplicate("x", 513)

      long =
        CapturePolicy.terminal_attrs(
          :metadata,
          terminal_attrs(%{
            response_payload: %{"output_text" => long_response},
            response_preview: long_response,
            response_preview_source: :assistant_text
          })
        )

      assert String.length(long.response_preview) == 512
      assert String.ends_with?(long.response_preview, "…")
      refute long.response_preview == long_response
    end

    test "full preserves the response and bounds its convenience preview" do
      long_response = String.duplicate("x", 700)

      attrs =
        CapturePolicy.terminal_attrs(
          :full,
          terminal_attrs(%{
            response_payload: %{"output_text" => long_response},
            response_preview: long_response
          })
        )

      assert attrs.response_payload == %{"output_text" => long_response}
      assert String.length(attrs.response_preview) == 512
      assert byte_size(attrs.response_hash) == 32
    end

    test "preview bounds match PostgreSQL code-point length without splitting graphemes" do
      decomposed = String.duplicate("e\u0301", 300)
      emoji = String.duplicate("👨‍👩‍👧‍👦", 90)

      for content <- [decomposed, emoji], mode <- [:metadata, :full] do
        attrs =
          CapturePolicy.terminal_attrs(
            mode,
            terminal_attrs(%{
              response_payload: %{"output_text" => content},
              response_preview: content,
              response_preview_source: :assistant_text
            })
          )

        assert length(String.codepoints(attrs.response_preview)) <= 512
        assert String.ends_with?(attrs.response_preview, "…")

        prefix = String.trim_trailing(attrs.response_preview, "…")
        prefix_graphemes = String.graphemes(prefix)
        assert Enum.take(String.graphemes(content), length(prefix_graphemes)) == prefix_graphemes
      end
    end

    test "omitted terminal fields stay omitted so repeated updates cannot clear them" do
      for mode <- [:none, :metadata, :full] do
        attrs = CapturePolicy.terminal_attrs(mode, %{state: :completed, output_tokens: 7})

        refute Map.has_key?(attrs, :response_preview)
        refute Map.has_key?(attrs, :error_code)
        assert attrs.output_tokens == 7
      end
    end

    test "restricted modes retain only closed stable error codes" do
      for mode <- [:none, :metadata] do
        assert CapturePolicy.terminal_attrs(mode, %{error_code: "queue_timeout"}).error_code ==
                 "queue_timeout"

        attrs =
          CapturePolicy.terminal_attrs(mode, %{
            error_code: "runtime echoed #{@prompt}"
          })

        assert attrs.error_code == "internal_error"
        refute inspect(attrs) =~ @prompt
      end
    end
  end

  describe "event_attrs/2" do
    test "none and metadata retain normalized inference error codes without raw error text" do
      for mode <- [:none, :metadata] do
        stable =
          CapturePolicy.event_attrs(
            mode,
            inference_step_result(%{
              "error_code" => "request_cancelled",
              "error_message" => @prompt
            })
          )

        unknown =
          CapturePolicy.event_attrs(
            mode,
            inference_step_result(%{
              "error_code" => "runtime echoed #{@prompt}",
              "error_message" => @prompt
            })
          )

        assert stable.payload["result"] == %{"error_code" => "request_cancelled"}
        assert unknown.payload["result"] == %{"error_code" => "internal_error"}
        refute inspect(stable) =~ @prompt
        refute inspect(unknown) =~ @prompt
      end
    end

    test "none and metadata distinguish invalid finish reasons from absent evidence" do
      for mode <- [:none, :metadata] do
        valid =
          CapturePolicy.event_attrs(
            mode,
            inference_step_result(%{"finish_reason" => "stop"}, "request_step.completed")
          )

        absent =
          CapturePolicy.event_attrs(
            mode,
            inference_step_result(%{"finish_reason_invalid" => true}, "request_step.completed")
          )

        invalid_nil =
          CapturePolicy.event_attrs(
            mode,
            inference_step_result(%{"finish_reason" => nil}, "request_step.completed")
          )

        invalid_content =
          CapturePolicy.event_attrs(
            mode,
            inference_step_result(%{"finish_reason" => @prompt}, "request_step.completed")
          )

        assert valid.payload["result"] == %{"finish_reason" => "stop"}
        assert absent.payload["result"] == %{}
        assert invalid_nil.payload["result"] == %{"finish_reason_invalid" => true}
        assert invalid_content.payload["result"] == %{"finish_reason_invalid" => true}
        refute inspect(invalid_content) =~ @prompt
      end
    end

    test "generic restricted event results use the same inference sanitizer" do
      attrs =
        CapturePolicy.event_attrs(:metadata, %{
          event_type: "request.completed",
          payload: %{
            "result" => %{
              "finish_reason" => nil,
              "error_code" => "request_cancelled",
              "error_message" => @prompt
            }
          }
        })

      assert attrs.payload["result"] == %{
               "error_code" => "request_cancelled",
               "finish_reason_invalid" => true
             }

      refute inspect(attrs) =~ @prompt
    end

    test "none and metadata remove model-generated tool arguments and raw error messages" do
      for mode <- [:none, :metadata] do
        attrs = CapturePolicy.event_attrs(mode, event_attrs())
        encoded = Jason.encode!(attrs)

        refute encoded =~ @arguments
        refute encoded =~ @prompt
        refute encoded =~ "error_message"
        assert attrs.payload["result"]["finish_reason"] == "tool_calls"
      end
    end

    test "none and metadata reject content smuggled under every approved event key" do
      secret = "prompt-secret"

      payload =
        Map.new(@event_integer_keys ++ @result_integer_keys, &{&1, secret})
        |> Map.merge(%{
          "boundary" => secret,
          "step_type" => secret,
          "result" =>
            Map.new(@result_integer_keys ++ ["finish_reason"], &{&1, %{"secret" => secret}})
        })

      for mode <- [:none, :metadata] do
        sanitized = CapturePolicy.event_attrs(mode, %{payload: payload})
        refute inspect(sanitized) =~ secret
      end
    end

    test "full preserves approved request-step content" do
      attrs = CapturePolicy.event_attrs(:full, event_attrs())
      assert attrs.payload["result"]["arguments_json"] == @arguments
    end

    test "none and metadata keep restricted request_step events readable" do
      for mode <- [:none, :metadata], step <- readable_step_events() do
        sanitized = CapturePolicy.event_attrs(mode, step)

        assert {:ok, step_event} =
                 RequestStepEvent.from_request_event(%RequestEvent{
                   event_type: step.event_type,
                   payload: sanitized.payload,
                   request_id: Ecto.UUID.generate(),
                   seq: 1,
                   occurred_at: ~U[2026-07-31 04:00:00.000000Z]
                 })

        assert step_event.step_type == step.payload["step_type"]
        assert step_event.turn_index == step.payload["turn_index"]
        assert step_event.attempt == step.payload["attempt"]
        refute inspect(step_event) =~ @prompt
        refute inspect(step_event) =~ @arguments
      end
    end

    test "none and metadata retain stable tool_execution error codes without raw error text" do
      failed =
        CapturePolicy.event_attrs(
          :metadata,
          tool_execution_step("request_step.failed", %{
            "error_code" => "tool_execution_timed_out",
            "error_message" => "runtime echoed #{@prompt}"
          })
        )

      assert failed.payload["result"]["error_code"] == "tool_execution_timed_out"
      assert failed.payload["result"]["error_message"] == "Tool execution failed"
      refute inspect(failed) =~ @prompt

      unknown =
        CapturePolicy.event_attrs(
          :metadata,
          tool_execution_step("request_step.cancelled", %{
            "error_code" => "runtime echoed #{@prompt}",
            "error_message" => @prompt
          })
        )

      assert unknown.payload["result"]["error_code"] == "tool_execution_cancelled"
      refute inspect(unknown) =~ @prompt

      indeterminate =
        CapturePolicy.event_attrs(
          :metadata,
          tool_execution_step("request_step.indeterminate", %{
            "error_code" => "tool_execution_indeterminate_result_not_observed",
            "error_message" => @prompt,
            "indeterminate_reason" => "result_not_observed"
          })
        )

      assert indeterminate.payload["result"]["indeterminate_reason"] == "result_not_observed"
      refute inspect(indeterminate) =~ @prompt
    end
  end

  defp inference_step_result(result, event_type \\ "request_step.failed") do
    %{
      event_type: event_type,
      payload: %{
        "step_id" => "inference_turn:t1:a1",
        "step_type" => "inference_turn",
        "turn_index" => 1,
        "attempt" => 1,
        "boundary" => "post_observation",
        "result" => result
      }
    }
  end

  describe "schedule_attrs/2" do
    test "none and metadata keep only bounded scheduler fields" do
      schedule = %{
        strategy: :multi_node,
        node_id: Ecto.UUID.generate(),
        selected_prefix_cache_score_status_code: "ok",
        selected_prefix_cache_prompt: @prompt,
        prompt: @prompt,
        diagnostics: %{"error_message" => @prompt},
        scored_candidates: [
          %{
            node_id: "node-a",
            eligible: true,
            score: 1.0,
            reason_codes: [],
            components: %{pool_bonus: 200, prompt_fragment: @prompt},
            diagnostics: %{"prompt" => @prompt}
          }
        ]
      }

      for mode <- [:none, :metadata] do
        sanitized = CapturePolicy.schedule_attrs(mode, schedule)
        encoded = Jason.encode!(sanitized)

        assert sanitized["strategy"] == "multi_node"
        assert sanitized["selected_prefix_cache_score_status_code"] == "ok"

        assert sanitized["scored_candidates"] == [
                 %{
                   "eligible" => true,
                   "reason_codes" => [],
                   "score" => 1.0,
                   "components" => %{"pool_bonus" => 200}
                 }
               ]

        refute encoded =~ @prompt
        refute Map.has_key?(sanitized, "prompt")
        refute Map.has_key?(sanitized, "diagnostics")
      end
    end

    test "none and metadata reject content smuggled under approved scheduler keys" do
      secret = "scheduler-secret"

      schedule =
        Map.new(
          @schedule_numeric_keys ++ @schedule_boolean_keys ++ @schedule_enums,
          &{&1, %{"secret" => secret}}
        )
        |> Map.merge(%{
          "node_id" => secret,
          "selected_node_id" => secret,
          "queue_granted_at" => %{"secret" => secret},
          "queued_at" => [secret],
          "scored_candidates" => [
            %{
              "node_id" => secret,
              "target_ref" => secret,
              "tier" => secret,
              "score" => secret,
              "eligible" => secret,
              "reason_codes" => [secret],
              "components" => %{"pool_bonus" => secret, "prompt_fragment" => secret}
            }
          ]
        })

      for mode <- [:none, :metadata] do
        sanitized = CapturePolicy.schedule_attrs(mode, schedule)
        refute inspect(sanitized) =~ secret
      end
    end

    test "none and metadata normalize valid timestamps and reject malformed types" do
      timestamp = ~U[2026-07-31 04:00:00Z]

      for mode <- [:none, :metadata] do
        sanitized =
          CapturePolicy.schedule_attrs(mode, %{
            queue_granted_at: timestamp,
            queued_at: DateTime.to_iso8601(timestamp)
          })

        assert sanitized == %{
                 "queue_granted_at" => "2026-07-31T04:00:00Z",
                 "queued_at" => "2026-07-31T04:00:00Z"
               }

        assert CapturePolicy.schedule_attrs(mode, %{
                 queue_granted_at: %{"content" => @prompt},
                 queued_at: [@prompt]
               }) == %{}
      end
    end

    test "none and metadata retain only typed cache-affinity feedback" do
      affinity_key = "hmac-sha256:#{String.duplicate("a", 64)}"

      for mode <- [:none, :metadata] do
        sanitized =
          CapturePolicy.schedule_attrs(mode, %{
            cache_affinity_enabled: true,
            cache_affinity_key: affinity_key,
            cache_affinity_hint_available: true,
            cache_affinity_selected_match: false,
            cache_affinity_source: "recent_completed_request",
            cache_affinity_candidate_count: 2
          })

        assert sanitized == %{
                 "cache_affinity_enabled" => true,
                 "cache_affinity_key" => affinity_key,
                 "cache_affinity_hint_available" => true,
                 "cache_affinity_selected_match" => false,
                 "cache_affinity_source" => "recent_completed_request",
                 "cache_affinity_candidate_count" => 2
               }

        assert CapturePolicy.schedule_attrs(mode, %{
                 cache_affinity_enabled: @prompt,
                 cache_affinity_key: "hmac-sha256:#{String.duplicate("g", 64)}",
                 cache_affinity_hint_available: %{"content" => @prompt},
                 cache_affinity_selected_match: [@prompt],
                 cache_affinity_source: @prompt,
                 cache_affinity_candidate_count: -1
               }) == %{}
      end
    end
  end

  test "content_columns/0 explicitly classifies the purge surface" do
    assert CapturePolicy.content_columns() == %{
             request_events: [:payload],
             requests: [
               :canonical_request,
               :request_shape,
               :request_payload,
               :response_payload,
               :response_preview,
               :sampling_params,
               :response_format,
               :scheduler_decision,
               :error_message
             ]
           }
  end

  test "content and safe classifications fail when request schemas drift" do
    content = CapturePolicy.content_columns()
    safe = CapturePolicy.safe_columns()

    assert Enum.sort(content.requests ++ safe.requests) ==
             Enum.sort(Request.__schema__(:fields))

    assert Enum.sort(content.request_events ++ safe.request_events) ==
             Enum.sort(RequestEvent.__schema__(:fields))
  end

  defp create_attrs do
    %{
      body_hash: <<1, 2, 3>>,
      canonical_request: %{
        "endpoint" => "responses",
        "model_ref" => %{"model_id" => "model", "version" => "v1"},
        "input_items" => [%{"role" => "user", "content" => @prompt}],
        "rendered_prompt" => @prompt,
        "input_token_count" => 12,
        "stream" => false,
        "stream_include_usage" => false,
        "sampling" => %{
          "temperature" => 0.5,
          "top_p" => 0.9,
          "max_output_tokens" => 64,
          "stop" => ["private stop"],
          "seed" => 7
        },
        "response_format" => %{"type" => "text"},
        "tooling" => %{
          "tools" => [
            %{
              "function" => %{
                "name" => "private_tool",
                "description" => "private tool description"
              }
            }
          ],
          "requested_tools" => [],
          "tool_choice" => nil,
          "registry_snapshot" => %{"entries" => []},
          "execution_snapshot" => %{"entries" => []}
        },
        "metadata" => %{"note" => "private metadata"},
        "admission" => %{"timeout_ms" => 30_000},
        "resolved_policy" => %{"residency_preference" => "allow_cold_load"}
      },
      request_payload: %{"prompt" => @prompt},
      sampling_params: %{
        "temperature" => 0.5,
        "top_p" => 0.9,
        "max_output_tokens" => 64,
        "stop" => ["private stop"],
        "seed" => 7
      },
      response_format: %{"type" => "text"}
    }
  end

  defp terminal_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        state: :completed,
        response_payload: %{
          "output_text" => @response,
          "echoed_prompt" => @prompt
        },
        response_preview: @response,
        error_code: "runtime_failure",
        error_message: "runtime echoed #{@prompt}"
      },
      overrides
    )
  end

  defp readable_step_events do
    [
      %{
        event_type: "request_step.started",
        payload: %{
          "step_id" => "inference_turn:t1:a1",
          "step_type" => "inference_turn",
          "turn_index" => 1,
          "attempt" => 1,
          "boundary" => "pre_side_effect",
          "result" => %{},
          "model_id" => "model",
          "model_version" => "v1"
        }
      },
      %{
        event_type: "request_step.completed",
        payload: %{
          "step_id" => "inference_turn:t1:a1",
          "step_type" => "inference_turn",
          "turn_index" => 1,
          "attempt" => 1,
          "boundary" => "post_observation",
          "result" => %{"finish_reason" => "stop", "output_tokens" => 12, "prompt" => @prompt}
        }
      },
      %{
        event_type: "request_step.proposed",
        payload: %{
          "step_id" => "tool_call:t1:ccall-1",
          "step_type" => "tool_call",
          "turn_index" => 1,
          "attempt" => 1,
          "parent_step_id" => "inference_turn:t1:a1",
          "boundary" => "post_observation",
          "call_id" => "call-1",
          "tool_name" => "transfer",
          "arguments_json" => @arguments,
          "result" => %{"finish_reason" => "tool_calls"}
        }
      },
      tool_execution_step("request_step.completed", %{}),
      tool_execution_step("request_step.timed_out", %{
        "error_code" => "tool_execution_timed_out",
        "error_message" => "runtime echoed #{@prompt}"
      })
    ]
  end

  defp tool_execution_step(event_type, result) do
    %{
      event_type: event_type,
      payload: %{
        "step_id" => "tool_execution:t1:ccall-1:a1",
        "step_type" => "tool_execution",
        "turn_index" => 1,
        "attempt" => 1,
        "parent_step_id" => "tool_call:t1:ccall-1",
        "boundary" => "post_observation",
        "call_id" => "call-1",
        "result" => result
      }
    }
  end

  test "restricted capture retains closed attempt evidence and hashes targets" do
    raw_target = "grpc://10.0.0.8:50071/private"
    node_id = "00000000-0000-4000-a000-000000000001"
    attrs = enriched_attempt_event(raw_target, node_id)
    expected_target = "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw_target), case: :lower)

    for mode <- [:none, :metadata] do
      sanitized = CapturePolicy.event_attrs(mode, attrs)
      result = sanitized.payload["result"]

      assert result["attempt_outcome"] == "failed"
      assert result["failure_class"] == "runtime_failure"
      assert result["failure_code"] == "runtime_unavailable"
      assert result["node_id"] == node_id
      assert result["target_ref"] == expected_target
      refute Map.has_key?(result, "raw_source_code")
      refute Map.has_key?(result, "error_message")
      refute inspect(sanitized) =~ @prompt
      refute inspect(sanitized) =~ @arguments
    end
  end

  test "full capture permits only strict enriched fields and approved target identifiers" do
    attrs =
      enriched_attempt_event(
        "grpc://10.0.0.8:50071/private",
        "00000000-0000-4000-a000-000000000001"
      )

    sanitized = CapturePolicy.event_attrs(:full, attrs)
    assert sanitized.payload["result"] == %{"result_invalid" => true}

    stable_target = "sha256:" <> String.duplicate("a", 64)
    stable = put_in(attrs, [:payload, "result", "target_ref"], stable_target)

    assert CapturePolicy.event_attrs(:full, stable).payload["result"]["target_ref"] ==
             stable_target

    invalid = put_in(stable, [:payload, "result", "content"], @prompt)
    sanitized = CapturePolicy.event_attrs(:full, invalid)
    assert sanitized.payload["result"] == %{"result_invalid" => true}
  end

  test "restricted tool-call parent identity follows the payload attempt" do
    attrs = %{
      event_type: "request_step.proposed",
      payload: %{
        "step_type" => "tool_call",
        "turn_index" => 1,
        "attempt" => 2,
        "call_id" => "call-private",
        "boundary" => "post_observation",
        "result" => %{}
      }
    }

    sanitized = CapturePolicy.event_attrs(:metadata, attrs)
    assert sanitized.payload["parent_step_id"] == "inference_turn:t1:a2"
  end

  defp enriched_attempt_event(raw_target, node_id) do
    %{
      event_type: "request_step.failed",
      payload: %{
        "step_id" => "inference_turn:t1:a1",
        "step_type" => "inference_turn",
        "turn_index" => 1,
        "attempt" => 1,
        "boundary" => "post_observation",
        "result" => %{
          "attempt_outcome" => "failed",
          "started_at" => ~U[2026-08-12 10:00:00.000000Z],
          "ended_at" => ~U[2026-08-12 10:00:01.000000Z],
          "accepted" => true,
          "output_committed" => false,
          "execution_resolution" => "terminated",
          "capacity_release_outcome" => "released",
          "excluded_node_ids" => [],
          "node_id" => node_id,
          "target_ref" => raw_target,
          "failure_class" => "runtime_failure",
          "failure_code" => "runtime_unavailable",
          "runtime_retryable" => true,
          "retry_decision" => "not_retryable",
          "raw_source_code" => "private-runtime-code",
          "error_message" => "runtime echoed #{@prompt}"
        },
        "arguments_json" => @arguments,
        "content" => @prompt
      }
    }
  end

  defp event_attrs do
    %{
      event_type: "request_step.proposed",
      payload: %{
        "step_id" => "turn-1",
        "step_type" => "inference_turn",
        "turn_index" => 0,
        "attempt" => 1,
        "boundary" => "post_observation",
        "result" => %{
          "finish_reason" => "tool_calls",
          "arguments_json" => @arguments,
          "error_message" => "runtime echoed #{@prompt}"
        }
      }
    }
  end
end
