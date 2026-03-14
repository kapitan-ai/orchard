defmodule OrchardCLI.Commands.TLSTest do
  use ExUnit.Case, async: false

  alias OrchardCLI.Commands.TLS

  import ExUnit.CaptureIO

  @moduletag :tls

  # Helper: build a test runtime with injectable stubs
  defp test_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        cmd: fn executable, args, _opts ->
          case {executable, args} do
            {"openssl", ["version"]} -> {:ok, "LibreSSL 3.3.6\n"}
            {"openssl", _} -> {:ok, ""}
            {"security", _} -> {:ok, ""}
            {"id", ["-u"]} -> {:ok, "501\n"}
            _ -> {:error, 127, "command not found"}
          end
        end,
        os_type: fn -> {:unix, :darwin} end,
        uid: fn -> 501 end,
        hostname: fn -> {:ok, ~c"testhost"} end,
        ifaddrs: fn -> {:ok, []} end,
        now_utc: fn -> ~U[2026-03-14 00:00:00Z] end
      },
      overrides
    )
  end

  # Helper: build a real runtime that actually calls openssl (for integration tests)
  defp real_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        cmd: &real_cmd/3,
        os_type: fn -> :os.type() end,
        uid: fn -> 501 end,
        hostname: fn -> {:ok, ~c"testhost"} end,
        ifaddrs: fn ->
          {:ok,
           [
             {~c"en0",
              [
                flags: [:up, :broadcast, :running, :multicast],
                addr: {192, 168, 1, 42}
              ]}
           ]}
        end,
        now_utc: fn -> DateTime.utc_now() |> DateTime.truncate(:second) end
      },
      overrides
    )
  end

  defp real_cmd(executable, args, opts) do
    case System.find_executable(executable) do
      nil ->
        {:error, 127, "#{executable}: command not found"}

      exe_path ->
        cmd_opts =
          opts
          |> Keyword.take([:cd, :env])
          |> Keyword.put(:stderr_to_stdout, true)

        {output, status} = System.cmd(exe_path, args, cmd_opts)
        if status == 0, do: {:ok, output}, else: {:error, status, output}
    end
  end

  # ── Group Usage ───────────────────────────────────────────────────

  test "tls without subcommand returns group usage with non-zero exit" do
    assert {:error, message, 1} = TLS.run([])
    assert message =~ "orchardctl tls <command>"
    assert message =~ "init"
    assert message =~ "trust-ca"
  end

  test "tls help returns group usage with ok" do
    assert {:ok, message} = TLS.run(["help"])
    assert message =~ "orchardctl tls <command>"
  end

  test "tls --help returns group usage with ok" do
    assert {:ok, message} = TLS.run(["--help"])
    assert message =~ "orchardctl tls <command>"
  end

  test "tls unknown-command returns group usage with non-zero exit" do
    assert {:error, message, 1} = TLS.run(["unknown"])
    assert message =~ "orchardctl tls <command>"
  end

  # ── Init Usage/Parsing ────────────────────────────────────────────

  test "init --help returns init usage" do
    assert {:ok, message} = TLS.run(["init", "--help"])
    assert message =~ "orchardctl tls init"
    assert message =~ "--output-dir"
    assert message =~ "--force"
  end

  test "init with unknown flag returns error" do
    assert {:error, message, 1} = TLS.run(["init", "--unknown-flag"], test_runtime())
    assert message =~ "unknown option"
  end

  test "init with positional args returns error" do
    assert {:error, message, 1} = TLS.run(["init", "extra-arg"], test_runtime())
    assert message =~ "unexpected argument"
  end

  test "init with invalid --ip returns error" do
    assert {:error, message, 1} =
             TLS.run(["init", "--ip", "not-an-ip", "--output-dir", "/tmp/tls-test"], test_runtime())

    assert message =~ "invalid IP"
  end

  test "init with --host that is an IP literal returns error" do
    assert {:error, message, 1} =
             TLS.run(["init", "--host", "192.168.1.1", "--output-dir", "/tmp/tls-test"], test_runtime())

    assert message =~ "must not be an IP"
  end

  test "init with --server-days 0 returns error" do
    assert {:error, message, 1} =
             TLS.run(["init", "--server-days", "0", "--output-dir", "/tmp/tls-test"], test_runtime())

    assert message =~ "positive integer"
  end

  test "init with --server-days exceeding --ca-days returns error" do
    assert {:error, message, 1} =
             TLS.run(
               ["init", "--server-days", "4000", "--ca-days", "3000", "--output-dir", "/tmp/tls-test"],
               test_runtime()
             )

    assert message =~ "exceeds"
  end

  # ── Trust-CA Usage/Parsing ────────────────────────────────────────

  test "trust-ca --help returns trust-ca usage" do
    assert {:ok, message} = TLS.run(["trust-ca", "--help"])
    assert message =~ "orchardctl tls trust-ca"
  end

  test "trust-ca with unknown flag returns error" do
    assert {:error, message, 1} = TLS.run(["trust-ca", "--unknown"], test_runtime())
    assert message =~ "unknown option"
  end

  test "trust-ca with positional args returns error" do
    assert {:error, message, 1} = TLS.run(["trust-ca", "extra"], test_runtime())
    assert message =~ "unexpected argument"
  end

  # ── Trust-CA Validation ───────────────────────────────────────────

  test "trust-ca without CA cert returns error" do
    dir = make_tmp_dir()
    assert {:error, message, 1} = TLS.run(["trust-ca", "--output-dir", dir], test_runtime())
    assert message =~ "CA certificate not found"
  end

  test "trust-ca as non-root returns error" do
    dir = make_tmp_dir()

    # Generate certs first so CA exists
    generate_test_certs(dir)

    runtime = test_runtime(%{uid: fn -> 501 end})
    assert {:error, message, 1} = TLS.run(["trust-ca", "--output-dir", dir], runtime)
    assert message =~ "root privileges required"
  end

  # ── Init: Existing State Logic ────────────────────────────────────

  test "init refuses when CA and server cert exist without --force" do
    dir = make_tmp_dir()
    generate_test_certs(dir)

    assert {:error, message, 1} =
             TLS.run(["init", "--no-trust", "--output-dir", dir], real_runtime())

    assert message =~ "already exist"
  end

  test "init refuses --ca-days when reusing existing CA" do
    dir = make_tmp_dir()
    generate_test_certs(dir)

    # Remove server cert so CA reuse path is triggered
    File.rm!(Path.join(dir, "controller.key"))
    File.rm!(Path.join(dir, "controller.crt"))
    File.rm(Path.join(dir, ".orchard-tls-meta.json"))

    assert {:error, message, 1} =
             TLS.run(
               ["init", "--no-trust", "--output-dir", dir, "--ca-days", "5000"],
               real_runtime()
             )

    assert message =~ "cannot be used when reusing"
  end

  test "init errors on inconsistent CA state (only ca.key exists)" do
    dir = make_tmp_dir()
    File.write!(Path.join(dir, "ca.key"), "fake-key")

    assert {:error, message, 1} =
             TLS.run(["init", "--no-trust", "--output-dir", dir], real_runtime())

    assert message =~ "inconsistent CA state"
  end

  # ── Integration: Full Generation ──────────────────────────────────

  @tag :integration
  test "init --no-trust generates CA + server cert with correct structure" do
    dir = make_tmp_dir()

    result =
      TLS.run(
        ["init", "--no-trust", "--output-dir", dir, "--common-name", "test.local"],
        real_runtime()
      )

    assert {:ok, message} = result
    assert message =~ "TLS certificates generated successfully"
    assert message =~ "test.local"
    assert message =~ "Skipped (--no-trust)"

    # Verify all 5 files exist
    assert File.regular?(Path.join(dir, "ca.key"))
    assert File.regular?(Path.join(dir, "ca.crt"))
    assert File.regular?(Path.join(dir, "controller.key"))
    assert File.regular?(Path.join(dir, "controller.crt"))
    assert File.regular?(Path.join(dir, ".orchard-tls-meta.json"))

    # Verify file permissions
    assert file_mode(Path.join(dir, "ca.key")) == 0o600
    assert file_mode(Path.join(dir, "ca.crt")) == 0o644
    assert file_mode(Path.join(dir, "controller.key")) == 0o600
    assert file_mode(Path.join(dir, "controller.crt")) == 0o644

    # Verify metadata
    meta = Path.join(dir, ".orchard-tls-meta.json") |> File.read!() |> Jason.decode!()
    assert meta["source"] == "generated_local_ca"
    assert is_binary(meta["ca_fingerprint_sha256"])
    assert is_binary(meta["server_fingerprint_sha256"])
    assert is_binary(meta["ca_not_after"])
    assert is_binary(meta["server_not_after"])
    assert is_binary(meta["generated_at"])
    assert "localhost" in meta["san_dns"]
    assert "testhost" in meta["san_dns"]
    assert "test.local" in meta["san_dns"]
    assert "127.0.0.1" in meta["san_ip"]
    assert "192.168.1.42" in meta["san_ip"]

    # Verify cert chain with openssl
    {output, 0} =
      System.cmd("openssl", [
        "verify",
        "-CAfile",
        Path.join(dir, "ca.crt"),
        Path.join(dir, "controller.crt")
      ], stderr_to_stdout: true)

    assert output =~ "OK"

    # Verify SANs are in the server cert
    {san_output, 0} =
      System.cmd("openssl", [
        "x509",
        "-in",
        Path.join(dir, "controller.crt"),
        "-noout",
        "-text"
      ], stderr_to_stdout: true)

    assert san_output =~ "DNS:localhost"
    assert san_output =~ "DNS:test.local"
    assert san_output =~ "IP Address:127.0.0.1"

    # Verify CA fingerprint matches metadata
    ca_pem = File.read!(Path.join(dir, "ca.crt"))

    {:Certificate, ca_der, :not_encrypted} =
      :public_key.pem_decode(ca_pem)
      |> Enum.find(fn
        {:Certificate, _, :not_encrypted} -> true
        _ -> false
      end)

    expected_fp =
      :crypto.hash(:sha256, ca_der)
      |> Base.encode16()
      |> String.graphemes()
      |> Enum.chunk_every(2)
      |> Enum.map_join(":", &Enum.join/1)

    assert meta["ca_fingerprint_sha256"] == expected_fp
  end

  @tag :integration
  test "init --force regenerates CA + server cert" do
    dir = make_tmp_dir()

    # First generation
    assert {:ok, _} =
             TLS.run(
               ["init", "--no-trust", "--output-dir", dir],
               real_runtime()
             )

    original_ca = File.read!(Path.join(dir, "ca.crt"))

    # Force regeneration
    assert {:ok, message} =
             TLS.run(
               ["init", "--no-trust", "--output-dir", dir, "--force"],
               real_runtime()
             )

    assert message =~ "TLS certificates generated successfully"

    new_ca = File.read!(Path.join(dir, "ca.crt"))
    assert new_ca != original_ca
  end

  @tag :integration
  test "init reuses existing CA to generate server cert" do
    dir = make_tmp_dir()

    # First generation
    assert {:ok, _} =
             TLS.run(
               ["init", "--no-trust", "--output-dir", dir],
               real_runtime()
             )

    original_ca = File.read!(Path.join(dir, "ca.crt"))

    # Remove server cert
    File.rm!(Path.join(dir, "controller.key"))
    File.rm!(Path.join(dir, "controller.crt"))
    File.rm!(Path.join(dir, ".orchard-tls-meta.json"))

    # Regenerate — should reuse CA
    assert {:ok, message} =
             TLS.run(
               ["init", "--no-trust", "--output-dir", dir],
               real_runtime()
             )

    assert message =~ "reused existing CA"
    assert File.read!(Path.join(dir, "ca.crt")) == original_ca

    # Verify new server cert is valid against same CA
    {output, 0} =
      System.cmd("openssl", [
        "verify",
        "-CAfile",
        Path.join(dir, "ca.crt"),
        Path.join(dir, "controller.crt")
      ], stderr_to_stdout: true)

    assert output =~ "OK"
  end

  @tag :integration
  test "lock prevents concurrent tls init runs" do
    dir = make_tmp_dir()
    lock_path = Path.join(Path.dirname(dir), ".tls.lock")

    # Create the lock manually
    File.mkdir_p!(lock_path)

    assert {:error, message, 1} =
             TLS.run(["init", "--no-trust", "--output-dir", dir], real_runtime())

    assert message =~ "already in progress"

    # Clean up lock
    File.rmdir!(lock_path)
  end

  @tag :integration
  test "init with extra --host and --ip SANs" do
    dir = make_tmp_dir()

    assert {:ok, message} =
             TLS.run(
               [
                 "init",
                 "--no-trust",
                 "--output-dir",
                 dir,
                 "--host",
                 "custom.local",
                 "--ip",
                 "10.0.0.1"
               ],
               real_runtime()
             )

    assert message =~ "custom.local"
    assert message =~ "10.0.0.1"

    meta = Path.join(dir, ".orchard-tls-meta.json") |> File.read!() |> Jason.decode!()
    assert "custom.local" in meta["san_dns"]
    assert "10.0.0.1" in meta["san_ip"]
  end

  # ── CLI Dispatch Integration ──────────────────────────────────────

  test "orchardctl tls dispatches to TLS module" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["tls"], fn code -> send(parent, {:halt_called, code}) end)
      end)

    assert stderr =~ "orchardctl tls <command>"
    assert_received {:halt_called, 1}
  end

  # ── Review Regression: R1 — External cert safety ──────────────────

  test "init refuses when server cert exists without Orchard CA" do
    dir = make_tmp_dir()
    server_key = Path.join(dir, "controller.key")
    server_crt = Path.join(dir, "controller.crt")
    File.write!(server_key, "external-key")
    File.write!(server_crt, "external-cert")

    assert {:error, message, 1} =
             TLS.run(["init", "--no-trust", "--output-dir", dir], real_runtime())

    assert message =~ "existing server certificate files"
    assert message =~ "--force"

    # Verify files were NOT overwritten
    assert File.read!(server_key) == "external-key"
    assert File.read!(server_crt) == "external-cert"
  end

  test "init refuses when only server key exists without Orchard CA" do
    dir = make_tmp_dir()
    File.write!(Path.join(dir, "controller.key"), "external-key")

    assert {:error, message, 1} =
             TLS.run(["init", "--no-trust", "--output-dir", dir], real_runtime())

    assert message =~ "existing server certificate files"
  end

  # ── Review Regression: R2 — Corrupt metadata ─────────────────────

  test "trust-ca rejects corrupt metadata JSON" do
    dir = make_tmp_dir()
    generate_test_certs(dir)

    # Corrupt the metadata file
    File.write!(Path.join(dir, ".orchard-tls-meta.json"), "not valid json{{{")

    runtime = test_runtime(%{uid: fn -> 0 end})
    assert {:error, message, 1} = TLS.run(["trust-ca", "--output-dir", dir], runtime)
    assert message =~ "corrupt"
  end

  # ── Review Regression: R3 — Exception normalization ───────────────

  test "init returns error tuple (not raise) when output_dir is a file" do
    dir = make_tmp_dir()
    blocked_dir = Path.join(dir, "blocked")
    # Create a regular file where a directory is expected
    File.write!(blocked_dir, "not a directory")

    assert {:error, message, 1} =
             TLS.run(["init", "--no-trust", "--output-dir", blocked_dir], real_runtime())

    assert message =~ "filesystem error"
  end

  test "trust-ca returns error tuple (not raise) for garbage CA cert" do
    dir = make_tmp_dir()
    File.write!(Path.join(dir, "ca.crt"), "this is not a PEM file")
    # Valid metadata so check_metadata_source passes
    File.write!(Path.join(dir, ".orchard-tls-meta.json"),
      Jason.encode!(%{"source" => "generated_local_ca"}))

    runtime = test_runtime(%{uid: fn -> 0 end})
    assert {:error, message, 1} = TLS.run(["trust-ca", "--output-dir", dir], runtime)
    assert message =~ "invalid TLS file contents"
  end

  # ── Review Regression: R4 — CN validation ─────────────────────────

  test "init with --common-name containing '/' returns error" do
    assert {:error, message, 1} =
             TLS.run(
               ["init", "--common-name", "foo/bar", "--output-dir", "/tmp/tls-test"],
               test_runtime()
             )

    assert message =~ "must not contain '/'"
  end

  test "init with --common-name that is an IP literal returns error" do
    assert {:error, message, 1} =
             TLS.run(
               ["init", "--common-name", "192.168.1.1", "--output-dir", "/tmp/tls-test"],
               test_runtime()
             )

    assert message =~ "must not be an IP address"
  end

  test "init with --common-name containing null byte returns error" do
    assert {:error, message, 1} =
             TLS.run(
               ["init", "--common-name", "foo\0bar", "--output-dir", "/tmp/tls-test"],
               test_runtime()
             )

    assert message =~ "must not contain null"
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp make_tmp_dir do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    dir = Path.join(System.tmp_dir!(), "orchard-tls-test-#{suffix}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    dir
  end

  defp generate_test_certs(dir) do
    # Generate real certs for testing existing-state logic
    TLS.run(["init", "--no-trust", "--output-dir", dir], real_runtime())
  end

  defp file_mode(path) do
    {:ok, stat} = File.stat(path)
    # Extract permission bits only (lower 12 bits)
    stat.mode |> Bitwise.band(0o7777)
  end
end
