defmodule Orchard.API.ErrorHelpersTest do
  use ExUnit.Case, async: true

  alias Orchard.API.ErrorHelpers

  describe "error_envelope/3" do
    test "builds OpenAI-shaped error map with all four keys" do
      envelope =
        ErrorHelpers.error_envelope("Bad request", "invalid_request_error", param: "model")

      assert envelope == %{
               error: %{
                 message: "Bad request",
                 type: "invalid_request_error",
                 param: "model",
                 code: nil
               }
             }
    end

    test "includes code when provided" do
      envelope =
        ErrorHelpers.error_envelope("Not found", "not_found_error",
          param: "model",
          code: "model_not_found"
        )

      assert envelope.error.code == "model_not_found"
      assert envelope.error.param == "model"
    end

    test "defaults param and code to nil" do
      envelope = ErrorHelpers.error_envelope("Server error", "server_error")

      assert envelope.error.param == nil
      assert envelope.error.code == nil
    end
  end
end
