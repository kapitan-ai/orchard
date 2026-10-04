# Relocated-root composition fixture: real kernel verification, synthetic
# credential/configuration readers, and deliberate refusal before runtime start.
defmodule OrchardSourceGuardFixture.Identity do
  def load_registered_identity(root, require_controller_certificate: true) do
    File.write!(System.fetch_env!("FIXTURE_IDENTITY_READ"), "read\n", [:append])

    {:ok,
     %{
       node_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
       certfile: root <> "/generations/g/node.crt",
       keyfile: root <> "/generations/g/node.key",
       cacertfile: root <> "/generations/g/ca.crt",
       controller_certfile: root <> "/generations/g/controller.crt"
     }}
  end
end

defmodule OrchardSourceGuardFixture.Launch do
  use GenServer

  def preflight(_options), do: :ok
  def start_link(_options), do: {:error, :fixture_stop_before_runtime}
  @impl true
  def init(_options), do: {:stop, :fixture_stop_before_runtime}
end

alias Orchard.Node.SourceStartup

root = System.fetch_env!("ORCHARD_NODE_IDENTITY_ROOT")

Application.put_env(:orchard_node_agent, :source_startup,
  profile: "ubuntu_24_04_x86_64_node",
  source_role: :node_agent,
  helper_path: System.fetch_env!("HELPER")
)

Application.put_env(:orchard_node_agent, :runtime,
  node_identity_root: root,
  node_identity_path: nil,
  node_id: nil
)

Application.put_env(:orchard_node_agent, :beam_peer_grants,
  enabled: true,
  identity_root: root,
  descriptor_path: System.fetch_env!("ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR"),
  identity_loader: OrchardSourceGuardFixture.Identity,
  startup_verifier: OrchardSourceGuardFixture.Launch
)

case System.fetch_env!("FIXTURE_MODE") do
  "application" ->
    {:error, {:shutdown, {:failed_to_start_child, _, :fixture_stop_before_runtime}}} =
      Orchard.NodeAgent.Application.start(:normal, [])

    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" = Orchard.Node.node_id()

    IO.puts(
      "PASS: actual Application guard reached registered identity and stopped before runtime"
    )

  "preflight" ->
    :ok = SourceStartup.preflight!()
    IO.puts("PASS: actual preflight proved its own VM is the guarded launcher's child")

  "refuse" ->
    try do
      SourceStartup.before_identity!()
      raise "unguarded caller was accepted"
    rescue
      error in SourceStartup.Error ->
        :guardian_unproven = error.reason
        false = File.exists?(System.fetch_env!("FIXTURE_IDENTITY_READ"))
    end

    IO.puts("PASS: sibling with copied marker refused before identity")

  "refuse_preflight" ->
    try do
      SourceStartup.preflight!()
      raise "unguarded preflight was accepted"
    rescue
      error in SourceStartup.Error ->
        :guardian_unproven = error.reason
        false = File.exists?(System.fetch_env!("FIXTURE_IDENTITY_READ"))
    end

    IO.puts("PASS: sibling preflight with copied marker refused before identity")
end
