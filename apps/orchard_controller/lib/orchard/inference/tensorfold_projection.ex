defmodule Orchard.Inference.TensorFoldProjection do
  @moduledoc false

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.{CacheAffinity, ReasoningEffort}
  alias Orchard.Models.ModelRenderAssets

  @binding_keys ~w(schema_version profile_id model_id version artifact_sha256 template_sha256 tokenizer_config_sha256 enable_thinking reasoning_effort output_projection)
  @max_bytes 1_048_576
  @max_config_bytes 4_194_304
  @max_request_seconds 3_600

  @spec config() :: map() | nil
  def config, do: Application.get_env(:orchard_controller, :tensorfold_experiment_profile)

  @spec selected?(CanonicalRequest.t(), map() | nil) :: boolean()
  def selected?(request, profile \\ config())

  def selected?(%CanonicalRequest{model_ref: %{model_id: model_id}}, %{"model_id" => model_id}),
    do: true

  def selected?(_request, _profile), do: false

  @doc """
  Whether the dispatcher refused a selected request before Node acceptance.

  Such a refusal keeps its classified `runtime_incompatible` error instead of
  surfacing as an opaque failure code.
  """
  @spec refused_before_acceptance?(CanonicalRequest.t(), map(), map() | nil) :: boolean()
  def refused_before_acceptance?(request, outcome, profile \\ config())

  def refused_before_acceptance?(
        request,
        %{accepted: false, events: [], failure: %{"failure_code" => "runtime_incompatible"}},
        profile
      ),
      do: selected?(request, profile)

  def refused_before_acceptance?(_request, _outcome, _profile), do: false

  @spec validate(CanonicalRequest.t(), map() | nil) :: :ok | {:error, term()}
  def validate(request, profile \\ config())
  def validate(_request, nil), do: :ok

  def validate(%CanonicalRequest{} = request, profile) when is_map(profile) do
    if request.model_ref.model_id == profile["model_id"] do
      validate_selected(request, profile)
    else
      :ok
    end
  end

  def validate(_request, _profile), do: incompatible()

  @spec issue(CanonicalRequest.t(), map(), map(), map() | nil, keyword()) ::
          {:ok, binary()} | {:error, term()}
  def issue(request, model, schedule, profile \\ config(), opts \\ [])
  def issue(_request, _model, _schedule, nil, _opts), do: {:ok, ""}

  def issue(request, model, schedule, profile, opts) when is_map(profile) do
    if request.model_ref.model_id == profile["model_id"] do
      with :ok <- validate_selected(request, profile),
           :ok <- within_request_limit(schedule, profile),
           :ok <- authorize_route(Map.get(schedule, :node_id), profile),
           true <- model.artifact_sha256 == profile["artifact_sha256"],
           {:ok, assets} <- assets(model, opts),
           :ok <- verify_assets(assets, profile) do
        bounded_envelope(request, profile)
      else
        _failure -> incompatible()
      end
    else
      {:ok, ""}
    end
  end

  def issue(_request, _model, _schedule, _profile, _opts), do: incompatible()

  @spec authorize_route(term(), map() | nil) :: :ok | {:error, term()}
  def authorize_route(node_id, %{"authorized_node_ids" => ids})
      when is_binary(node_id) and is_list(ids) do
    if node_id in ids, do: :ok, else: incompatible()
  end

  def authorize_route(_node_id, _profile), do: incompatible()

  defp validate_selected(request, profile) do
    reasoning = request.reasoning
    contract = reasoning.effective_contract

    with true <- valid_profile?(profile),
         true <- request.model_ref.version == profile["version"],
         true <- reasoning.generation_policy == :enabled,
         true <- reasoning.projection == :legacy_blended,
         true <- reasoning.reasoning_effort == :medium,
         true <- reasoning.source == :explicit_public,
         true <- contract.mode == :rendered,
         true <- authoritative_tokenization?(request),
         true <- contract.model_artifact_digest == profile["artifact_sha256"],
         true <- contract.chat_template_digest == profile["template_sha256"],
         {:ok, ^reasoning} <-
           ReasoningEffort.resolve(
             :medium,
             profile["artifact_sha256"],
             profile["template_sha256"]
           ),
         true <- is_nil(request.sampling.seed) and request.sampling.stop == [],
         true <- request.response_format.type == :text,
         true <- is_nil(request.tooling.tool_choice),
         false <-
           CacheAffinity.live_fingerprint_match_enabled?(
             Orchard.Inference.cache_affinity_config()
           ),
         false <- structured_reasoning?(request.input_items) do
      :ok
    else
      _failure -> incompatible()
    end
  end

  defp valid_profile?(profile) do
    profile["schema_version"] == 1 and profile["enable_thinking"] == true and
      profile["reasoning_effort"] == "medium" and profile["output_projection"] == "legacy_blended" and
      valid_names?(profile) and valid_digests?(profile) and valid_nodes?(profile) and
      valid_limit?(Map.get(profile, "max_projection_bytes", 262_144)) and
      valid_request_seconds?(profile)
  end

  # SPEC.md §7.2.9: the bridge admits only the authoritative rendered bytes and
  # their whole-prompt token IDs, so a selected request without them is refused
  # here instead of failing opaquely inside the Worker.
  defp authoritative_tokenization?(%CanonicalRequest{
         rendered_prompt: prompt,
         input_token_count: count,
         prompt_token_ids: ids
       }) do
    is_binary(prompt) and prompt != "" and is_list(ids) and ids != [] and length(ids) == count
  end

  defp valid_request_seconds?(%{"max_request_seconds" => seconds}),
    do: is_number(seconds) and seconds > 0 and seconds <= @max_request_seconds

  defp valid_request_seconds?(_profile), do: true

  # The bridge refuses a deadline further away than its frozen request limit.
  defp within_request_limit(schedule, %{"max_request_seconds" => seconds}) do
    case Map.get(schedule, :timeout_at) do
      %DateTime{} = timeout_at ->
        remaining_ms = DateTime.diff(timeout_at, DateTime.utc_now(), :millisecond)

        if remaining_ms > 0 and remaining_ms <= seconds * 1000,
          do: :ok,
          else: incompatible()

      _missing ->
        incompatible()
    end
  end

  defp within_request_limit(_schedule, _profile), do: :ok

  defp valid_names?(profile) do
    Enum.all?(~w(profile_id model_id), fn key ->
      is_binary(profile[key]) and byte_size(profile[key]) in 1..256
    end)
  end

  defp valid_digests?(profile) do
    Enum.all?(~w(version artifact_sha256 template_sha256 tokenizer_config_sha256), fn key ->
      is_binary(profile[key]) and String.match?(profile[key], ~r/\A[0-9a-f]{64}\z/)
    end)
  end

  defp valid_nodes?(%{"authorized_node_ids" => ids}) when is_list(ids) do
    length(ids) in 1..64 and Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..256))
  end

  defp valid_nodes?(_profile), do: false

  defp structured_reasoning?(messages) do
    Enum.any?(messages, fn message ->
      Enum.any?(
        ~w(reasoning reasoning_content reasoning_details thinking),
        &Map.has_key?(message, &1)
      )
    end)
  end

  defp assets(model, opts) do
    loader = Keyword.get(opts, :assets_loader, &ModelRenderAssets.load/1)
    loader.(model)
  end

  defp verify_assets(assets, profile) do
    manifest = Keyword.get(assets, :manifest)

    with %{chat_template: %{sha256: digest}, tokenizer: %{config_path: path}} <- manifest,
         true <- digest == profile["template_sha256"],
         true <- is_binary(path),
         {:ok, bytes} <- read_config(Keyword.fetch!(assets, :bundle_root), path),
         true <-
           Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
             profile["tokenizer_config_sha256"] do
      :ok
    else
      _failure -> incompatible()
    end
  end

  defp read_config(root, relative) do
    root = Path.expand(root)
    path = Path.expand(relative, root)

    if String.starts_with?(path, root <> "/") do
      bounded_config_read(path)
    else
      incompatible()
    end
  end

  defp bounded_config_read(path) do
    case File.open(path, [:read, :binary], &read_config_bytes/1) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @max_config_bytes -> {:ok, bytes}
      _failure -> incompatible()
    end
  end

  defp read_config_bytes(file), do: IO.binread(file, @max_config_bytes + 1)

  defp valid_limit?(limit), do: is_integer(limit) and limit > 0 and limit <= @max_bytes

  defp bounded_envelope(request, profile) do
    limit = Map.get(profile, "max_projection_bytes", 262_144)

    json =
      profile
      |> Map.take(@binding_keys)
      |> Map.merge(%{"messages" => request.input_items, "tools" => request.tooling.tools})
      |> Jason.encode!()

    if valid_limit?(limit) and byte_size(json) <= limit,
      do: {:ok, json},
      else: incompatible()
  end

  defp incompatible,
    do:
      {:error, {:tokenization, {:runtime_incompatible, "TensorFold experiment admission failed"}}}
end
