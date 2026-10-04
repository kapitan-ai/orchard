defmodule Orchard.Node.SourceStartup do
  @moduledoc """
  Enforces the selected source Node startup profile before identity resolution.

  Ordinary source development has no selected profile. Candidate ownership is
  delegated to its host adapter and never establishes runtime resource release.
  """

  alias Orchard.Node.HostLifecycle.LinuxSourceStartup

  @profile "ubuntu_24_04_x86_64_node"
  @environment_keys ~w(ORCHARD_NODE_PLATFORM_PROFILE ORCHARD_NODE_ROOT_GUARD
    ORCHARD_NODE_IDENTITY_ROOT ORCHARD_NODE_ID ORCHARD_NODE_IDENTITY_PATH
    ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR ORCHARD_SOURCE_DEV_ROLE)

  # This is an intentional startup refusal, not a background/request crash.
  # credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames
  defmodule Error do
    @moduledoc false
    defexception [:reason]

    @impl true
    def message(%{reason: reason}),
      do: "Experimental Node source startup refused (#{reason})"
  end

  @type guard :: :disabled | {module(), map()}

  @doc """
  Validates candidate ownership before any application identity side effect.
  """
  @spec before_identity!() :: guard()
  def before_identity! do
    verify!(
      Application.get_env(:orchard_node_agent, :source_startup, []),
      Application.get_env(:orchard_node_agent, :runtime, []),
      Application.get_env(:orchard_node_agent, :beam_peer_grants, []),
      environment(),
      System.pid()
    )
  end

  @doc """
  Checks the pinned root again after registered identity resolution.
  """
  @spec after_identity!(guard()) :: :ok
  def after_identity!(:disabled), do: :ok

  def after_identity!({adapter, guard}) do
    adapter.after_identity!(
      guard,
      Application.fetch_env!(:orchard_node_agent, :runtime),
      Application.get_env(:orchard_node_agent, :beam_peer_grants, []),
      environment()
    )
  end

  @doc """
  Validates stored launch configuration in a nondistributed pre-boot VM.

  It starts no application and publishes no credential or launch artifact.
  The existing running-VM verifier still runs during final Agent startup.
  """
  @spec preflight!() :: :ok
  def preflight! do
    environment = environment()
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    grants = Application.get_env(:orchard_node_agent, :beam_peer_grants, [])

    case verify!(
           Application.get_env(:orchard_node_agent, :source_startup, [])
           |> Keyword.put(:verification_mode, :preflight),
           runtime,
           grants,
           environment,
           System.pid()
         ) do
      :disabled ->
        raise Error, reason: :candidate_required

      {adapter, guard} ->
        verifier =
          Keyword.get(grants, :startup_verifier, Orchard.Node.BeamPeerGrantStartupVerifier)

        case verifier.preflight(Keyword.delete(grants, :enabled)) do
          :ok -> adapter.recheck!(guard, runtime, grants, environment)
          {:error, _reason} -> raise Error, reason: :registered_launch_invalid
        end
    end
  end

  @doc """
  Validates an explicit source startup context. Host evidence belongs to the
  configured adapter; a marker alone is never ownership evidence.
  """
  @spec verify!(keyword(), keyword(), keyword(), map(), String.t()) :: guard()
  def verify!(config, runtime, grants, environment, subject_pid) do
    profile = environment["ORCHARD_NODE_PLATFORM_PROFILE"] || config[:profile]

    case {profile, environment["ORCHARD_NODE_ROOT_GUARD"]} do
      {nil, nil} ->
        :disabled

      {@profile, marker} when is_binary(marker) and marker != "" ->
        unless config[:profile] == @profile and config[:source_role] == :node_agent do
          raise Error, reason: :source_node_role_required
        end

        adapter = Keyword.get(config, :adapter, LinuxSourceStartup)
        {adapter, adapter.verify!(config, runtime, grants, environment, subject_pid)}

      {@profile, _marker} ->
        raise Error, reason: :guardian_required

      _other ->
        raise Error, reason: :profile_invalid
    end
  end

  defp environment do
    Map.new(@environment_keys, &{&1, System.get_env(&1)})
  end
end
