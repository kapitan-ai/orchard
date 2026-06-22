defmodule OrchardCLI.Commands.SupportTest do
  use ExUnit.Case, async: false

  alias OrchardCLI.Commands.Support

  @fixed_now ~U[2026-06-22 12:34:56Z]

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "orchard support test #{System.unique_integer([:positive])}")

    support_root = Path.join(tmp_dir, "Application Support/Orchard")
    output_dir = Path.join(tmp_dir, "output")

    File.mkdir_p!(Path.join([support_root, "config"]))
    File.mkdir_p!(Path.join([support_root, "logs", "workers"]))
    File.mkdir_p!(Path.join([support_root, "support"]))
    File.write!(Path.join([support_root, "support", ".install-role"]), "all\n")

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{support_root: support_root, output_dir: output_dir, tmp_dir: tmp_dir}
  end

  test "help displays support bundle create usage", %{support_root: support_root} do
    assert {:ok, group} = Support.run(["--help"], runtime(support_root))
    assert group =~ "orchardctl support bundle create"

    assert {:ok, command} = Support.run(["bundle", "create", "--help"], runtime(support_root))
    assert command =~ "--output DIR"
    assert command =~ "--support-root PATH"
    assert command =~ "--max-log-bytes BYTES"
  end

  test "unknown create option exits with usage error", %{support_root: support_root} do
    assert {:error, message, 2} =
             Support.run(["bundle", "create", "--bogus"], runtime(support_root))

    assert message =~ "Unknown option: --bogus"
    assert message =~ "orchardctl support bundle create"
  end

  test "SPEC M5 bundle contains redacted config, bounded logs, node snapshots, and request summary",
       %{support_root: support_root, output_dir: output_dir, tmp_dir: tmp_dir} do
    File.write!(
      Path.join([support_root, "config", "controller.env"]),
      """
      PORT=4000
      SECRET_KEY_BASE=super-secret
      DATABASE_URL=postgres://user:password@localhost/orchard
      OPENAI_API_KEY=sk-test
      ORCHARD_API_KEY=orch_test.secret
      AWS_ACCESS_KEY_ID=AKIASECRET
      #SECRET_KEY_BASE=old-super-secret
      # DATABASE_URL=postgres://user:old-password@localhost/old_orchard
      ORCHARD_PUBLIC_HOST=orchard.local
      """
    )

    File.write!(Path.join([support_root, "logs", "controller.log"]), "abcdefghij")
    File.write!(Path.join([support_root, "logs", "workers", "worker.log"]), "worker-ready\n")

    assert {:ok, output} =
             Support.run(
               [
                 "bundle",
                 "create",
                 "--support-root",
                 support_root,
                 "--output",
                 output_dir,
                 "--max-log-bytes",
                 "4"
               ],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    assert output =~ "Created support bundle: #{archive_path}"
    assert output =~ "Audit: recorded"
    assert File.regular?(archive_path)
    assert Bitwise.band(File.stat!(archive_path).mode, 0o777) == 0o600
    assert_received {:support_bundle_audit, audit_event}
    assert audit_event.archive_name == Path.basename(archive_path)
    refute Map.has_key?(audit_event, :support_root)

    extract_dir = Path.join(tmp_dir, "extracted")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    manifest = read_json!(extract_dir, "manifest.json")

    assert manifest["bundle_format"] == "orchard.support_bundle.v1"
    assert Enum.any?(manifest["spec_references"], &String.contains?(&1, "SPEC.md 11.9"))

    config = File.read!(Path.join([extract_dir, "config", "controller.env"]))
    assert config =~ "PORT=4000"
    assert config =~ "ORCHARD_PUBLIC_HOST=orchard.local"
    assert config =~ "SECRET_KEY_BASE=[redacted]"
    assert config =~ "DATABASE_URL=[redacted]"
    assert config =~ "OPENAI_API_KEY=[redacted]"
    assert config =~ "ORCHARD_API_KEY=[redacted]"
    assert config =~ "AWS_ACCESS_KEY_ID=[redacted]"
    assert config =~ "#SECRET_KEY_BASE=[redacted]"
    assert config =~ "# DATABASE_URL=[redacted]"
    refute config =~ "super-secret"
    refute config =~ "old-super-secret"
    refute config =~ "postgres://user"
    refute config =~ "sk-test"
    refute config =~ "orch_test.secret"
    refute config =~ "AKIASECRET"

    controller_log = File.read!(Path.join([extract_dir, "logs", "controller.log"]))
    assert controller_log == "[truncated to last 4 bytes]\n"

    worker_log = File.read!(Path.join([extract_dir, "logs", "workers", "worker.log"]))
    assert worker_log == "[truncated to last 4 bytes]\n"

    nodes = read_json!(extract_dir, "diagnostics/nodes.json")
    assert nodes["status"] == "ok"
    assert get_in(nodes, ["data", "summary", "total"]) == 1
    assert get_in(nodes, ["data", "nodes", Access.at(0), "display_name"]) == "node-a"

    requests = read_json!(extract_dir, "diagnostics/requests.json")
    assert requests["status"] == "ok"
    assert get_in(requests, ["data", "summary", "total"]) == 2
    assert get_in(requests, ["data", "recent", Access.at(0), "public_id"]) == "req_1"
    assert get_in(requests, ["data", "recent", Access.at(0), "stream"]) == false
    refute Jason.encode!(requests) =~ "request_payload"
  end

  test "log collection redacts sensitive lines", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    File.write!(
      Path.join([support_root, "logs", "controller.log"]),
      """
      booted
      Authorization: Bearer orch_secret.token
      request_payload={"prompt":"private prompt"}
      password=orch_password
      token=orch_token
      ready
      """
    )

    File.write!(
      Path.join([support_root, "logs", "truncated.log"]),
      "Authorization: Bearer orch_partial_secret\nready\n"
    )

    assert {:ok, _output} =
             Support.run(
               [
                 "bundle",
                 "create",
                 "--support-root",
                 support_root,
                 "--output",
                 output_dir,
                 "--max-log-bytes",
                 "512"
               ],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "redacted")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    log = File.read!(Path.join([extract_dir, "logs", "controller.log"]))
    assert log =~ "booted"
    assert log =~ "ready"
    assert log =~ "[redacted log line]"
    refute log =~ "orch_secret"
    refute log =~ "private prompt"
    refute log =~ "orch_password"
    refute log =~ "orch_token"

    truncated_log = File.read!(Path.join([extract_dir, "logs", "truncated.log"]))
    refute truncated_log =~ "orch_partial_secret"
  end

  test "log collection redacts credential URLs and query secrets", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    File.write!(
      Path.join([support_root, "logs", "controller.log"]),
      """
      booted
      postgresql://orchard:db-secret@db.local/orchard
      callback=/health?api_key=query-api-secret&token=query-token-secret
      redirect=https://user:http-secret@example.test/path
      license=/status?license_key=query-license-secret
      stats=/status?token_count=7&license_mode=offline
      ready
      """
    )

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "credential-url-redaction")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    log = File.read!(Path.join([extract_dir, "logs", "controller.log"]))
    assert log =~ "booted"
    assert log =~ "ready"
    assert log =~ "stats=/status?token_count=7&license_mode=offline"
    assert log =~ "[redacted log line]"
    refute log =~ "db-secret"
    refute log =~ "query-api-secret"
    refute log =~ "query-token-secret"
    refute log =~ "http-secret"
    refute log =~ "query-license-secret"
  end

  test "redaction covers env secret values, multiline env blocks, and escaped JSON logs", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    File.write!(
      Path.join([support_root, "config", "controller.env"]),
      """
      ORCHARD_PUBLIC_HOST=orchard.local
      REDIS_URL=redis://:redis-secret@localhost:6379/0
      WEBHOOK=/callback?api_key=env-query-secret&token_count=7
      PRIVATE_KEY="-----BEGIN PRIVATE KEY-----
      EnvPrivateKeyBody
      -----END PRIVATE KEY-----"
      """
    )

    File.write!(
      Path.join([support_root, "logs", "controller.log"]),
      ~S"""
      booted
      body={\"prompt\":\"escaped prompt secret\"}
      payload=\"{\\\"messages\\\":[{\\\"content\\\":\\\"escaped message secret\\\"}]}\"
      tokenizer diagnostic prompt_tokens=2 token_count=2
      ids={\"input_ids\":[1,2,3]}
      ready
      """
    )

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "env-value-redaction")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    config = File.read!(Path.join([extract_dir, "config", "controller.env"]))
    assert config =~ "ORCHARD_PUBLIC_HOST=orchard.local"
    assert config =~ "REDIS_URL=[redacted]"
    assert config =~ "WEBHOOK=[redacted]"
    assert config =~ "PRIVATE_KEY=[redacted]"
    refute config =~ "redis-secret"
    refute config =~ "env-query-secret"
    refute config =~ "EnvPrivateKeyBody"
    refute config =~ "PRIVATE KEY"

    log = File.read!(Path.join([extract_dir, "logs", "controller.log"]))
    assert log =~ "booted"
    assert log =~ "tokenizer diagnostic prompt_tokens=2 token_count=2"
    assert log =~ "ready"
    assert log =~ "[redacted log line]"
    refute log =~ "escaped prompt secret"
    refute log =~ "escaped message secret"
    refute log =~ "input_ids"
    refute log =~ "[1,2,3]"
  end

  test "redaction covers bare license assignments and compact secret keys", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    File.write!(
      Path.join([support_root, "config", "controller.env"]),
      """
      LICENSE=env-license-secret
      SECRETKEY=env-secret-key
      PRIVATEKEY=env-private-key
      ACCESSKEY=env-access-key
      LICENSEKEY=env-license-key
      ORCHARD_LICENSE_ENFORCEMENT=strict
      ORCHARD_LICENSE_MODE=offline
      """
    )

    File.write!(
      Path.join([support_root, "logs", "controller.log"]),
      """
      license=log-license-secret
      orchard_license=log-orchard-license-secret
      callback=/cb?license=query-license-secret&license_mode=offline
      SECRETKEY=log-secret-key
      PRIVATEKEY=log-private-key
      ACCESSKEY=log-access-key
      LICENSEKEY=log-license-key
      ORCHARD_LICENSE_ENFORCEMENT=strict license_mode=offline
      """
    )

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "compact-key-redaction")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    config = File.read!(Path.join([extract_dir, "config", "controller.env"]))
    assert config =~ "LICENSE=[redacted]"
    assert config =~ "SECRETKEY=[redacted]"
    assert config =~ "PRIVATEKEY=[redacted]"
    assert config =~ "ACCESSKEY=[redacted]"
    assert config =~ "LICENSEKEY=[redacted]"
    assert config =~ "ORCHARD_LICENSE_ENFORCEMENT=strict"
    assert config =~ "ORCHARD_LICENSE_MODE=offline"
    refute config =~ "env-license-secret"
    refute config =~ "env-secret-key"
    refute config =~ "env-private-key"
    refute config =~ "env-access-key"
    refute config =~ "env-license-key"

    log = File.read!(Path.join([extract_dir, "logs", "controller.log"]))
    assert log =~ "[redacted log line]"
    assert log =~ "ORCHARD_LICENSE_ENFORCEMENT=strict license_mode=offline"
    refute log =~ "log-license-secret"
    refute log =~ "log-orchard-license-secret"
    refute log =~ "query-license-secret"
    refute log =~ "log-secret-key"
    refute log =~ "log-private-key"
    refute log =~ "log-access-key"
    refute log =~ "log-license-key"
  end

  test "redaction preserves tokenizer and license diagnostics while redacting credentials", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    File.write!(
      Path.join([support_root, "config", "controller.env"]),
      """
      ORCHARD_TOKENIZER_EXECUTABLE=/Library/Application Support/Orchard/native/tokenizer
      ORCHARD_LICENSE_ENFORCEMENT=strict
      ORCHARD_LICENSE_MODE=offline
      ORCHARD_LICENSE_KEY=lic-secret
      ORCHARD_ACCESS_TOKEN=access-secret
      ORCHARD_TOKEN=plain-token-secret
      """
    )

    File.write!(
      Path.join([support_root, "logs", "controller.log"]),
      """
      tokenizer loaded executable=/Library/Application Support/Orchard/native/tokenizer
      input_tokens=12 output_tokens=4 token_count=16
      ORCHARD_LICENSE_ENFORCEMENT=strict license_mode=offline
      license_key=lic-secret
      api_token=api-secret
      token=plain-token-secret
      """
    )

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "precise-redaction")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    config = File.read!(Path.join([extract_dir, "config", "controller.env"]))

    assert config =~
             "ORCHARD_TOKENIZER_EXECUTABLE=/Library/Application Support/Orchard/native/tokenizer"

    assert config =~ "ORCHARD_LICENSE_ENFORCEMENT=strict"
    assert config =~ "ORCHARD_LICENSE_MODE=offline"
    assert config =~ "ORCHARD_LICENSE_KEY=[redacted]"
    assert config =~ "ORCHARD_ACCESS_TOKEN=[redacted]"
    assert config =~ "ORCHARD_TOKEN=[redacted]"
    refute config =~ "lic-secret"
    refute config =~ "access-secret"
    refute config =~ "plain-token-secret"

    log = File.read!(Path.join([extract_dir, "logs", "controller.log"]))

    assert log =~
             "tokenizer loaded executable=/Library/Application Support/Orchard/native/tokenizer"

    assert log =~ "input_tokens=12 output_tokens=4 token_count=16"
    assert log =~ "ORCHARD_LICENSE_ENFORCEMENT=strict license_mode=offline"
    refute log =~ "lic-secret"
    refute log =~ "api-secret"
    refute log =~ "plain-token-secret"
  end

  test "redaction covers compact password keys, PEM blocks, and payload assignments", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    File.write!(
      Path.join([support_root, "config", "controller.env"]),
      """
      PGPASSWORD=pg-secret
      #PGPASSWORD=old-pg-secret
      ORCHARD_PUBLIC_HOST=orchard.local
      """
    )

    File.write!(
      Path.join([support_root, "logs", "controller.log"]),
      """
      PGPASSWORD=pg-log-secret
      prompt: private prompt text
      %{messages: [%{role: "user", content: "private message text"}]}
      input: private input text
      content: private content text
      -----BEGIN PRIVATE KEY-----
      MIIPrivateKeyBody
      -----END PRIVATE KEY-----
      input_tokens=12 prompt_tokens=8 token_count=20
      safe diagnostic line
      """
    )

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "payload-redaction")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    config = File.read!(Path.join([extract_dir, "config", "controller.env"]))
    assert config =~ "PGPASSWORD=[redacted]"
    assert config =~ "#PGPASSWORD=[redacted]"
    assert config =~ "ORCHARD_PUBLIC_HOST=orchard.local"
    refute config =~ "pg-secret"
    refute config =~ "old-pg-secret"

    log = File.read!(Path.join([extract_dir, "logs", "controller.log"]))
    assert log =~ "input_tokens=12 prompt_tokens=8 token_count=20"
    assert log =~ "safe diagnostic line"
    assert log =~ "[redacted log line]"
    refute log =~ "pg-log-secret"
    refute log =~ "private prompt text"
    refute log =~ "private message text"
    refute log =~ "private input text"
    refute log =~ "private content text"
    refute log =~ "MIIPrivateKeyBody"
    refute log =~ "PRIVATE KEY"
  end

  test "redaction covers prompt token IDs and camel-case sensitive keys", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    File.write!(
      Path.join([support_root, "config", "controller.env"]),
      """
      accessToken=env-access-secret
      clientSecret=env-client-secret
      secretAccessKey=env-secret-access-key
      license_certificate=env-license-certificate
      machine_certificate=env-machine-certificate
      ORCHARD_TOKENIZER_EXECUTABLE=/Library/Application Support/Orchard/native/tokenizer
      """
    )

    File.write!(
      Path.join([support_root, "logs", "controller.log"]),
      """
      prompt_token_ids=[101, 202, 303]
      promptTokenIds: [404, 505, 606]
      token_ids=[111, 222, 333]
      tokenIds: [444, 555, 666]
      input_ids=[777, 888, 999]
      inputIds: [123, 234, 345]
      tokenizer failed with prompt_token_ids_length_mismatch ids=[707, 808]
      supports_prompt_token_ids=true worker_supports_prompt_token_ids=true token_count=3
      input_tokens=9 prompt_tokens=8 total_tokens=17 token_count=17
      accessToken=log-access-secret
      clientSecret: log-client-secret
      secretAccessKey=log-secret-access-key
      license_certificate=log-license-certificate
      machine_certificate=log-machine-certificate
      safe diagnostic line
      """
    )

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "token-id-redaction")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    config = File.read!(Path.join([extract_dir, "config", "controller.env"]))
    assert config =~ "accessToken=[redacted]"
    assert config =~ "clientSecret=[redacted]"
    assert config =~ "secretAccessKey=[redacted]"
    assert config =~ "license_certificate=[redacted]"
    assert config =~ "machine_certificate=[redacted]"

    assert config =~
             "ORCHARD_TOKENIZER_EXECUTABLE=/Library/Application Support/Orchard/native/tokenizer"

    refute config =~ "env-access-secret"
    refute config =~ "env-client-secret"
    refute config =~ "env-secret-access-key"
    refute config =~ "env-license-certificate"
    refute config =~ "env-machine-certificate"

    log = File.read!(Path.join([extract_dir, "logs", "controller.log"]))
    assert log =~ "[redacted log line]"

    assert log =~
             "supports_prompt_token_ids=true worker_supports_prompt_token_ids=true token_count=3"

    assert log =~ "input_tokens=9 prompt_tokens=8 total_tokens=17 token_count=17"
    assert log =~ "safe diagnostic line"
    refute log =~ "101"
    refute log =~ "404"
    refute log =~ "111"
    refute log =~ "444"
    refute log =~ "777"
    refute log =~ "123"
    refute log =~ "707"
    refute log =~ "log-access-secret"
    refute log =~ "log-client-secret"
    refute log =~ "log-secret-access-key"
    refute log =~ "log-license-certificate"
    refute log =~ "log-machine-certificate"
  end

  test "truncated PEM tails redact through unmatched private key terminators", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    retained_tail = """
    MIIPrivateKeyBody1
    MIIPrivateKeyBody2
    -----END PRIVATE KEY-----
    safe diagnostic line
    """

    File.write!(
      Path.join([support_root, "logs", "controller.log"]),
      """
      before
      -----BEGIN PRIVATE KEY-----
      """ <> retained_tail
    )

    assert {:ok, _output} =
             Support.run(
               [
                 "bundle",
                 "create",
                 "--support-root",
                 support_root,
                 "--output",
                 output_dir,
                 "--max-log-bytes",
                 Integer.to_string(byte_size(retained_tail))
               ],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "truncated-pem")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    log = File.read!(Path.join([extract_dir, "logs", "controller.log"]))
    assert log =~ "[truncated to last #{byte_size(retained_tail)} bytes]"
    assert log =~ "[redacted log line]"
    assert log =~ "safe diagnostic line"
    refute log =~ "MIIPrivateKeyBody"
    refute log =~ "PRIVATE KEY"
  end

  test "config collection skips symlinked env files", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    outside_path = Path.join(tmp_dir, "outside.env")
    File.write!(outside_path, "ORCHARD_PUBLIC_HOST=leaked.example\n")
    File.ln_s!(outside_path, Path.join([support_root, "config", "controller.env"]))

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "symlink-config")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    refute File.exists?(Path.join([extract_dir, "config", "controller.env"]))

    assert File.read!(Path.join([extract_dir, "config", "README.txt"])) =~
             "No Orchard env config files were found."
  end

  test "config collection skips symlinked config directories", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    outside_config_dir = Path.join(tmp_dir, "outside-config")
    File.mkdir_p!(outside_config_dir)

    File.write!(
      Path.join(outside_config_dir, "controller.env"),
      "ORCHARD_PUBLIC_HOST=leaked.example\n"
    )

    File.rm_rf!(Path.join(support_root, "config"))
    File.ln_s!(outside_config_dir, Path.join(support_root, "config"))

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "symlink-config-dir")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    refute File.exists?(Path.join([extract_dir, "config", "controller.env"]))

    assert File.read!(Path.join([extract_dir, "config", "README.txt"])) =~
             "No Orchard env config files were found."
  end

  test "log collection skips files that become unavailable", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    log_path = Path.join([support_root, "logs", "controller.log"])
    File.write!(log_path, "ready\n")
    File.chmod!(log_path, 0o000)

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "unavailable-log")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    refute File.exists?(Path.join([extract_dir, "logs", "controller.log"]))

    assert File.read!(Path.join([extract_dir, "logs", "README.txt"])) =~
             "No Orchard log files were found."
  end

  test "log collection caps file count and prefers Orchard service logs", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    controller_log = Path.join([support_root, "logs", "controller.log"])
    File.write!(controller_log, "controller\n")
    touch_log!(controller_log, 1)

    for index <- 1..5 do
      path = Path.join([support_root, "logs", "rotated-#{index}.log"])
      File.write!(path, "rotated #{index}\n")
      touch_log!(path, index + 10)
    end

    runtime =
      support_root
      |> runtime()
      |> Map.put(:log_collection_limits, fn -> %{max_files: 3, max_total_bytes: 1_024} end)

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "log-file-count-cap")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    assert File.exists?(Path.join([extract_dir, "logs", "controller.log"]))
    assert File.exists?(Path.join([extract_dir, "logs", "rotated-5.log"]))
    assert File.exists?(Path.join([extract_dir, "logs", "rotated-4.log"]))
    refute File.exists?(Path.join([extract_dir, "logs", "rotated-3.log"]))

    log_collection = read_json!(extract_dir, "diagnostics/logs.json")
    assert get_in(log_collection, ["data", "files_available"]) == 6
    assert get_in(log_collection, ["data", "files_collected"]) == 3
    assert get_in(log_collection, ["data", "files_skipped"]) == 3

    assert %{"path" => "rotated-3.log", "reason" => "file_count_limit"} in get_in(
             log_collection,
             ["data", "skipped"]
           )

    manifest = read_json!(extract_dir, "manifest.json")
    assert get_in(manifest, ["log_collection", "files_collected"]) == 3
  end

  test "log collection caps aggregate retained bytes and records metadata", %{
    support_root: support_root,
    output_dir: output_dir,
    tmp_dir: tmp_dir
  } do
    for index <- 1..3 do
      path = Path.join([support_root, "logs", "aggregate-#{index}.log"])
      File.write!(path, "prefix\n" <> String.duplicate(Integer.to_string(index), 24))
      touch_log!(path, index)
    end

    runtime =
      support_root
      |> runtime()
      |> Map.put(:log_collection_limits, fn -> %{max_files: 10, max_total_bytes: 25} end)

    assert {:ok, _output} =
             Support.run(
               [
                 "bundle",
                 "create",
                 "--support-root",
                 support_root,
                 "--output",
                 output_dir,
                 "--max-log-bytes",
                 "20"
               ],
               runtime
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "log-aggregate-cap")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    assert File.exists?(Path.join([extract_dir, "logs", "aggregate-3.log"]))
    assert File.exists?(Path.join([extract_dir, "logs", "aggregate-2.log"]))
    refute File.exists?(Path.join([extract_dir, "logs", "aggregate-1.log"]))

    log_collection = read_json!(extract_dir, "diagnostics/logs.json")
    assert get_in(log_collection, ["data", "bytes_retained"]) == 25

    assert %{"path" => "aggregate-1.log", "reason" => "total_log_bytes_limit"} in get_in(
             log_collection,
             ["data", "skipped"]
           )

    truncated_paths =
      log_collection
      |> get_in(["data", "truncated"])
      |> Enum.map(& &1["path"])

    assert "aggregate-3.log" in truncated_paths
    assert "aggregate-2.log" in truncated_paths
  end

  test "truncated logs omit the first partial line before redaction",
       %{support_root: support_root, output_dir: output_dir, tmp_dir: tmp_dir} do
    File.write!(
      Path.join([support_root, "logs", "controller.log"]),
      "Authorization: Bearer orch_partial_secret\nsafe\n"
    )

    assert {:ok, _output} =
             Support.run(
               [
                 "bundle",
                 "create",
                 "--support-root",
                 support_root,
                 "--output",
                 output_dir,
                 "--max-log-bytes",
                 "12"
               ],
               runtime(support_root)
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "truncated")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    log = File.read!(Path.join([extract_dir, "logs", "controller.log"]))
    assert log == "[truncated to last 12 bytes]\nsafe\n"
    refute log =~ "orch_partial_secret"
  end

  test "existing output directory permissions are not changed",
       %{support_root: support_root, output_dir: output_dir} do
    File.mkdir_p!(output_dir)
    File.chmod!(output_dir, 0o755)

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime(support_root)
             )

    assert Bitwise.band(File.stat!(output_dir).mode, 0o777) == 0o755
  end

  test "temporary archive is written under a private directory",
       %{support_root: support_root, output_dir: output_dir} do
    File.mkdir_p!(output_dir)
    File.chmod!(output_dir, 0o755)

    runtime =
      support_root
      |> runtime()
      |> Map.put(:archive, fn stage_dir, temp_archive_path ->
        archive_dir = Path.dirname(temp_archive_path)

        send(
          self(),
          {:archive_dir, archive_dir, Bitwise.band(File.stat!(archive_dir).mode, 0o777)}
        )

        archive_stage(stage_dir, temp_archive_path)
      end)

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime
             )

    assert_received {:archive_dir, archive_dir, 0o700}
    temp_root = Path.dirname(archive_dir)
    assert Path.dirname(temp_root) == output_dir
    assert Path.basename(archive_dir) == "archive"
    refute archive_dir == output_dir
    refute File.exists?(temp_root)
  end

  test "temporary path collision does not remove another in-flight bundle directory",
       %{support_root: support_root, output_dir: output_dir} do
    File.mkdir_p!(output_dir)

    colliding_stage_dir =
      Path.join(output_dir, ".orchard-support-bundle-20260622T123456Z-collide.stage")

    File.mkdir_p!(colliding_stage_dir)
    File.write!(Path.join(colliding_stage_dir, "sentinel"), "owned")

    {:ok, nonce_agent} = Agent.start(fn -> ["collide", "fresh"] end)
    on_exit(fn -> Agent.stop(nonce_agent) end)

    runtime =
      support_root
      |> runtime()
      |> Map.put(:path_nonce, fn ->
        Agent.get_and_update(nonce_agent, fn
          [nonce | rest] -> {nonce, rest}
          [] -> {"fresh", []}
        end)
      end)

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime
             )

    assert File.read!(Path.join(colliding_stage_dir, "sentinel")) == "owned"
  end

  test "final archive creation retries without overwriting an existing bundle",
       %{support_root: support_root, output_dir: output_dir} do
    File.mkdir_p!(output_dir)

    existing_archive = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")

    runtime =
      support_root
      |> runtime()
      |> Map.put(:archive, fn stage_dir, temp_archive_path ->
        :ok = archive_stage(stage_dir, temp_archive_path)
        File.write!(existing_archive, "existing archive")
        :ok
      end)

    assert {:ok, output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime
             )

    retry_archive = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z-1.tar.gz")
    assert output =~ "Created support bundle: #{retry_archive}"
    assert File.read!(existing_archive) == "existing archive"
    assert File.regular?(retry_archive)
  end

  test "snapshot failures do not serialize raw exception messages",
       %{support_root: support_root, output_dir: output_dir, tmp_dir: tmp_dir} do
    runtime =
      support_root
      |> runtime()
      |> Map.put(:nodes_summary, fn ->
        raise "DATABASE_URL=postgres://user:password@localhost/orchard"
      end)

    assert {:ok, _output} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime
             )

    archive_path = Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz")
    extract_dir = Path.join(tmp_dir, "snapshot-error")
    File.mkdir_p!(extract_dir)
    assert_tar_extract!(archive_path, extract_dir)

    nodes = read_json!(extract_dir, "diagnostics/nodes.json")
    assert nodes["status"] == "unavailable"
    assert nodes["error"] == "snapshot unavailable"
    assert nodes["reason"] == "RuntimeError"
    refute Jason.encode!(nodes) =~ "postgres://"
    refute Jason.encode!(nodes) =~ "password"
  end

  test "archive failure removes temporary archive and stage directory",
       %{support_root: support_root, output_dir: output_dir} do
    runtime =
      support_root
      |> runtime()
      |> Map.put(:archive, fn _stage_dir, temp_archive_path ->
        File.write!(temp_archive_path, "partial")
        {:error, "Error: tar failed with exit 2: no space left"}
      end)

    assert {:error, message, 1} =
             Support.run(
               ["bundle", "create", "--support-root", support_root, "--output", output_dir],
               runtime
             )

    assert message =~ "tar failed"
    refute File.exists?(Path.join(output_dir, "orchard-support-bundle-20260622T123456Z.tar.gz"))
    assert File.ls!(output_dir) == []
  end

  test "json output reports archive path", %{support_root: support_root, output_dir: output_dir} do
    assert {:ok, output} =
             Support.run(
               [
                 "bundle",
                 "create",
                 "--support-root",
                 support_root,
                 "--output",
                 output_dir,
                 "--json"
               ],
               runtime(support_root)
             )

    decoded = Jason.decode!(output)
    assert decoded["bundle_format"] == "orchard.support_bundle.v1"
    assert decoded["archive_path"] =~ "orchard-support-bundle-20260622T123456Z.tar.gz"
    assert decoded["audit"] == %{"status" => "recorded"}
  end

  test "create help is side-effect free", %{support_root: support_root} do
    runtime =
      support_root
      |> runtime()
      |> Map.put(:archive, fn _stage_dir, _archive_path -> flunk("help must not archive") end)

    assert {:ok, message} = Support.run(["bundle", "create", "--help"], runtime)
    assert message =~ "orchardctl support bundle create"
  end

  defp runtime(support_root) do
    %{
      archive: &archive_stage/2,
      audit_support_bundle: fn event ->
        send(self(), {:support_bundle_audit, event})
        :ok
      end,
      cmd: &launchctl_stub/3,
      file_regular?: fn path -> String.ends_with?(path, "com.orchard.controller.plist") end,
      list_nodes: fn ->
        [
          %{
            id: "node-id-a",
            display_name: "node-a",
            hostname: "node-a.local",
            state: :active,
            health: :healthy,
            agent_version: "0.5.0-dev",
            last_heartbeat_at: @fixed_now,
            connect_host: "127.0.0.1",
            connect_port: 50_071,
            capabilities: %{"supports_prompt_token_ids" => true},
            tool_readiness: %{}
          }
        ]
      end,
      list_recent_requests: fn _limit ->
        [
          %{
            id: "request-id-a",
            public_id: "req_1",
            endpoint: :responses,
            requested_model: "test-model",
            state: :completed,
            stream: false,
            node_id: "node-id-a",
            http_status: 200,
            error_code: nil,
            input_tokens: 12,
            output_tokens: 4,
            inserted_at: @fixed_now,
            completed_at: @fixed_now,
            request_payload: %{"must" => "not be serialized"}
          }
        ]
      end,
      nodes_summary: fn ->
        %{
          total: 1,
          by_state: %{active: 1},
          by_health: %{healthy: 1, degraded: 0, unhealthy: 0, unreachable: 0}
        }
      end,
      now: fn -> @fixed_now end,
      path_nonce: fn -> "testnonce" end,
      requests_performance_summary: fn ->
        %{
          sample_size: 1,
          avg_ttft_ms: 10.0,
          avg_generation_ms: 20.0,
          avg_total_latency_ms: 30.0,
          avg_tokens_per_second: 2.0
        }
      end,
      requests_summary: fn ->
        %{
          total: 2,
          active: 1,
          terminal: 1,
          by_state: %{running: 1, completed: 1}
        }
      end,
      status_snapshot: fn _runtime ->
        %{
          state: :ready,
          role: :all,
          body: %{
            "status" => "ok",
            "runtime" => %{
              "node_id" => "node-id-a",
              "worker_state" => "idle",
              "counts" => %{"loaded_models" => 1}
            }
          }
        }
      end,
      support_root: fn -> support_root end,
      version: fn -> "0.5.0-dev" end
    }
  end

  defp launchctl_stub("launchctl", ["print", "system/com.orchard.controller"], opts) do
    assert opts[:stderr_to_stdout] == true
    {"{ pid = 123 }", 0}
  end

  defp launchctl_stub("launchctl", ["print", "system/com.orchard.node-agent"], opts) do
    assert opts[:stderr_to_stdout] == true
    {"Could not find service", 113}
  end

  defp launchctl_stub(program, args, _opts) do
    flunk("unexpected command: #{inspect({program, args})}")
  end

  defp archive_stage(stage_dir, archive_path) do
    case System.cmd("tar", ["-czf", archive_path, "-C", stage_dir, "."], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, "tar failed #{code}: #{output}"}
    end
  end

  defp assert_tar_extract!(archive_path, extract_dir) do
    assert {"", 0} = System.cmd("tar", ["-xzf", archive_path, "-C", extract_dir])
  end

  defp read_json!(root, relative_path) do
    root
    |> Path.join(relative_path)
    |> File.read!()
    |> Jason.decode!()
  end

  defp touch_log!(path, second) do
    assert :ok = :file.change_time(String.to_charlist(path), {{2026, 1, 1}, {0, 0, second}})
  end
end
