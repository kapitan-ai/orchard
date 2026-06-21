defmodule OrchardConsole.Redaction do
  @moduledoc """
  Shared redaction helpers for Console log and error-message boundaries.
  """

  @bearer_header_pattern ~r/(?i)(authorization\s*[:=]\s*)(?:"|\[")?bearer\s+\S+/
  @authorization_kv_pattern ~r/(?i)(authorization\s*[:=]\s*)"[^"]*"/
  @authorization_header_value_pattern ~r/(?i)\b((?:proxy-)?authorization\s*[:=])(?!\s*(?:"|\[")?bearer\b)\s*(?:"[^"]*"|[^;,\n\r]+)/
  @authorization_arrow_value_pattern ~r/(?i)(("?(?:proxy-)?authorization"?\s*=>\s*))"[^"]*"/
  @authorization_tuple_value_pattern ~r/(?i)((?:\{|, )\:?"?(?:proxy-)?authorization"?\s*,\s*)"[^"]*"/
  @bare_bearer_pattern ~r/(?i)\bbearer\s+(?!authentication\b)[A-Za-z0-9._~+\/=-]{8,}/
  @candidate_key "(?:\\:?\"[^\"]+\"|\\:?[a-z0-9_. -]+)"
  @candidate_arrow_quoted_value_pattern Regex.compile!(
                                          "(?i)((?:#{@candidate_key})\\s*=>\\s*)\"[^\"]*\""
                                        )
  @candidate_arrow_bare_value_pattern Regex.compile!(
                                        "(?i)((?:#{@candidate_key})\\s*=>\\s*)(?![\"\\[])[^\\s;,}\\]]+"
                                      )
  @candidate_key_quoted_value_pattern Regex.compile!(
                                        "(?i)((?:#{@candidate_key})\\s*(?:[:]|=(?!>))\\s*)\"[^\"]*\""
                                      )
  @candidate_key_bearer_value_pattern Regex.compile!(
                                        "(?i)((?:#{@candidate_key})\\s*(?:[:]|=(?!>))\\s*)bearer\\s+\\S+"
                                      )
  @candidate_key_bracketed_value_pattern Regex.compile!(
                                           "(?i)((?:#{@candidate_key})\\s*(?:[:]|=(?!>))\\s*)\\[[\\s\\S]{0,4096}?\\]"
                                         )
  @candidate_key_open_bracketed_value_pattern Regex.compile!(
                                                "(?i)((?:#{@candidate_key})" <>
                                                  ~S'\s*(?:[:]|=(?!>))\s*)\[(?!REDACTED\])[\s\S]*'
                                              )
  @candidate_key_bare_value_pattern Regex.compile!(
                                      "(?i)((?:#{@candidate_key})\\s*(?:[:]|=(?!>))\\s*)(?![\"\\[])[^\\s;,}\\]]+"
                                    )
  @candidate_tuple_quoted_value_pattern Regex.compile!(
                                          ~S'(?i)((?:\{|,\s*)\:?(?:"[^"]+"|[a-z0-9_. -]+)\s*,\s*)"[^"]*"'
                                        )
  @hf_token_pattern ~r/\bhf_[A-Za-z0-9]{10,}\b/
  @inspect_opts [limit: 20, printable_limit: 1024]
  @inspect_limit Keyword.fetch!(@inspect_opts, :limit)
  @inspect_printable_limit Keyword.fetch!(@inspect_opts, :printable_limit)
  @preinspect_binary_bytes @inspect_printable_limit + 128
  @preinspect_max_depth 8
  @redaction_overlap 512
  @sensitive_key_names MapSet.new([
                         "access-token",
                         "api-key",
                         "api-token",
                         "auth-token",
                         "authorization",
                         "bearer-token",
                         "client-secret",
                         "hf-token",
                         "huggingface-token",
                         "id-token",
                         "password",
                         "private-key",
                         "proxy-authorization",
                         "refresh-token",
                         "secret",
                         "secret-key",
                         "session-token",
                         "token",
                         "x-api-key"
                       ])
  @auth_key_charlist_limit 64
  @public_metadata_redaction_exemptions MapSet.new(["hf_unauthorized", "hf_unavailable"])
  @depth_limit_placeholder "[REDACTED-DEPTH-LIMIT]"
  @improper_list_placeholder "[REDACTED-IMPROPER-LIST]"
  @invalid_binary_placeholder "[REDACTED-BINARY]"
  @truncated_secret_placeholder "[REDACTED-TRUNCATED]"
  @max_redacted_chars 4096
  @partial_sensitive_tail_patterns [
    ~r/(?is)\bbearer\s+(?!authentication\b)[A-Za-z0-9._~+\/=+-]*\z/,
    ~r/(?is)\bhf_[A-Za-z0-9]*\z/,
    ~r/(?is)\b(?:(?:proxy-)?authorization)\s*[:=]\s*\S*\z/,
    ~r/(?is)\b(?:api[._ -]*key|access[._ -]*token|client[._ -]*secret|password|secret|token)\s*(?:=>|[:=])\s*(?:\[[\s\S]*)?\S*\z/,
    ~r/(?i)(?:^|\s)(?:b|be|bea|bear|beare|bearer|h|hf)\z/
  ]

  @doc "Redacts known Console-sensitive token forms from a string."
  @spec redact_secrets(String.t()) :: String.t()
  def redact_secrets(string) when is_binary(string) do
    if String.valid?(string) do
      redact_valid_string(string)
    else
      @invalid_binary_placeholder
    end
  end

  defp redact_valid_string(string) do
    string
    |> String.replace(@authorization_header_value_pattern, "\\1 [REDACTED]")
    |> String.replace(@authorization_arrow_value_pattern, "\\1\"[REDACTED]\"")
    |> String.replace(@authorization_tuple_value_pattern, "\\1\"[REDACTED]\"")
    |> redact_sensitive_key_values()
    |> String.replace(@bearer_header_pattern, "\\1Bearer [REDACTED]")
    |> String.replace(@authorization_kv_pattern, "\\1\"[REDACTED]\"")
    |> String.replace(@bare_bearer_pattern, "Bearer [REDACTED]")
    |> String.replace(@hf_token_pattern, "[REDACTED-HF-TOKEN]")
  end

  defp redact_sensitive_key_values(string) do
    string
    |> replace_regex(@candidate_arrow_quoted_value_pattern, &redact_quoted_value/2)
    |> replace_regex(@candidate_arrow_bare_value_pattern, &redact_bare_value/2)
    |> replace_regex(@candidate_key_quoted_value_pattern, &redact_quoted_value/2)
    |> replace_regex(@candidate_key_bearer_value_pattern, &redact_bearer_value/2)
    |> replace_regex(@candidate_key_bracketed_value_pattern, &redact_bracketed_value/2)
    |> replace_regex(@candidate_key_open_bracketed_value_pattern, &redact_bracketed_value/2)
    |> replace_regex(@candidate_key_bare_value_pattern, &redact_bare_value/2)
    |> replace_regex(@candidate_tuple_quoted_value_pattern, &redact_quoted_value/2)
  end

  defp replace_regex(string, regex, replacement), do: Regex.replace(regex, string, replacement)

  defp redact_quoted_value(match, prefix) do
    if sensitive_prefix?(prefix), do: prefix <> "\"[REDACTED]\"", else: match
  end

  defp redact_bare_value(match, prefix) do
    if sensitive_prefix?(prefix), do: prefix <> "[REDACTED]", else: match
  end

  defp redact_bearer_value(match, prefix) do
    if sensitive_prefix?(prefix), do: prefix <> "Bearer [REDACTED]", else: match
  end

  defp redact_bracketed_value(match, prefix) do
    if sensitive_prefix?(prefix) do
      prefix <> "[REDACTED]"
    else
      prefix <> redact_sensitive_key_values(value_after_prefix(match, prefix))
    end
  end

  defp value_after_prefix(match, prefix) do
    binary_part(match, byte_size(prefix), byte_size(match) - byte_size(prefix))
  end

  defp sensitive_prefix?(prefix) do
    key =
      prefix
      |> String.replace(~r/\s*(?:=>|[:=]|,)\s*$/, "")
      |> String.replace(~r/^\s*(?:\{|,)\s*/, "")
      |> String.trim()
      |> String.trim_leading(":")
      |> String.trim(~s("))

    sensitive_key?(key) and not authorization_key?(key)
  end

  defp authorization_key?(key) do
    normalize_key_name(key) in ["authorization", "proxy-authorization"]
  end

  @doc "Inspects a term with bounded output and secret redaction."
  @spec safe_inspect(term()) :: String.t()
  def safe_inspect(term) do
    term
    |> redact_term(@preinspect_max_depth)
    |> inspect(@inspect_opts)
    |> String.slice(0, @max_redacted_chars)
    |> redact_secrets()
    |> String.slice(0, @max_redacted_chars)
  end

  defp redact_term(term, _depth) when is_binary(term) do
    if String.valid?(term) do
      {prefix, truncated?} = bounded_valid_prefix(term, @preinspect_binary_bytes)

      prefix
      |> mask_trailing_sensitive_context(truncated?, @inspect_printable_limit)
      |> redact_secrets()
    else
      @invalid_binary_placeholder
    end
  end

  defp redact_term(term, depth)
       when depth <= 0 and (is_list(term) or is_tuple(term) or is_map(term)),
       do: @depth_limit_placeholder

  defp redact_term(term, depth) when depth <= 0, do: term

  defp redact_term(%_{} = term, depth) do
    term
    |> Map.from_struct()
    |> redact_term(depth)
  end

  defp redact_term(term, depth) when is_list(term) do
    case take_proper_list(term, @inspect_limit, []) do
      {:ok, items} -> Enum.map(items, &redact_term(&1, depth - 1))
      :improper -> @improper_list_placeholder
    end
  end

  defp redact_term({key, value}, depth) do
    redacted_value =
      if sensitive_key?(key) do
        "[REDACTED]"
      else
        redact_term(value, depth - 1)
      end

    {redact_term(key, depth - 1), redacted_value}
  end

  defp redact_term(term, depth) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.take(@inspect_limit)
    |> Enum.map(&redact_term(&1, depth - 1))
    |> List.to_tuple()
  end

  defp redact_term(%{} = term, depth) do
    term
    |> Map.to_list()
    |> Enum.take(@inspect_limit)
    |> Map.new(fn {key, value} ->
      redacted_value =
        if sensitive_key?(key) do
          "[REDACTED]"
        else
          redact_term(value, depth - 1)
        end

      {redact_term(key, depth - 1), redacted_value}
    end)
  end

  defp redact_term(term, _depth), do: term

  defp bounded_valid_prefix(binary, byte_limit) do
    size = min(byte_size(binary), byte_limit)

    prefix =
      binary
      |> binary_part(0, size)
      |> valid_utf8_prefix()

    {prefix, byte_size(binary) > size}
  end

  defp bounded_redaction_input(string, char_limit) do
    if String.valid?(string) do
      {prefix, truncated?} = bounded_valid_prefix(string, char_limit + @redaction_overlap)

      redacted =
        prefix
        |> mask_trailing_sensitive_context(truncated?, char_limit)
        |> redact_secrets()

      redacted
      |> String.slice(0, char_limit)
      |> mask_trailing_sensitive_context(
        truncated? or String.length(redacted) > char_limit,
        char_limit
      )
    else
      @invalid_binary_placeholder
    end
  end

  defp mask_trailing_sensitive_context(string, false, _visible_limit), do: string

  defp mask_trailing_sensitive_context(string, true, visible_limit) do
    masked =
      Enum.reduce(@partial_sensitive_tail_patterns, string, fn pattern, acc ->
        Regex.replace(pattern, acc, @truncated_secret_placeholder)
      end)

    if masked == string do
      string
    else
      keep_placeholder_visible(masked, visible_limit)
    end
  end

  defp keep_placeholder_visible(string, visible_limit) do
    if String.length(string) <= visible_limit do
      string
    else
      prefix_limit = max(visible_limit - String.length(@truncated_secret_placeholder), 0)

      String.slice(string, 0, prefix_limit) <> @truncated_secret_placeholder
    end
  end

  defp valid_utf8_prefix(binary) do
    cond do
      String.valid?(binary) -> binary
      byte_size(binary) == 0 -> binary
      true -> binary |> binary_part(0, byte_size(binary) - 1) |> valid_utf8_prefix()
    end
  end

  defp take_proper_list(_list, 0, acc), do: {:ok, Enum.reverse(acc)}
  defp take_proper_list([], _remaining, acc), do: {:ok, Enum.reverse(acc)}

  defp take_proper_list([head | tail], remaining, acc) when is_list(tail) do
    take_proper_list(tail, remaining - 1, [head | acc])
  end

  defp take_proper_list([_head | _tail], _remaining, _acc), do: :improper

  defp sensitive_key?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> sensitive_key?()
  end

  defp sensitive_key?(key) when is_binary(key) do
    if String.valid?(key) do
      normalized = normalize_key_name(key)
      segments = String.split(normalized, "-", trim: true)

      MapSet.member?(@sensitive_key_names, normalized) or sensitive_key_segments?(segments)
    else
      true
    end
  end

  defp sensitive_key?(key) when is_list(key) do
    case printable_charlist_prefix(key) do
      {:ok, chars} -> chars |> List.to_string() |> sensitive_key?()
      :error -> false
    end
  end

  defp sensitive_key?(_key), do: false

  defp normalize_key_name(key) do
    key
    |> String.trim()
    |> Macro.underscore()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp sensitive_key_segments?(segments) do
    "token" in segments or
      "secret" in segments or
      segments == ["key"] or
      Enum.take(segments, 3) == ["x", "api", "key"] or
      contains_ordered_segments?(segments, ["api", "key"]) or
      contains_ordered_segments?(segments, ["private", "key"])
  end

  defp contains_ordered_segments?(segments, wanted) do
    segments
    |> Enum.reduce(wanted, fn
      _segment, [] -> []
      segment, [segment | rest] -> rest
      _segment, remaining -> remaining
    end)
    |> Enum.empty?()
  end

  defp printable_charlist_prefix(key) do
    case take_proper_list(key, @auth_key_charlist_limit, []) do
      {:ok, chars} ->
        if Enum.all?(chars, &printable_ascii?/1), do: {:ok, chars}, else: :error

      :improper ->
        :error
    end
  end

  defp printable_ascii?(char) when is_integer(char) and char in 32..126, do: true
  defp printable_ascii?(_char), do: false

  @doc "Formats an exception with bounded output and secret redaction."
  @spec format_exception(:error | :throw | :exit, term(), list()) :: String.t()
  def format_exception(kind, exception, stacktrace) do
    [format_exception_banner(kind, exception), format_bounded_stacktrace(stacktrace)]
    |> IO.iodata_to_binary()
    |> bounded_redaction_input(@max_redacted_chars)
    |> redact_secrets()
    |> String.slice(0, @max_redacted_chars)
  end

  defp format_exception_banner(:error, exception) do
    if is_exception(exception) do
      "** (" <> exception_label(exception) <> ") " <> bounded_exception_message(exception)
    else
      "** (error) " <> safe_inspect(exception)
    end
  end

  defp format_exception_banner(:throw, reason), do: "** (throw) " <> safe_inspect(reason)
  defp format_exception_banner(:exit, reason), do: "** (exit) " <> safe_inspect(reason)

  defp exception_label(%module{}), do: module |> inspect() |> String.trim_leading("Elixir.")

  defp bounded_exception_message(exception) do
    exception
    |> Exception.message()
    |> bounded_redaction_input(@max_redacted_chars)
  rescue
    _ -> safe_inspect(exception)
  end

  defp format_bounded_stacktrace(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.take(@inspect_limit)
    |> Enum.map(&sanitize_stacktrace_entry/1)
    |> Exception.format_stacktrace()
    |> bounded_redaction_input(@max_redacted_chars)
  rescue
    _ -> "\n    " <> safe_inspect(stacktrace)
  end

  defp format_bounded_stacktrace(_stacktrace), do: ""

  defp sanitize_stacktrace_entry({module, function, args, location}) when is_list(args) do
    {module, function, Enum.map(Enum.take(args, @inspect_limit), &redact_term(&1, 2)),
     sanitize_stacktrace_location(location)}
  end

  defp sanitize_stacktrace_entry({module, function, arity, location}) do
    {module, function, arity, sanitize_stacktrace_location(location)}
  end

  defp sanitize_stacktrace_entry(entry), do: entry

  defp sanitize_stacktrace_location(location) when is_list(location), do: redact_term(location, 2)
  defp sanitize_stacktrace_location(location), do: location

  @doc "Redacts secret-bearing user-visible message fields in error tuples."
  @spec sanitize_result(term()) :: term()
  def sanitize_result({:error, %{} = error}), do: {:error, sanitize_error_map(error)}
  def sanitize_result(result), do: result

  @doc "Redacts secret-bearing `message` fields in error maps."
  @spec sanitize_error_map(map()) :: map()

  def sanitize_error_map(%_{} = error) do
    error
    |> Map.from_struct()
    |> sanitize_map(@preinspect_max_depth, true)
  end

  def sanitize_error_map(%{} = error), do: sanitize_map(error, @preinspect_max_depth, true)

  defp sanitize_data(term, depth)
       when depth <= 0 and (is_list(term) or is_tuple(term) or is_map(term)),
       do: @depth_limit_placeholder

  defp sanitize_data(term, _depth) when is_binary(term), do: sanitize_visible_message(term)

  defp sanitize_data(%_{} = term, depth) do
    term
    |> Map.from_struct()
    |> sanitize_data(depth)
  end

  defp sanitize_data(%{} = term, depth), do: sanitize_map(term, depth, false)

  defp sanitize_data({key, value}, depth) do
    redacted_value =
      if sensitive_key?(key) do
        "[REDACTED]"
      else
        sanitize_data(value, depth - 1)
      end

    {sanitize_key(key), redacted_value}
  end

  defp sanitize_data(term, depth) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&sanitize_data(&1, depth - 1))
    |> List.to_tuple()
  end

  defp sanitize_data(term, depth) when is_list(term) do
    case printable_charlist_prefix(term) do
      {:ok, _chars} -> sanitize_charlist_value(term)
      :error -> sanitize_bounded_list(term, depth)
    end
  end

  defp sanitize_data(term, _depth), do: term

  defp sanitize_bounded_list(term, depth) do
    case take_proper_list(term, @inspect_limit, []) do
      {:ok, items} -> Enum.map(items, &sanitize_data(&1, depth - 1))
      :improper -> @improper_list_placeholder
    end
  end

  defp sanitize_charlist_value(original) do
    case bounded_printable_charlist_to_string(original, @max_redacted_chars) do
      {:ok, string, truncated?} ->
        redacted = sanitize_visible_message(string)

        if redacted == string and not truncated?, do: original, else: redacted

      :error ->
        @improper_list_placeholder
    end
  end

  defp sanitize_map(term, depth, preserve_contract_keys?) do
    term
    |> bounded_map_entries(preserve_contract_keys?)
    |> Map.new(fn {key, value} ->
      redacted_value =
        cond do
          public_error_metadata_key?(key) -> sanitize_public_metadata_value(value, depth - 1)
          message_key?(key) -> sanitize_message_value(value, depth - 1)
          sensitive_key?(key) -> "[REDACTED]"
          true -> sanitize_data(value, depth - 1)
        end

      {sanitize_key(key), redacted_value}
    end)
  end

  defp sanitize_key(key) when is_binary(key), do: sanitize_visible_message(key)

  defp sanitize_key(key) when is_list(key) do
    case bounded_printable_charlist_to_string(key, @max_redacted_chars) do
      {:ok, string, truncated?} -> sanitize_charlist_key(key, string, truncated?)
      :error -> sanitize_bounded_key_list(key)
    end
  end

  defp sanitize_key(key) when is_tuple(key) do
    key
    |> Tuple.to_list()
    |> Enum.map(&sanitize_key/1)
    |> List.to_tuple()
  end

  defp sanitize_key(key), do: key

  defp sanitize_charlist_key(original, string, truncated?) do
    redacted = sanitize_visible_message(string)

    if redacted == string and not truncated?, do: original, else: redacted
  end

  defp sanitize_bounded_key_list(key) do
    case take_proper_list(key, @inspect_limit, []) do
      {:ok, items} -> Enum.map(items, &sanitize_key/1)
      :improper -> @improper_list_placeholder
    end
  end

  defp bounded_map_entries(term, false), do: Enum.take(term, @inspect_limit)

  defp bounded_map_entries(term, true) do
    contract_keys = [:message, "message", :code, "code", :status, "status"]

    contract_entries =
      contract_keys
      |> Enum.filter(&Map.has_key?(term, &1))
      |> Enum.map(fn key -> {key, Map.fetch!(term, key)} end)

    extra_limit = max(@inspect_limit - length(contract_entries), 0)

    extras =
      term
      |> Stream.reject(fn {key, _value} -> key in contract_keys end)
      |> Enum.take(extra_limit)

    contract_entries ++ extras
  end

  defp bounded_printable_charlist_to_string(list, limit) do
    case take_proper_list(list, limit + 1, []) do
      {:ok, items} ->
        printable_items_to_string(items, limit)

      :improper ->
        :error
    end
  end

  defp printable_items_to_string(items, limit) do
    if Enum.all?(items, &printable_ascii?/1) do
      {bounded_items, truncated?} = bounded_items(items, limit)
      {:ok, List.to_string(bounded_items), truncated?}
    else
      :error
    end
  end

  defp bounded_items(items, limit) do
    if length(items) > limit do
      {Enum.take(items, limit), true}
    else
      {items, false}
    end
  end

  defp public_error_metadata_key?(:code), do: true
  defp public_error_metadata_key?("code"), do: true
  defp public_error_metadata_key?(:status), do: true
  defp public_error_metadata_key?("status"), do: true
  defp public_error_metadata_key?(_key), do: false

  defp sanitize_public_metadata_value(value, _depth) when is_binary(value) do
    if MapSet.member?(@public_metadata_redaction_exemptions, value) do
      value
    else
      sanitize_visible_message(value)
    end
  end

  defp sanitize_public_metadata_value(value, _depth)
       when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp sanitize_public_metadata_value(value, depth), do: sanitize_data(value, depth)

  defp message_key?(:message), do: true
  defp message_key?("message"), do: true
  defp message_key?(_key), do: false

  defp sanitize_message_value(message, _depth) when is_binary(message) do
    sanitize_visible_message(message)
  end

  defp sanitize_message_value(message, depth), do: sanitize_data(message, depth)

  defp sanitize_visible_message(message) when is_binary(message) do
    message
    |> bounded_redaction_input(@max_redacted_chars)
    |> redact_secrets()
    |> String.slice(0, @max_redacted_chars)
  end
end
