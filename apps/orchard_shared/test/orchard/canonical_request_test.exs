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
