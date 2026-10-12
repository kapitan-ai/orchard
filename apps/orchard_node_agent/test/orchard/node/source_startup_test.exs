defmodule Orchard.Node.SourceStartupTest.IdentityLoader do
  @moduledoc false

  def load_registered_identity(root, require_controller_certificate: true) do
    send(self(), :registered_root_read)

    identity = %{
      node_id: "a6e1994b-0bb2-45bc-8be2-cc8573d5b463",
      certfile: root <> "/generations/g/node.crt",
      keyfile: root <> "/generations/g/node.key",
      cacertfile: root <> "/generations/g/ca.crt",
      controller_certfile: root <> "/generations/g/controller.crt"
    }

    Process.get(:source_startup_identity, {:ok, identity})
  end
end

defmodule Orchard.Node.SourceStartupTest do
  use ExUnit.Case, async: false

  alias Orchard.Node.HostLifecycle.LinuxSourceStartup
  alias Orchard.Node.{SourceStartup, SourceStartup.Error}

  @profile "ubuntu_24_04_x86_64_node"
  @root "/tmp/orchard-source-startup-policy"
  @uuid "a6e1994b-0bb2-45bc-8be2-cc8573d5b463"

  defmodule Filesystem do
    def lstat(_path), do: {:ok, %{type: :directory, uid: 1000, mode: 0o40700}}
  end

  defmodule LaunchVerifier do
    def preflight(options) do
      send(self(), {:launch_configuration_read, options})
      Process.get(:source_startup_preflight_result, :ok)
    end
  end

  # These are policy tests with explicit fake kernel/credential readers. Native
  # Linux process tests separately exercise the actual guardian implementation.
  setup do
    runner = fn helper, args, _opts ->
      send(self(), {:kernel_verifier, helper, args})
      {"", 0}
    end

    config = [
      profile: @profile,
      source_role: :node_agent,
      helper_path: "/helper",
      runner: runner,
      filesystem: Filesystem
    ]

    runtime = [node_id: nil, node_identity_path: nil, node_identity_root: @root]

    grants = [
      enabled: true,
      identity_root: @root,
      descriptor_path: "/descriptor",
      identity_loader: Orchard.Node.SourceStartupTest.IdentityLoader
    ]

    environment = %{
      "ORCHARD_NODE_PLATFORM_PROFILE" => @profile,
      "ORCHARD_NODE_ROOT_GUARD" => "v1:100:101:8:1:200",
      "ORCHARD_NODE_IDENTITY_ROOT" => @root,
      "ORCHARD_SOURCE_DEV_ROLE" => "node_agent",
      "ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR" => "/descriptor"
    }

    %{config: config, runtime: runtime, grants: grants, environment: environment}
  end

  test "SPEC 4.9 legacy source startup needs no guardian" do
    assert :disabled == SourceStartup.verify!([], [], [], %{}, "101")
    assert :ok == SourceStartup.after_identity!(:disabled)
    refute_received :registered_root_read
  end

  test "unknown, empty, and marker-only profile contexts refuse before identity", context do
    for profile <- ["unknown", "", nil] do
      environment = Map.put(context.environment, "ORCHARD_NODE_PLATFORM_PROFILE", profile)
      config = Keyword.put(context.config, :profile, profile)
      assert_raise Error, fn -> verify(context, config: config, environment: environment) end
    end

    refute_received :registered_root_read
  end

  test "candidate requires a guardian even with registered-looking configuration", context do
    environment = Map.delete(context.environment, "ORCHARD_NODE_ROOT_GUARD")
    assert_raise Error, ~r/guardian_required/, fn -> verify(context, environment: environment) end
    refute_received :registered_root_read
  end

  test "SPEC 1.4 candidate refuses Controller and combined source roles", context do
    for role <- [:controller, :all_in_one] do
      config = Keyword.put(context.config, :source_role, role)
      assert_raise Error, ~r/source_node_role_required/, fn -> verify(context, config: config) end
    end

    refute_received :registered_root_read
  end

  test "SPEC 10.6 no descriptor or disabled grants never falls back to UUID generation",
       context do
    for grants <- [
          Keyword.put(context.grants, :enabled, false),
          Keyword.delete(context.grants, :descriptor_path)
        ] do
      assert_raise Error, ~r/peer_grant_node_required/, fn -> verify(context, grants: grants) end
    end

    refute_received :registered_root_read
  end

  test "distinct roots cannot select one explicit UUID or one outside identity file", context do
    for root <- [@root, @root <> "-second"] do
      runtime = Keyword.put(context.runtime, :node_identity_root, root)
      grants = Keyword.put(context.grants, :identity_root, root)
      environment = Map.put(context.environment, "ORCHARD_NODE_IDENTITY_ROOT", root)
      rooted = %{context | runtime: runtime, grants: grants, environment: environment}

      for {key, value} <- [
            {"ORCHARD_NODE_ID", @uuid},
            {"ORCHARD_NODE_IDENTITY_PATH", "/outside/shared"}
          ] do
        environment = Map.put(rooted.environment, key, value)

        assert_raise Error, ~r/legacy_identity_forbidden/, fn ->
          verify(rooted, environment: environment)
        end
      end

      for runtime <- [
            Keyword.put(runtime, :node_id, @uuid),
            Keyword.put(runtime, :node_identity_path, "/outside/shared")
          ] do
        assert_raise Error, ~r/legacy_identity_forbidden/, fn ->
          verify(rooted, runtime: runtime)
        end
      end
    end

    refute_received :registered_root_read
  end

  test "split effective Peer Grant root refuses before registered identity read", context do
    grants = Keyword.put(context.grants, :identity_root, @root <> "-second")
    assert_raise Error, ~r/identity_root_mismatch/, fn -> verify(context, grants: grants) end
    refute_received :registered_root_read
  end

  test "a marker with no affirmative kernel verifier result cannot reach identity", context do
    config = Keyword.put(context.config, :runner, fn _helper, _args, _opts -> {"", 77} end)
    assert_raise Error, ~r/guardian_unproven/, fn -> verify(context, config: config) end
    refute_received :registered_root_read
  end

  test "unavailable native verifier never reaches identity", context do
    for runner <- [nil, fn _helper, _args, _opts -> raise ErlangError, original: :enoent end] do
      config = Keyword.put(context.config, :runner, runner)
      assert_raise Error, fn -> verify(context, config: config) end
    end

    refute_received :registered_root_read
  end

  test "missing or corrupt registered credentials have no plaintext identity fallback", context do
    for identity <- [
          {:error, :identity_missing},
          {:ok, %{node_id: @uuid}},
          {:ok,
           %{
             node_id: @uuid,
             certfile: "/outside/node.crt",
             keyfile: @root <> "/generations/g/key",
             cacertfile: @root <> "/generations/g/ca",
             controller_certfile: @root <> "/generations/g/controller"
           }}
        ] do
      Process.put(:source_startup_identity, identity)
      assert_raise Error, ~r/registered_identity_required/, fn -> verify(context) end
    end
  end

  test "symlinked credential generations refuse before registered identity reads", context do
    root =
      Path.join(System.tmp_dir!(), "orchard-guard-layout-#{System.unique_integer([:positive])}")

    outside = root <> "-outside"
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.mkdir!(outside)
    File.ln_s!(outside, Path.join(root, "generations"))

    try do
      config = Keyword.put(context.config, :filesystem, File)
      runtime = Keyword.put(context.runtime, :node_identity_root, root)
      grants = Keyword.put(context.grants, :identity_root, root)
      environment = Map.put(context.environment, "ORCHARD_NODE_IDENTITY_ROOT", root)

      assert_raise Error, ~r/registered_identity_layout_invalid/, fn ->
        verify(context,
          config: config,
          runtime: runtime,
          grants: grants,
          environment: environment
        )
      end

      refute_received :registered_root_read
    after
      File.rm_rf!(root)
      File.rm_rf!(outside)
    end
  end

  test "root verifier failure after reading credentials refuses startup", context do
    runner = fn _helper, _args, _opts ->
      if Process.get(:source_startup_kernel_seen),
        do: {"", 77},
        else:
          {"", 0}
          |> tap(fn _result -> Process.put(:source_startup_kernel_seen, true) end)
    end

    config = Keyword.put(context.config, :runner, runner)
    assert_raise Error, ~r/guardian_unproven/, fn -> verify(context, config: config) end
    assert_received :registered_root_read
  end

  test "registered reader is bracketed by kernel checks and identity is checked again", context do
    {LinuxSourceStartup, guard} = verify(context)
    assert_received {:kernel_verifier, "/helper", ["--verify", @root, _, "101"]}
    assert_received :registered_root_read
    assert_received {:kernel_verifier, "/helper", ["--verify", @root, _, "101"]}

    runtime = Keyword.put(context.runtime, :node_id, @uuid)

    assert :ok ==
             LinuxSourceStartup.after_identity!(
               guard,
               runtime,
               context.grants,
               context.environment
             )

    assert_raise Error, ~r/registered_identity_mismatch/, fn ->
      LinuxSourceStartup.after_identity!(
        guard,
        Keyword.put(runtime, :node_id, "another"),
        context.grants,
        context.environment
      )
    end

    changed = Map.put(context.environment, "ORCHARD_NODE_IDENTITY_ROOT", @root <> "-replacement")

    assert_raise Error, ~r/identity_root_mismatch/, fn ->
      LinuxSourceStartup.after_identity!(guard, runtime, context.grants, changed)
    end
  end

  test "actual Application entrypoint invokes guard before mutating identity" do
    previous = System.get_env("ORCHARD_NODE_PLATFORM_PROFILE")
    runtime = Application.get_env(:orchard_node_agent, :runtime)
    System.put_env("ORCHARD_NODE_PLATFORM_PROFILE", "unqualified")

    try do
      assert_raise Error, ~r/profile_invalid/, fn ->
        Orchard.NodeAgent.Application.start(:normal, [])
      end

      assert runtime == Application.get_env(:orchard_node_agent, :runtime)
    after
      if previous,
        do: System.put_env("ORCHARD_NODE_PLATFORM_PROFILE", previous),
        else: System.delete_env("ORCHARD_NODE_PLATFORM_PROFILE")
    end
  end

  test "pre-boot seam verifies the guardian launcher and configuration without starting a role",
       context do
    grants = Keyword.put(context.grants, :startup_verifier, LaunchVerifier)

    config_values = [
      source_startup: context.config,
      runtime: context.runtime,
      beam_peer_grants: grants
    ]

    previous_config =
      Map.new(config_values, fn {key, _value} ->
        {key, Application.fetch_env(:orchard_node_agent, key)}
      end)

    previous_environment =
      Map.new(context.environment, fn {key, _value} ->
        {key, System.get_env(key)}
      end)

    try do
      for {key, value} <- config_values, do: Application.put_env(:orchard_node_agent, key, value)
      System.put_env(context.environment)
      assert :ok == SourceStartup.preflight!()
      assert_received {:launch_configuration_read, options}
      refute Keyword.has_key?(options, :enabled)
      expected_pid = System.pid()

      assert_received {:kernel_verifier, "/helper",
                       ["--verify-preflight", @root, _, ^expected_pid]}

      Process.put(:source_startup_preflight_result, {:error, :store_unavailable})
      assert_raise Error, ~r/registered_launch_invalid/, &SourceStartup.preflight!/0
      System.delete_env("ORCHARD_NODE_ROOT_GUARD")
      assert_raise Error, ~r/guardian_required/, &SourceStartup.preflight!/0
    after
      for {key, value} <- previous_environment do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      for {key, result} <- previous_config do
        case result do
          {:ok, value} -> Application.put_env(:orchard_node_agent, key, value)
          :error -> Application.delete_env(:orchard_node_agent, key)
        end
      end
    end
  end

  defp verify(context, overrides \\ []) do
    SourceStartup.verify!(
      Keyword.get(overrides, :config, context.config),
      Keyword.get(overrides, :runtime, context.runtime),
      Keyword.get(overrides, :grants, context.grants),
      Keyword.get(overrides, :environment, context.environment),
      "101"
    )
  end
end
