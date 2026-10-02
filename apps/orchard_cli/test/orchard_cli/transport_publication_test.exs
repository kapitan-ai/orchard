defmodule OrchardCLI.TransportPublicationTest do
  # SPEC.md §10.7 and ADR 0036: private-stage publication of the local CA and endpoint metadata.
  use ExUnit.Case, async: true

  alias OrchardCLI.TransportFixture
  alias OrchardCLI.TransportPublication

  @ca "-----BEGIN CERTIFICATE-----\nlocal ca\n-----END CERTIFICATE-----\n"
  @endpoint ~s({"schema_version":1}\n)

  setup do
    base = TransportFixture.support_root!()
    root = Path.join(base, "support")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, root: root, public: Path.join(root, "public")}
  end

  defp prepare(root, opts \\ []) do
    TransportPublication.prepare(root, Keyword.put_new(opts, :executable, helper(opts)))
  end

  defp helper(opts), do: TransportFixture.helper(Keyword.get(opts, :helper, :production))

  defp fault(point), do: [helper: :test, env: [{"ORCHARD_TRANSPORT_PUBLISH_TEST_FAULT", point}]]

  defp publish!(root, opts \\ []) do
    assert {:ok, publication} = prepare(root, opts)
    assert {:ok, []} = TransportPublication.publish(publication, @ca, @endpoint)
    assert :ok = TransportPublication.commit(publication)
    publication
  end

  defp make_public!(public, mode) do
    File.mkdir!(public)
    File.chmod!(public, mode)
  end

  defp write_file!(path, contents, mode) do
    File.write!(path, contents)
    File.chmod!(path, mode)
  end

  defp tree(root) do
    for path <- [root | Path.wildcard(Path.join(root, "**"), match_dot: true)], into: %{} do
      {:ok, stat} = File.lstat(path)
      {path, {stat.type, stat.inode, Bitwise.band(stat.mode, 0o7777), read_regular(path, stat)}}
    end
  end

  defp read_regular(path, %File.Stat{type: :regular}), do: File.read!(path)
  defp read_regular(_path, _stat), do: nil

  defp assert_refused(root, opts, code, subject) do
    before = tree(root)
    assert {:error, %{code: ^code, subject: ^subject}} = prepare(root, opts)
    assert tree(root) == before
  end

  defp assert_published(root, public) do
    assert TransportFixture.mode(root) == 0o711
    assert TransportFixture.mode(public) == 0o755
    assert TransportFixture.mode(Path.join(public, "ca.crt")) == 0o644
    assert TransportFixture.mode(Path.join(public, "endpoint.json")) == 0o644
    assert File.read!(Path.join(public, "ca.crt")) == @ca
    assert File.read!(Path.join(public, "endpoint.json")) == @endpoint
    assert Enum.sort(File.ls!(public)) == ["ca.crt", "endpoint.json"]
    assert TransportFixture.stage_entries(root) == []
  end

  describe "private stage creation" do
    for umask <- [0o022, 0o077, 0o002, 0o000] do
      @umask umask
      test "child umask #{Integer.to_string(umask, 8)} publishes absent and existing public directories",
           %{root: root, public: public} do
        wrapper = TransportFixture.umask_wrapper(@umask)

        publish!(root, wrapper: wrapper)
        assert_published(root, public)

        publish!(root, wrapper: wrapper)
        assert_published(root, public)
      end
    end

    test "caller umask is unchanged", %{base: base, root: root} do
      probe_mode = fn name ->
        path = Path.join(base, name)
        File.write!(path, "")
        TransportFixture.mode(path)
      end

      before = probe_mode.("before")
      publish!(root, wrapper: TransportFixture.umask_wrapper(0o000))
      assert probe_mode.("after") == before
    end

    for umask <- [0o777, 0o700] do
      @umask umask
      test "owner-masking umask #{Integer.to_string(umask, 8)} fails closed and identifies residue",
           %{root: root, public: public} do
        assert {:error, %{code: "postcheck_failed", subject: "stage", detail: detail}} =
                 prepare(root, wrapper: TransportFixture.umask_wrapper(@umask))

        assert [stage] = TransportFixture.stage_entries(root)
        assert detail =~ "retained=#{stage} dev="
        assert detail =~ "mode=0000"
        refute File.exists?(public)
        assert TransportFixture.mode(root) == 0o700
      end
    end

    test "an inherited stage ACL is retained and identified", %{root: root} do
      assert {:error, %{code: "postcheck_failed", subject: "stage", detail: detail}} =
               prepare(root, fault("acl_present:stage"))

      assert [stage] = TransportFixture.stage_entries(root)
      assert detail =~ "retained=#{stage}"
    end

    test "an unqualified stage filesystem is retained and identified", %{root: root} do
      assert {:error, %{code: "postcheck_failed", subject: "stage"}} =
               prepare(root, fault("fs_unqualified:stage"))

      assert [_stage] = TransportFixture.stage_entries(root)
    end
  end

  describe "existing safe paths" do
    for mode <- [0o700, 0o750, 0o755] do
      @mode mode
      test "public directory mode #{Integer.to_string(mode, 8)} is accepted and widened to 0755",
           %{root: root, public: public} do
        make_public!(public, @mode)
        write_file!(Path.join(public, "endpoint.json"), "old\n", 0o644)
        write_file!(Path.join(public, "ca.crt"), "old ca\n", 0o600)

        publish!(root)
        assert_published(root, public)
      end
    end

    test "hardlinked existing endpoint is accepted and its other link is untouched",
         %{base: base, root: root, public: public} do
      make_public!(public, 0o755)
      endpoint = Path.join(public, "endpoint.json")
      write_file!(endpoint, "old\n", 0o644)
      link = Path.join(base, "endpoint-link")
      File.ln!(endpoint, link)

      publish!(root)
      assert_published(root, public)
      assert File.read!(link) == "old\n"
    end
  end

  describe "unsafe paths refuse unchanged" do
    for mode <- [0o775, 0o777, 0o720, 0o702] do
      @mode mode
      test "public directory mode #{Integer.to_string(mode, 8)}", %{root: root, public: public} do
        make_public!(public, @mode)
        assert_refused(root, [], "writable", "public")
      end

      test "support root mode #{Integer.to_string(mode, 8)}", %{root: root} do
        File.chmod!(root, @mode)
        assert_refused(root, [], "writable", "support_root")
      end
    end

    test "setgid public directory", %{root: root, public: public} do
      make_public!(public, 0o755)
      {gid, 0} = System.cmd("id", ["-g"])
      File.chgrp!(public, gid |> String.trim() |> String.to_integer())
      File.chmod!(public, 0o2755)
      assert_refused(root, [], "setgid", "public")
    end

    test "public directory symlink and dangling symlink", %{
      base: base,
      root: root,
      public: public
    } do
      target = Path.join(base, "elsewhere")
      File.ln_s!(target, public)
      assert_refused(root, [], "symlink", "public")

      File.mkdir!(target)
      File.chmod!(target, 0o755)
      assert_refused(root, [], "symlink", "public")
      assert File.ls!(target) == []
    end

    test "regular-file public substitution", %{root: root, public: public} do
      write_file!(public, "not a directory", 0o644)
      assert_refused(root, [], "not_directory", "public")
    end

    test "endpoint symlink, directory, and writable substitutions",
         %{base: base, root: root, public: public} do
      make_public!(public, 0o755)
      endpoint = Path.join(public, "endpoint.json")

      File.ln_s!(Path.join(base, "missing"), endpoint)
      assert_refused(root, [], "symlink", "endpoint")
      File.rm!(endpoint)

      File.mkdir!(endpoint)
      assert_refused(root, [], "not_regular", "endpoint")
      File.rmdir!(endpoint)

      write_file!(endpoint, "old\n", 0o666)
      assert_refused(root, [], "writable", "endpoint")
    end

    test "support root symlink", %{base: base, root: root} do
      link = Path.join(base, "support-link")
      File.ln_s!(root, link)
      before = tree(root)
      assert {:error, %{code: "symlink", subject: "support_root"}} = prepare(link)
      assert tree(root) == before
    end

    test "symlinked and writable ancestors", %{base: base} do
      real = Path.join(base, "real")
      File.mkdir!(real)
      File.chmod!(real, 0o755)
      root = Path.join(real, "support")
      File.mkdir!(root)
      File.chmod!(root, 0o700)
      File.ln_s!(real, Path.join(base, "alias"))

      assert {:error, %{code: "symlink", subject: "ancestor"}} =
               prepare(Path.join([base, "alias", "support"]))

      File.chmod!(real, 0o777)
      assert_refused(root, [], "writable", "ancestor")
      File.chmod!(real, 0o755)
    end

    test "missing support root is not created", %{base: base} do
      root = Path.join(base, "absent")
      assert {:error, %{code: "missing", subject: "support_root"}} = prepare(root)
      refute File.exists?(root)
    end

    test "relative and non-canonical support roots", %{root: root} do
      for path <- ["relative/support", root <> "/", root <> "/.", root <> "/../support"] do
        assert {:error, %{code: "path_invalid"}} = prepare(path)
      end
    end

    for {point, code, subject} <- [
          {"acl_present:public", "acl_present", "public"},
          {"acl_present:support_root", "acl_present", "support_root"},
          {"acl_present:ancestor", "acl_present", "ancestor"},
          {"acl_present:endpoint", "acl_present", "endpoint"},
          {"acl_error:support_root", "acl_inspection_failed", "support_root"},
          {"acl_error:public", "acl_inspection_failed", "public"},
          {"fs_unqualified:support_root", "filesystem_unqualified", "support_root"},
          {"fs_error:public", "filesystem_inspection_failed", "public"}
        ] do
      @point point
      @code code
      @subject subject
      test "#{point} refuses before stage creation", %{root: root, public: public} do
        make_public!(public, 0o755)
        write_file!(Path.join(public, "endpoint.json"), "old\n", 0o644)
        assert_refused(root, fault(@point), @code, @subject)
      end
    end
  end

  describe "rollback and cleanup" do
    test "rollback restores the previous endpoint through a fresh inode",
         %{root: root, public: public} do
      make_public!(public, 0o755)
      endpoint = Path.join(public, "endpoint.json")
      write_file!(endpoint, "old\n", 0o640)
      %File.Stat{inode: old_inode} = File.stat!(endpoint)
      retained = Path.join(root, "retained-old-endpoint")
      File.ln!(endpoint, retained)

      assert {:ok, publication} = prepare(root)
      assert {:ok, []} = TransportPublication.publish(publication, @ca, @endpoint)
      assert File.read!(endpoint) == @endpoint
      assert {:ok, []} = TransportPublication.rollback(publication)
      assert :ok = TransportPublication.commit(publication)

      assert File.read!(endpoint) == "old\n"
      assert TransportFixture.mode(endpoint) == 0o640
      refute File.stat!(endpoint).inode == old_inode
      assert File.stat!(retained).inode == old_inode
      assert File.read!(retained) == "old\n"
      assert TransportFixture.stage_entries(root) == []
    end

    test "rollback removes a newly-created endpoint", %{root: root, public: public} do
      assert {:ok, publication} = prepare(root)
      assert {:ok, []} = TransportPublication.publish(publication, @ca, @endpoint)
      assert {:ok, []} = TransportPublication.rollback(publication)
      assert :ok = TransportPublication.commit(publication)

      refute File.exists?(Path.join(public, "endpoint.json"))
      assert File.read!(Path.join(public, "ca.crt")) == @ca
    end

    test "rollback never overwrites a substituted endpoint", %{root: root, public: public} do
      make_public!(public, 0o755)
      endpoint = Path.join(public, "endpoint.json")
      write_file!(endpoint, "old\n", 0o644)

      assert {:ok, publication} = prepare(root)
      assert {:ok, []} = TransportPublication.publish(publication, @ca, @endpoint)
      write_file!(endpoint <> ".foreign", "foreign\n", 0o644)
      File.rename!(endpoint <> ".foreign", endpoint)

      assert {:error, %{code: "identity_mismatch", subject: "rollback"}} =
               TransportPublication.rollback(publication)

      assert File.read!(endpoint) == "foreign\n"
      assert TransportFixture.stage_entries(root) == []
    end

    test "abort removes only the unpublished stage", %{root: root, public: public} do
      assert {:ok, publication} = prepare(root)
      assert [_stage] = TransportFixture.stage_entries(root)
      assert :ok = TransportPublication.abort(publication)
      assert TransportFixture.stage_entries(root) == []
      refute File.exists?(public)
    end

    test "abort retains a stage holding foreign entries", %{root: root} do
      assert {:ok, publication} = prepare(root)
      [stage] = TransportFixture.stage_entries(root)
      File.write!(Path.join([root, stage, "foreign"]), "x")

      assert {:error, %{code: "retained", subject: "cleanup"}} =
               TransportPublication.abort(publication)

      assert File.read!(Path.join([root, stage, "foreign"])) == "x"
    end

    test "absent public directory is not published with foreign stage entries",
         %{root: root, public: public} do
      assert {:ok, publication} = prepare(root)
      [stage] = TransportFixture.stage_entries(root)
      foreign = "foreign-" <> String.duplicate("entry", 40)
      File.write!(Path.join([root, stage, foreign]), "x")

      assert {:error, %{code: "unexpected_entry", subject: "stage", detail: detail}} =
               TransportPublication.publish(publication, @ca, @endpoint)

      assert [^foreign | rest] = String.split(detail, " ")
      assert "cleanup_retained=#{stage}" in rest
      refute File.exists?(public)
      assert File.ls!(Path.join(root, stage)) == [foreign]
    end

    test "existing public publication reports retained stage residue",
         %{root: root, public: public} do
      make_public!(public, 0o755)
      assert {:ok, publication} = prepare(root)
      [stage] = TransportFixture.stage_entries(root)
      File.write!(Path.join([root, stage, "foreign"]), "x")

      assert {:ok, [warning]} = TransportPublication.publish(publication, @ca, @endpoint)
      assert warning =~ stage
      assert :ok = TransportPublication.commit(publication)
      assert File.read!(Path.join(public, "endpoint.json")) == @endpoint
      assert File.ls!(Path.join(root, stage)) == ["foreign"]
    end

    test "publish failure removes the private stage", %{root: root, public: public} do
      assert {:ok, publication} = prepare(root, fault("rename_error:public"))

      assert {:error, %{code: "rename_failed", subject: "publication"}} =
               TransportPublication.publish(publication, @ca, @endpoint)

      assert TransportFixture.stage_entries(root) == []
      refute File.exists?(public)
    end

    test "helper exit after prepare removes the private stage", %{root: root} do
      assert {:ok, %TransportPublication{port: port}} = prepare(root)
      Port.close(port)
      assert wait_until(fn -> TransportFixture.stage_entries(root) == [] end)
    end
  end

  describe "publisher serialization" do
    test "a second publisher waits until the first commits", %{root: root, public: public} do
      assert {:ok, first} = prepare(root)
      parent = self()

      second =
        Task.async(fn ->
          with {:ok, publication} <- prepare(root) do
            Port.connect(publication.port, parent)
            {:ok, publication}
          end
        end)

      refute Task.yield(second, 300)

      assert {:ok, []} = TransportPublication.publish(first, @ca, @endpoint)
      assert :ok = TransportPublication.commit(first)

      assert {:ok, %TransportPublication{public: :existing, endpoint: :existing} = later} =
               Task.await(second)

      assert {:ok, []} = TransportPublication.publish(later, @ca, "second\n")
      assert :ok = TransportPublication.commit(later)
      assert File.read!(Path.join(public, "endpoint.json")) == "second\n"
    end
  end

  describe "helper protocol" do
    test "missing helper is reported unavailable", %{base: base, root: root} do
      missing = Path.join(base, "orchard-transport-publish")

      assert {:error, {:helper_unavailable, ^missing}} =
               TransportPublication.prepare(root, executable: missing)

      assert TransportPublication.format_error({:helper_unavailable, missing}) =~
               "explicit native-helper builder"
    end

    test "non-executable helper is reported unavailable", %{base: base, root: root} do
      helper = Path.join(base, "orchard-transport-publish")
      write_file!(helper, "#!/bin/sh\n", 0o644)

      assert {:error, {:helper_unavailable, ^helper}} =
               TransportPublication.prepare(root, executable: helper)
    end

    test "wrong protocol version exits with usage status" do
      assert {_output, 64} =
               System.cmd(TransportFixture.helper(:production), ["--protocol", "0"])
    end

    test "out-of-order and malformed frames are terminal protocol errors", %{root: root} do
      for frames <- [
            ["PUBLISH\n" <> <<0::32, 1::32>> <> "x"],
            ["COMMIT"],
            ["PREPARE\n" <> root, "PUBLISH\n" <> <<5::32>> <> "x"],
            ["PREPARE\n" <> root, "PREPARE\n" <> root],
            ["PREPARE\n" <> root, "PUBLISH\n" <> <<0::32, 0::32>>]
          ] do
        port = open_raw()
        replies = Enum.map(frames, &raw_request(port, &1))
        assert "ERR protocol_error einval protocol" = List.last(replies)
        assert_receive {^port, {:exit_status, 1}}, 5_000
        assert TransportFixture.stage_entries(root) == []
      end
    end
  end

  defp open_raw do
    Port.open({:spawn_executable, TransportFixture.helper(:production)}, [
      :binary,
      :exit_status,
      {:packet, 4},
      {:args, ["--protocol", "1"]}
    ])
  end

  defp raw_request(port, frame) do
    Port.command(port, frame)

    receive do
      {^port, {:data, reply}} -> reply
    after
      5_000 -> flunk("helper did not reply")
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
