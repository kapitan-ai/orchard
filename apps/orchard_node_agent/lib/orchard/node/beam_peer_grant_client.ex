defmodule Orchard.Node.BeamPeerGrantClient do
  @moduledoc """
  Retrieves and installs one certificate-authenticated BEAM Peer Grant.
  """

  alias Orchard.Cluster.V1.RetrieveBeamPeerGrantResponse
  alias Orchard.Node.BeamPeerGrantStore
  alias Orchard.TransportTLS.PeerVerifier

  @spec retrieve_and_install(
          String.t(),
          map(),
          String.t(),
          String.t(),
          Orchard.Cluster.V1.RetrieveBeamPeerGrantRequest.t(),
          keyword()
        ) :: {:ok, BeamPeerGrantStore.stored_grant()} | {:error, atom()}
  def retrieve_and_install(root, identity, node_beam_name, target, request, opts \\ [])
      when is_binary(root) and is_map(identity) and is_binary(node_beam_name) and
             is_binary(target) do
    transport = Keyword.get(opts, :transport, __MODULE__.GRPCTransport)

    with {:ok, credential} <- client_credential(identity),
         {:ok, response} <- retrieve(transport, target, credential, request),
         true <- response_matches_request?(response, request),
         true <- response.node_beam_name == node_beam_name do
      install_response(root, identity, node_beam_name, response)
    else
      false -> {:error, :beam_peer_credential_mismatch}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_peer_grant_control_unavailable}
    end
  end

  defp retrieve(transport, target, credential, request) do
    transport.retrieve(target, credential, request)
  rescue
    _error -> {:error, :beam_peer_grant_control_unavailable}
  catch
    :exit, _reason -> {:error, :beam_peer_grant_control_unavailable}
  end

  defp response_matches_request?(response, request) do
    response.grant_id == request.grant_id and
      response.generation == request.generation and
      response.controller_id == request.controller_id
  end

  @spec install_response(String.t(), map(), String.t(), RetrieveBeamPeerGrantResponse.t()) ::
          {:ok, BeamPeerGrantStore.stored_grant()} | {:error, atom()}
  def install_response(
        root,
        identity,
        node_beam_name,
        %RetrieveBeamPeerGrantResponse{} = response
      )
      when is_binary(root) and is_map(identity) and is_binary(node_beam_name) do
    with {:ok, delivery} <- normalize_response(response) do
      BeamPeerGrantStore.install(root, identity, delivery, node_beam_name)
    end
  end

  defp normalize_response(response) do
    with {:ok, issued_at} <- datetime(response.issued_at),
         {:ok, not_before_at} <- datetime(response.not_before_at),
         {:ok, cutover_at} <- optional_datetime(response.cutover_at),
         {:ok, expires_at} <- datetime(response.expires_at) do
      response
      |> Map.from_struct()
      |> Map.delete(:__unknown_fields__)
      |> Map.merge(%{
        issued_at: issued_at,
        not_before_at: not_before_at,
        cutover_at: cutover_at,
        expires_at: expires_at
      })
      |> then(&{:ok, &1})
    else
      _other -> {:error, :beam_peer_grant_response_invalid}
    end
  end

  defp client_credential(identity) do
    with certfile when is_binary(certfile) <- value(identity, :certfile),
         keyfile when is_binary(keyfile) <- value(identity, :keyfile),
         cacertfile when is_binary(cacertfile) <- value(identity, :cacertfile),
         controller_uri when is_binary(controller_uri) <- value(identity, :controller_uri_san),
         {:ok, controller_serial} <- controller_serial(identity),
         controller_fingerprint when is_binary(controller_fingerprint) <-
           value(identity, :controller_certificate_fingerprint) do
      {:ok,
       GRPC.Credential.new(
         ssl: [
           certfile: certfile,
           keyfile: keyfile,
           cacertfile: cacertfile,
           verify: :verify_peer,
           versions: [:"tlsv1.3"],
           server_name_indication: :disable,
           verify_fun:
             PeerVerifier.new(controller_uri,
               serial: controller_serial,
               fingerprint: controller_fingerprint
             )
         ]
       )}
    else
      _other -> {:error, :node_runtime_tls_identity_invalid}
    end
  end

  defp controller_serial(identity) do
    case value(identity, :controller_certificate_identifier) do
      "serial:" <> serial when serial != "" -> {:ok, serial}
      _other -> {:error, :node_runtime_tls_identity_invalid}
    end
  end

  defp optional_datetime(""), do: {:ok, nil}
  defp optional_datetime(value), do: datetime(value)

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _other -> {:error, :beam_peer_grant_response_invalid}
    end
  end

  defp datetime(_value), do: {:error, :beam_peer_grant_response_invalid}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end

defmodule Orchard.Node.BeamPeerGrantClient.GRPCTransport do
  @moduledoc false

  alias Orchard.Cluster.V1.ControllerPeerGrantService.Stub

  @default_connect_timeout_ms 5_000
  @default_rpc_timeout_ms 5_000

  @spec retrieve(String.t(), GRPC.Credential.t(), struct(), keyword()) ::
          {:ok, Orchard.Cluster.V1.RetrieveBeamPeerGrantResponse.t()} | {:error, atom()}
  def retrieve(target, credential, request, opts \\ []) do
    connector = Keyword.get(opts, :connector, GRPC.Stub)
    service_stub = Keyword.get(opts, :service_stub, Stub)
    connect_timeout_ms = timeout(opts, :connect_timeout_ms, @default_connect_timeout_ms)
    rpc_timeout_ms = timeout(opts, :rpc_timeout_ms, @default_rpc_timeout_ms)

    connect_options = [
      cred: credential,
      adapter_opts: [transport_opts: [timeout: connect_timeout_ms]]
    ]

    case connector.connect(target, connect_options) do
      {:ok, channel} ->
        retrieve_connected(channel, request, connector, service_stub, rpc_timeout_ms)

      {:error, _reason} ->
        {:error, :beam_peer_grant_control_unavailable}
    end
  end

  defp retrieve_connected(channel, request, connector, service_stub, rpc_timeout_ms) do
    result = safe_retrieve(service_stub, channel, request, rpc_timeout_ms)
    safe_disconnect(connector, channel)
    result
  end

  defp safe_retrieve(service_stub, channel, request, rpc_timeout_ms) do
    case service_stub.retrieve_beam_peer_grant(channel, request, timeout: rpc_timeout_ms) do
      {:ok, response} -> {:ok, response}
      {:error, error} -> {:error, control_error(error)}
    end
  rescue
    _error -> {:error, :beam_peer_grant_control_unavailable}
  catch
    _kind, _reason -> {:error, :beam_peer_grant_control_unavailable}
  end

  defp timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp safe_disconnect(connector, channel) do
    connector.disconnect(channel)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp control_error(%GRPC.RPCError{message: message}) do
    case message do
      "beam_peer_grant_missing" -> :beam_peer_grant_missing
      "beam_peer_grant_generation_mismatch" -> :beam_peer_grant_generation_mismatch
      "beam_peer_grant_revoked" -> :beam_peer_grant_revoked
      "beam_peer_grant_expired" -> :beam_peer_grant_expired
      "beam_peer_grant_not_active" -> :beam_peer_grant_not_active
      "beam_peer_grant_delivery_unavailable" -> :beam_peer_grant_delivery_unavailable
      "beam_peer_credential_mismatch" -> :beam_peer_credential_mismatch
      _other -> :beam_peer_grant_control_rejected
    end
  end

  defp control_error(_error), do: :beam_peer_grant_control_unavailable
end
