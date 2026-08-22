defmodule Orchard.Inference.AdmissionPolicy do
  @moduledoc """
  Resolves authoritative admission and routing defaults onto a CanonicalRequest.

  SPEC.md routing_policies defaults and §3.4 admission budgets are applied before
  canonical persistence so scheduler and queue owners consume the same values the
  request row records.

  Request deadlines use an explicit timeout as the generation budget when one is
  supplied, otherwise the configured request timeout is the generation budget
  and floor. When a resolved policy permits cold loading, its cold-start budget
  is added to that generation budget and the queue-wait budget.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.{Admission, ResolvedPolicy}
  alias Orchard.Inference

  @default_max_cold_start_ms 15_000
  @default_queue_wait_ms 3_000
  @default_residency_preference :allow_cold_load

  @type resolve_opts :: [
          {:max_cold_start_ms, non_neg_integer()},
          {:queue_wait_ms, non_neg_integer()},
          {:timeout_ms, pos_integer()},
          {:residency_preference, ResolvedPolicy.residency_preference()},
          {:quota_id, String.t() | nil},
          {:routing_policy_id, String.t() | nil},
          {:allowed_pool_ids, [String.t()]},
          {:max_active_requests, pos_integer() | nil}
        ]

  @resolve_option_keys [
    :max_cold_start_ms,
    :queue_wait_ms,
    :timeout_ms,
    :residency_preference,
    :quota_id,
    :routing_policy_id,
    :allowed_pool_ids,
    :max_active_requests
  ]

  @doc false
  @spec resolve_option_keys() :: [atom()]
  def resolve_option_keys, do: @resolve_option_keys

  @doc """
  SPEC default cold-start budget when no routing policy row is resolved.
  """
  @spec default_max_cold_start_ms() :: pos_integer()
  def default_max_cold_start_ms, do: @default_max_cold_start_ms

  @doc """
  SPEC default queue wait budget when no routing policy row is resolved.
  """
  @spec default_queue_wait_ms() :: pos_integer()
  def default_queue_wait_ms, do: @default_queue_wait_ms

  @doc """
  Returns the canonical routing values used when an access grant has no policy.
  """
  @spec default_routing_opts() :: resolve_opts()
  def default_routing_opts do
    [
      routing_policy_id: nil,
      allowed_pool_ids: [],
      residency_preference: @default_residency_preference,
      max_cold_start_ms: @default_max_cold_start_ms,
      queue_wait_ms: @default_queue_wait_ms
    ]
  end

  @doc """
  Returns a CanonicalRequest with authoritative admission and resolved_policy.

  Defaults come from SPEC routing_policies (`max_cold_start_ms`, `max_queue_wait_ms`)
  and `allow_cold_load` residency. `timeout_ms` falls back to the configured
  request timeout when present, otherwise to the legacy 30-second fallback.
  For a resolved `allow_cold_load` policy, the effective deadline is the
  configured or explicit generation budget plus queue wait and cold-start
  budgets.
  """
  @spec resolve(CanonicalRequest.t(), resolve_opts()) :: CanonicalRequest.t()
  def resolve(%CanonicalRequest{} = request, opts \\ []) when is_list(opts) do
    admission = resolve_admission(request.admission || %Admission{}, opts)
    resolved_policy = resolve_policy(request.resolved_policy || %ResolvedPolicy{}, opts)

    %CanonicalRequest{request | admission: admission, resolved_policy: resolved_policy}
  end

  @doc """
  Builds default admission + resolved_policy attrs for CanonicalRequest.new/1.
  """
  @spec default_attrs(resolve_opts()) :: %{
          admission: map(),
          resolved_policy: map()
        }
  def default_attrs(opts \\ []) when is_list(opts) do
    admission = resolve_admission(%Admission{}, opts)
    resolved_policy = resolve_policy(%ResolvedPolicy{}, opts)

    %{
      admission: Map.from_struct(admission),
      resolved_policy: Map.from_struct(resolved_policy)
    }
  end

  defp resolve_admission(%Admission{} = admission, opts) do
    queue_wait_ms = resolve_queue_wait_ms(admission.queue_wait_ms, opts)
    max_cold_start_ms = resolve_max_cold_start_ms(admission.max_cold_start_ms, opts)
    residency_preference = resolve_residency_preference(nil, opts)

    %Admission{
      timeout_ms:
        resolve_timeout_ms(
          admission.timeout_ms,
          queue_wait_ms,
          max_cold_start_ms,
          residency_preference,
          opts
        ),
      queue_wait_ms: queue_wait_ms,
      max_cold_start_ms: max_cold_start_ms
    }
  end

  defp resolve_policy(%ResolvedPolicy{} = policy, opts) do
    %ResolvedPolicy{
      quota_id: Keyword.get(opts, :quota_id, policy.quota_id),
      routing_policy_id: Keyword.get(opts, :routing_policy_id, policy.routing_policy_id),
      allowed_pool_ids: Keyword.get(opts, :allowed_pool_ids, policy.allowed_pool_ids),
      max_active_requests: Keyword.get(opts, :max_active_requests, policy.max_active_requests),
      residency_preference: resolve_residency_preference(policy.residency_preference, opts)
    }
  end

  defp resolve_timeout_ms(current, queue_wait_ms, max_cold_start_ms, residency_preference, opts) do
    timeout_ms =
      cond do
        keyword_integer?(opts, :timeout_ms) ->
          Keyword.fetch!(opts, :timeout_ms)

        is_integer(current) and current > 0 ->
          current

        true ->
          case Inference.request_timeout_ms() do
            timeout when is_integer(timeout) and timeout > 0 -> timeout
            _other -> 30_000
          end
      end

    if policy_timeout?(opts, residency_preference) do
      timeout_ms + queue_wait_ms + max_cold_start_ms
    else
      timeout_ms
    end
  end

  defp policy_timeout?(opts, :allow_cold_load) do
    Keyword.has_key?(opts, :max_cold_start_ms) or Keyword.has_key?(opts, :residency_preference)
  end

  defp policy_timeout?(_opts, _residency_preference), do: false

  defp resolve_queue_wait_ms(current, opts) do
    cond do
      keyword_integer?(opts, :queue_wait_ms) -> Keyword.fetch!(opts, :queue_wait_ms)
      is_integer(current) and current > 0 -> current
      true -> @default_queue_wait_ms
    end
  end

  defp resolve_max_cold_start_ms(current, opts) do
    residency =
      case Keyword.get(opts, :residency_preference) do
        preference
        when preference in [:required_loaded, :prefer_loaded, :allow_cold_load] ->
          preference

        _other ->
          nil
      end

    cond do
      keyword_integer?(opts, :max_cold_start_ms) ->
        Keyword.fetch!(opts, :max_cold_start_ms)

      # Historical constructor default was 0 against allow_cold_load. Upgrade only
      # that contradictory pair so required_loaded + 0 stays intentional.
      current == 0 and residency in [nil, :allow_cold_load, :prefer_loaded] ->
        @default_max_cold_start_ms

      is_integer(current) and current >= 0 ->
        current

      true ->
        @default_max_cold_start_ms
    end
  end

  defp resolve_residency_preference(current, opts) do
    case Keyword.get(opts, :residency_preference, current) do
      preference
      when preference in [:required_loaded, :prefer_loaded, :allow_cold_load] ->
        preference

      _other ->
        @default_residency_preference
    end
  end

  defp keyword_integer?(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> true
      _other -> false
    end
  end
end
