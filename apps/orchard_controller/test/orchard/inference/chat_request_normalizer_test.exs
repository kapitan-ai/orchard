defmodule Orchard.Inference.ChatRequestNormalizerTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.{ModelRef, ResponseFormat, Sampling, Tooling}
  alias Orchard.Governance
  alias Orchard.Inference.ChatRequestNormalizer

  @valid_params %{
    "model" => "llama-3.1-8b-instruct@mlx-q4-v1",
    "messages" => [
      %{"role" => "user", "content" => "Hello"}
    ]
  }

  describe "normalize/2" do
    test "produces a CanonicalRequest from minimal params" do
      assert {:ok, %CanonicalRequest{} = req} = ChatRequestNormalizer.normalize(@valid_params)

      assert req.endpoint == :chat_completions
      assert req.tenant_id == Governance.legacy_tenant_id()
      assert req.model_ref == %ModelRef{model_id: "llama-3.1-8b-instruct", version: "mlx-q4-v1"}
      assert req.input_items == [%{"role" => "user", "content" => "Hello"}]
      assert req.stream? == false
      assert req.sampling == %Sampling{temperature: 1.0, top_p: 1.0}
      assert req.response_format == %ResponseFormat{type: :text}
      assert req.tooling == %Tooling{tools: [], tool_choice: nil}
      assert req.metadata == %{}
      assert String.starts_with?(req.public_id, "chatcmpl-")
      assert is_binary(req.internal_id) and req.internal_id != ""
    end

    test "parses model without version as model_id with default version" do
      params = %{@valid_params | "model" => "my-model"}
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.model_ref == %ModelRef{model_id: "my-model", version: "default"}
    end

    test "normalizes max_tokens to sampling.max_output_tokens" do
      params = Map.put(@valid_params, "max_tokens", 256)
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.sampling.max_output_tokens == 256
    end

    test "normalizes max_completion_tokens to sampling.max_output_tokens" do
      params = Map.put(@valid_params, "max_completion_tokens", 512)
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.sampling.max_output_tokens == 512
    end

    test "normalizes stop string to single-element list" do
      params = Map.put(@valid_params, "stop", "\n")
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.sampling.stop == ["\n"]
    end

    test "preserves stop array" do
      params = Map.put(@valid_params, "stop", ["\n", "END"])
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.sampling.stop == ["\n", "END"]
    end

    test "normalizes response_format json_object" do
      params = Map.put(@valid_params, "response_format", %{"type" => "json_object"})
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.response_format == %ResponseFormat{type: :json_object}
    end

    test "carries stream flag" do
      params = Map.put(@valid_params, "stream", true)
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.stream? == true
    end

    test "carries tools and tool_choice" do
      tools = [%{"type" => "function", "function" => %{"name" => "f"}}]
      params = Map.merge(@valid_params, %{"tools" => tools, "tool_choice" => "auto"})
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.tooling.tools == tools
      assert req.tooling.tool_choice == "auto"
    end

    test "carries seed" do
      params = Map.put(@valid_params, "seed", 42)
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.sampling.seed == 42
    end

    test "carries metadata" do
      params = Map.put(@valid_params, "metadata", %{"request_id" => "abc"})
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.metadata == %{"request_id" => "abc"}
    end

    test "normalizes nil metadata to an empty map" do
      params = Map.put(@valid_params, "metadata", nil)
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.metadata == %{}
    end

    test "accepts overridden IDs" do
      {:ok, req} =
        ChatRequestNormalizer.normalize(@valid_params,
          internal_id: "my-id",
          public_id: "chatcmpl-custom",
          tenant_id: "tenant-1"
        )

      assert req.internal_id == "my-id"
      assert req.public_id == "chatcmpl-custom"
      assert req.tenant_id == "tenant-1"
    end

    test "normalizes integer temperature to float" do
      params = Map.put(@valid_params, "temperature", 1)
      {:ok, req} = ChatRequestNormalizer.normalize(params)
      assert req.sampling.temperature == 1.0
      assert is_float(req.sampling.temperature)
    end
  end
end
