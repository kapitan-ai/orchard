defmodule Orchard.Inference.ResponsesRequestNormalizerTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.Inference.ResponsesRequestNormalizer

  test "normalizes string input into a responses canonical request" do
    {:ok, %CanonicalRequest{} = request} =
      ResponsesRequestNormalizer.normalize(
        %{
          "model" => "test-model@v1",
          "input" => "Hello",
          "max_output_tokens" => 128,
          "metadata" => nil
        },
        tenant_id: "tenant-1",
        principal_id: "principal-1",
        api_key_id: "api-key-1",
        internal_id: "internal-1",
        public_id: "resp_123"
      )

    assert request.endpoint == :responses
    assert request.internal_id == "internal-1"
    assert request.public_id == "resp_123"
    assert request.tenant_id == "tenant-1"
    assert request.principal_id == "principal-1"
    assert request.api_key_id == "api-key-1"
    assert request.model_ref == %ModelRef{model_id: "test-model", version: "v1"}
    assert request.input_items == [%{"role" => "user", "content" => "Hello"}]
    assert request.sampling.max_output_tokens == 128
    assert request.metadata == %{}
  end

  test "prepends instructions as a system message and rewrites input_text parts" do
    {:ok, request} =
      ResponsesRequestNormalizer.normalize(%{
        "model" => "test-model@v1",
        "instructions" => "Be helpful",
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "Hello"}]
          }
        ],
        "temperature" => 0.5,
        "top_p" => 0.8,
        "metadata" => %{"trace" => "abc"}
      })

    assert request.endpoint == :responses

    assert request.input_items == [
             %{"role" => "system", "content" => "Be helpful"},
             %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "Hello"}]
             }
           ]

    assert request.sampling.temperature == 0.5
    assert request.sampling.top_p == 0.8
    assert request.metadata == %{"trace" => "abc"}
  end
end
