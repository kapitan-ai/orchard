defmodule OrchardCLI.PlatformACLTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.PlatformACL
  alias OrchardCLI.TestTemp

  test "Darwin ACL removal preserves the established absolute command contract" do
    runner = recording_runner({"", 0})

    assert :ok =
             PlatformACL.remove_extended("/tmp/path with spaces", :directory,
               platform: :darwin,
               runner: runner
             )

    assert_receive {:command, "/bin/chmod", ["-N", "/tmp/path with spaces"], command_opts}
    assert command_opts[:env] == [{"LC_ALL", "C"}]
    assert command_opts[:stderr_to_stdout]
  end

  test "Darwin inspection accepts a valid header and complete numbered ACL entries" do
    assert {:ok, []} =
             darwin_entries("-rw-------  1 orchard  staff  6 Aug 26 20:00 /tmp/secret\n")

    assert {:ok, []} =
             darwin_entries("-rw-------@ 1 orchard  staff  6 Aug 26 20:00 /tmp/secret\n")

    output = """
    drwx------@ 3 orchard  staff  96 Aug 26 20:00 /tmp/parent
     0: group:everyone deny delete
    """

    assert {:ok, [entry]} = darwin_entries(output)
    assert entry.platform == :darwin
    assert entry.disposition == :deny
    assert entry.permissions == "delete"
  end

  test "Darwin inspection fails closed on empty, malformed, truncated, or inconsistent output" do
    invalid_outputs = [
      "",
      "arbitrary successful output\n",
      "drwx------@ 3 \n",
      "drwx------@ 3 arbitrary\n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 0:\n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 0: group:everyone allow , \n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 0: group:everyone allow read,\n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 0: group:everyone allow read,,search\n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 0: group:everyone allow add_fil\n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 0: group:everyone allow unknown_right\n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 1: group:everyone allow read\n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 0: group:everyone allow read\n 2: group:everyone allow search\n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 0: group:everyone allow read\n 0: group:everyone allow search\n",
      "drwx------+ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 0: group:everyone allow read\n 2: group:everyone allow search\n 1: group:everyone allow execute\n",
      "drwx------ 3 orchard staff 96 Aug 26 20:00 /tmp/parent\n 0: group:everyone allow write\n"
    ]

    for output <- invalid_outputs do
      assert {:error, :acl_inspection_failed} = darwin_entries(output)
    end
  end

  test "Linux ACL removal clears access ACLs from files and access plus default ACLs from directories" do
    runner = recording_runner({"", 0})

    assert :ok =
             PlatformACL.remove_extended("/tmp/-file", :regular,
               platform: :linux,
               runner: runner
             )

    assert_receive {:command, "/usr/bin/setfacl", ["-b", "--", "/tmp/-file"], _opts}

    assert :ok =
             PlatformACL.remove_extended("/tmp/directory", :directory,
               platform: :linux,
               runner: runner
             )

    assert_receive {:command, "/usr/bin/setfacl", ["-b", "-k", "--", "/tmp/directory"], _opts}
  end

  test "Linux inspection ignores mode-derived base entries" do
    output = """
    user::rw-
    group::r--
    other::---
    """

    assert {:ok, []} = linux_entries(output)
  end

  test "Linux inspection retains named entries, masks, and default entries" do
    output = """
    user::rwx
    user:1001:r--
    group::r-x
    group:operators:rwx #effective:r-x
    mask::r-x
    other::---
    default:user::rwx
    default:user:1002:r--
    default:group::r-x
    default:mask::r-x
    default:other::---
    """

    assert {:ok, entries} = linux_entries(output)
    assert length(entries) == 8
    assert Enum.any?(entries, &match?(%{scope: :access, kind: :user, qualifier: "1001"}, &1))
    assert Enum.any?(entries, &match?(%{scope: :access, kind: :mask}, &1))
    assert Enum.count(entries, &(&1.scope == :default)) == 5
  end

  test "parent mutation uses declared named access permissions and ignores effective and default permissions" do
    output = """
    user::rwx
    user:reader:r--
    user:writer:rwx #effective:r-x
    group::r-x
    group:auditors:r-x
    mask::r-x
    other::---
    default:user:future-writer:rwx
    """

    assert {:ok, entries} = linux_entries(output)

    reader = Enum.find(entries, &(&1.qualifier == "reader"))
    writer = Enum.find(entries, &(&1.qualifier == "writer"))
    default_writer = Enum.find(entries, &(&1.scope == :default))

    refute PlatformACL.grants_parent_mutation?(reader)
    assert PlatformACL.grants_parent_mutation?(writer)
    refute PlatformACL.grants_parent_mutation?(default_writer)
  end

  test "inspection fails closed on malformed output, unsupported platforms, and partial command failures" do
    assert {:error, :acl_inspection_failed} = linux_entries("user::rwx\nunexpected acl line\n")

    assert {:error, :acl_inspection_failed} =
             PlatformACL.entries("/tmp/path",
               platform: :freebsd,
               runner: recording_runner({"", 0})
             )

    assert {:error, :acl_inspection_failed} =
             PlatformACL.entries("/tmp/path",
               platform: :linux,
               runner: recording_runner({"user:1001:rwx\n", 1})
             )
  end

  test "Linux inspection requires one complete base access ACL" do
    invalid_outputs = [
      "",
      "# comments alone are not an ACL\n",
      "user::rwx\ngroup::r-x\n",
      "user::rwx\nuser::rwx\ngroup::r-x\nother::---\n",
      "user::rwx\ngroup::r-x\nother::--\n"
    ]

    for output <- invalid_outputs do
      assert {:error, :acl_inspection_failed} = linux_entries(output)
    end
  end

  @tag skip:
         if(:os.type() == {:unix, :linux},
           do: false,
           else: "Linux ACL integration contract"
         )
  test "hosted Linux exercises real access and default ACL cleanup" do
    run = TestTemp.create_run!(prefix: "orchard-platform-acl")
    on_exit(fn -> TestTemp.cleanup!(run) end)

    file = TestTemp.path(run, "file with spaces")
    directory = TestTemp.path(run, "directory")
    File.write!(file, "secret")
    File.mkdir!(directory)

    assert {"", 0} = System.cmd("/usr/bin/setfacl", ["-m", "u:65534:rw", "--", file])

    assert {"", 0} =
             System.cmd("/usr/bin/setfacl", ["-m", "u:65534:rwx,d:u:65534:rwx", "--", directory])

    assert {:ok, [_named_file_entry, _mask]} = PlatformACL.entries(file)
    assert {:ok, directory_entries} = PlatformACL.entries(directory)
    assert Enum.any?(directory_entries, &(&1.scope == :default))

    assert :ok = PlatformACL.remove_extended(file, :regular)
    assert :ok = PlatformACL.remove_extended(directory, :directory)
    assert {:ok, []} = PlatformACL.entries(file)
    assert {:ok, []} = PlatformACL.entries(directory)
  end

  defp linux_entries(output) do
    PlatformACL.entries("/tmp/path with spaces",
      platform: :linux,
      runner: recording_runner({output, 0})
    )
  end

  defp darwin_entries(output) do
    PlatformACL.entries("/tmp/path with spaces",
      platform: :darwin,
      runner: recording_runner({output, 0})
    )
  end

  defp recording_runner(result) do
    test_pid = self()

    fn command, args, opts ->
      send(test_pid, {:command, command, args, opts})
      result
    end
  end
end
