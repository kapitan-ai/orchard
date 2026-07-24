defmodule Orchard.ProductVersion do
  @moduledoc false

  @version_path Path.expand("../VERSION", __DIR__)
  @version_pattern ~r/\A0\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-dev|-rc\.[1-9][0-9]*)?\z/
  @invalid_message "VERSION must contain exactly one ASCII SemVer line followed by one terminal newline"

  @spec read!() :: String.t()
  def read! do
    case File.read(@version_path) do
      {:ok, contents} ->
        validate!(contents)

      {:error, reason} ->
        raise ArgumentError, "VERSION could not be read: #{:file.format_error(reason)}"
    end
  end

  defp validate!(contents) do
    with true <- String.ends_with?(contents, "\n"),
         version <- binary_part(contents, 0, byte_size(contents) - 1),
         true <- ascii?(version),
         true <- Regex.match?(@version_pattern, version) do
      version
    else
      _invalid -> raise ArgumentError, @invalid_message
    end
  end

  defp ascii?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 < 128))
  end
end
