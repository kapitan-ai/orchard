defmodule Orchard.Inference.RequestLocalEffortPreparationTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.CanonicalRequest
  alias Orchard.Governance
  alias Orchard.Inference.{ChatOrchestrator, ReasoningEffort, ResponsesOrchestrator}
  alias Orchard.Repo
  alias Orchard.Requests.Request

  @artifact "48ba838e9c9c86b10ab68630ec0d8e1b6dfd760c98c2111432c56f94804d5af9"
  @template "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"

  defmodule ProvingTokenizer do
    def tokenize(request, _opts) do
      {:ok,
       %{
         rendered_prompt: "model-free fixture",
         input_token_count: 7,
         reasoning: CanonicalRequest.Reasoning.to_wire(request.reasoning),
         applied_template_arguments: ReasoningEffort.arguments(request.reasoning)
       }}
    end
  end

  defmodule DroppingTokenizer do
    def tokenize(_request, _opts), do: {:ok, %{rendered_prompt: "fixture", input_token_count: 7}}
  end

  defmodule TrackingTokenizer do
    def tokenize(request, opts) do
      send(self(), :tokenizer_called)

      case request.reasoning.effective_contract do
        %{mode: :legacy} -> DroppingTokenizer.tokenize(request, opts)
        %{mode: :rendered} -> ProvingTokenizer.tokenize(request, opts)
      end
    end
  end

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "orchard-effort-prepare-#{suffix}")
    File.mkdir!(root)
    previous = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous,
        tokenizer_mode: :port,
        tokenizer_safe_mode: :off,
        tokenizer_client_impl: ProvingTokenizer
      )
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous)
      File.rm_rf!(root)
    end)

    model_id = "effort-model-#{suffix}"

    manifest = %{
      "model_id" => model_id,
      "version" => "v1",
      "format" => "mlx",
      "artifact_layout" => "directory",
      "entrypoint" => "weights/",
      "capabilities" => ["chat"],
      "tokenizer" => %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
      "chat_template" => %{"path" => "chat_template.jinja", "sha256" => @template},
      "runtime_requirements" => %{"adapter" => "mlx_lm", "min_agent_capability" => "mlx"}
    }

    File.write!(Path.join(root, "manifest.json"), Jason.encode!(manifest))

    model =
      create_model!(%{
        model_id: model_id,
        version: "v1",
        state: :active,
        artifact_uri: "file://#{root}",
        artifact_sha256: @artifact,
        max_context_tokens: 16
      })

    {:ok, tenant} = Governance.create_tenant(%{slug: "effort-#{suffix}", name: "Effort"})
    grant_model_access!(tenant, model)
    %{model: model, tenant: tenant}
  end

  # The proving seam is synthetic; real rendering/counting is tested in the helper.
  # Preparation alone never persists a Request or invokes a Worker.
  test "SPEC §3.4 preparation binds each API control before applying count and reserve", ctx do
    for endpoint <- [:chat_completions, :responses], tier <- ["low", "medium", "high", "xhigh"] do
      assert {:ok, request, model} = prepare(ctx, endpoint, tier, 9)
      assert model.id == ctx.model.id
      assert request.input_token_count == 7
      assert request.sampling.max_output_tokens == 9
      assert CanonicalRequest.Reasoning.to_wire(request.reasoning)["reasoning_effort"] == tier
      assert request.reasoning.effective_contract.model_artifact_digest == @artifact
      assert request.reasoning.projection == :legacy_blended
    end

    assert Repo.aggregate(Request, :count) == 0
  end

  test "SPEC §7.2.3 unsupported registered-model values fail before a Request write", ctx do
    for endpoint <- [:chat_completions, :responses], value <- ["max", "minimal", "none"] do
      assert {:error, {:validation, {:unsupported_reasoning_control, _field}}} =
               prepare(ctx, endpoint, value, 9)
    end

    assert Repo.aggregate(Request, :count) == 0
  end

  test "SPEC §5.2 model authorization precedes effort capability probing", ctx do
    Orchard.Models.Access.revoke_model_access(ctx.tenant, ctx.model)

    for endpoint <- [:chat_completions, :responses], value <- ["medium", "max"] do
      assert {:error, :model_not_authorized} = prepare(ctx, endpoint, value, 9)
    end

    assert Repo.aggregate(Request, :count) == 0
  end

  test "SPEC §5.2 omitted effort preserves error precedence while explicit effort checks access first",
       ctx do
    Orchard.Models.Access.revoke_model_access(ctx.tenant, ctx.model)
    inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(inference, :tokenizer_client_impl, TrackingTokenizer)
    )

    for endpoint <- [:chat_completions, :responses] do
      assert {:error, {:context_overflow, _message}} = prepare(ctx, endpoint, nil, 10)
      assert_receive :tokenizer_called

      assert {:error, :model_not_authorized} = prepare(ctx, endpoint, "medium", 10)
      refute_received :tokenizer_called

      assert {:error, :model_not_authorized} = prepare(ctx, endpoint, nil, 9)
      assert_receive :tokenizer_called
    end

    assert Repo.aggregate(Request, :count) == 0
  end

  test "SPEC §3.5 actual returned input count plus output reserve rejects overflow", ctx do
    for endpoint <- [:chat_completions, :responses] do
      assert {:error, {:context_overflow, message}} = prepare(ctx, endpoint, "medium", 10)
      assert message =~ "17 tokens (7 input + 10 output)"
    end

    assert Repo.aggregate(Request, :count) == 0
  end

  test "configured tokenizer seam cannot silently drop a selected public control", ctx do
    inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(inference, :tokenizer_client_impl, DroppingTokenizer)
    )

    for endpoint <- [:chat_completions, :responses] do
      assert {:error, {:tokenization, {:runtime_incompatible, _}}} =
               prepare(ctx, endpoint, "medium", 9)
    end

    assert Repo.aggregate(Request, :count) == 0
  end

  defp prepare(ctx, :chat_completions, tier, output) do
    params =
      %{
        "model" => "#{ctx.model.model_id}@v1",
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "max_tokens" => output
      }

    params = if is_nil(tier), do: params, else: Map.put(params, "reasoning_effort", tier)
    ChatOrchestrator.prepare(params, tenant_id: ctx.tenant.id)
  end

  defp prepare(ctx, :responses, tier, output) do
    params =
      %{
        "model" => "#{ctx.model.model_id}@v1",
        "input" => "hello",
        "max_output_tokens" => output
      }

    params = if is_nil(tier), do: params, else: Map.put(params, "reasoning", %{"effort" => tier})
    ResponsesOrchestrator.prepare(params, tenant_id: ctx.tenant.id)
  end
end
