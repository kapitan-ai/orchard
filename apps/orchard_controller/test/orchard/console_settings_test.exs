defmodule Orchard.ConsoleSettingsTest do
  use Orchard.DataCase, async: false

  alias Orchard.ConsoleSettings
  alias Orchard.Inference.SamplingValidation

  @playground_defaults_key "playground_defaults"

  describe "get_playground_defaults/0" do
    test "returns built-in playground defaults when no setting is saved" do
      assert %{
               default_model: nil,
               temperature: nil,
               top_p: nil,
               max_completion_tokens: nil
             } = ConsoleSettings.get_playground_defaults()
    end

    test "normalizes malformed saved JSON to safe defaults" do
      insert_raw_playground_defaults(%{
        "default_model" => 123,
        "temperature" => "0.7",
        "top_p" => 0.9,
        "max_completion_tokens" => nil,
        "unknown" => "ignored"
      })

      assert %{
               default_model: nil,
               temperature: nil,
               top_p: 0.9,
               max_completion_tokens: nil
             } = ConsoleSettings.get_playground_defaults()
    end

    test "drops overlong saved default model ids while normalizing raw values" do
      insert_raw_playground_defaults(%{"default_model" => String.duplicate("m", 257)})

      assert %{
               default_model: nil,
               temperature: nil,
               top_p: nil,
               max_completion_tokens: nil
             } = ConsoleSettings.get_playground_defaults()
    end
  end

  describe "save_playground_defaults/1" do
    test "casts form strings before validation and persists native values" do
      assert {:ok,
              %{
                default_model: nil,
                temperature: 0.7,
                top_p: 0.95,
                max_completion_tokens: 256
              }} =
               ConsoleSettings.save_playground_defaults(%{
                 "default_model" => "",
                 "temperature" => "0.7",
                 "top_p" => "0.95",
                 "max_completion_tokens" => "256"
               })

      assert %{
               default_model: nil,
               temperature: 0.7,
               top_p: 0.95,
               max_completion_tokens: 256
             } = ConsoleSettings.get_playground_defaults()
    end

    test "persists a default model id" do
      assert {:ok, %{default_model: "mlx-community/example-model"}} =
               ConsoleSettings.save_playground_defaults(%{
                 "default_model" => "mlx-community/example-model"
               })

      assert %{
               default_model: "mlx-community/example-model",
               temperature: nil,
               top_p: nil,
               max_completion_tokens: nil
             } = ConsoleSettings.get_playground_defaults()
    end

    test "trims default model ids before persisting" do
      assert {:ok, %{default_model: "mlx-community/example-model"}} =
               ConsoleSettings.save_playground_defaults(%{
                 "default_model" => "  mlx-community/example-model\n"
               })

      assert %{
               default_model: "mlx-community/example-model",
               temperature: nil,
               top_p: nil,
               max_completion_tokens: nil
             } = ConsoleSettings.get_playground_defaults()

      assert [[1, %{"default_model" => "mlx-community/example-model"}]] =
               select_playground_defaults_count_and_value()
    end

    test "treats whitespace-only default model ids as unset" do
      assert {:ok, %{default_model: nil}} =
               ConsoleSettings.save_playground_defaults(%{"default_model" => "  \n\t  "})

      assert %{
               default_model: nil,
               temperature: nil,
               top_p: nil,
               max_completion_tokens: nil
             } = ConsoleSettings.get_playground_defaults()

      assert [[1, %{}]] = select_playground_defaults_count_and_value()
    end

    test "accepts trimmed default model ids at the max length" do
      model_id = String.duplicate("m", 256)

      assert {:ok, %{default_model: ^model_id}} =
               ConsoleSettings.save_playground_defaults(%{"default_model" => "  #{model_id}\n"})

      assert %{default_model: ^model_id} = ConsoleSettings.get_playground_defaults()
      assert [[1, %{"default_model" => ^model_id}]] = select_playground_defaults_count_and_value()
    end

    test "rejects overlong default model ids" do
      assert {:error, changeset} =
               ConsoleSettings.save_playground_defaults(%{
                 "default_model" => String.duplicate("m", 257)
               })

      assert %{default_model: ["should be at most 256 character(s)"]} = errors_on(changeset)
      assert [] = select_playground_defaults_count_and_value()
    end

    test "upserts the playground defaults row" do
      assert {:ok, %{temperature: 0.2}} =
               ConsoleSettings.save_playground_defaults(%{"temperature" => "0.2"})

      assert {:ok, %{temperature: 0.4, top_p: 0.8}} =
               ConsoleSettings.save_playground_defaults(%{
                 "temperature" => "0.4",
                 "top_p" => "0.8",
                 "unknown" => "ignored"
               })

      assert [[1, %{"temperature" => 0.4, "top_p" => 0.8}]] =
               select_playground_defaults_count_and_value()
    end

    test "returns form errors for unparseable string values" do
      assert {:error, changeset} =
               ConsoleSettings.save_playground_defaults(%{"temperature" => "abc"})

      assert %{temperature: ["is invalid"]} = errors_on(changeset)
    end

    test "returns shared validation errors after casting form strings" do
      assert {:error, top_p_changeset} =
               ConsoleSettings.save_playground_defaults(%{"top_p" => "2"})

      assert %{top_p: ["must be between 0 (exclusive) and 1 (inclusive)"]} =
               errors_on(top_p_changeset)

      assert {:error, max_tokens_changeset} =
               ConsoleSettings.save_playground_defaults(%{"max_completion_tokens" => "0"})

      assert %{max_completion_tokens: ["must be a positive integer"]} =
               errors_on(max_tokens_changeset)
    end
  end

  test "shared sampling validation keeps its native-numeric contract" do
    assert {:error, :invalid_value, "temperature", "must be a non-negative number"} =
             SamplingValidation.validate_temperature(%{"temperature" => "0.7"})

    assert {:error, :invalid_value, "max_completion_tokens", "must be a positive integer"} =
             SamplingValidation.validate_positive_integer("256", "max_completion_tokens")
  end

  defp insert_raw_playground_defaults(value) do
    Repo.query!(
      """
      INSERT INTO console_settings (key, value, inserted_at, updated_at)
      VALUES ($1, $2::jsonb, NOW(), NOW())
      """,
      [@playground_defaults_key, value]
    )
  end

  defp select_playground_defaults_count_and_value do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT COUNT(*), value
        FROM console_settings
        WHERE key = $1
        GROUP BY value
        """,
        [@playground_defaults_key]
      )

    rows
  end
end
