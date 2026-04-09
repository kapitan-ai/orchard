defmodule Orchard.Tokenizer.ClientTest do
  use ExUnit.Case, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.{ChatTemplate, RuntimeRequirements, Tokenizer}
  alias Orchard.Tokenizer.Client

  setup do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous_inference)
    end)

    :ok
  end

  test "fake mode renders a deterministic prompt and token count" do
    request = canonical_request()

    assert {:ok,
            %{
              rendered_prompt: "system orchard\nuser hello orchard\nassistant",
              input_token_count: 6
            }} = Client.tokenize(request)
  end

  test "fake mode returns invalid_input for malformed content parts" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal_tokenizer_invalid",
        public_id: "req_tokenizer_invalid",
        endpoint: :chat_completions,
        tenant_id: "tenant_test",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        input_items: [
          %{role: "user", content: ["not-a-map"]}
        ]
      })

    assert {:error, {:invalid_input, message}} = Client.tokenize(request)
    assert message =~ "text parts"
  end

  test "fake mode rejects effective tool-calling requests" do
    assert {:error, {:invalid_input, message}} =
             Client.tokenize(
               canonical_request(tooling: %{tools: [tool("lookup_weather")], tool_choice: "auto"})
             )

    assert message =~ "does not support tool-calling"
  end

  test "port mode returns rendered prompt and exact token count from structured JSON" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        request = canonical_request()

        assert {:ok,
                %{
                  rendered_prompt: "system orchard\nuser hello orchard\nassistant",
                  input_token_count: 6
                }} =
                 Client.tokenize(request,
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root()
                 )
      end
    )
  end

  test "port mode forwards tools and tool_choice into template context" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        request =
          canonical_request(
            tooling: %{
              tools: [tool("lookup_weather")],
              tool_choice: %{"type" => "function", "function" => %{"name" => "lookup_weather"}}
            }
          )

        assert {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}} =
                 Client.tokenize(request,
                   manifest: tools_template_manifest(),
                   bundle_root: huggingface_fixture_root()
                 )

        assert rendered_prompt =~ "tools_defined=True tools_len=1 tool_choice_is_none=False"
        assert rendered_prompt =~ "tool lookup_weather"
        assert is_integer(input_token_count)
        assert input_token_count > 0
      end
    )
  end

  test "port mode maps missing tokenizer assets to a stable error category" do
    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        request = canonical_request()

        assert {:error, {:missing_assets, message}} =
                 Client.tokenize(request,
                   manifest: missing_asset_manifest(),
                   bundle_root: huggingface_fixture_root()
                 )

        assert message =~ "tokenizer"
      end
    )
  end

  test "port mode returns unavailable when the executable is missing" do
    missing_executable = Path.join(System.tmp_dir!(), "orchard-tokenizer-missing")

    with_inference_overrides(
      [tokenizer_mode: :port, tokenizer_executable: missing_executable],
      fn ->
        assert {:error, :unavailable} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root()
                 )
      end
    )
  end

  test "port mode returns timeout when the executable does not finish in time" do
    slow_executable = write_sleeping_executable!()

    on_exit(fn ->
      File.rm(slow_executable)
    end)

    with_inference_overrides([tokenizer_mode: :port, tokenizer_executable: slow_executable], fn ->
      assert {:error, :timeout} =
               Client.tokenize(canonical_request(),
                 manifest: huggingface_manifest(),
                 bundle_root: huggingface_fixture_root(),
                 timeout_ms: 25
               )
    end)
  end

  test "port mode returns missing_assets when manifest tokenizer metadata is incomplete" do
    malformed_manifest = %{huggingface_manifest() | tokenizer: nil}

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        assert {:error, {:missing_assets, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: malformed_manifest,
                   bundle_root: huggingface_fixture_root()
                 )

        assert message =~ "tokenizer"
      end
    )
  end

  test "port mode rejects manifest without chat_template" do
    no_chat_template_manifest = %{huggingface_manifest() | chat_template: nil}

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        assert {:error, {:missing_assets, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: no_chat_template_manifest,
                   bundle_root: huggingface_fixture_root()
                 )

        assert message =~ "chat_template"
      end
    )
  end

  test "fake mode still succeeds without chat_template in manifest" do
    # Fake mode does not use manifest assets, so missing chat_template is fine
    assert {:ok,
            %{
              rendered_prompt: "system orchard\nuser hello orchard\nassistant",
              input_token_count: 6
            }} = Client.tokenize(canonical_request())
  end

  test "port mode rejects malformed executable output" do
    malformed_executable = write_malformed_executable!()

    on_exit(fn ->
      File.rm(malformed_executable)
    end)

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: malformed_executable
      ],
      fn ->
        assert {:error, :invalid_response} =
                 Client.tokenize(canonical_request(),
                   manifest: huggingface_manifest(),
                   bundle_root: huggingface_fixture_root()
                 )
      end
    )
  end

  test "port mode rejects symlinked assets that escape bundle_root" do
    # Create isolated temp directory with two siblings:
    # parent/
    #   bundle/        <- bundle_root
    #     tokenizer.json -> ../outside/tokenizer.json  (symlink escape)
    #     chat_template.jinja  (normal file)
    #   outside/
    #     tokenizer.json  (real file, outside bundle_root)
    parent_dir =
      Path.join(System.tmp_dir!(), "orchard-symlink-test-#{System.unique_integer([:positive])}")

    bundle_dir = Path.join(parent_dir, "bundle")
    outside_dir = Path.join(parent_dir, "outside")

    File.mkdir_p!(bundle_dir)
    File.mkdir_p!(outside_dir)

    on_exit(fn -> File.rm_rf!(parent_dir) end)

    # Create real tokenizer file outside bundle_root
    outside_tokenizer = Path.join(outside_dir, "tokenizer.json")
    File.write!(outside_tokenizer, "{\"model_type\": \"escaped\"}")

    # Create symlink inside bundle_root pointing outside
    symlink_path = Path.join(bundle_dir, "tokenizer.json")
    File.ln_s!(outside_tokenizer, symlink_path)

    # Create normal chat_template inside bundle_root
    File.write!(Path.join(bundle_dir, "chat_template.jinja"), "{{ content }}")

    with_inference_overrides(
      [
        tokenizer_mode: :port,
        tokenizer_executable: tokenizer_executable()
      ],
      fn ->
        manifest = huggingface_manifest()

        assert {:error, {:invalid_input, message}} =
                 Client.tokenize(canonical_request(),
                   manifest: manifest,
                   bundle_root: bundle_dir
                 )

        assert message =~ "escapes bundle_root"
      end
    )
  end

  defp with_inference_overrides(overrides, fun) when is_function(fun, 0) do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous_inference, overrides)
    )

    try do
      fun.()
    after
      Application.put_env(:orchard_controller, :inference, previous_inference)
    end
  end

  defp canonical_request(overrides \\ %{}) do
    base = %{
      internal_id: "req_internal_tokenizer_test",
      public_id: "req_tokenizer_test",
      endpoint: :chat_completions,
      tenant_id: "tenant_test",
      model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
      input_items: [
        %{role: "system", content: "orchard"},
        %{role: "user", content: [%{type: "text", text: "hello orchard"}]}
      ]
    }

    CanonicalRequest.new(Map.merge(base, Map.new(overrides)))
  end

  defp huggingface_manifest do
    manifest_with_chat_template("chat_template.jinja")
  end

  defp tools_template_manifest do
    manifest_with_chat_template("chat_template_tools.jinja")
  end

  defp manifest_with_chat_template(chat_template_path) do
    ModelManifest.new(%{
      model_id: "mlx-community/phi-3",
      version: "main",
      format: "mlx",
      artifact_layout: "directory",
      entrypoint: "weights/",
      sha256: String.duplicate("a", 64),
      max_context_tokens: 32_768,
      capabilities: ["chat"],
      tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
      chat_template: %ChatTemplate{
        path: chat_template_path,
        sha256: String.duplicate("b", 64)
      },
      runtime_requirements: %RuntimeRequirements{
        adapter: "mlx_lm",
        min_agent_capability: "mlx"
      }
    })
  end

  defp missing_asset_manifest do
    ModelManifest.new(%{
      model_id: "mlx-community/phi-3",
      version: "main",
      format: "mlx",
      artifact_layout: "directory",
      entrypoint: "weights/",
      sha256: String.duplicate("a", 64),
      max_context_tokens: 32_768,
      capabilities: ["chat"],
      tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "missing-tokenizer.json"},
      chat_template: %ChatTemplate{
        path: "chat_template.jinja",
        sha256: String.duplicate("b", 64)
      },
      runtime_requirements: %RuntimeRequirements{
        adapter: "mlx_lm",
        min_agent_capability: "mlx"
      }
    })
  end

  defp huggingface_fixture_root do
    Path.expand("../fixtures/tokenizer/minimal_hf", __DIR__)
  end

  defp tokenizer_executable do
    Client.executable()
  end

  defp write_sleeping_executable! do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-sleeping-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(script_path, "#!/bin/sh\nsleep 1\n")
    File.chmod!(script_path, 0o755)
    script_path
  end

  defp tool(name) do
    %{"type" => "function", "function" => %{"name" => name}}
  end

  defp write_malformed_executable! do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-malformed-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(script_path, "#!/bin/sh\necho not-json\n")
    File.chmod!(script_path, 0o755)
    script_path
  end
end
