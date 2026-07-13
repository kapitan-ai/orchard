defmodule Orchard.RuntimeEndpoint.BeamClient do
  @moduledoc """
  Runtime Endpoint client backed by first-party BEAM Distribution.

  Releases and `:prod` require explicit BEAM guardrail configuration before
  connecting.
  Source-dev and test may use the adapter without enabled guardrails for local
  endpoint validation, but targets are still normalized and BEAM node addresses
  are validated at the client boundary.
  """

  @behaviour Orchard.RuntimeEndpoint.Client

  alias Orchard.BeamPeerGrants
  alias Orchard.Nodes
  alias Orchard.RuntimeEndpoint.{BeamConfig, Operation, Target}

  defstruct [:authenticated_peer, :node, :target, :server_module]

  @type t :: %__MODULE__{
          authenticated_peer: Orchard.RuntimeEndpoint.AuthenticatedPeer.t() | nil,
          node: node(),
          target: Target.t(),
          server_module: module()
        }

  @default_timeout 5_000
  @default_server_module Orchard.Node.RuntimeEndpoint
  @expired_cookie :orchard_expired_peer_grant

  @impl true
  def connect(target), do: connect(target, [])

  @spec connect(Target.t() | map() | keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(%Target{} = target, opts) when is_list(opts) do
    target = Target.normalize(target)

    case target.transport do
      :beam -> connect_beam(target, opts)
      transport -> {:error, {:unsupported_transport, transport}}
    end
  end

  def connect(target, opts) when (is_list(target) or is_map(target)) and is_list(opts) do
    target
    |> Target.normalize()
    |> connect(opts)
  end

  defp connect_beam(%Target{transport: :beam} = target, opts) do
    with {:ok, config} <- validate_beam_enabled(),
         :ok <- validate_production_target_provenance(target),
         {:ok, authorization} <- BeamPeerGrants.authorize_target(target, opts),
         :ok <- validate_beam_target(config, target, opts),
         {:ok, node} <- target_node(target, authorization, opts) do
      establish_connection(node, target, authorization, opts)
    end
  end

  defp establish_connection(node, target, authorization, opts) do
    case ensure_connected(node, opts) do
      :ok ->
        finish_connect(node, target, authorization, opts)

      {:error, _reason} = error ->
        scrub_installed_peer(node, authorization, opts)
        error
    end
  end

  defp scrub_installed_peer(node, authorization, opts) when not is_nil(authorization),
    do: invalidate_peer(node, opts)

  defp scrub_installed_peer(_node, nil, _opts), do: :ok

  @impl true
  def disconnect(%__MODULE__{}), do: :ok

  @impl true
  def status(connection, opts \\ [])

  def status(%__MODULE__{authenticated_peer: nil, target: target} = connection, opts) do
    rpc(connection, :status, [target, opts], opts)
  end

  def status(
        %__MODULE__{authenticated_peer: peer, target: target} = connection,
        opts
      ) do
    with {:ok, response} <- rpc(connection, :status, [target, opts], opts),
         {:ok, _node} <-
           Nodes.observe_authenticated_status(target, response, DateTime.utc_now(), peer) do
      {:ok, response}
    else
      :noop -> {:error, :beam_peer_observation_rejected}
      {:error, reason} -> {:error, reason}
    end
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
    validate_beam_mode(
      BeamPeerGrants.production_enabled?(),
      BeamConfig.config()[:enabled] == true,
      source_dev?()
    )
  end

  defp validate_beam_mode(true, _enabled, _source_dev),
    do: BeamConfig.validate_peer_grant_enabled()

  defp validate_beam_mode(false, true, _source_dev), do: BeamConfig.validate_enabled()
  defp validate_beam_mode(false, false, true), do: {:ok, nil}
  defp validate_beam_mode(false, false, false), do: {:error, :beam_distribution_disabled}

  defp source_dev?, do: Code.ensure_loaded?(Mix) and Mix.env() != :prod

  defp validate_beam_target(nil, _target, _opts), do: :ok

  defp validate_beam_target(%BeamConfig{} = config, target, opts),
    do: BeamConfig.validate_target(config, target, opts)

  defp validate_production_target_provenance(%Target{metadata: metadata}) do
    if BeamPeerGrants.production_enabled?() do
      case metadata_value(metadata, :source) do
        source when source in [:trusted_node_inventory, "trusted_node_inventory"] ->
          validate_production_grant_reference(metadata)

        _source ->
          {:error, :beam_target_not_in_trusted_inventory}
      end
    else
      :ok
    end
  end

  defp validate_production_grant_reference(metadata) do
    case Ecto.UUID.cast(metadata_value(metadata, :grant_id)) do
      {:ok, _grant_id} -> :ok
      :error -> {:error, :beam_peer_grant_missing}
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp target_node(%Target{} = target, nil, _opts), do: compatibility_target_node(target)

  defp target_node(
         %Target{},
         %{node_name: node_name, encoded_secret: encoded_secret} = authorization,
         opts
       )
       when is_binary(node_name) and is_binary(encoded_secret) do
    with :ok <- BeamPeerGrants.ensure_authorization_current(authorization, opts) do
      install_peer_cookie(node_name, encoded_secret, opts)
    end
  end

  defp install_peer_cookie(node_name, encoded_secret, opts) do
    if Keyword.get(opts, :current_node, node()) == :nonode@nohost do
      {:error, :beam_distribution_unavailable}
    else
      node = String.to_atom(node_name)
      cookie = String.to_atom(encoded_secret)
      cookie_setter = Keyword.get(opts, :cookie_setter, &Node.set_cookie/2)

      if cookie_setter.(node, cookie),
        do: {:ok, node},
        else: {:error, :beam_cookie_install_failed}
    end
  end

  defp finish_connect(node, target, authorization, opts) do
    case BeamPeerGrants.ensure_authorization_current(authorization, opts) do
      :ok ->
        {:ok,
         %__MODULE__{
           authenticated_peer: authenticated_peer(authorization),
           node: node,
           target: target,
           server_module: server_module(target)
         }}

      {:error, _reason} = error ->
        invalidate_peer(node, opts)
        error
    end
  end

  defp invalidate_peer(node, opts) do
    cookie_setter = Keyword.get(opts, :cookie_setter, &Node.set_cookie/2)
    disconnect = Keyword.get(opts, :disconnect, &Node.disconnect/1)
    _cookie_result = safe_transport_call(cookie_setter, [node, @expired_cookie])
    _disconnect_result = safe_transport_call(disconnect, [node])
    :ok
  end

  defp compatibility_target_node(%Target{address: node}) when is_atom(node), do: {:ok, node}

  defp compatibility_target_node(%Target{address: address}) when is_binary(address) do
    {:ok, String.to_existing_atom(address)}
  rescue
    ArgumentError -> {:error, :beam_target_unknown}
  end

  defp compatibility_target_node(%Target{address: address}),
    do: {:error, {:invalid_beam_node, address}}

  defp authenticated_peer(%{authenticated_peer: peer}), do: peer
  defp authenticated_peer(nil), do: nil

  defp ensure_connected(node, opts) do
    case Keyword.get(opts, :connector) do
      connector when is_function(connector, 1) -> connector.(node)
      nil -> ensure_connected(node)
    end
  end

  defp ensure_connected(node) when node == node(), do: :ok

  defp ensure_connected(node) do
    if node() == :nonode@nohost do
      {:error, :beam_distribution_unavailable}
    else
      case Node.ping(node) do
        :pong -> :ok
        :pang -> {:error, :beam_node_unavailable}
      end
    end
  end

  defp safe_transport_call(fun, args) do
    apply(fun, args)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
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

  defp normalize_rpc_result({:badrpc, :nodedown}), do: {:error, :beam_node_unavailable}

  defp normalize_rpc_result({:badrpc, {:EXIT, :nodedown}}),
    do: {:error, :beam_node_unavailable}

  defp normalize_rpc_result({:badrpc, :timeout}), do: {:error, :beam_node_timeout}
  defp normalize_rpc_result({:badrpc, _reason}), do: {:error, :beam_rpc_failed}

  defp normalize_rpc_result(result), do: result

  defp safe_apply(module, function, args) do
    apply(module, function, args)
  rescue
    _error -> {:error, :beam_rpc_failed}
  catch
    :exit, _reason -> {:error, :beam_rpc_failed}
    _kind, _reason -> {:error, :beam_rpc_failed}
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

  defp prefix_cache_status_code(:beam_node_timeout), do: "timeout"
  defp prefix_cache_status_code(:beam_node_unavailable), do: "unavailable"
  defp prefix_cache_status_code(:beam_distribution_unavailable), do: "unavailable"
  defp prefix_cache_status_code(_reason), do: "error"
end
