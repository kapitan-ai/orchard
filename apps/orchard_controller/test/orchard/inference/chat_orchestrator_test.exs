defmodule Orchard.Inference.ChatOrchestratorTest do
  @moduledoc """
  Focused tests for ChatOrchestrator.prepare/2 boundary behavior.
  """
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ToolRegistryTestSupport,
    only: [fixture_bundle_path: 0, with_inference_overrides: 2, write_tokenizer_executable!: 0]

  alias Orchard.Inference.ChatOrchestrator
  alias Orchard.TestSupport.ModelRequestFixtures
  alias Orchard.Tools

  defmodule SegmentedTokenizerClient do
    def tokenize(_canonical, _opts) do
      {:ok,
       %{
         rendered_prompt: "segmented prompt",
         input_token_count: 2,
         prompt_token_ids: [17, 18]
       }}
    end
  end

  describe "prepare/2 context-window enforcement with omitted max_tokens" do
    test "rejects omitted max_tokens when prompt fills most of the context window" do
      model =
        ModelRequestFixtures.create_model!(%{
          model_id: "test/small-context-model",
          version: "v1",
          state: :active,
          max_context_tokens: 100
        })

      content = Enum.map_join(1..98, " ", fn i -> "word#{i}" end)

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => content}]
      }

      assert {:error, {:context_overflow, detail}} = ChatOrchestrator.prepare(params, [])
      assert detail =~ "100 input"
      assert detail =~ "4096 output"
    end

    test "accepts omitted max_tokens when prompt leaves room for the default budget" do
      model =
        ModelRequestFixtures.create_model!(%{
          model_id: "test/large-context-model",
          version: "v1",
          state: :active,
          max_context_tokens: 131_072
        })

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      assert {:ok, canonical, _model} = ChatOrchestrator.prepare(params, [])
      assert canonical.sampling.max_output_tokens == nil
    end

    test "explicit max_tokens still takes precedence over default" do
      model =
        ModelRequestFixtures.create_model!(%{
          model_id: "test/explicit-max-model",
          version: "v1",
          state: :active,
          max_context_tokens: 131_072
        })

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "max_tokens" => 50
      }

      assert {:ok, canonical, _model} = ChatOrchestrator.prepare(params, [])
      assert canonical.sampling.max_output_tokens == 50
    end

    test "threads segmented prompt_token_ids into canonical request state" do
      model =
        ModelRequestFixtures.create_model!(%{
          model_id: "test/segmented-tokenization-model",
          version: "v1",
          state: :active,
          max_context_tokens: 131_072
        })

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "max_tokens" => 50
      }

      with_inference_overrides(
        [tokenizer_mode: :fake, tokenizer_client_impl: SegmentedTokenizerClient],
        fn ->
          assert {:ok, canonical, _model} = ChatOrchestrator.prepare(params, [])
          assert canonical.rendered_prompt == "segmented prompt"
          assert canonical.input_token_count == 2
          assert canonical.prompt_token_ids == [17, 18]
        end
      )
    end

    test "nil max_context_tokens skips overflow enforcement" do
      model =
        ModelRequestFixtures.create_model!(%{
          model_id: "test/nil-context-model",
          version: "v1",
          state: :active,
          max_context_tokens: nil
        })

      content = Enum.map_join(1..10_000, " ", fn i -> "word#{i}" end)

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => content}]
      }

      assert {:ok, _canonical, returned_model} = ChatOrchestrator.prepare(params, [])
      assert returned_model.max_context_tokens == nil
    end

    test "rejects tool-calling requests for models without tool_calling capability" do
      model =
        ModelRequestFixtures.create_model!(%{
          model_id: "test/no-tool-capability-model",
          version: "v1",
          state: :active,
          capabilities: ["chat"]
        })

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
        "tool_choice" => "auto"
      }

      assert {:error, {:tooling_not_supported, detail}} = ChatOrchestrator.prepare(params, [])
      assert detail == "#{model.model_id}@#{model.version}"
    end

    test "rejects ref-backed tool-calling requests for models without tool_calling capability" do
      create_tool!("lookup_weather", "2026-04-10")

      model =
        ModelRequestFixtures.create_model!(%{
          model_id: "test/no-tool-capability-ref-model",
          version: "v1",
          state: :active,
          capabilities: ["chat"]
        })

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "tools" => [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
        "tool_choice" => "auto"
      }

      assert {:error, {:tooling_not_supported, detail}} = ChatOrchestrator.prepare(params, [])
      assert detail == "#{model.model_id}@#{model.version}"
    end

    test "accepts tool_choice none for ref-backed tools on models without tool_calling capability" do
      weather =
        create_tool!("lookup_weather", "2026-04-10", %{
          execution_mode: :server_hostable,
          source_kind: :mcp_server,
          source_ref: "mcp://weather-server/tools/lookup_weather"
        })

      model =
        ModelRequestFixtures.create_model!(%{
          model_id: "test/no-tool-capability-none-model",
          version: "v1",
          state: :active,
          capabilities: ["chat"]
        })

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "tools" => [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
        "tool_choice" => "none"
      }

      assert {:ok, canonical, prepared_model} = ChatOrchestrator.prepare(params, [])
      assert prepared_model.id == model.id

      assert canonical.tooling.requested_tools == params["tools"]
      assert canonical.tooling.tools == [weather.definition]

      assert canonical.tooling.registry_snapshot == %{
               entries: [
                 %{
                   "tool_id" => weather.id,
                   "ref" => "tool://lookup_weather@2026-04-10",
                   "name" => "lookup_weather",
                   "version" => "2026-04-10",
                   "execution_mode" => "server_hostable",
                   "source_kind" => "mcp_server",
                   "source_ref" => "mcp://weather-server/tools/lookup_weather"
                 }
               ]
             }

      assert canonical.tooling.execution_snapshot == %{entries: []}
    end

    test "attaches ordered execution semantics after resolving mixed tools" do
      docs =
        create_tool!("lookup_docs", "2026-04-11", %{
          execution_mode: :server_hostable,
          source_kind: :mcp_server,
          source_ref: "mcp://docs-server/tools/lookup_docs"
        })

      executable = write_tokenizer_executable!()
      on_exit(fn -> File.rm(executable) end)

      model =
        ModelRequestFixtures.create_model!(%{
          model_id: "test/tool-semantics-model",
          version: "v1",
          state: :active,
          capabilities: ["chat", "tool_calling"],
          artifact_uri: "file://#{fixture_bundle_path()}",
          artifact_source_uri: "file://#{fixture_bundle_path()}"
        })

      inline = %{
        "type" => "function",
        "function" => %{
          "name" => "lookup_weather",
          "description" => "Lookup weather.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}}
          }
        }
      }

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "tools" => [inline, %{"type" => "function", "ref" => "tool://lookup_docs@2026-04-11"}],
        "tool_choice" => "auto"
      }

      with_inference_overrides([tokenizer_mode: :port, tokenizer_executable: executable], fn ->
        assert {:ok, canonical, _prepared_model} = ChatOrchestrator.prepare(params, [])

        assert canonical.tooling.requested_tools == params["tools"]
        assert canonical.tooling.tools == [inline, docs.definition]

        assert canonical.tooling.registry_snapshot == %{
                 entries: [
                   %{
                     "tool_id" => docs.id,
                     "ref" => "tool://lookup_docs@2026-04-11",
                     "name" => "lookup_docs",
                     "version" => "2026-04-11",
                     "execution_mode" => "server_hostable",
                     "source_kind" => "mcp_server",
                     "source_ref" => "mcp://docs-server/tools/lookup_docs"
                   }
                 ]
               }

        assert canonical.tooling.execution_snapshot == %{
                 entries: [
                   %{
                     "name" => "lookup_weather",
                     "provenance" => "inline",
                     "disposition" => "client_passthrough",
                     "execution_mode" => "client_only"
                   },
                   %{
                     "name" => "lookup_docs",
                     "provenance" => "registry",
                     "disposition" => "client_passthrough",
                     "execution_mode" => "server_hostable"
                   }
                 ]
               }
      end)
    end

    test "validates refs before model resolution" do
      params = %{
        "model" => "missing-model@v1",
        "messages" => [%{"role" => "user", "content" => "Hello"}],
        "tools" => [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
        "tool_choice" => "auto"
      }

      assert {:error,
              {:validation,
               {:invalid_value, "tools",
                "tool ref tool://lookup_weather@2026-04-10 was not found or is not active"}}} =
               ChatOrchestrator.prepare(params, [])
    end
  end

  defp create_tool!(name, version, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: name,
          version: version,
          state: :active,
          definition: %{
            "type" => "function",
            "function" => %{
              "name" => name,
              "description" => "Lookup details.",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"query" => %{"type" => "string"}}
              }
            }
          },
          execution_mode: :client_only,
          source_kind: :manual,
          source_ref: nil
        },
        overrides
      )

    case Tools.create_tool(attrs) do
      {:ok, tool} -> tool
      {:error, changeset} -> raise "create_tool! failed: #{inspect(changeset.errors)}"
    end
  end
end
