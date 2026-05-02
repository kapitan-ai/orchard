defmodule Orchard.Tokenizer.Telemetry do
  @moduledoc """
  Telemetry emitters for tokenizer safety observations.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.ModelManifest

  @control_token_event [:orchard, :tokenizer, :control_token_in_user_content]
  @detector_error_event [:orchard, :tokenizer, :detector_error]
  @prompt_token_ids_dispatched_event [:orchard, :tokenizer, :prompt_token_ids_dispatched]
  @unsafe_mode_active_event [:orchard, :tokenizer, :unsafe_mode_active]
  @degraded_no_manifest_catalog_event [
    :orchard,
    :tokenizer,
    :safe_tokenization,
    :degraded_no_manifest_catalog
  ]
  @missing_partial_catalog_sources [:chat_template_literals, :wrapper_tool_markers]
  @metadata_limit 16
  @literal_metadata_bytes 64

  @type detector_hit :: {String.t(), String.t(), non_neg_integer()}
  @type detector_error :: %{category: atom(), detail: atom()}

  @spec emit_control_token_hits([detector_hit()], CanonicalRequest.t(), ModelManifest.t() | nil) ::
          :ok
  def emit_control_token_hits([], %CanonicalRequest{}, _manifest), do: :ok

  def emit_control_token_hits(hits, %CanonicalRequest{} = request, manifest) when is_list(hits) do
    bounded_hits = Enum.take(hits, @metadata_limit)

    bounded_literals =
      Enum.map(bounded_hits, fn {_path, literal, _offset} -> bounded_literal(literal) end)

    :telemetry.execute(
      @control_token_event,
      %{count: length(hits)},
      request_metadata(request, manifest)
      |> Map.merge(%{
        provenance_paths: Enum.map(bounded_hits, fn {path, _literal, _offset} -> path end),
        literals: Enum.map(bounded_literals, fn literal -> literal.value end),
        literal_byte_sizes: Enum.map(bounded_literals, fn literal -> literal.byte_size end),
        literal_families: Enum.map(bounded_literals, fn literal -> literal.family end),
        literal_metadata_max_bytes: @literal_metadata_bytes,
        literal_truncated: Enum.any?(bounded_literals, fn literal -> literal.truncated end),
        partial_detection: true,
        missing_catalog_sources: @missing_partial_catalog_sources,
        truncated: length(hits) > @metadata_limit
      })
    )

    :ok
  end

  @spec emit_degraded_no_manifest_catalog(CanonicalRequest.t(), ModelManifest.t() | nil) :: :ok
  def emit_degraded_no_manifest_catalog(%CanonicalRequest{} = request, manifest) do
    :telemetry.execute(
      @degraded_no_manifest_catalog_event,
      %{count: 1},
      request_metadata(request, manifest)
      |> Map.merge(%{
        tokenizer_safe_mode: :on,
        degraded_reason: :no_manifest_catalog
      })
    )

    :ok
  end

  @spec prompt_token_ids_dispatched(map(), non_neg_integer()) :: :ok
  def prompt_token_ids_dispatched(metadata, token_count) when is_map(metadata) do
    :telemetry.execute(
      @prompt_token_ids_dispatched_event,
      %{token_count: token_count},
      metadata
    )

    :ok
  end

  @spec unsafe_mode_active(map()) :: :ok
  def unsafe_mode_active(metadata) when is_map(metadata) do
    :telemetry.execute(
      @unsafe_mode_active_event,
      %{count: 1},
      metadata
    )

    :ok
  end

  @spec emit_detector_error(term(), CanonicalRequest.t(), ModelManifest.t() | nil) :: :ok
  def emit_detector_error(reason, %CanonicalRequest{} = request, manifest) do
    %{category: category, detail: detail} = normalize_detector_error(reason)

    :telemetry.execute(
      @detector_error_event,
      %{count: 1},
      request_metadata(request, manifest)
      |> Map.merge(%{
        error_category: category,
        error_detail: detail,
        reason: Atom.to_string(category) <> "." <> Atom.to_string(detail),
        partial_detection: true,
        missing_catalog_sources: @missing_partial_catalog_sources
      })
    )

    :ok
  end

  defp bounded_literal(literal) when is_binary(literal) do
    %{
      value: literal_prefix(literal, @literal_metadata_bytes),
      byte_size: byte_size(literal),
      family: literal_family(literal),
      truncated: byte_size(literal) > @literal_metadata_bytes
    }
  end

  defp literal_prefix(literal, max_bytes) when byte_size(literal) <= max_bytes, do: literal

  defp literal_prefix(literal, max_bytes) do
    literal
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      next = acc <> grapheme

      if byte_size(next) > max_bytes do
        {:halt, acc}
      else
        {:cont, next}
      end
    end)
  end

  defp literal_family("<|" <> _rest), do: :angle_pipe
  defp literal_family("<" <> _rest), do: :angle
  defp literal_family("[" <> _rest), do: :bracket
  defp literal_family(_literal), do: :other

  @spec normalize_detector_error(term()) :: detector_error()
  defp normalize_detector_error({:tokenizer_config, reason}) do
    %{category: :tokenizer_config, detail: normalize_detector_detail(reason)}
  end

  defp normalize_detector_error({:catalog_load_failed, reason}) do
    %{category: :tokenizer_catalog, detail: normalize_detector_detail(reason)}
  end

  defp normalize_detector_error(:detector_exception) do
    %{category: :detector_runtime, detail: :exception}
  end

  defp normalize_detector_error({:detector_catch, kind}) do
    %{category: :detector_runtime, detail: normalize_catch_kind(kind)}
  end

  defp normalize_detector_error({:missing_tokenizer_path, _path_kind}) do
    %{category: :tokenizer_catalog, detail: :missing_tokenizer_path}
  end

  defp normalize_detector_error(_reason) do
    %{category: :detector_runtime, detail: :unknown}
  end

  defp normalize_detector_detail({:invalid_json, _path}), do: :invalid_json
  defp normalize_detector_detail({:invalid_json_object, _path}), do: :invalid_json_object
  defp normalize_detector_detail({:json_read_failed, _path, _reason}), do: :json_read_failed

  defp normalize_detector_detail({:asset_escapes_tokenizer_root, _path}),
    do: :asset_escapes_tokenizer_root

  defp normalize_detector_detail({:invalid_tokenizer_path, _path}), do: :invalid_tokenizer_path
  defp normalize_detector_detail(_reason), do: :unknown

  defp normalize_catch_kind(:throw), do: :caught_throw
  defp normalize_catch_kind(:exit), do: :caught_exit
  defp normalize_catch_kind(:error), do: :caught_error
  defp normalize_catch_kind(_kind), do: :caught_unknown

  defp request_metadata(%CanonicalRequest{} = request, manifest) do
    %{
      model_id: request.model_ref.model_id,
      endpoint: request.endpoint,
      bundle_id: bundle_id(manifest)
    }
  end

  defp bundle_id(%ModelManifest{sha256: sha256}) when is_binary(sha256) and sha256 != "",
    do: sha256

  defp bundle_id(_manifest), do: nil
end
