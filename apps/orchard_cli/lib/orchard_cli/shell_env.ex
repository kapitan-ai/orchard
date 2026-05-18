defmodule OrchardCLI.ShellEnv do
  @moduledoc false

  @type assignment :: {String.t(), String.t()}

  @control_chars Enum.map(0..31, &<<&1>>) ++ [<<127>>]
  @key_pattern ~r/^[A-Z][A-Z0-9_]*$/

  @spec shell_quote(String.t()) :: String.t()
  def shell_quote(value) when is_binary(value) do
    case validate_value(value) do
      :ok -> quote_valid_value(value)
      {:error, message} -> raise ArgumentError, message
    end
  end

  @spec validate_value(String.t()) :: :ok | {:error, String.t()}
  def validate_value(value) when is_binary(value) do
    if String.contains?(value, @control_chars) do
      {:error, "env value contains newline or NUL/control characters"}
    else
      :ok
    end
  end

  @spec write_file(String.t(), String.t()) :: :ok
  def write_file(target_path, content) when is_binary(target_path) and is_binary(content) do
    target_path
    |> atomic_write(content, 0o600)
    |> raise_on_file_error(target_path)
  end

  @spec upsert(String.t(), [assignment()]) :: :ok | {:error, String.t()}
  def upsert(target_path, assignments) when is_binary(target_path) and is_list(assignments) do
    with {:ok, rendered} <- render_assignments(assignments),
         {:ok, current} <- read_existing(target_path),
         content <- upsert_content(current, rendered),
         :ok <- atomic_write(target_path, content, 0o600) do
      :ok
    else
      {:error, %File.Error{} = error} -> {:error, Exception.message(error)}
      {:error, reason} when is_atom(reason) -> {:error, :file.format_error(reason)}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  defp quote_valid_value(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("$", "\\$")
      |> String.replace("`", "\\`")

    "\"#{escaped}\""
  end

  defp render_assignments(assignments) do
    Enum.reduce_while(assignments, {:ok, []}, fn {key, value}, {:ok, acc} ->
      with :ok <- validate_key(key),
           :ok <- validate_value(value) do
        {:cont, {:ok, [{key, "#{key}=#{shell_quote(value)}"} | acc]}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      {:error, message} -> {:error, message}
    end
  end

  defp validate_key(key) when is_binary(key) do
    if Regex.match?(@key_pattern, key) do
      :ok
    else
      {:error, "invalid env key: #{inspect(key)}"}
    end
  end

  defp validate_key(key), do: {:error, "invalid env key: #{inspect(key)}"}

  defp read_existing(target_path) do
    case File.read(target_path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_content(current, rendered) do
    render_by_key = Map.new(rendered)
    keys = MapSet.new(Map.keys(render_by_key))

    {lines, seen} =
      current
      |> split_lines()
      |> Enum.reduce({[], MapSet.new()}, fn line, {acc, seen} ->
        upsert_line(line, keys, render_by_key, acc, seen)
      end)

    missing =
      rendered
      |> Enum.reject(fn {key, _line} -> MapSet.member?(seen, key) end)
      |> Enum.map(fn {_key, line} -> line end)

    lines
    |> Enum.reverse()
    |> append_missing(missing)
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

  defp upsert_line(line, keys, render_by_key, acc, seen) do
    case active_assignment_key(line, keys) do
      nil -> {[line | acc], seen}
      key -> upsert_assignment_line(key, line, render_by_key, acc, seen)
    end
  end

  defp upsert_assignment_line(key, line, render_by_key, acc, seen) do
    if MapSet.member?(seen, key) do
      {acc, seen}
    else
      replacement = Map.get(render_by_key, key, line)
      {[replacement | acc], MapSet.put(seen, key)}
    end
  end

  defp split_lines(""), do: []

  defp split_lines(content) do
    case String.split(content, "\n", trim: false) do
      [] -> []
      lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    end
  end

  defp active_assignment_key(line, keys) do
    trimmed = String.trim_leading(line)

    if String.starts_with?(trimmed, "#") do
      nil
    else
      Enum.find(keys, fn key -> Regex.match?(~r/^#{Regex.escape(key)}\s*=/, trimmed) end)
    end
  end

  defp append_missing(lines, []), do: lines
  defp append_missing([], missing), do: missing
  defp append_missing(lines, missing), do: lines ++ [""] ++ missing

  defp ensure_trailing_newline(content), do: String.trim_trailing(content, "\n") <> "\n"

  defp atomic_write(target_path, content, mode) do
    dir = Path.dirname(target_path)

    tmp_path =
      Path.join(dir, ".#{Path.basename(target_path)}.#{System.unique_integer([:positive])}.tmp")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp_path, content),
         :ok <- File.chmod(tmp_path, mode),
         :ok <- File.rename(tmp_path, target_path),
         :ok <- File.chmod(target_path, mode) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(tmp_path)
        if reason in [:enoent, :eacces], do: error, else: {:error, reason}
    end
  end

  defp raise_on_file_error(:ok, _target_path), do: :ok

  defp raise_on_file_error({:error, reason}, target_path) do
    raise File.Error, reason: reason, action: "write file", path: target_path
  end
end
