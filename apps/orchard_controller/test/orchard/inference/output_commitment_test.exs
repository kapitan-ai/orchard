defmodule Orchard.Inference.OutputCommitmentTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.OutputCommitment
  alias Orchard.InferenceEvent
  alias Orchard.InferenceEvent.Usage

  test "SPEC 5.8 classifies validated output monotonically without owning time" do
    control_events = [
      InferenceEvent.accepted(1),
      InferenceEvent.progress("loading", "readying model"),
      InferenceEvent.usage_update(%Usage{input_tokens: 1, output_tokens: 0, total_tokens: 1}),
      InferenceEvent.completed(:finish_reason_stop, nil),
      InferenceEvent.failed("runtime_unavailable", "worker unavailable", true),
      InferenceEvent.output_text_delta("")
    ]

    uncommitted =
      Enum.reduce(control_events, OutputCommitment.new(), fn event, commitment ->
        OutputCommitment.observe(commitment, event)
      end)

    refute OutputCommitment.committed?(uncommitted)
    assert OutputCommitment.kind(uncommitted) == nil
    refute Map.has_key?(uncommitted, :committed_at)
    refute Map.has_key?(uncommitted, :first_token_at)

    text = OutputCommitment.observe(uncommitted, InferenceEvent.output_text_delta("   "))
    assert OutputCommitment.committed?(text)
    assert OutputCommitment.kind(text) == :text

    assert text ==
             OutputCommitment.observe(
               text,
               InferenceEvent.tool_call_delta("call-later", "{")
             )

    for arguments <- ["", "{", "not json"] do
      tool =
        OutputCommitment.observe(
          OutputCommitment.new(),
          InferenceEvent.tool_call_delta("call-stable", arguments)
        )

      assert OutputCommitment.committed?(tool)
      assert OutputCommitment.kind(tool) == :tool_call
    end

    assert_raise ArgumentError, fn -> InferenceEvent.tool_call_delta("", "{}") end
  end

  test "SPEC 5.8 commits future structured output only when the delta carries content" do
    uncommitted = OutputCommitment.new()

    assert uncommitted == OutputCommitment.observe_structured_output(uncommitted, "")

    committed = OutputCommitment.observe_structured_output(uncommitted, "{")
    assert OutputCommitment.committed?(committed)
    assert OutputCommitment.kind(committed) == :structured_output

    assert committed == OutputCommitment.observe_structured_output(committed, "ignored")
  end
end
