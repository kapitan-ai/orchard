defmodule Orchard.CanonicalRequestTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest

  test "with_tokenization/3 keeps legacy behavior and clears prompt_token_ids" do
    request =
      base_request()
      |> CanonicalRequest.with_tokenization("hello", 2, [10, 11])
      |> CanonicalRequest.with_tokenization("world", 1)

    assert request.rendered_prompt == "world"
    assert request.input_token_count == 1
    assert request.prompt_token_ids == nil
  end

  test "with_tokenization/4 stores segmented tokenization state" do
    request = CanonicalRequest.with_tokenization(base_request(), "prompt", 3, [1, 2, 3])

    assert request.rendered_prompt == "prompt"
    assert request.input_token_count == 3
    assert request.prompt_token_ids == [1, 2, 3]
  end

  test "with_tokenization/4 rejects prompt_token_ids length mismatches" do
    assert_raise ArgumentError, ~r/prompt_token_ids length to equal input_token_count/, fn ->
      CanonicalRequest.with_tokenization(base_request(), "prompt", 3, [1, 2])
    end
  end

  test "with_tokenization/4 rejects invalid prompt_token_ids values" do
    assert_raise ArgumentError, ~r/prompt_token_ids length to equal input_token_count/, fn ->
      CanonicalRequest.with_tokenization(base_request(), "prompt", 2, [1, -1])
    end
  end

  test "new/1 accepts segmented tokenization state" do
    request =
      CanonicalRequest.new(%{
        internal_id: "internal-1",
        public_id: "public-1",
        endpoint: :chat_completions,
        tenant_id: "tenant-1",
        model_ref: %{model_id: "model", version: "v1"},
        rendered_prompt: "prompt",
        input_token_count: 2,
        prompt_token_ids: [4, 5]
      })

    assert request.prompt_token_ids == [4, 5]
  end

  test "new/1 rejects segmented tokenization state with mismatched count" do
    assert_raise ArgumentError,
                 ~r/prompt_token_ids must contain non-negative integers and match input_token_count/,
                 fn ->
                   CanonicalRequest.new(%{
                     internal_id: "internal-1",
                     public_id: "public-1",
                     endpoint: :chat_completions,
                     tenant_id: "tenant-1",
                     model_ref: %{model_id: "model", version: "v1"},
                     rendered_prompt: "prompt",
                     input_token_count: 2,
                     prompt_token_ids: [4]
                   })
                 end
  end

  test "new/1 gives omitted public requests the exact legacy reasoning contract from SPEC.md 3.4" do
    assert base_request().reasoning == %CanonicalRequest.Reasoning{
             generation_policy: :model_default,
             projection: :legacy_blended,
             source: :omitted_public,
             effective_contract: %{mode: :legacy}
           }
  end

  test "new/1 accepts a complete negotiated final-only contract" do
    request =
      CanonicalRequest.new(%{
        internal_id: "internal-negotiated",
        public_id: "public-negotiated",
        endpoint: :chat_completions,
        tenant_id: "tenant-1",
        model_ref: %{model_id: "model", version: "v1"},
        reasoning: %{
          generation_policy: :disabled,
          projection: :final_only,
          source: :console_default,
          effective_contract: negotiated_contract()
        }
      })

    assert request.reasoning.effective_contract == negotiated_contract()
  end

  test "new/1 accepts canonical effort only for enabled final-only negotiated requests" do
    request =
      CanonicalRequest.new(%{
        internal_id: "internal-effort",
        public_id: "public-effort",
        endpoint: :chat_completions,
        tenant_id: "tenant-1",
        model_ref: %{model_id: "model", version: "v1"},
        reasoning: %{
          generation_policy: :enabled,
          projection: :final_only,
          reasoning_effort: :high,
          source: :explicit_public,
          effective_contract: negotiated_contract()
        }
      })

    assert request.reasoning.reasoning_effort == :high
  end

  test "new/1 rejects effort outside the enabled final-only negotiated contract" do
    for {generation_policy, projection, reasoning_effort, source} <- [
          {:model_default, :final_only, :low, :explicit_public},
          {:disabled, :final_only, :medium, :console_explicit},
          {:enabled, :legacy_blended, :high, :explicit_public},
          {:enabled, :final_only, :low, :console_default},
          {:enabled, :final_only, :unknown, :explicit_public}
        ] do
      assert_raise ArgumentError, ~r/reasoning/, fn ->
        CanonicalRequest.new(%{
          internal_id: "internal-invalid-effort",
          public_id: "public-invalid-effort",
          endpoint: :chat_completions,
          tenant_id: "tenant-1",
          model_ref: %{model_id: "model", version: "v1"},
          reasoning: %{
            generation_policy: generation_policy,
            projection: projection,
            reasoning_effort: reasoning_effort,
            source: source,
            effective_contract: negotiated_contract()
          }
        })
      end
    end
  end

  test "new/1 rejects a contradictory console default reasoning policy" do
    assert_raise ArgumentError, ~r/unsupported reasoning combination/, fn ->
      CanonicalRequest.new(%{
        internal_id: "internal-invalid-console",
        public_id: "public-invalid-console",
        endpoint: :chat_completions,
        tenant_id: "tenant-1",
        model_ref: %{model_id: "model", version: "v1"},
        reasoning: %{
          generation_policy: :enabled,
          projection: :final_only,
          source: :console_default,
          effective_contract: negotiated_contract()
        }
      })
    end
  end

  test "new/1 rejects legacy identity fields and unavailable structured projection" do
    assert_raise ArgumentError, ~r/must use exactly/, fn ->
      CanonicalRequest.new(%{
        internal_id: "internal-invalid-legacy",
        public_id: "public-invalid-legacy",
        endpoint: :chat_completions,
        tenant_id: "tenant-1",
        model_ref: %{model_id: "model", version: "v1"},
        reasoning: %{
          generation_policy: :model_default,
          projection: :legacy_blended,
          source: :omitted_public,
          effective_contract: %{mode: :legacy, parser_family: "invented"}
        }
      })
    end

    assert_raise ArgumentError, ~r/unsupported reasoning combination/, fn ->
      CanonicalRequest.new(%{
        internal_id: "internal-invalid-structured",
        public_id: "public-invalid-structured",
        endpoint: :chat_completions,
        tenant_id: "tenant-1",
        model_ref: %{model_id: "model", version: "v1"},
        reasoning: %{
          generation_policy: :enabled,
          projection: :reasoning_structured,
          source: :explicit_public,
          effective_contract: negotiated_contract()
        }
      })
    end
  end

  test "Reasoning.to_wire/1 renders one string-keyed shape for legacy and negotiated policies" do
    assert CanonicalRequest.Reasoning.to_wire(base_request().reasoning) == %{
             "generation_policy" => "model_default",
             "projection" => "legacy_blended",
             "reasoning_effort" => nil,
             "source" => "omitted_public",
             "effective_contract" => %{"mode" => "legacy"}
           }

    negotiated = %CanonicalRequest.Reasoning{
      generation_policy: :disabled,
      projection: :final_only,
      reasoning_effort: nil,
      source: :console_default,
      effective_contract: negotiated_contract()
    }

    assert CanonicalRequest.Reasoning.to_wire(negotiated)["reasoning_effort"] == nil

    assert CanonicalRequest.Reasoning.to_wire(negotiated)["effective_contract"] == %{
             "mode" => "negotiated",
             "model_artifact_digest" => String.duplicate("a", 64),
             "chat_template_digest" => String.duplicate("b", 64),
             "render_contract" => "synthetic-render-v1",
             "render_contract_version" => "1",
             "parser_family" => "synthetic-parser",
             "parser_version" => "1",
             "runtime_contract_version" => "1",
             "event_binding_version" => "1"
           }
  end

  test "Reasoning.to_wire/1 rejects effective contract values that are not atoms or binaries" do
    reasoning = %CanonicalRequest.Reasoning{
      effective_contract: Map.put(negotiated_contract(), :render_contract_version, 1)
    }

    assert_raise ArgumentError, ~r/must be atoms or binaries/, fn ->
      CanonicalRequest.Reasoning.to_wire(reasoning)
    end
  end

  test "Reasoning.to_wire/1 rejects an effort outside the canonical nil|low|medium|high contract" do
    reasoning = %CanonicalRequest.Reasoning{
      generation_policy: :enabled,
      projection: :final_only,
      reasoning_effort: :xhigh,
      source: :explicit_public,
      effective_contract: negotiated_contract()
    }

    assert_raise ArgumentError, ~r/reasoning_effort must be nil, :low, :medium, or :high/, fn ->
      CanonicalRequest.Reasoning.to_wire(reasoning)
    end
  end

  defp negotiated_contract do
    %{
      mode: :negotiated,
      model_artifact_digest: String.duplicate("a", 64),
      chat_template_digest: String.duplicate("b", 64),
      render_contract: "synthetic-render-v1",
      render_contract_version: "1",
      parser_family: "synthetic-parser",
      parser_version: "1",
      runtime_contract_version: "1",
      event_binding_version: "1"
    }
  end

  defp base_request do
    CanonicalRequest.new(%{
      internal_id: "internal-1",
      public_id: "public-1",
      endpoint: :chat_completions,
      tenant_id: "tenant-1",
      model_ref: %{model_id: "model", version: "v1"}
    })
  end
end
