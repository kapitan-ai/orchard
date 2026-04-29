defmodule Orchard.Tokenizer.ControlTokenDetectorTest do
  use ExUnit.Case, async: true

  alias Orchard.Tokenizer.ControlTokenDetector

  test "partial_catalog extracts special added tokens and tokenizer_config special tokens" do
    fixture_root =
      write_tokenizer_fixture!(
        %{
          "added_tokens" => [
            %{"content" => "<|im_start|>", "special" => true},
            %{"content" => "ordinary_added_token", "special" => false},
            %{"content" => "<|im_end|>", "special" => true}
          ]
        },
        %{
          "bos_token" => "<s>",
          "eos_token" => %{"content" => "</s>"},
          "additional_special_tokens" => ["<extra_a>", %{"content" => "<extra_b>"}]
        }
      )

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    assert {:ok, catalog, []} =
             ControlTokenDetector.partial_catalog(Path.join(fixture_root, "tokenizer.json"))

    assert catalog ==
             Enum.sort(["<|im_start|>", "<|im_end|>", "<s>", "</s>", "<extra_a>", "<extra_b>"])
  end

  test "partial_catalog ignores non-special tokenizer added tokens" do
    fixture_root =
      write_tokenizer_fixture!(
        %{
          "added_tokens" => [
            %{"content" => "ordinary_added_token", "special" => false},
            %{"content" => "missing_special_flag"}
          ]
        },
        %{"additional_special_tokens" => ["<extra_a>"]}
      )

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    assert {:ok, ["<extra_a>"], []} =
             ControlTokenDetector.partial_catalog(Path.join(fixture_root, "tokenizer.json"))
  end

  test "detect returns provenance, literal, and byte offset for catalog hits" do
    catalog = ["<|im_start|>", "</s>"]
    caller_strings = [{"messages[0].content", "a<|im_start|> b </s>"}]

    assert ControlTokenDetector.detect(catalog, caller_strings) == [
             {"messages[0].content", "<|im_start|>", 1},
             {"messages[0].content", "</s>", 16}
           ]
  end

  test "partial_catalog preserves tokenizer added tokens when tokenizer_config is malformed" do
    fixture_root =
      write_tokenizer_fixture!(
        %{"added_tokens" => [%{"content" => "<|im_start|>", "special" => true}]},
        :malformed_config
      )

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    assert {:ok, ["<|im_start|>"], diagnostics} =
             ControlTokenDetector.partial_catalog(Path.join(fixture_root, "tokenizer.json"))

    assert [{:tokenizer_config, reason}] = diagnostics
    assert inspect(reason) =~ "invalid_json"
    refute inspect(reason) =~ "NOT JSON"
  end

  test "partial_catalog skips escaped tokenizer_config without suppressing tokenizer added tokens" do
    parent_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-detector-escape-test-#{System.unique_integer([:positive])}"
      )

    fixture_root = Path.join(parent_dir, "bundle")
    outside_root = Path.join(parent_dir, "outside")

    File.mkdir_p!(fixture_root)
    File.mkdir_p!(outside_root)

    File.write!(
      Path.join(fixture_root, "tokenizer.json"),
      Jason.encode!(%{"added_tokens" => [%{"content" => "<|im_start|>", "special" => true}]})
    )

    outside_config = Path.join(outside_root, "tokenizer_config.json")

    File.write!(
      outside_config,
      Jason.encode!(%{"additional_special_tokens" => ["<outside_secret>"]})
    )

    File.ln_s!(outside_config, Path.join(fixture_root, "tokenizer_config.json"))

    on_exit(fn -> File.rm_rf!(parent_dir) end)

    assert {:ok, ["<|im_start|>"], diagnostics} =
             ControlTokenDetector.partial_catalog(Path.join(fixture_root, "tokenizer.json"))

    assert diagnostics == [
             {:tokenizer_config, {:asset_escapes_tokenizer_root, "tokenizer_config.json"}}
           ]
  end

  defp write_tokenizer_fixture!(tokenizer_json, tokenizer_config) do
    fixture_root =
      Path.join(System.tmp_dir!(), "orchard-detector-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fixture_root)
    File.write!(Path.join(fixture_root, "tokenizer.json"), Jason.encode!(tokenizer_json))

    case tokenizer_config do
      :malformed_config ->
        File.write!(Path.join(fixture_root, "tokenizer_config.json"), "NOT JSON")

      config ->
        File.write!(Path.join(fixture_root, "tokenizer_config.json"), Jason.encode!(config))
    end

    fixture_root
  end
end
