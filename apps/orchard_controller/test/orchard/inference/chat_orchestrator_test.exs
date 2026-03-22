defmodule Orchard.Inference.ChatOrchestratorTest do
  @moduledoc """
  Focused tests for ChatOrchestrator.prepare/2 boundary behavior.
  """
  use Orchard.DataCase, async: true

  alias Orchard.Inference.ChatOrchestrator
  alias Orchard.TestSupport.ModelRequestFixtures

  describe "prepare/2 context-window enforcement with omitted max_tokens" do
    test "rejects omitted max_tokens when prompt fills most of the context window" do
      # Model with a small context window — 100 tokens.
      model =
        ModelRequestFixtures.create_model!(%{
          model_id: "test/small-context-model",
          version: "v1",
          state: :active,
          max_context_tokens: 100
        })

      # In fake tokenizer mode, token count = whitespace-word count of the
      # prompt lines. One user message becomes "user <content>\nassistant".
      # 98 words of content + "user" + "assistant" = 100 input tokens.
      content = Enum.map_join(1..98, " ", fn i -> "word#{i}" end)

      params = %{
        "model" => "#{model.model_id}@#{model.version}",
        "messages" => [%{"role" => "user", "content" => content}]
        # max_tokens intentionally omitted
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
        # max_tokens intentionally omitted
      }

      assert {:ok, canonical, _model} = ChatOrchestrator.prepare(params, [])
      # Canonical preserves nil — the default is applied at orchestration time only
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
  end
end
