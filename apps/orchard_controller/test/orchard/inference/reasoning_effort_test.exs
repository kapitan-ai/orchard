defmodule Orchard.Inference.ReasoningEffortTest do
  use ExUnit.Case, async: false

  alias Orchard.CanonicalRequest

  alias Orchard.Inference.{
    CanonicalRequestSerializer,
    ChatError,
    ChatRequestNormalizer,
    ChatRequestValidator,
    ReasoningEffort,
    ResponsesRequestNormalizer,
    ResponsesRequestValidator
  }

  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.{ChatTemplate, RuntimeRequirements, Tokenizer}
  alias Orchard.Requests.Idempotency
  alias Orchard.Tokenizer.Client

  @artifact "48ba838e9c9c86b10ab68630ec0d8e1b6dfd760c98c2111432c56f94804d5af9"
  @template "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"

  setup do
    previous = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous, tokenizer_mode: :port, tokenizer_safe_mode: :off)
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :inference, previous) end)
  end

  test "SPEC §7.2.1 both public JSON shapes select three tiers on one model identity" do
    for endpoint <- [:chat_completions, :responses], tier <- ["low", "medium", "high", "xhigh"] do
      {validator, normalizer} = modules(endpoint)
      params = endpoint |> params(tier) |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^params} = validator.validate(params)
      assert {:ok, skeleton} = normalizer.normalize(params)
      assert skeleton.reasoning.effective_contract == %{mode: :legacy}
      assert {:ok, bound} = ReasoningEffort.bind(skeleton, params, options())
      assert bound.model_ref == skeleton.model_ref
      assert CanonicalRequest.Reasoning.to_wire(bound.reasoning)["reasoning_effort"] == tier
      assert bound.reasoning.projection == :legacy_blended
      assert bound.reasoning.effective_contract.native_effort == native(tier)

      assert ReasoningEffort.arguments(bound.reasoning) ==
               %{"enable_thinking" => true, "reasoning_effort" => native(tier)}
    end
  end

  test "omitted effort leaves both normalized requests and serialized shapes unchanged" do
    for endpoint <- [:chat_completions, :responses] do
      {_validator, normalizer} = modules(endpoint)
      params = params(endpoint, nil)
      assert {:ok, skeleton} = normalizer.normalize(params)
      assert {:ok, ^skeleton} = ReasoningEffort.bind(skeleton, params, [])
      refute Map.has_key?(CanonicalRequestSerializer.serialize(skeleton), "reasoning")
      assert :ok = ReasoningEffort.verify_tokenization(skeleton, %{})
    end
  end

  test "SPEC §3.4 aliases keep requested identity while selecting identical native controls" do
    {:ok, high} = bound(:chat_completions, "high")
    {:ok, xhigh} = bound(:chat_completions, "xhigh")
    assert high.reasoning.reasoning_effort == :high
    assert xhigh.reasoning.reasoning_effort == "xhigh"
    assert high.reasoning.effective_contract == xhigh.reasoning.effective_contract
    assert ReasoningEffort.arguments(high.reasoning) == ReasoningEffort.arguments(xhigh.reasoning)

    assert CanonicalRequestSerializer.serialize(high)["reasoning"] !=
             CanonicalRequestSerializer.serialize(xhigh)["reasoning"]

    assert {:ok, same_high} = ReasoningEffort.resolve("high", @artifact, @template)
    assert same_high == high.reasoning

    for endpoint <- [:chat_completions, :responses] do
      tenant_id = Ecto.UUID.generate()

      assert {:ok, high_context} =
               Idempotency.build_context(tenant_id, "same-key", params(endpoint, "high"))

      assert {:ok, xhigh_context} =
               Idempotency.build_context(tenant_id, "same-key", params(endpoint, "xhigh"))

      assert high_context.body_hash != xhigh_context.body_hash
    end
  end

  test "SPEC §3.4 additional rendered values cannot enter the negotiated protocol" do
    {:ok, request} = bound(:responses, "xhigh")
    assert CanonicalRequest.Reasoning.to_wire(request.reasoning)["reasoning_effort"] == "xhigh"

    assert_raise ArgumentError, ~r/unsupported reasoning combination/, fn ->
      reasoning = %{request.reasoning | projection: :final_only}
      CanonicalRequest.new(Map.put(Map.from_struct(request), :reasoning, reasoning))
    end
  end

  test "invalid public types and unknown levels never silently select a default" do
    for endpoint <- [:chat_completions, :responses] do
      {validator, _normalizer} = modules(endpoint)

      for invalid <- [nil, 1, true, %{}, []] do
        assert {:error, :invalid_value, _field, _reason} =
                 validator.validate(params(endpoint, invalid, true))
      end

      for unsupported <- ["MEDIUM", "", "xhigh ", String.duplicate("a", 33)] do
        assert {:error, :invalid_value, _field, _reason} =
                 validator.validate(params(endpoint, unsupported))
      end

      for unsupported <- ["none", "minimal", "max", "future_effort"] do
        params = params(endpoint, unsupported)
        assert {:ok, ^params} = validator.validate(params)
        {_validator, normalizer} = modules(endpoint)
        assert {:ok, skeleton} = normalizer.normalize(params)

        assert {:error, {:validation, {:unsupported_reasoning_control, _field}}} =
                 ReasoningEffort.bind(skeleton, params, options())
      end
    end
  end

  test "Responses effort rejects extra controls and both endpoints reject raw template overrides" do
    assert {:error, :unsupported_parameter, "reasoning.summary"} =
             ResponsesRequestValidator.validate(
               Map.put(params(:responses, "medium"), "reasoning", %{
                 "effort" => "medium",
                 "summary" => "auto"
               })
             )

    for endpoint <- [:chat_completions, :responses] do
      {validator, _normalizer} = modules(endpoint)

      assert {:error, :unsupported_parameter, "template_kwargs"} =
               validator.validate(Map.put(params(endpoint, "medium"), "template_kwargs", %{}))
    end
  end

  test "structured prior reasoning rejects omitted and explicit controls on both endpoints" do
    for endpoint <- [:chat_completions, :responses],
        tier <- [nil, "medium"],
        key <- ["reasoning_content", "reasoning", "thinking"] do
      {validator, _normalizer} = modules(endpoint)
      field = if endpoint == :responses, do: "input", else: "messages"
      message = %{"role" => "assistant", "content" => "prior answer", key => "prior thought"}
      request = Map.put(params(endpoint, tier), field, [message])

      if endpoint == :responses do
        assert {:error, :invalid_value, "input[0]", "contains unsupported or mixed fields"} =
                 validator.validate(request)
      else
        assert {:error, :unsupported_parameter, param} = validator.validate(request)
        assert param == "messages[0].#{key}"
      end
    end
  end

  test "exact model/template registration rejects unknown identities before rendering" do
    {_, normalizer} = modules(:chat_completions)
    params = params(:chat_completions, "medium")
    {:ok, skeleton} = normalizer.normalize(params)

    assert {:error, {:validation, {:unsupported_reasoning_control, "reasoning_effort"}}} =
             ReasoningEffort.bind(
               skeleton,
               params,
               Keyword.put(options(), :bundle_sha256, String.duplicate("a", 64))
             )

    assert {:error, :unsupported_reasoning_control} =
             ReasoningEffort.resolve(:medium, @artifact, String.duplicate("b", 64))
  end

  test "fake and segmented/degraded modes refuse explicit effort instead of dropping it" do
    params = params(:chat_completions, "medium")
    {:ok, skeleton} = ChatRequestNormalizer.normalize(params)

    for {mode, safe} <- [fake: :off, port: :on, port: :reject] do
      configure(tokenizer_mode: mode, tokenizer_safe_mode: safe)

      assert {:error, {:validation, {:unsupported_reasoning_control, "reasoning_effort"}}} =
               ReasoningEffort.bind(skeleton, params, options())
    end
  end

  test "render proof is durable and complete while wrong or dropped helper proof fails" do
    {:ok, request} = bound(:responses, "medium")
    wire = CanonicalRequest.Reasoning.to_wire(request.reasoning)
    assert CanonicalRequestSerializer.serialize(request)["reasoning"] == wire
    assert :ok = ReasoningEffort.verify_tokenization(request, proof(request))

    for response <- [
          %{},
          Map.delete(proof(request), :reasoning),
          Map.put(proof(request), :applied_template_arguments, %{"reasoning_effort" => "xhigh"})
        ] do
      assert {:error, {:tokenization, {:runtime_incompatible, _message}}} =
               ReasoningEffort.verify_tokenization(request, response)
    end

    unknown =
      put_in(
        request.reasoning.effective_contract.model_artifact_digest,
        String.duplicate("a", 64)
      )

    assert {:error, {:tokenization, {:runtime_incompatible, _}}} =
             ReasoningEffort.verify_tokenization(unknown, proof(unknown, %{}))
  end

  test "model-free port rejects helper protocol downgrade, changed proof and missing proof" do
    {:ok, request} = bound(:chat_completions, "medium")
    valid = %{contract_version: 5, ok: true, result: proof(request)}

    for response <- [
          valid,
          %{valid | contract_version: 2},
          put_in(valid.result.reasoning, %{}),
          %{valid | result: Map.delete(valid.result, :applied_template_arguments)}
        ] do
      executable = helper(response)
      configure(tokenizer_executable: executable)
      result = Client.tokenize(request, options())

      if response == valid do
        assert {:ok, tokenization} = result
        assert :ok = ReasoningEffort.verify_tokenization(request, tokenization)
        assert tokenization.input_token_count == 7
      else
        assert {:error, {:runtime_incompatible, _message}} = result
      end
    end
  end

  test "parallel mixed-effort requests retain distinct render and serialized identities" do
    tiers = Enum.take(Stream.cycle(["low", "medium", "high", "xhigh"]), 48)

    results =
      Task.async_stream(tiers, fn tier ->
        {:ok, request} = bound(:chat_completions, tier)
        {request.model_ref, CanonicalRequestSerializer.serialize(request)["reasoning"]}
      end)
      |> Enum.to_list()

    for {tier, {:ok, {model, wire}}} <- Enum.zip(tiers, results) do
      assert model.model_id == "reviewed-qwen"
      assert wire["reasoning_effort"] == tier
      assert wire["effective_contract"]["native_effort"] == native(tier)
    end
  end

  test "unsupported effort has a public-safe HTTP 400 mapping" do
    error =
      ChatError.from_prepare_reason(
        {:validation, {:unsupported_reasoning_control, "reasoning.effort"}}
      )

    assert %{
             status: :bad_request,
             code: "unsupported_reasoning_control",
             param: "reasoning.effort"
           } =
             ChatError.api_mapping(error)
  end

  test "SPEC §3.4 rendered canonical identity rejects incomplete or extra contract fields" do
    {:ok, request} = bound(:chat_completions, "medium")

    for contract <- [
          Map.delete(request.reasoning.effective_contract, :native_effort),
          Map.put(request.reasoning.effective_contract, :caller_override, "xhigh")
        ] do
      reasoning = %{request.reasoning | effective_contract: contract}

      assert_raise ArgumentError,
                   ~r/rendered effort requires every exact input identity field/,
                   fn ->
                     request
                     |> Map.from_struct()
                     |> Map.put(:reasoning, reasoning)
                     |> CanonicalRequest.new()
                   end
    end
  end

  defp bound(endpoint, tier) do
    {_validator, normalizer} = modules(endpoint)
    params = params(endpoint, tier)
    {:ok, skeleton} = normalizer.normalize(params)
    ReasoningEffort.bind(skeleton, params, options())
  end

  defp params(endpoint, effort, explicit \\ false) do
    base = %{"model" => "reviewed-qwen@v1"}

    base =
      if endpoint == :responses,
        do: Map.put(base, "input", "hello"),
        else: Map.put(base, "messages", [%{"role" => "user", "content" => "hello"}])

    cond do
      effort == nil and not explicit -> base
      endpoint == :responses -> Map.put(base, "reasoning", %{"effort" => effort})
      true -> Map.put(base, "reasoning_effort", effort)
    end
  end

  defp modules(:chat_completions), do: {ChatRequestValidator, ChatRequestNormalizer}
  defp modules(:responses), do: {ResponsesRequestValidator, ResponsesRequestNormalizer}
  defp native("high"), do: "xhigh"
  defp native(tier), do: tier

  defp options do
    [
      bundle_sha256: @artifact,
      bundle_root: Path.expand("../../fixtures/tokenizer/minimal_hf_template_divergent", __DIR__),
      manifest: %ModelManifest{
        model_id: "reviewed-qwen",
        version: "v1",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        capabilities: ["chat"],
        runtime_requirements: %RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"},
        tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
        chat_template: %ChatTemplate{path: "chat_template.jinja", sha256: @template}
      }
    ]
  end

  defp proof(request, arguments \\ nil) do
    %{
      rendered_prompt: "fixture",
      input_token_count: 7,
      reasoning: CanonicalRequest.Reasoning.to_wire(request.reasoning),
      applied_template_arguments: arguments || ReasoningEffort.arguments(request.reasoning)
    }
  end

  defp configure(overrides) do
    current = Application.fetch_env!(:orchard_controller, :inference)
    Application.put_env(:orchard_controller, :inference, Keyword.merge(current, overrides))
  end

  defp helper(response) do
    path =
      Path.join(System.tmp_dir!(), "orchard-effort-test-#{System.unique_integer([:positive])}.sh")

    File.write!(path, "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '#{Jason.encode!(response)}'\n")
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
