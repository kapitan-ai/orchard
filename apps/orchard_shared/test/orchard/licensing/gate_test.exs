defmodule Orchard.Licensing.GateTest do
  use ExUnit.Case, async: false

  alias Orchard.Licensing
  alias Orchard.Licensing.Gate
  alias Orchard.Licensing.LocalStore

  @fixture_dir Path.expand("../../fixtures/licensing", __DIR__)
  @public_key_hex "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
  @local_node_id "11111111-2222-4333-8444-555555555555"
  @other_node_id "11111111-2222-4333-8444-555555555556"
  @now ~U[2026-04-15 00:00:00Z]

  setup do
    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "orchard-license-gate-test",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    bundle_path = Path.join([tmp_dir, "config", "licensing", "current.json"])
    node_identity_path = Path.join([tmp_dir, "data", "node-id"])
    previous_licensing = Application.get_env(:orchard_shared, :licensing, [])

    Application.put_env(
      :orchard_shared,
      :licensing,
      Keyword.merge(previous_licensing,
        bundle_path: bundle_path,
        node_identity_path: node_identity_path,
        keygen_public_key: @public_key_hex,
        enforcement_mode: :hard,
        gate_cache_ttl_seconds: 1
      )
    )

    Gate.refresh()
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      Gate.refresh()
      Application.put_env(:orchard_shared, :licensing, previous_licensing)
      File.rm_rf!(tmp_dir)
    end)

    %{bundle_path: bundle_path, node_identity_path: node_identity_path}
  end

  describe "check/1" do
    test "allows a valid local license bundle in hard mode", ctx do
      copy_fixture!("valid_bound_to_local", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert Gate.check(now: @now, cache_now_ms: 1_000) == :ok
    end

    test "allows without local inspection when enforcement is off" do
      put_enforcement_mode(:off)

      assert Gate.check(now: @now, cache_now_ms: 1_000) == :ok
    end

    test "denies a missing bundle with activation guidance", ctx do
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert {:error, status} = Gate.check(now: @now, cache_now_ms: 1_000)
      assert status.state == :missing_bundle
      assert_denial(status, :missing, "license_required", "requires an activated license")
    end

    test "denies an expired bundle with renewal guidance", ctx do
      copy_fixture!("expired", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert {:error, status} = Gate.check(now: @now, cache_now_ms: 1_000)
      assert status.state == :expired
      assert_denial(status, :expired, "license_expired", "license has expired")
    end

    test "denies a not-yet-valid bundle", ctx do
      copy_fixture!("valid_bound_to_local", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert {:error, status} = Gate.check(now: ~U[2025-01-01 00:00:00Z], cache_now_ms: 1_000)
      assert status.state == :not_yet_valid
      assert_denial(status, :not_yet_valid, "license_not_yet_valid", "not valid yet")
    end

    test "denies an invalid license signature", ctx do
      bundle = load_fixture_bundle!("valid_bound_to_local")

      write_bundle!(ctx.bundle_path, %{
        bundle
        | license_certificate: tamper_signature(bundle.license_certificate)
      })

      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert {:error, status} = Gate.check(now: @now, cache_now_ms: 1_000)
      assert status.state == :invalid_license_signature

      assert_denial(
        status,
        :invalid_signature,
        "license_invalid_signature",
        "failed signature validation"
      )
    end

    test "denies an invalid machine signature", ctx do
      bundle = load_fixture_bundle!("valid_bound_to_local")

      write_bundle!(ctx.bundle_path, %{
        bundle
        | machine_certificate: tamper_signature(bundle.machine_certificate)
      })

      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert {:error, status} = Gate.check(now: @now, cache_now_ms: 1_000)
      assert status.state == :invalid_machine_signature

      assert_denial(
        status,
        :invalid_signature,
        "license_invalid_signature",
        "failed signature validation"
      )
    end

    test "denies a malformed bundle", ctx do
      copy_fixture!("malformed", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert {:error, status} = Gate.check(now: @now, cache_now_ms: 1_000)
      assert status.state == :malformed_bundle
      assert_denial(status, :malformed, "license_malformed", "unreadable or malformed")
    end

    test "denies a machine-bound bundle for another node", ctx do
      copy_fixture!("valid_bound_to_other_node", ctx.bundle_path)
      write_node_identity!(ctx.node_identity_path, @local_node_id)

      assert {:error, status} = Gate.check(now: @now, cache_now_ms: 1_000)
      assert status.state == :fingerprint_mismatch

      assert_denial(
        status,
        :machine_mismatch,
        "license_machine_mismatch",
        "bound to a different machine"
      )
    end
  end

  test "successful activation refreshes cached denial before TTL expiry", ctx do
    copy_fixture!("expired", ctx.bundle_path)
    write_node_identity!(ctx.node_identity_path, @local_node_id)

    assert {:error, %Licensing{state: :expired}} = Gate.check(now: @now, cache_now_ms: 1_000)

    assert {:ok, %Licensing{state: :valid}} =
             Licensing.install_pair(load_fixture_bundle!("valid_bound_to_local"), now: @now)

    assert Gate.check(now: @now, cache_now_ms: 1_000) == :ok
  end

  test "external bundle replacement forces local re-evaluation before TTL expiry", ctx do
    copy_fixture!("expired", ctx.bundle_path)
    write_node_identity!(ctx.node_identity_path, @local_node_id)

    assert {:error, %Licensing{state: :expired}} = Gate.check(now: @now, cache_now_ms: 1_000)

    replace_bundle_externally!(ctx.bundle_path, "valid_bound_to_local")

    assert Gate.check(now: @now, cache_now_ms: 1_500) == :ok
  end

  test "external bundle replacement invalidates cached valid status before TTL expiry", ctx do
    copy_fixture!("valid_bound_to_local", ctx.bundle_path)
    write_node_identity!(ctx.node_identity_path, @local_node_id)

    assert Gate.check(now: @now, cache_now_ms: 1_000) == :ok

    replace_bundle_externally!(ctx.bundle_path, "expired")

    assert {:error, %Licensing{state: :expired}} = Gate.check(now: @now, cache_now_ms: 1_500)
  end

  test "external node identity replacement invalidates cached valid status before TTL expiry",
       ctx do
    copy_fixture!("valid_bound_to_local", ctx.bundle_path)
    write_node_identity!(ctx.node_identity_path, @local_node_id)

    assert Gate.check(now: @now, cache_now_ms: 1_000) == :ok

    replace_node_identity_externally!(ctx.node_identity_path, @other_node_id)

    assert {:error, %Licensing{state: :fingerprint_mismatch}} =
             Gate.check(now: @now, cache_now_ms: 1_500)
  end

  test "external node identity removal invalidates cached valid status before TTL expiry", ctx do
    copy_fixture!("valid_bound_to_local", ctx.bundle_path)
    write_node_identity!(ctx.node_identity_path, @local_node_id)

    assert Gate.check(now: @now, cache_now_ms: 1_000) == :ok

    File.rm!(ctx.node_identity_path)

    assert {:error, %Licensing{state: :identity_missing}} =
             Gate.check(now: @now, cache_now_ms: 1_500)
  end

  test "cached valid license is re-evaluated after expires_at before cache TTL expiry", ctx do
    copy_fixture!("valid_bound_to_local", ctx.bundle_path)
    write_node_identity!(ctx.node_identity_path, @local_node_id)

    assert %Licensing{state: :valid, expires_at: %DateTime{} = expires_at} =
             Licensing.inspect_local(now: @now)

    assert Gate.check(now: @now, cache_now_ms: 1_000) == :ok

    assert {:error, %Licensing{state: :expired}} =
             Gate.check(now: DateTime.add(expires_at, 1, :second), cache_now_ms: 1_500)
  end

  defp assert_denial(status, reason, code, message_fragment) do
    payload = Gate.denial(status)

    assert payload.reason == reason
    assert payload.code == code
    assert payload.message =~ message_fragment
    assert payload.activation_guidance =~ "orchardctl license"
    assert status.message == payload.message <> " " <> payload.activation_guidance
  end

  defp put_enforcement_mode(mode) do
    licensing =
      :orchard_shared
      |> Application.get_env(:licensing, [])
      |> Keyword.put(:enforcement_mode, mode)

    Application.put_env(:orchard_shared, :licensing, licensing)
  end

  defp load_fixture_bundle!(name) do
    fixture_path(name)
    |> File.read!()
    |> Jason.decode!()
    |> then(fn %{
                 "license_certificate" => license_certificate,
                 "machine_certificate" => machine_certificate
               } ->
      %{license_certificate: license_certificate, machine_certificate: machine_certificate}
    end)
  end

  defp copy_fixture!(name, bundle_path) do
    File.mkdir_p!(Path.dirname(bundle_path))
    File.cp!(fixture_path(name), bundle_path)
  end

  defp fixture_path(name), do: Path.join(@fixture_dir, "#{name}.json")

  defp replace_bundle_externally!(bundle_path, fixture_name) do
    bundle = load_fixture_bundle!(fixture_name)
    assert :ok = LocalStore.write(bundle_path, bundle)
  end

  defp write_node_identity!(node_identity_path, node_id) do
    File.mkdir_p!(Path.dirname(node_identity_path))
    File.write!(node_identity_path, node_id <> "\n")
  end

  defp replace_node_identity_externally!(node_identity_path, node_id) do
    File.mkdir_p!(Path.dirname(node_identity_path))
    tmp_path = node_identity_path <> ".tmp"
    File.write!(tmp_path, node_id <> "\n")
    File.rename!(tmp_path, node_identity_path)
  end

  defp write_bundle!(bundle_path, %{license_certificate: license, machine_certificate: machine}) do
    File.mkdir_p!(Path.dirname(bundle_path))

    File.write!(
      bundle_path,
      Jason.encode!(%{"license_certificate" => license, "machine_certificate" => machine},
        pretty: true
      ) <>
        "\n"
    )
  end

  defp tamper_signature(certificate) do
    bad_signature = Base.encode64(:binary.copy(<<0>>, 64))
    mutate_certificate_envelope(certificate, &Map.put(&1, "sig", bad_signature))
  end

  defp mutate_certificate_envelope(certificate, mutator) do
    {header, footer, envelope} = decode_certificate_envelope(certificate)
    encode_certificate(header, footer, mutator.(envelope))
  end

  defp decode_certificate_envelope(certificate) do
    normalized =
      certificate
      |> String.replace("\r\n", "\n")
      |> String.trim()

    [header | rest] = String.split(normalized, "\n")
    footer = List.last(rest)
    body = rest |> Enum.drop(-1) |> Enum.join("")
    envelope = body |> Base.decode64!() |> Jason.decode!()
    {header, footer, envelope}
  end

  defp encode_certificate(header, footer, envelope) do
    body =
      envelope
      |> Jason.encode!()
      |> Base.encode64()
      |> wrap_base64()

    Enum.join([header, body, footer, ""], "\n")
  end

  defp wrap_base64(encoded) do
    encoded
    |> String.graphemes()
    |> Enum.chunk_every(64)
    |> Enum.map_join("\n", &Enum.join/1)
  end
end
