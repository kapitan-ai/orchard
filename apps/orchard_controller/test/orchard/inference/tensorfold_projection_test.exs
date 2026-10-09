defmodule Orchard.Inference.TensorFoldProjectionTest do
  use ExUnit.Case, async: false

  alias Orchard.Inference.{
    ChatRequestNormalizer,
    ChatRequestValidator,
    ReasoningEffort,
    ResponsesRequestNormalizer,
    ResponsesRequestValidator,
    TensorFoldProjection,
    ToolRegistryResolver
  }

  alias Orchard.{CanonicalRequest, ModelManifest}

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
      %{request | tooling: %{request.tooling | tool_choice: "required"}},
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

  test "SPEC §7.2.9 selected requests require the authoritative rendered token IDs" do
    request = bound(:chat_completions)
    untokenized = %{request | rendered_prompt: nil, input_token_count: nil, prompt_token_ids: nil}

    rejected = [
      untokenized,
      CanonicalRequest.with_tokenization(request, "rendered medium", 3),
      CanonicalRequest.with_tokenization(request, "rendered medium", 0, []),
      CanonicalRequest.with_tokenization(request, "", 3, [11, 12, 13]),
      %{request | prompt_token_ids: [11, 12]}
    ]

    for candidate <- rejected do
      assert {:error, {:tokenization, {:runtime_incompatible, _}}} =
               TensorFoldProjection.validate(candidate, profile())

      assert {:error, {:tokenization, {:runtime_incompatible, _}}} = issue(candidate)
    end
  end

  test "SPEC §7.2.9 a deadline beyond the frozen request limit is refused before dispatch" do
    request = bound(:chat_completions)
    limited = Map.put(profile(), "max_request_seconds", 90)
    in_limit = %{timeout_at: DateTime.add(DateTime.utc_now(), 89_500, :millisecond)}
    default_timeout = %{timeout_at: DateTime.add(DateTime.utc_now(), 120_000, :millisecond)}
    expired = %{timeout_at: DateTime.add(DateTime.utc_now(), -1, :second)}

    assert {:ok, _json} = issue(request, limited, "node-one", in_limit)
    assert {:error, _} = issue(request, limited, "node-one", default_timeout)
    assert {:error, _} = issue(request, limited, "node-one", expired)
    assert {:error, _} = issue(request, limited, "node-one", %{})
    assert {:ok, _json} = issue(request, profile(), "node-one", default_timeout)

    for invalid <- [0, -1, "90", 3_601] do
      assert {:error, _} =
               TensorFoldProjection.validate(
                 request,
                 Map.put(profile(), "max_request_seconds", invalid)
               )
    end
  end

  test "SPEC §7.2.9 tool_choice auto with declared tools is the admitted default on both endpoints" do
    for endpoint <- [:chat_completions_with_tools, :responses] do
      request = bound(endpoint)
      {:ok, tooling} = ToolRegistryResolver.resolve(request.tooling)
      request = %{request | tooling: tooling}
      assert [_ | _] = request.tooling.tools
      auto = %{request | tooling: %{request.tooling | tool_choice: "auto"}}

      assert :ok = TensorFoldProjection.validate(auto, profile())
      assert {:ok, auto_json} = issue(auto)
      assert {:ok, ^auto_json} = issue(request)

      for choice <- [
            "none",
            "required",
            %{"type" => "function", "function" => %{"name" => "lookup"}}
          ] do
        explicit = %{request | tooling: %{request.tooling | tool_choice: choice}}
        assert {:error, _} = TensorFoldProjection.validate(explicit, profile())
      end
    end
  end

  test "SPEC §7.2.9 OpenCode title, tool and continuation request shapes are admitted" do
    for body <- opencode_requests() do
      assert {:ok, params} = ChatRequestValidator.validate(body)
      assert {:ok, request} = ChatRequestNormalizer.normalize(params)
      assert {:ok, tooling} = ToolRegistryResolver.resolve(request.tooling)
      request = bind(%{request | tooling: tooling})

      deadline = %{timeout_at: DateTime.add(DateTime.utc_now(), 1_799_000, :millisecond)}

      assert :ok = TensorFoldProjection.validate(request, opencode_profile())
      assert {:ok, json} = issue(request, opencode_profile(), "node-one", deadline)
      assert Jason.decode!(json)["tools"] == request.tooling.tools
    end
  end

  test "SPEC §7.2.9 frozen profile token limits are refused before dispatch" do
    request = bound(:chat_completions)
    sized = %{request | sampling: %{request.sampling | max_output_tokens: 32_000}}

    limits = %{
      "max_input_tokens" => 3,
      "max_output_tokens" => 32_000,
      "max_context_tokens" => 32_003
    }

    limited = Map.merge(profile(), limits)

    assert :ok = TensorFoldProjection.validate(sized, limited)
    assert {:ok, _json} = issue(sized, limited)
    assert :ok = TensorFoldProjection.validate(request, limited)

    for {key, value} <- [
          {"max_input_tokens", 2},
          {"max_output_tokens", 31_999},
          {"max_context_tokens", 32_002}
        ] do
      assert {:error, {:tokenization, {:runtime_incompatible, _}}} =
               TensorFoldProjection.validate(sized, Map.put(limited, key, value))
    end

    defaulted = Map.put(limited, "max_output_tokens", 4_095)
    assert {:error, _} = TensorFoldProjection.validate(request, defaulted)

    for key <- Map.keys(limits), invalid <- [0, -1, "3", 1.5, 1_048_577] do
      assert {:error, _} = TensorFoldProjection.validate(sized, Map.put(limited, key, invalid))
    end
  end

  test "SPEC §7.2.9 selection follows the configured model only" do
    request = bound(:chat_completions)
    assert TensorFoldProjection.selected?(request, profile())
    refute TensorFoldProjection.selected?(request, nil)
    refute TensorFoldProjection.selected?(request, Map.put(profile(), "model_id", "other"))
  end

  test "SPEC §7.2.9 only a selected request refused before acceptance keeps the classified error" do
    request = bound(:chat_completions)
    other = %{request | model_ref: %{request.model_ref | model_id: "other"}}

    refused = %{
      accepted: false,
      events: [],
      failure: %{"failure_code" => "runtime_incompatible"}
    }

    assert TensorFoldProjection.refused_before_acceptance?(request, refused, profile())
    refute TensorFoldProjection.refused_before_acceptance?(other, refused, profile())
    refute TensorFoldProjection.refused_before_acceptance?(request, refused, nil)

    for changed <- [
          %{refused | accepted: true},
          %{refused | events: [:accepted]},
          %{refused | failure: %{"failure_code" => "internal_error"}}
        ] do
      refute TensorFoldProjection.refused_before_acceptance?(request, changed, profile())
    end
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

  defp normalized(:chat_completions_with_tools) do
    params = %{
      "model" => "qwen@#{@version}",
      "messages" => [%{"role" => "user", "content" => "lookup it"}],
      "tools" => [lookup_tool()]
    }

    assert {:ok, params} = ChatRequestValidator.validate(params)
    {:ok, request} = ChatRequestNormalizer.normalize(params)
    request
  end

  defp bound(endpoint), do: endpoint |> normalized() |> bind()

  defp bind(request) do
    {:ok, reasoning} = ReasoningEffort.resolve(:medium, @artifact, @template)

    %{request | reasoning: reasoning}
    |> CanonicalRequest.with_tokenization("rendered medium", 3, [11, 12, 13])
  end

  defp lookup_tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => "lookup",
        "description" => "Look up a value",
        "parameters" => %{
          "$schema" => "https://json-schema.org/draft/2020-12/schema",
          "type" => "object",
          "properties" => %{"q" => %{"type" => "string"}, "limit" => %{"type" => "integer"}},
          "required" => ["q"]
        }
      }
    }
  end

  # Placeholder content in the request shapes OpenCode 1.18.34 sends through
  # the pinned pilot configuration: a title request without tools, then a tool
  # request and its continuation with tool_choice "auto".
  defp opencode_requests do
    controls = %{
      "model" => "qwen@#{@version}",
      "max_tokens" => 32_000,
      "temperature" => 1,
      "top_p" => 0.95,
      "reasoning_effort" => "medium",
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }

    system = %{"role" => "system", "content" => "You are a coding agent."}
    task = %{"role" => "user", "content" => "Fix the failing test."}

    call = %{
      "id" => "call_one",
      "type" => "function",
      "function" => %{"name" => "lookup", "arguments" => ~s({"q":"value"})}
    }

    tools = %{"tools" => [lookup_tool()], "tool_choice" => "auto"}

    [
      Map.put(controls, "messages", [
        %{"role" => "system", "content" => "Generate a short title."},
        %{"role" => "user", "content" => "Title request"},
        task
      ]),
      controls |> Map.merge(tools) |> Map.put("messages", [system, task]),
      controls
      |> Map.merge(tools)
      |> Map.put("messages", [
        system,
        task,
        %{"role" => "assistant", "content" => "", "tool_calls" => [call]},
        %{"role" => "tool", "tool_call_id" => "call_one", "content" => "result"}
      ])
    ]
  end

  defp opencode_profile do
    Map.merge(profile(), %{
      "max_input_tokens" => 65_536,
      "max_output_tokens" => 32_768,
      "max_context_tokens" => 98_304,
      "max_request_seconds" => 1_800
    })
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

  defp issue(request, profile \\ profile(), node_id \\ "node-one", schedule \\ %{}) do
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
      Map.put(schedule, :node_id, node_id),
      profile,
      assets_loader: loader
    )
  end
end
