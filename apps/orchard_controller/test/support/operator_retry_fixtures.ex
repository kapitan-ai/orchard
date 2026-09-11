defmodule Orchard.TestSupport.OperatorRetryFixtures do
  @moduledoc false

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.CanonicalRequestSerializer
  alias Orchard.Requests

  @spec create_full_legacy_source!(struct(), struct(), keyword()) :: struct()
  def create_full_legacy_source!(tenant, model, opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, :chat_completions)
    internal_id = Ecto.UUID.generate()
    public_id = public_id(endpoint, internal_id)

    canonical =
      CanonicalRequest.new(%{
        internal_id: internal_id,
        public_id: public_id,
        endpoint: endpoint,
        tenant_id: tenant.id,
        principal_type: :tenant,
        principal_id: tenant.id,
        model_ref: %{model_id: model.model_id, version: model.version},
        input_items: [%{"role" => "user", "content" => "retry this request"}],
        rendered_prompt: "user retry this request\nassistant",
        input_token_count: 5,
        stream?: false,
        sampling: %{temperature: 0.7, top_p: 0.9, max_output_tokens: 64, stop: [], seed: nil},
        response_format: %{type: :text},
        tooling: %{
          tools: [],
          requested_tools: [],
          tool_choice: nil,
          registry_snapshot: %{entries: []},
          execution_snapshot: %{entries: []}
        },
        metadata: %{},
        admission: %{timeout_ms: 10_000, queue_wait_ms: 1_000, max_cold_start_ms: 1_000},
        resolved_policy: %{
          quota_id: nil,
          routing_policy_id: nil,
          allowed_pool_ids: [],
          max_active_requests: nil,
          residency_preference: :allow_cold_load
        }
      })

    serialized = CanonicalRequestSerializer.serialize(canonical)

    attrs =
      %{
        id: internal_id,
        public_id: public_id,
        endpoint: endpoint,
        tenant_id: tenant.id,
        principal_type: :tenant,
        model_id: model.id,
        requested_model: "#{model.model_id}@#{model.version}",
        state: :failed,
        stream: false,
        payload_capture_mode: :full,
        canonical_request: serialized,
        request_payload: %{"prompt" => canonical.rendered_prompt},
        body_hash: :crypto.hash(:sha256, Jason.encode!(serialized)),
        sampling_params: CanonicalRequestSerializer.sampling_params(canonical.sampling),
        response_format: %{"type" => "text"},
        input_tokens: canonical.input_token_count,
        output_tokens: 0,
        reserved_output_tokens: 0,
        timeout_at: DateTime.add(DateTime.utc_now(), 10_000, :millisecond)
      }
      |> Map.merge(Map.new(Keyword.drop(opts, [:endpoint])))

    case Requests.create_request(attrs) do
      {:ok, request} ->
        request

      {:error, changeset} ->
        raise ArgumentError, "retry source fixture failed: #{inspect(changeset.errors)}"
    end
  end

  defp public_id(:chat_completions, internal_id), do: "chatcmpl-#{internal_id}"
  defp public_id(:responses, _internal_id), do: "resp_#{Ecto.UUID.generate()}"
end
