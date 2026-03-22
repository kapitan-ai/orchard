defmodule Orchard.Node.ModelAcquisition.Source.S3Test do
  use ExUnit.Case, async: false

  alias Orchard.ArtifactBundle
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Node.ModelAcquisition
  alias Orchard.Node.ModelAcquisition.Request
  alias Orchard.Node.ModelAcquisition.Source.S3
  alias Orchard.Node.ModelAcquisition.Tar

  @bucket "test-bucket"
  @object_key "models/test-model.tar.gz"

  setup do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("s3_test_#{:rand.uniform(1_000_000)}")

    models_root = Path.join(tmp_dir, "models")
    source_dir = Path.join(tmp_dir, "source")

    File.mkdir_p!(models_root)
    File.mkdir_p!(source_dir)

    # Create source bundle files
    config_content = ~s({"model_type":"llama","hidden_size":256})
    tokenizer_content = ~s({"version":"1.0"})
    weights_content = "fake-safetensors-weights-data-for-testing"

    File.write!(Path.join(source_dir, "config.json"), config_content)
    File.write!(Path.join(source_dir, "tokenizer.json"), tokenizer_content)
    File.write!(Path.join(source_dir, "model.safetensors"), weights_content)

    {:ok, hash} = ArtifactBundle.tree_sha256(source_dir)

    # Create tar.gz from source dir
    tar_gz_bytes = create_tar_gz(source_dir)
    # Create tar (uncompressed) from source dir
    tar_bytes = create_tar(source_dir)
    # Create tar.gz with single wrapper directory
    tar_gz_wrapped_bytes = create_tar_gz_wrapped(source_dir, "model-v1")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # Configure Req.Test stub
    stub_name = :"s3_test_#{:rand.uniform(1_000_000)}"

    previous_runtime = Application.get_env(:orchard_node_agent, :runtime, [])
    override_s3_config(stub_name)

    on_exit(fn ->
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
    end)

    %{
      tmp_dir: tmp_dir,
      models_root: models_root,
      source_dir: source_dir,
      hash: hash,
      tar_gz_bytes: tar_gz_bytes,
      tar_bytes: tar_bytes,
      tar_gz_wrapped_bytes: tar_gz_wrapped_bytes,
      stub_name: stub_name
    }
  end

  # ============================================================================
  # URI Parsing
  # ============================================================================

  describe "parse_s3_uri/1" do
    test "parses bucket/key.tar.gz" do
      assert {:ok,
              %{bucket: "my-bucket", object_key: "models/model.tar.gz", archive_format: :tar_gz}} =
               S3.parse_s3_uri("s3://my-bucket/models/model.tar.gz")
    end

    test "parses bucket/key.tar" do
      assert {:ok, %{bucket: "my-bucket", object_key: "model.tar", archive_format: :tar}} =
               S3.parse_s3_uri("s3://my-bucket/model.tar")
    end

    test "parses region override" do
      assert {:ok, %{bucket: "my-bucket", region: "us-west-2"}} =
               S3.parse_s3_uri("s3://my-bucket/model.tar.gz?region=us-west-2")
    end

    test "parses endpoint override" do
      assert {:ok, %{bucket: "my-bucket", endpoint: "http://minio:9000"}} =
               S3.parse_s3_uri("s3://my-bucket/model.tar.gz?endpoint=http://minio:9000")
    end

    test "parses region and endpoint together" do
      assert {:ok, %{region: "eu-west-1", endpoint: "http://minio:9000"}} =
               S3.parse_s3_uri(
                 "s3://my-bucket/model.tar.gz?region=eu-west-1&endpoint=http://minio:9000"
               )
    end

    test "decodes percent-encoded object keys" do
      assert {:ok, %{bucket: "my-bucket", object_key: "models/my model.tar.gz"}} =
               S3.parse_s3_uri("s3://my-bucket/models/my%20model.tar.gz")
    end

    test "decodes percent-encoded path segments without double-encoding" do
      assert {:ok, %{bucket: "my-bucket", object_key: "special chars/model+v1.tar.gz"}} =
               S3.parse_s3_uri("s3://my-bucket/special%20chars/model+v1.tar.gz")
    end

    test "rejects missing bucket" do
      assert {:error, :invalid_source_uri} = S3.parse_s3_uri("s3:///key.tar.gz")
    end

    test "rejects missing key" do
      assert {:error, :invalid_source_uri} = S3.parse_s3_uri("s3://bucket")
      assert {:error, :invalid_source_uri} = S3.parse_s3_uri("s3://bucket/")
    end

    test "rejects unknown query params" do
      assert {:error, :invalid_source_uri} =
               S3.parse_s3_uri("s3://bucket/key.tar.gz?version=123")
    end

    test "rejects unsupported extensions" do
      assert {:error, {:unsupported_archive_extension, _}} =
               S3.parse_s3_uri("s3://bucket/model.zip")

      assert {:error, {:unsupported_archive_extension, _}} =
               S3.parse_s3_uri("s3://bucket/model.tgz")

      assert {:error, {:unsupported_archive_extension, _}} =
               S3.parse_s3_uri("s3://bucket/model.safetensors")
    end

    test "rejects non-s3 scheme" do
      assert {:error, :invalid_source_uri} = S3.parse_s3_uri("http://bucket/key.tar.gz")
    end

    test "rejects nil and non-string" do
      assert {:error, :invalid_source_uri} = S3.parse_s3_uri(nil)
      assert {:error, :invalid_source_uri} = S3.parse_s3_uri(123)
    end
  end

  # ============================================================================
  # Tar Extraction
  # ============================================================================

  describe "Tar.extract_archive/3" do
    test "extracts tar.gz into staging", ctx do
      staging = Path.join(ctx.tmp_dir, "tar_staging")
      File.mkdir_p!(staging)
      archive_path = Path.join(ctx.tmp_dir, "test.tar.gz")
      File.write!(archive_path, ctx.tar_gz_bytes)

      assert :ok = Tar.extract_archive(archive_path, staging, :tar_gz)

      assert File.exists?(Path.join(staging, "config.json"))
      assert File.exists?(Path.join(staging, "tokenizer.json"))
      assert File.exists?(Path.join(staging, "model.safetensors"))
    end

    test "extracts uncompressed tar into staging", ctx do
      staging = Path.join(ctx.tmp_dir, "tar_staging")
      File.mkdir_p!(staging)
      archive_path = Path.join(ctx.tmp_dir, "test.tar")
      File.write!(archive_path, ctx.tar_bytes)

      assert :ok = Tar.extract_archive(archive_path, staging, :tar)

      assert File.exists?(Path.join(staging, "config.json"))
    end

    test "normalizes single wrapper directory", ctx do
      staging = Path.join(ctx.tmp_dir, "tar_staging")
      File.mkdir_p!(staging)
      archive_path = Path.join(ctx.tmp_dir, "wrapped.tar.gz")
      File.write!(archive_path, ctx.tar_gz_wrapped_bytes)

      assert :ok = Tar.extract_archive(archive_path, staging, :tar_gz)

      # Files should be at staging root, not inside model-v1/
      assert File.exists?(Path.join(staging, "config.json"))
      assert File.exists?(Path.join(staging, "model.safetensors"))
      refute File.exists?(Path.join(staging, "model-v1"))
    end

    test "rejects archive with path traversal" do
      {archive_path, staging} = create_malicious_tar(:traversal)

      assert {:error, {:invalid_source_layout, msg}} =
               Tar.extract_archive(archive_path, staging, :tar)

      assert msg =~ "path traversal"
    end

    test "rejects archive with absolute path" do
      {archive_path, staging} = create_malicious_tar(:absolute)

      assert {:error, {:invalid_source_layout, msg}} =
               Tar.extract_archive(archive_path, staging, :tar)

      assert msg =~ "absolute path"
    end

    test "rejects archive with symlink" do
      {archive_path, staging} = create_malicious_tar(:symlink)

      assert {:error, {:invalid_source_layout, msg}} =
               Tar.extract_archive(archive_path, staging, :tar)

      assert msg =~ "symlink"
    end

    test "rejects empty archive" do
      tmp = System.tmp_dir!() |> Path.join("empty_tar_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp)
      staging = Path.join(tmp, "staging")
      File.mkdir_p!(staging)
      archive_path = Path.join(tmp, "empty.tar")

      # Create empty tar
      {:ok, tar} = :erl_tar.open(String.to_charlist(archive_path), [:write])
      :ok = :erl_tar.close(tar)

      assert {:error, {:invalid_source_layout, msg}} =
               Tar.extract_archive(archive_path, staging, :tar)

      assert msg =~ "no files"

      File.rm_rf!(tmp)
    end

    test "archive entries named .extract or .source_archive do not collide with temp names" do
      tmp = System.tmp_dir!() |> Path.join("collision_tar_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp)
      staging = Path.join(tmp, "staging")
      File.mkdir_p!(staging)

      # Create a source dir with files that used to collide with internal temp names
      source_dir = Path.join(tmp, "source")
      File.mkdir_p!(Path.join(source_dir, ".extract"))
      File.write!(Path.join(source_dir, ".extract/nested.txt"), "nested")
      File.write!(Path.join(source_dir, "config.json"), "{}")

      archive_path = Path.join(tmp, "collision.tar.gz")

      file_list = [
        {~c".extract/nested.txt",
         String.to_charlist(Path.join(source_dir, ".extract/nested.txt"))},
        {~c"config.json", String.to_charlist(Path.join(source_dir, "config.json"))}
      ]

      :ok = :erl_tar.create(String.to_charlist(archive_path), file_list, [:compressed])

      assert :ok = Tar.extract_archive(archive_path, staging, :tar_gz)

      # Both files should be present in staging
      assert File.exists?(Path.join(staging, "config.json"))
      assert File.exists?(Path.join(staging, ".extract/nested.txt"))

      # No leftover temp dirs in staging
      staging_entries = File.ls!(staging) |> Enum.sort()
      assert ".extract" in staging_entries
      assert "config.json" in staging_entries

      File.rm_rf!(tmp)
    end
  end

  # ============================================================================
  # Happy-Path Materialization (end-to-end via ModelAcquisition)
  # ============================================================================

  describe "end-to-end materialization" do
    test "downloads tar.gz, extracts, verifies hash", ctx do
      stub_s3_success(ctx.stub_name, ctx.tar_gz_bytes)

      request = build_s3_request(ctx, artifact_source_uri: "s3://#{@bucket}/#{@object_key}")

      assert {:ok, final_path, :materialized} = ModelAcquisition.ensure_cached(request)
      assert File.exists?(Path.join(final_path, "config.json"))
      assert File.exists?(Path.join(final_path, "model.safetensors"))
    end

    test "downloads .tar, extracts, verifies hash", ctx do
      stub_s3_success(ctx.stub_name, ctx.tar_bytes)

      request =
        build_s3_request(ctx,
          artifact_source_uri: "s3://#{@bucket}/models/test-model.tar"
        )

      assert {:ok, final_path, :materialized} = ModelAcquisition.ensure_cached(request)
      assert File.exists?(Path.join(final_path, "config.json"))
    end

    test "wrapped tar.gz with single directory is normalized", ctx do
      stub_s3_success(ctx.stub_name, ctx.tar_gz_wrapped_bytes)

      request = build_s3_request(ctx, artifact_source_uri: "s3://#{@bucket}/#{@object_key}")

      assert {:ok, final_path, :materialized} = ModelAcquisition.ensure_cached(request)
      assert File.exists?(Path.join(final_path, "config.json"))
      refute File.exists?(Path.join(final_path, "model-v1"))
    end

    test "final progress telemetry reports files_completed: 1", ctx do
      stub_s3_success(ctx.stub_name, ctx.tar_gz_bytes)

      test_pid = self()

      handler_id = "test-s3-progress-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:orchard, :node, :model_acquisition, :progress],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:progress, measurements, metadata})
        end,
        nil
      )

      request = build_s3_request(ctx, artifact_source_uri: "s3://#{@bucket}/#{@object_key}")
      assert {:ok, _path, :materialized} = ModelAcquisition.ensure_cached(request)

      :telemetry.detach(handler_id)

      events = collect_progress_events()
      refute events == []

      {last_measurements, last_metadata} = List.last(events)
      assert last_measurements.files_completed == 1
      assert last_measurements.total_files == 1
      assert last_metadata.source_scheme == "s3"
    end
  end

  # ============================================================================
  # Cache Hit
  # ============================================================================

  describe "cache behavior" do
    test "second ensure_cached returns cache_hit without network", ctx do
      stub_s3_success(ctx.stub_name, ctx.tar_gz_bytes)

      request = build_s3_request(ctx, artifact_source_uri: "s3://#{@bucket}/#{@object_key}")

      assert {:ok, _path, :materialized} = ModelAcquisition.ensure_cached(request)

      # Second call should hit cache (stub would fail if called again since
      # it's consumed by first call, but cache path exists)
      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
    end
  end

  # ============================================================================
  # HTTP Error Mapping
  # ============================================================================

  describe "S3 HTTP error mapping" do
    test "HEAD 403 returns source_unauthorized", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 403, "Forbidden")
      end)

      request = build_s3_request(ctx, artifact_source_uri: "s3://#{@bucket}/#{@object_key}")

      assert {:error, {:source_unauthorized, _msg}} = ModelAcquisition.ensure_cached(request)
    end

    test "HEAD 404 returns source_not_found", ctx do
      Req.Test.stub(ctx.stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      request = build_s3_request(ctx, artifact_source_uri: "s3://#{@bucket}/#{@object_key}")

      assert {:error, {:source_not_found, _msg}} = ModelAcquisition.ensure_cached(request)
    end

    test "GET 403 returns source_unauthorized", ctx do
      tar_gz = ctx.tar_gz_bytes

      Req.Test.stub(ctx.stub_name, fn conn ->
        case conn.method do
          "HEAD" ->
            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(tar_gz)))
            |> Plug.Conn.send_resp(200, "")

          "GET" ->
            Plug.Conn.send_resp(conn, 403, "Forbidden")
        end
      end)

      request = build_s3_request(ctx, artifact_source_uri: "s3://#{@bucket}/#{@object_key}")

      assert {:error, {:source_unauthorized, _msg}} = ModelAcquisition.ensure_cached(request)
    end

    test "short download returns download_incomplete", ctx do
      tar_gz = ctx.tar_gz_bytes
      # Report full size but return partial data
      partial = binary_part(tar_gz, 0, div(byte_size(tar_gz), 2))

      Req.Test.stub(ctx.stub_name, fn conn ->
        case conn.method do
          "HEAD" ->
            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(tar_gz)))
            |> Plug.Conn.send_resp(200, "")

          "GET" ->
            conn
            |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(partial)))
            |> Plug.Conn.send_resp(200, partial)
        end
      end)

      request = build_s3_request(ctx, artifact_source_uri: "s3://#{@bucket}/#{@object_key}")

      assert {:error, {:download_incomplete, _msg}} = ModelAcquisition.ensure_cached(request)
    end
  end

  # ============================================================================
  # Hash Verification
  # ============================================================================

  describe "integrity verification" do
    test "wrong artifact_sha256 returns hash mismatch", ctx do
      stub_s3_success(ctx.stub_name, ctx.tar_gz_bytes)

      request =
        build_s3_request(ctx,
          artifact_source_uri: "s3://#{@bucket}/#{@object_key}",
          artifact_sha256: "0000000000000000000000000000000000000000000000000000000000000000"
        )

      assert {:error, :artifact_hash_mismatch} = ModelAcquisition.ensure_cached(request)

      # Final path should not exist
      refute File.dir?(request.final_path)
    end
  end

  # ============================================================================
  # Unsupported Extension
  # ============================================================================

  describe "unsupported archive extension" do
    test "rejects .zip URI", ctx do
      request =
        build_s3_request(ctx,
          artifact_source_uri: "s3://#{@bucket}/model.zip"
        )

      assert {:error, {:unsupported_archive_extension, _msg}} =
               ModelAcquisition.ensure_cached(request)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_s3_request(ctx, overrides) do
    model_id = Keyword.get(overrides, :model_id, "test-org/model")
    version = Keyword.get(overrides, :version, "v1")
    uri = Keyword.get(overrides, :artifact_source_uri, "s3://#{@bucket}/#{@object_key}")
    sha = Keyword.get(overrides, :artifact_sha256, ctx.hash)

    proto = %EnsureModelLoadedRequest{
      model_id: model_id,
      version: version,
      artifact_sha256: sha,
      artifact_source_uri: uri,
      deadline_unix_ms: System.os_time(:millisecond) + 120_000
    }

    {:ok, request} = Request.from_proto(proto, ctx.models_root)
    request
  end

  defp stub_s3_success(stub_name, archive_bytes) do
    Req.Test.stub(stub_name, fn conn ->
      case conn.method do
        "HEAD" ->
          conn
          |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(archive_bytes)))
          |> Plug.Conn.put_resp_header("etag", "\"test-etag-123\"")
          |> Plug.Conn.send_resp(200, "")

        "GET" ->
          conn
          |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(archive_bytes)))
          |> Plug.Conn.put_resp_header("etag", "\"test-etag-123\"")
          |> Plug.Conn.send_resp(200, archive_bytes)
      end
    end)
  end

  defp create_tar_gz(source_dir) do
    files = list_bundle_files(source_dir)
    tar_path = Path.join(System.tmp_dir!(), "s3_test_#{:rand.uniform(1_000_000)}.tar.gz")

    file_list =
      Enum.map(files, fn rel_path ->
        {String.to_charlist(rel_path), String.to_charlist(Path.join(source_dir, rel_path))}
      end)

    :ok = :erl_tar.create(String.to_charlist(tar_path), file_list, [:compressed])
    bytes = File.read!(tar_path)
    File.rm!(tar_path)
    bytes
  end

  defp create_tar(source_dir) do
    files = list_bundle_files(source_dir)
    tar_path = Path.join(System.tmp_dir!(), "s3_test_#{:rand.uniform(1_000_000)}.tar")

    file_list =
      Enum.map(files, fn rel_path ->
        {String.to_charlist(rel_path), String.to_charlist(Path.join(source_dir, rel_path))}
      end)

    :ok = :erl_tar.create(String.to_charlist(tar_path), file_list, [])
    bytes = File.read!(tar_path)
    File.rm!(tar_path)
    bytes
  end

  defp create_tar_gz_wrapped(source_dir, wrapper_name) do
    files = list_bundle_files(source_dir)
    tar_path = Path.join(System.tmp_dir!(), "s3_test_wrapped_#{:rand.uniform(1_000_000)}.tar.gz")

    file_list =
      Enum.map(files, fn rel_path ->
        name_in_archive = "#{wrapper_name}/#{rel_path}"
        {String.to_charlist(name_in_archive), String.to_charlist(Path.join(source_dir, rel_path))}
      end)

    :ok = :erl_tar.create(String.to_charlist(tar_path), file_list, [:compressed])
    bytes = File.read!(tar_path)
    File.rm!(tar_path)
    bytes
  end

  defp list_bundle_files(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(fn entry -> File.regular?(Path.join(dir, entry)) end)
    |> Enum.sort()
  end

  defp create_malicious_tar(type) do
    tmp = System.tmp_dir!() |> Path.join("malicious_tar_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    staging = Path.join(tmp, "staging")
    File.mkdir_p!(staging)

    content_file = Path.join(tmp, "content.txt")
    File.write!(content_file, "malicious content")

    archive_path = Path.join(tmp, "malicious.tar")

    malicious_name =
      case type do
        :traversal -> "../../../etc/evil.txt"
        :absolute -> "/etc/evil.txt"
        :symlink -> :symlink
      end

    if type == :symlink do
      symlink_dir = Path.join(tmp, "symlink_source")
      File.mkdir_p!(symlink_dir)
      File.write!(Path.join(symlink_dir, "legit.txt"), "legit")
      symlink_path = Path.join(symlink_dir, "evil_link")
      File.ln_s!("../../etc/passwd", symlink_path)

      file_list = [
        {~c"legit.txt", String.to_charlist(Path.join(symlink_dir, "legit.txt"))},
        {~c"evil_link", String.to_charlist(symlink_path)}
      ]

      :ok = :erl_tar.create(String.to_charlist(archive_path), file_list, [])
    else
      file_list = [
        {String.to_charlist(malicious_name), String.to_charlist(content_file)}
      ]

      :ok = :erl_tar.create(String.to_charlist(archive_path), file_list, [])
    end

    {archive_path, staging}
  end

  defp override_s3_config(stub_name) do
    current_runtime = Application.get_env(:orchard_node_agent, :runtime, [])

    s3_config = [
      endpoint: "http://localhost:9000",
      region: "us-east-1",
      access_key_id: "test-access-key",
      secret_access_key: "test-secret-key",
      session_token: nil,
      force_path_style?: true,
      connect_timeout_ms: 5_000,
      receive_timeout_ms: 5_000,
      req_options: [plug: {Req.Test, stub_name}]
    ]

    updated_runtime = Keyword.put(current_runtime, :s3, s3_config)
    Application.put_env(:orchard_node_agent, :runtime, updated_runtime)
  end

  defp collect_progress_events do
    receive do
      {:progress, measurements, metadata} ->
        [{measurements, metadata} | collect_progress_events()]
    after
      100 -> []
    end
    |> Enum.reverse()
  end
end
