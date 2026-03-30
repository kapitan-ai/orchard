defmodule Orchard.TestSupport.HuggingFaceReqStubTest do
  use ExUnit.Case, async: true

  alias Orchard.TestSupport.HuggingFaceReqStub

  describe "extract_file_path/2" do
    test "decodes slash-containing revisions" do
      request_path = "/mlx-community/test-model/resolve/refs%2Fpr%2F1/model.safetensors"

      assert HuggingFaceReqStub.extract_file_path(request_path, "refs/pr/1") ==
               "model.safetensors"
    end

    test "preserves nested file paths for encoded revisions" do
      request_path = "/mlx-community/test-model/resolve/refs%2Fpr%2F1/subdir%2Fextra.json"

      assert HuggingFaceReqStub.extract_file_path(request_path, "refs/pr/1") ==
               "subdir/extra.json"
    end
  end
end
