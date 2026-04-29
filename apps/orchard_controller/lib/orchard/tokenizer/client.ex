defmodule Orchard.Tokenizer.Client do
  @moduledoc """
  Injectable tokenizer seam for controller-side prompt rendering and token counting.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.ToolingValidation
  alias Orchard.ModelManifest
  alias Orchard.PathUtils
  alias Orchard.Tokenizer.{CallerStrings, ControlTokenDetector, Telemetry}

  @render_and_count_contract_version 2
  @default_timeout_ms 5_000
  @control_token_catalog_kinds ~w(huggingface_tokenizer_json)

  @type tokenization_result :: %{
          rendered_prompt: binary(),
          input_token_count: non_neg_integer()
        }

  @type error_reason ::
          {:invalid_input | :missing_assets | :unsupported_tokenizer | :internal_error,
           String.t()}
          | :invalid_response
          | :timeout
          | :unavailable
          | :not_implemented

  @callback tokenize(CanonicalRequest.t(), keyword()) ::
              {:ok, tokenization_result()} | {:error, error_reason()}

  def tokenize(%CanonicalRequest{} = request, opts \\ []) do
    case Orchard.Inference.tokenizer_client() do
      __MODULE__ -> default_tokenize(request, opts)
      module -> module.tokenize(request, opts)
    end
  end

  def mode, do: Orchard.Inference.tokenizer_mode()
  def executable, do: Orchard.Inference.tokenizer_executable()

  defp default_tokenize(%CanonicalRequest{} = request, opts) do
    case mode() do
      :fake -> fake_tokenize(request)
      :port -> port_tokenize(request, opts)
      _other -> {:error, :not_implemented}
    end
  end

  defp fake_tokenize(%CanonicalRequest{} = request) do
    if tool_calling_enabled?(request) do
      {:error,
       {:invalid_input,
        "fake tokenizer mode does not support tool-calling requests; switch to tokenizer_mode=:port"}}
    else
      with {:ok, prompt_lines} <- build_prompt_lines(request.input_items) do
        rendered_prompt = Enum.join(prompt_lines ++ ["assistant"], "\n")

        {:ok,
         %{rendered_prompt: rendered_prompt, input_token_count: fake_token_count(rendered_prompt)}}
      end
    end
  end

  defp port_tokenize(%CanonicalRequest{} = request, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with {:ok, payload} <- build_payload(request, opts),
         :ok <- observe_control_token_inputs(request, payload, opts),
         {:ok, executable_path} <- resolve_executable(executable()),
         {:ok, response_json, exit_status} <-
           run_executable(executable_path, Jason.encode!(payload), timeout_ms),
         {:ok, response} <- decode_response(response_json) do
      normalize_response(response, exit_status)
    end
  end

  defp build_payload(%CanonicalRequest{} = request, opts) do
    with {:ok, assets} <- resolve_assets(opts) do
      {:ok,
       %{
         contract_version: @render_and_count_contract_version,
         command: "render_and_count",
         assets: assets,
         request: %{
           input_items: request.input_items,
           tools: request.tooling.tools,
           tool_choice: request.tooling.tool_choice
         }
       }}
    end
  end

  defp observe_control_token_inputs(%CanonicalRequest{} = request, payload, opts) do
    manifest = Keyword.get(opts, :manifest)

    try do
      assets = Map.get(payload, :assets, %{})
      tokenizer_kind = Map.get(assets, :tokenizer_kind)

      if tokenizer_kind in @control_token_catalog_kinds do
        assets
        |> Map.get(:tokenizer_path)
        |> observe_control_token_inputs(request, manifest, opts)
      end
    rescue
      _exception ->
        Telemetry.emit_detector_error(:detector_exception, request, manifest)
    catch
      kind, _reason ->
        Telemetry.emit_detector_error({:detector_catch, kind}, request, manifest)
    end

    :ok
  end

  defp observe_control_token_inputs(tokenizer_path, request, manifest, opts)
       when is_binary(tokenizer_path) do
    detector = Keyword.get(opts, :control_token_detector, ControlTokenDetector)

    case detector.partial_catalog(tokenizer_path) do
      {:ok, catalog, diagnostics} ->
        Enum.each(diagnostics, fn diagnostic ->
          Telemetry.emit_detector_error(diagnostic, request, manifest)
        end)

        hits =
          request.input_items
          |> CallerStrings.walk_caller_strings(request.tooling.tools, request.tooling.tool_choice)
          |> then(&detector.detect(catalog, &1))

        Telemetry.emit_control_token_hits(hits, request, manifest)

      {:error, reason} ->
        Telemetry.emit_detector_error({:catalog_load_failed, reason}, request, manifest)
    end
  end

  defp observe_control_token_inputs(tokenizer_path, request, manifest, _opts) do
    Telemetry.emit_detector_error(
      {:missing_tokenizer_path, value_kind(tokenizer_path)},
      request,
      manifest
    )
  end

  defp value_kind(value) when is_nil(value), do: nil
  defp value_kind(value) when is_binary(value), do: :binary
  defp value_kind(value) when is_atom(value), do: :atom
  defp value_kind(value) when is_integer(value), do: :integer
  defp value_kind(value) when is_float(value), do: :float
  defp value_kind(value) when is_list(value), do: :list
  defp value_kind(value) when is_map(value), do: :map
  defp value_kind(_value), do: :other

  defp resolve_assets(opts) do
    manifest = Keyword.get(opts, :manifest)
    bundle_root = Keyword.get(opts, :bundle_root)

    with {:ok, {tokenizer_kind, tokenizer_path, chat_template_path}} <-
           extract_manifest_assets(manifest),
         {:ok, resolved_tokenizer_path} <- resolve_asset_path(tokenizer_path, bundle_root),
         {:ok, resolved_chat_template_path} <-
           resolve_asset_path(chat_template_path, bundle_root) do
      {:ok,
       %{
         tokenizer_kind: tokenizer_kind,
         tokenizer_path: resolved_tokenizer_path,
         chat_template_path: resolved_chat_template_path
       }}
    else
      {:error, _reason} = error ->
        error
    end
  end

  defp extract_manifest_assets(%ModelManifest{tokenizer: tokenizer, chat_template: chat_template}) do
    with {:ok, tokenizer_kind, tokenizer_path} <- extract_tokenizer_asset(tokenizer),
         {:ok, chat_template_path} <- extract_chat_template_asset(chat_template) do
      {:ok, {tokenizer_kind, tokenizer_path, chat_template_path}}
    end
  end

  defp extract_manifest_assets(_other) do
    {:error,
     {:invalid_input,
      "tokenizer opts must include :manifest with an Orchard.ModelManifest and optional :bundle_root"}}
  end

  defp extract_tokenizer_asset(%{kind: kind, path: path})
       when is_binary(kind) and kind != "" and is_binary(path) and path != "" do
    {:ok, kind, path}
  end

  defp extract_tokenizer_asset(_other) do
    {:error, {:missing_assets, "model manifest tokenizer must include non-empty kind and path"}}
  end

  defp extract_chat_template_asset(nil) do
    {:error,
     {:missing_assets,
      "model manifest must include chat_template with a non-empty path for port-mode tokenization"}}
  end

  defp extract_chat_template_asset(%{path: path}) when is_binary(path) and path != "" do
    {:ok, path}
  end

  defp extract_chat_template_asset(_other) do
    {:error,
     {:missing_assets, "model manifest chat_template must include a non-empty path when present"}}
  end

  defp resolve_asset_path(path, bundle_root) when is_binary(path) and path != "" do
    case bundle_root do
      nil ->
        resolve_absolute_asset_path(path)

      bundle_root when is_binary(bundle_root) and bundle_root != "" ->
        resolve_bundle_asset_path(path, bundle_root)

      _other ->
        {:error, {:invalid_input, "bundle_root must be a non-empty binary when provided"}}
    end
  end

  defp resolve_asset_path(path, _bundle_root) do
    {:error,
     {:invalid_input, "tokenizer asset path must be a non-empty binary, got: #{inspect(path)}"}}
  end

  defp resolve_absolute_asset_path(path) do
    case Path.type(path) do
      :absolute ->
        {:ok, Path.expand(path)}

      _relative ->
        {:error,
         {:invalid_input,
          "relative tokenizer asset paths require :bundle_root, got: #{inspect(path)}"}}
    end
  end

  defp resolve_bundle_asset_path(path, bundle_root) do
    with {:ok, real_root} <- realpath_bundle_root(bundle_root) do
      expanded_path = Path.expand(path, real_root)

      case realpath_asset(expanded_path) do
        {:ok, real_asset} ->
          ensure_confined(real_asset, real_root, path)

        {:error, _posix} ->
          {:error,
           {:missing_assets, "tokenizer asset not found or inaccessible: #{inspect(path)}"}}
      end
    end
  end

  defp realpath_bundle_root(bundle_root) do
    case PathUtils.resolve_realpath(Path.expand(bundle_root)) do
      {:ok, real_root} ->
        {:ok, real_root}

      {:error, _posix} ->
        {:error,
         {:invalid_input,
          "bundle_root does not exist or is inaccessible: #{inspect(bundle_root)}"}}
    end
  end

  defp realpath_asset(expanded_path) do
    PathUtils.resolve_realpath(expanded_path)
  end

  defp ensure_confined(real_asset, real_root, original_path) do
    case Path.relative_to(real_asset, real_root) do
      <<"..", _rest::binary>> ->
        {:error,
         {:invalid_input, "tokenizer asset path escapes bundle_root: #{inspect(original_path)}"}}

      ^real_asset ->
        # Path.relative_to returns the path unchanged when it's not relative to root
        {:error,
         {:invalid_input, "tokenizer asset path escapes bundle_root: #{inspect(original_path)}"}}

      _relative_path ->
        {:ok, real_asset}
    end
  end

  defp resolve_executable(path) when is_binary(path) and path != "" do
    case Path.type(path) do
      :absolute ->
        expanded_path = Path.expand(path)

        case File.stat(expanded_path) do
          {:ok, %File.Stat{type: :regular}} -> {:ok, expanded_path}
          _other -> {:error, :unavailable}
        end

      _relative ->
        case System.find_executable(path) do
          resolved_path when is_binary(resolved_path) -> {:ok, resolved_path}
          _other -> {:error, :unavailable}
        end
    end
  end

  defp resolve_executable(_path), do: {:error, :unavailable}

  defp run_executable(executable_path, request_json, timeout_ms)
       when is_binary(executable_path) and is_binary(request_json) and is_integer(timeout_ms) and
              timeout_ms > 0 do
    request_path = write_request_file!(request_json)

    try do
      port =
        Port.open(
          {:spawn_executable, ~c"/bin/sh"},
          [
            :binary,
            :exit_status,
            :use_stdio,
            {:args,
             ["-c", ~s(exec "$1" < "$2"), "orchard-tokenizer-port", executable_path, request_path]}
          ]
        )

      collect_port_output(port, [], timeout_ms)
    after
      File.rm(request_path)
    end
  rescue
    ArgumentError ->
      {:error, :unavailable}
  end

  defp write_request_file!(request_json) do
    request_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-tokenizer-request-#{System.unique_integer([:positive])}.json"
      )

    File.write!(request_path, request_json)
    request_path
  end

  defp collect_port_output(port, chunks, timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, [data | chunks], timeout_ms)

      {^port, {:exit_status, exit_status}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), exit_status}
    after
      timeout_ms ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp decode_response(response_json) when is_binary(response_json) do
    case Jason.decode(response_json) do
      {:ok, response} when is_map(response) -> {:ok, response}
      _other -> {:error, :invalid_response}
    end
  end

  defp normalize_response(
         %{
           "contract_version" => @render_and_count_contract_version,
           "ok" => true,
           "result" => %{
             "rendered_prompt" => rendered_prompt,
             "input_token_count" => input_token_count
           }
         },
         0
       )
       when is_binary(rendered_prompt) and is_integer(input_token_count) and
              input_token_count >= 0 do
    {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}}
  end

  defp normalize_response(
         %{
           "contract_version" => @render_and_count_contract_version,
           "ok" => false,
           "error" => %{"category" => category, "message" => message}
         },
         _exit_status
       )
       when is_binary(category) and is_binary(message) do
    {:error, {normalize_error_category(category), message}}
  end

  defp normalize_response(_response, _exit_status), do: {:error, :invalid_response}

  defp normalize_error_category("invalid_input"), do: :invalid_input
  defp normalize_error_category("missing_assets"), do: :missing_assets
  defp normalize_error_category("unsupported_tokenizer"), do: :unsupported_tokenizer
  defp normalize_error_category(_category), do: :internal_error

  defp build_prompt_lines(input_items) when is_list(input_items) do
    input_items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, lines} ->
      with {:ok, role} <- fetch_string_field(item, [:role, "role"], "role", index),
           {:ok, content} <-
             normalize_content(fetch_first_present(item, [:content, "content"]), index) do
        {:cont, {:ok, lines ++ [role <> " " <> content]}}
      else
        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp build_prompt_lines(input_items) do
    {:error,
     {:invalid_input,
      "canonical request input_items must be a list of role/content maps, got: #{inspect(input_items)}"}}
  end

  defp fetch_string_field(item, keys, field_name, index) when is_map(item) do
    value = fetch_first_present(item, keys)

    case value do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error,
         {:invalid_input,
          "input_items[#{index}] must include non-empty #{field_name}, got: #{inspect(item)}"}}
    end
  end

  defp fetch_string_field(item, _keys, _field_name, index) do
    {:error, {:invalid_input, "input_items[#{index}] must be maps, got: #{inspect(item)}"}}
  end

  defp fetch_first_present(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp normalize_content(content, _index) when is_binary(content), do: {:ok, content}

  defp normalize_content(content_parts, index) when is_list(content_parts) do
    content_parts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {part, part_index}, {:ok, texts} ->
      case normalize_content_part(part, index, part_index) do
        {:ok, text} -> {:cont, {:ok, texts ++ [text]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.join(texts, "")}
      error -> error
    end
  end

  defp normalize_content(content, index) do
    {:error,
     {:invalid_input,
      "input_items[#{index}].content must be a string or text-part list, got: #{inspect(content)}"}}
  end

  defp normalize_content_part(part, index, part_index) do
    case part do
      %{} ->
        type = fetch_first_present(part, [:type, "type"])
        text = fetch_first_present(part, [:text, "text"])

        case {type, text} do
          {"text", text} when is_binary(text) -> {:ok, text}
          _other -> invalid_text_part_error(part, index, part_index)
        end

      _other ->
        invalid_text_part_error(part, index, part_index)
    end
  end

  defp invalid_text_part_error(part, index, part_index) do
    {:error,
     {:invalid_input,
      "input_items[#{index}].content[#{part_index}] must be text parts, got: #{inspect(part)}"}}
  end

  defp fake_token_count(rendered_prompt) do
    rendered_prompt
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp tool_calling_enabled?(%CanonicalRequest{tooling: tooling}) do
    ToolingValidation.effective_tool_calling?(tooling.tools, tooling.tool_choice)
  end
end
