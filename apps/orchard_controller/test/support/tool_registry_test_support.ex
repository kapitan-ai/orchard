defmodule Orchard.TestSupport.ToolRegistryTestSupport do
  @moduledoc false

  alias Orchard.ArtifactBundle
  alias Orchard.Tools

  @fixture_bundle Path.expand("../fixtures/bundles/test-model-bundle", __DIR__)

  def fixture_bundle_path, do: @fixture_bundle

  def fixture_bundle_hash! do
    {:ok, hash} = ArtifactBundle.tree_sha256(@fixture_bundle)
    hash
  end

  def create_tool!(name, version, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: name,
          version: version,
          state: :active,
          definition: function_definition(name),
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

  def function_definition(name) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => "Lookup details.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}}
        }
      }
    }
  end

  def with_inference_overrides(overrides, fun) when is_function(fun, 0) do
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

  def write_tokenizer_executable!(
        rendered_prompt \\ "user hello orchard\nassistant",
        input_token_count \\ 3
      ) do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-port-test-#{System.unique_integer([:positive])}.sh"
      )

    payload =
      Jason.encode!(%{
        contract_version: 2,
        ok: true,
        result: %{
          rendered_prompt: rendered_prompt,
          input_token_count: input_token_count
        }
      })

    File.write!(script_path, "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '#{payload}'\n")
    File.chmod!(script_path, 0o755)
    script_path
  end
end
