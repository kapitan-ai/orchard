defmodule Orchard.Inference.TensorFoldProjectionTest do
  use ExUnit.Case, async: false

  alias Orchard.Inference.{
    ChatRequestNormalizer,
    ChatRequestValidator,
    ReasoningEffort,
    ResponsesRequestNormalizer,
    ResponsesRequestValidator,
    TensorFoldProjection
  }

  alias Orchard.ModelManifest

  @artifact "48ba838e9c9c86b10ab68630ec0d8e1b6dfd760c98c2111432c56f94804d5af9"
  @template "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"
  @version String.duplicate("c", 64)
  @config_bytes ~s({"enable_thinking":true})

  setup do
    old = Application.fetch_env!(:orchard_controller, :inference)
    Application.put_env(:orchard_controller, :inference, Keyword.put(old, :cache_affinity, []))
    on_exit(fn -> Application.put_env(:orchard_controller, :inference, old) end)
    :ok
  end

  test "SPEC §3.4 default off cannot be selected by public metadata" do
    request = normalized(:chat_completions)
    request = %{request | metadata: %{"tensorfold_experiment_profile" => profile()}}
    assert :ok = TensorFoldProjection.validate(request, nil)
    assert {:ok, ""} = TensorFoldProjection.issue(request, %{}, %{}, nil)
  end

  test "SPEC §3.4 both real public normalizers preserve canonical history in trusted envelope" do
    for endpoint <- [:chat_completions, :responses] do
      request = bound(endpoint)
      assert :ok = TensorFoldProjection.validate(request, profile())
      assert {:ok, json} = issue(request)
      envelope = Jason.decode!(json)
      assert envelope["messages"] == request.input_items
      assert envelope["tools"] == request.tooling.tools
      assert envelope["reasoning_effort"] == "medium"
      assert envelope["enable_thinking"] == true
      refute Map.has_key?(envelope, "incarnation")
      refute Map.has_key?(envelope, "metadata")
    end
  end

  test "SPEC §3.4 omitted, other tiers, disabled and negotiated reasoning are refused" do
    request = bound(:chat_completions)
    assert {:error, _} = TensorFoldProjection.validate(normalized(:chat_completions), profile())

    for tier <- [:low, :high, "xhigh"] do
      {:ok, reasoning} = ReasoningEffort.resolve(tier, @artifact, @template)

      assert {:error, _} =
               TensorFoldProjection.validate(%{request | reasoning: reasoning}, profile())
    end

    for attrs <- [
          %{generation_policy: :disabled},
          %{projection: :final_only},
          %{source: :console_explicit},
          %{effective_contract: %{mode: :negotiated}}
        ] do
      rejected = %{request | reasoning: struct(request.reasoning, attrs)}
      assert {:error, _} = TensorFoldProjection.validate(rejected, profile())
    end
  end

  test "SPEC §3.4 unsupported accepted controls and structured prior reasoning fail closed" do
    request = bound(:chat_completions)

    rejected = [
      %{request | sampling: %{request.sampling | seed: 0}},
      %{request | sampling: %{request.sampling | stop: ["END"]}},
      %{request | response_format: %{request.response_format | type: :json_object}},
      %{request | tooling: %{request.tooling | tool_choice: "auto"}},
      %{
        request
        | input_items: [
            %{"role" => "assistant", "content" => "opaque", "reasoning_content" => "private"}
          ]
      }
    ]

    for candidate <- rejected,
        do: assert({:error, _} = TensorFoldProjection.validate(candidate, profile()))
  end

  test "SPEC §3.4 exact model version, registry identity, target and bounds are required" do
    request = bound(:chat_completions)
    assert {:error, _} = issue(%{request | model_ref: %{request.model_ref | version: "wrong"}})

    assert {:error, _} =
             issue(request, Map.put(profile(), "artifact_sha256", String.duplicate("a", 64)))

    assert {:error, _} = issue(request, profile(), "unauthorized")
    assert {:error, _} = issue(request, Map.put(profile(), "max_projection_bytes", 1))

    assert {:error, _} =
             issue(
               request,
               Map.put(profile(), "tokenizer_config_sha256", String.duplicate("b", 64))
             )

    assert {:error, _} =
             TensorFoldProjection.issue(
               request,
               %{artifact_sha256: "wrong"},
               %{node_id: "node-one"},
               profile()
             )
  end

  test "SPEC §3.4 unconfigured models retain baseline dispatch" do
    request = bound(:chat_completions)
    request = %{request | model_ref: %{request.model_ref | model_id: "other"}}
    assert :ok = TensorFoldProjection.validate(request, profile())
    assert {:ok, ""} = TensorFoldProjection.issue(request, %{}, %{}, profile())
  end

  defp normalized(:chat_completions) do
    params = %{
      "model" => "qwen@#{@version}",
      "messages" => [
        %{"role" => "developer", "content" => [%{"type" => "text", "text" => "Be exact"}]},
        %{"role" => "assistant", "content" => "<think>opaque\n</think>\n"},
        %{"role" => "user", "content" => "continue"}
      ]
    }

    assert {:ok, params} = ChatRequestValidator.validate(params)
    {:ok, request} = ChatRequestNormalizer.normalize(params)
    request
  end

  defp normalized(:responses) do
    params = %{
      "model" => "qwen@#{@version}",
      "input" => [
        %{"role" => "user", "content" => "lookup it"},
        %{
          "type" => "function_call",
          "call_id" => "call_one",
          "name" => "lookup",
          "arguments" => ~s({"q":"value"})
        },
        %{"type" => "function_call_output", "call_id" => "call_one", "output" => "result\n"}
      ],
      "tools" => [
        %{"type" => "function", "name" => "lookup", "parameters" => %{"type" => "object"}}
      ]
    }

    assert {:ok, params} = ResponsesRequestValidator.validate(params)
    {:ok, request} = ResponsesRequestNormalizer.normalize(params)
    request
  end

  defp bound(endpoint) do
    {:ok, reasoning} = ReasoningEffort.resolve(:medium, @artifact, @template)
    %{normalized(endpoint) | reasoning: reasoning}
  end

  defp profile do
    %{
      "schema_version" => 1,
      "profile_id" => "qwen-medium",
      "model_id" => "qwen",
      "version" => @version,
      "artifact_sha256" => @artifact,
      "template_sha256" => @template,
      "tokenizer_config_sha256" =>
        Base.encode16(:crypto.hash(:sha256, @config_bytes), case: :lower),
      "enable_thinking" => true,
      "reasoning_effort" => "medium",
      "output_projection" => "legacy_blended",
      "authorized_node_ids" => ["node-one"]
    }
  end

  defp issue(request, profile \\ profile(), node_id \\ "node-one") do
    root =
      Path.join(System.tmp_dir!(), "orchard-projection-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "tokenizer_config.json"), @config_bytes)
    on_exit(fn -> File.rm_rf!(root) end)

    manifest =
      struct(ModelManifest,
        tokenizer: struct(ModelManifest.Tokenizer, config_path: "tokenizer_config.json"),
        chat_template: struct(ModelManifest.ChatTemplate, sha256: @template)
      )

    loader = fn _model -> {:ok, [manifest: manifest, bundle_root: root]} end

    TensorFoldProjection.issue(
      request,
      %{artifact_sha256: @artifact},
      %{node_id: node_id},
      profile,
      assets_loader: loader
    )
  end
end
