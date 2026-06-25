defmodule Orchard.RuntimeEndpoint.BeamClient do
  @moduledoc """
  Runtime Endpoint client backed by first-party BEAM Distribution.
  """

  @behaviour Orchard.RuntimeEndpoint.Client

  alias Orchard.RuntimeEndpoint.{BeamConfig, Operation, Target}

  defstruct [:node, :target, :server_module]

  @type t :: %__MODULE__{node: node(), target: Target.t(), server_module: module()}

  @default_timeout 5_000
  @default_server_module Orchard.Node.RuntimeEndpoint

  @impl true
  def connect(%Target{transport: :beam} = target) do
    with :ok <- validate_beam_enabled(),
         {:ok, node} <- target_node(target),
         :ok <- ensure_connected(node) do
      {:ok, %__MODULE__{node: node, target: target, server_module: server_module(target)}}
    end
  end

  def connect(%Target{} = target), do: {:error, {:unsupported_transport, target.transport}}

  def connect(target) when is_list(target) or is_map(target) do
    target
    |> Target.normalize()
    |> connect()
  end

  @impl true
  def disconnect(%__MODULE__{}), do: :ok

  @impl true
  def status(%__MODULE__{target: target} = connection, opts \\ []) do
    rpc(connection, :status, [target, opts], opts)
  end

  @impl true
  def ensure_model_loaded(
        %__MODULE__{} = connection,
        %Operation.EnsureModelLoadedRequest{} = request,
        opts \\ []
      ) do
    rpc(connection, :ensure_model_loaded, [request, opts], opts)
  end

  @impl true
  def unload_model(
        %__MODULE__{} = connection,
        %Operation.UnloadModelRequest{} = request,
        opts \\ []
      ) do
    rpc(connection, :unload_model, [request, opts], opts)
  end

  @impl true
  def execute_inference(
        %__MODULE__{} = connection,
        %Operation.ExecuteRequest{} = request,
        opts \\ []
      ) do
    owner = Keyword.get(opts, :owner, self())
    stream_ref = make_ref()

    {:ok, _pid} =
      Task.start(fn ->
        case rpc(connection, :execute_inference, [request, owner, stream_ref, opts], opts) do
          {:ok, _remote_ref} -> :ok
          {:error, reason} -> send(owner, {:runtime_endpoint_done, stream_ref, {:error, reason}})
        end
      end)

    {:ok, stream_ref}
  end

  @impl true
  def cancel_inference(
        %__MODULE__{} = connection,
        %Operation.CancelRequest{} = request,
        opts \\ []
      ) do
    rpc(connection, :cancel_inference, [request, opts], opts)
  end

  @impl true
  def score_prefix_cache(target_or_connection, request, opts \\ [])

  def score_prefix_cache(
        %__MODULE__{} = connection,
        %Operation.PrefixCacheScoreRequest{} = request,
        opts
      ) do
    case rpc(connection, :score_prefix_cache, [request, opts], opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:ok, failed_prefix_cache_score(reason)}
    end
  end

  def score_prefix_cache(%Target{} = target, %Operation.PrefixCacheScoreRequest{} = request, opts) do
    case connect(target) do
      {:ok, connection} -> score_prefix_cache(connection, request, opts)
      {:error, reason} -> {:ok, failed_prefix_cache_score(reason)}
    end
  end

  def score_prefix_cache(target, %Operation.PrefixCacheScoreRequest{} = request, opts)
      when is_list(target) or is_map(target) do
    target
    |> Target.normalize()
    |> score_prefix_cache(request, opts)
  end

  # BEAM connections must validate guardrails when enabled. When BEAM is not
  # enabled, only source-dev (Mix present, non-:prod) may proceed for local-node
  # tests; releases (where Mix is absent) and :prod require explicit enablement.
  # `Mix.env/0` is unavailable in a packaged release, so it is never called at
  # runtime here.
  defp validate_beam_enabled do
    cond do
      BeamConfig.config()[:enabled] == true ->
        BeamConfig.validate_enabled() |> validation_result()

      Code.ensure_loaded?(Mix) and Mix.env() != :prod ->
        :ok

      true ->
        {:error, :beam_distribution_disabled}
    end
  end

  defp validation_result({:ok, _config}), do: :ok
  defp validation_result({:error, reason}), do: {:error, reason}

  defp target_node(%Target{address: node}) when is_atom(node), do: {:ok, node}

  defp target_node(%Target{address: address}) when is_binary(address) do
    {:ok, String.to_existing_atom(address)}
  rescue
    ArgumentError -> {:error, :unknown_beam_node}
  end

  defp target_node(%Target{address: address}), do: {:error, {:invalid_beam_node, address}}

  defp ensure_connected(node) when node == node(), do: :ok

  defp ensure_connected(node) do
    if node() == :nonode@nohost do
      {:error, :beam_distribution_unavailable}
    else
      case Node.ping(node) do
        :pong -> :ok
        :pang -> {:error, :node_unavailable}
      end
    end
  end

  if Mix.env() == :test do
    defp server_module(%Target{metadata: %{server_module: module}}) when is_atom(module),
      do: module

    defp server_module(%Target{metadata: %{"server_module" => module}}) when is_atom(module),
      do: module
  end

  defp server_module(_target), do: @default_server_module

  defp rpc(%__MODULE__{node: node} = connection, function, args, _opts) when node == node() do
    safe_apply(connection.server_module, function, args)
  end

  defp rpc(%__MODULE__{} = connection, function, args, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    connection.node
    |> :rpc.call(connection.server_module, function, args, timeout)
    |> normalize_rpc_result()
  end

  defp normalize_rpc_result({:badrpc, :nodedown}), do: {:error, :node_unavailable}
  defp normalize_rpc_result({:badrpc, {:EXIT, :nodedown}}), do: {:error, :node_unavailable}
  defp normalize_rpc_result({:badrpc, :timeout}), do: {:error, :node_timeout}

  defp normalize_rpc_result({:badrpc, reason}),
    do: {:error, {:beam_rpc_error, safe_reason(reason)}}

  defp normalize_rpc_result(result), do: result

  defp safe_apply(module, function, args) do
    apply(module, function, args)
  rescue
    _error -> {:error, {:beam_rpc_error, :remote_error}}
  catch
    :exit, _reason -> {:error, {:beam_rpc_error, :remote_error}}
    _kind, _reason -> {:error, {:beam_rpc_error, :remote_error}}
  end

  defp failed_prefix_cache_score(reason) do
    %Operation.PrefixCacheScoreResult{
      status_code: prefix_cache_status_code(reason),
      status_message: "prefix cache score unavailable",
      resident_fingerprint_match: false,
      score_tier: "unknown",
      session_started_unix_ms: 0
    }
  end

  defp prefix_cache_status_code(:node_timeout), do: "timeout"
  defp prefix_cache_status_code(:node_unavailable), do: "unavailable"
  defp prefix_cache_status_code(:beam_distribution_unavailable), do: "unavailable"
  defp prefix_cache_status_code(_reason), do: "error"

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason({kind, _detail}) when is_atom(kind), do: kind
  defp safe_reason(_reason), do: :remote_error
end
