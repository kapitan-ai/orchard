defmodule Orchard.TestSupport.HuggingFaceReqStubTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Orchard.TestSupport.HuggingFaceReqStub

  describe "resume_download/2" do
    test "respects the Range header" do
      conn =
        :get
        |> conn("/mlx-community/test-model/resolve/main/model.safetensors")
        |> Map.put(:req_headers, [{"range", "bytes=5-"}])

      model = HuggingFaceReqStub.sample_file_contents()["model.safetensors"]
      conn = HuggingFaceReqStub.resume_download(conn, model)

      assert conn.status == 206
      assert conn.resp_body == binary_part(model, 5, byte_size(model) - 5)
    end
  end

  describe "dispatch/4" do
    test "uses route handlers with :default fallback" do
      conn =
        :get
        |> conn("/mlx-community/test-model/resolve/main/model.safetensors")
        |> Map.put(:req_headers, [{"range", "bytes=5-"}])

      file_contents = HuggingFaceReqStub.sample_file_contents()
      tree_response = HuggingFaceReqStub.tree_response(file_contents)

      model = file_contents["model.safetensors"]

      conn =
        HuggingFaceReqStub.dispatch(conn, file_contents, tree_response,
          download_handler: fn _conn, file_path, content ->
            assert file_path == "model.safetensors"
            assert content == model
            :default
          end
        )

      assert conn.status == 206
      assert conn.resp_body == binary_part(model, 5, byte_size(model) - 5)
    end
  end

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
