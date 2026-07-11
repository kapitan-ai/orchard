defmodule OrchardCLI.Commands.NodeJoin do
  @moduledoc false

  alias OrchardCLI.NodeEnrollmentBundle
  alias OrchardCLI.NodeIdentity.Store
  alias OrchardCLI.PinnedHTTPS

  @default_support_root "/Library/Application Support/Orchard"

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(["--help"]), do: {:ok, usage()}
  def run(["help"]), do: {:ok, usage()}

  def run(args) do
    with {:ok, bundle_path} <- parse_args(args),
         {:ok, bundle} <- NodeEnrollmentBundle.load(bundle_path),
         {:ok, root} <- identity_root(),
         {:ok, runtime_endpoint} <- runtime_endpoint(),
         {:ok, identity} <- Store.prepare(root, bundle) do
      join(root, bundle, Map.put(identity, :runtime_endpoint, runtime_endpoint))
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp parse_args(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [enrollment_bundle: :string])

    case {Keyword.get_values(options, :enrollment_bundle), positional, invalid} do
      {[path], [], []} when path != "" -> {:ok, path}
      _other -> {:error, :invalid_join_arguments}
    end
  end

  defp identity_root do
    configured = Application.get_env(:orchard_cli, :node_identity_root)
    support_root = System.get_env("ORCHARD_SUPPORT_ROOT") || @default_support_root

    root =
      configured || System.get_env("ORCHARD_NODE_IDENTITY_ROOT") ||
        Path.join(support_root, "config/node-identity")

    if is_binary(root) and String.trim(root) != "" do
      {:ok, Path.expand(root)}
    else
      {:error, :node_identity_root_invalid}
    end
  end

  defp runtime_endpoint do
    configured = Application.get_env(:orchard_cli, :node_runtime_endpoint, [])
    host = endpoint_host(configured)
    port = endpoint_port(configured)
    hostname = endpoint_hostname(configured, host)

    if valid_endpoint_host?(host) and valid_endpoint_port?(port) and valid_hostname?(hostname) do
      {:ok, %{host: host, port: port, hostname: hostname}}
    else
      {:error, :node_runtime_endpoint_invalid}
    end
  end

  defp endpoint_host(configured) do
    Keyword.get(configured, :host) ||
      System.get_env("ORCHARD_NODE_AGENT_ADVERTISE_HOST") ||
      System.get_env("ORCHARD_NODE_AGENT_LISTEN_HOST") || "127.0.0.1"
  end

  defp endpoint_port(configured) do
    configured_port = Keyword.get(configured, :port)

    case configured_port || System.get_env("ORCHARD_NODE_AGENT_ADVERTISE_PORT") ||
           System.get_env("ORCHARD_NODE_AGENT_LISTEN_PORT") || 50_061 do
      port when is_integer(port) -> port
      port when is_binary(port) -> parse_port(port)
      _port -> nil
    end
  end

  defp endpoint_hostname(configured, _host) do
    Keyword.get(configured, :hostname) ||
      System.get_env("ORCHARD_NODE_HOSTNAME") ||
      local_hostname()
  end

  defp local_hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end

  defp parse_port(port) do
    case Integer.parse(port) do
      {parsed, ""} -> parsed
      _result -> nil
    end
  end

  defp valid_endpoint_host?(host) do
    is_binary(host) and host not in ["", "0.0.0.0", "::", "[::]"] and
      byte_size(host) <= 253 and not String.match?(host, ~r/[\s\/]/)
  end

  defp valid_endpoint_port?(port), do: is_integer(port) and port in 1..65_535

  defp valid_hostname?(hostname) do
    is_binary(hostname) and hostname != "" and byte_size(hostname) <= 253 and
      not String.match?(hostname, ~r/[\s\/]/)
  end

  defp join(_root, bundle, %{state: "registered"} = identity) do
    {:ok, success_message(bundle, identity)}
  end

  defp join(root, bundle, %{state: "prepared"} = identity) do
    with {:ok, response} <- enrollment_client().redeem(bundle, identity),
         {:ok, registered} <- Store.finalize(root, identity, response) do
      {:ok, success_message(bundle, registered)}
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp enrollment_client do
    Application.get_env(:orchard_cli, :node_enrollment_client, PinnedHTTPS)
  end

  defp success_message(bundle, identity) do
    "Node joined and registered\n" <>
      "Node ID: #{bundle.node_id}\n" <>
      "Certificate ID: #{identity.certificate_identifier}\n" <>
      "Node Admission remains required before active or schedulable."
  end

  defp command_error(:invalid_join_arguments) do
    {:error, "Error: --enrollment-bundle PATH is required.\n\n#{usage()}", 1}
  end

  defp command_error(:invalid_enrollment_bundle) do
    {:error, "Error: the Node Enrollment Bundle is malformed or unsupported.", 1}
  end

  defp command_error(:enrollment_bundle_expired) do
    {:error, "Error: the Node Enrollment Bundle has expired; no credential was transmitted.", 1}
  end

  defp command_error(:controller_trust_or_connection_failed) do
    {:error,
     "Error: Controller TLS identity or trust pin validation failed; no enrollment result was accepted.",
     1}
  end

  defp command_error(:node_enrollment_rejected) do
    {:error, "Error: the Controller rejected Node Enrollment redemption.", 1}
  end

  defp command_error(:node_enrollment_unavailable) do
    {:error, "Error: the Controller could not complete Node Enrollment redemption.", 1}
  end

  defp command_error(reason)
       when reason in [
              :node_identity_binding_mismatch,
              :node_identity_generation_failed,
              :node_identity_root_invalid,
              :node_identity_storage_failed,
              :node_identity_storage_invalid,
              :node_runtime_endpoint_invalid
            ] do
    {:error, "Error: protected local Node identity state could not be prepared or persisted.", 1}
  end

  defp command_error(_reason) do
    {:error, "Error: Node join failed.", 1}
  end

  defp usage do
    "Usage: orchardctl node join --enrollment-bundle PATH"
  end
end
