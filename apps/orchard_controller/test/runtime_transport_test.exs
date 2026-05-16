defmodule Orchard.RuntimeTransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_config Path.expand("../../../config/runtime.exs", __DIR__)

  setup do
    env_snapshot =
      System.get_env()
      |> Enum.filter(fn {key, _value} -> config_env_key?(key) end)
      |> Map.new()

    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "orchard-runtime-transport-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      clear_config_env!()
      Enum.each(env_snapshot, fn {key, value} -> System.put_env(key, value) end)
      File.rm_rf(tmp_root)
    end)

    {:ok, support_root: tmp_root}
  end

  test "SPEC 10.7: ORCHARD_TRANSPORT_MODE=plain_http_localhost wins over legacy TLS envs", %{
    support_root: support_root
  } do
    output =
      capture_io(:stderr, fn ->
        config =
          read_controller_config!(support_root, %{
            "ORCHARD_TRANSPORT_MODE" => "plain_http_localhost",
            "ORCHARD_TLS_DISABLED" => "false",
            "ORCHARD_TLS_CERTFILE" => "/missing/conflicting.crt",
            "ORCHARD_TLS_KEYFILE" => "/missing/conflicting.key"
          })

        endpoint = Keyword.fetch!(config, Orchard.API.Endpoint)

        assert config[:transport_mode] == :plain_http_localhost
        assert config[:transport_cert_source] == :unknown
        assert config[:transport_degraded] == true
        assert endpoint[:http] == [ip: {127, 0, 0, 1}, port: 4000]
        assert endpoint[:https] == nil
      end)

    assert output =~ "ORCHARD_TRANSPORT_MODE=plain_http_localhost"
    assert output =~ "new transport mode wins"
  end

  test "SPEC 10.7: reverse_proxy uses an HTTP backend with unknown cert source", %{
    support_root: support_root
  } do
    install_generated_local_ca!(support_root)

    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "reverse_proxy",
        "PORT" => "4010"
      })

    endpoint = Keyword.fetch!(config, Orchard.API.Endpoint)

    assert config[:transport_mode] == :reverse_proxy
    assert config[:transport_cert_source] == :unknown
    assert config[:transport_degraded] == false
    assert endpoint[:http] == [ip: {127, 0, 0, 1}, port: 4010]
    assert endpoint[:https] == nil
  end

  test "SPEC 10.7: direct_https cert/key overrides set transport_cert_source operator_provided",
       %{
         support_root: support_root
       } do
    tls_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "operator.crt")
    keyfile = Path.join(tls_dir, "operator.key")
    generate_self_signed_cert!(certfile, keyfile)

    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https",
        "ORCHARD_TLS_CERTFILE" => certfile,
        "ORCHARD_TLS_KEYFILE" => keyfile
      })

    endpoint = Keyword.fetch!(config, Orchard.API.Endpoint)

    assert config[:transport_mode] == :direct_https
    assert config[:transport_cert_source] == :operator_provided
    assert config[:transport_degraded] == false
    assert endpoint[:https][:certfile] == certfile
    assert endpoint[:https][:keyfile] == keyfile
  end

  test "SPEC 10.7: direct_https explicit default paths with generated-local metadata sets operator_provided",
       %{
         support_root: support_root
       } do
    install_generated_local_ca!(support_root)

    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")

    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https",
        "ORCHARD_TLS_CERTFILE" => certfile,
        "ORCHARD_TLS_KEYFILE" => keyfile
      })

    assert config[:transport_mode] == :direct_https
    assert config[:transport_cert_source] == :operator_provided
  end

  test "SPEC 10.7: direct_https generated-local metadata sets transport_cert_source generated_local_ca",
       %{
         support_root: support_root
       } do
    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")
    cacertfile = Path.join(tls_dir, "ca.crt")
    meta_path = Path.join(tls_dir, ".orchard-tls-meta.json")

    generate_self_signed_cert!(certfile, keyfile)
    File.cp!(certfile, cacertfile)
    File.write!(meta_path, Jason.encode!(%{"source" => "generated_local_ca"}))

    config =
      read_controller_config!(support_root, %{
        "ORCHARD_TRANSPORT_MODE" => "direct_https"
      })

    assert config[:transport_mode] == :direct_https
    assert config[:transport_cert_source] == :generated_local_ca
  end

  test "SPEC 10.7: legacy ORCHARD_TLS_DISABLED=true maps to plain_http_localhost", %{
    support_root: support_root
  } do
    install_generated_local_ca!(support_root)

    output =
      capture_io(:stderr, fn ->
        config = read_controller_config!(support_root, %{"ORCHARD_TLS_DISABLED" => "true"})

        assert config[:transport_mode] == :plain_http_localhost
        assert config[:transport_cert_source] == :unknown
        assert config[:transport_degraded] == true
      end)

    assert output =~ "ORCHARD_TLS_DISABLED is deprecated"
  end

  test "SPEC 10.7: legacy ORCHARD_TLS_DISABLED=false maps to direct_https", %{
    support_root: support_root
  } do
    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")
    generate_self_signed_cert!(certfile, keyfile)

    output =
      capture_io(:stderr, fn ->
        config = read_controller_config!(support_root, %{"ORCHARD_TLS_DISABLED" => "false"})

        assert config[:transport_mode] == :direct_https
        assert config[:transport_cert_source] == :unknown
        assert config[:transport_degraded] == false
      end)

    assert output =~ "ORCHARD_TLS_DISABLED=false is deprecated"
  end

  test "SPEC 10.7: legacy cert/key overrides map to direct_https operator_provided", %{
    support_root: support_root
  } do
    tls_dir = Path.join(support_root, "external-tls")
    certfile = Path.join(tls_dir, "legacy.crt")
    keyfile = Path.join(tls_dir, "legacy.key")
    generate_self_signed_cert!(certfile, keyfile)

    output =
      capture_io(:stderr, fn ->
        config =
          read_controller_config!(support_root, %{
            "ORCHARD_TLS_CERTFILE" => certfile,
            "ORCHARD_TLS_KEYFILE" => keyfile
          })

        assert config[:transport_mode] == :direct_https
        assert config[:transport_cert_source] == :operator_provided
        assert config[:transport_degraded] == false
      end)

    assert output =~ "ORCHARD_TLS_CERTFILE/ORCHARD_TLS_KEYFILE are deprecated transport shims"
  end

  test "SPEC 10.7: invalid transport mode fails closed", %{support_root: support_root} do
    assert_raise RuntimeError, ~r/ORCHARD_TRANSPORT_MODE must be/, fn ->
      read_controller_config!(support_root, %{"ORCHARD_TRANSPORT_MODE" => "https"})
    end
  end

  defp read_controller_config!(support_root, overrides) do
    base = %{
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/orchard_config_eval",
      "MIX_RELEASE_NAME" => nil,
      "ORCHARD_SUPPORT_ROOT" => support_root,
      "RELEASE_NAME" => "orchard_controller",
      "SECRET_KEY_BASE" => String.duplicate("runtime-secret", 8)
    }

    clear_config_env!()

    base
    |> Map.merge(overrides)
    |> Enum.each(fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    @runtime_config
    |> Config.Reader.read!(env: :prod)
    |> Keyword.fetch!(:orchard_controller)
  end

  defp install_generated_local_ca!(support_root) do
    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")
    cacertfile = Path.join(tls_dir, "ca.crt")
    meta_path = Path.join(tls_dir, ".orchard-tls-meta.json")

    generate_self_signed_cert!(certfile, keyfile)
    File.cp!(certfile, cacertfile)
    File.write!(meta_path, Jason.encode!(%{"source" => "generated_local_ca"}))
  end

  defp generate_self_signed_cert!(certfile, keyfile) do
    openssl =
      System.find_executable("openssl") || flunk("openssl is required for TLS config tests")

    File.mkdir_p!(Path.dirname(certfile))
    File.mkdir_p!(Path.dirname(keyfile))

    {output, status} =
      System.cmd(
        openssl,
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          keyfile,
          "-out",
          certfile,
          "-days",
          "365",
          "-subj",
          "/CN=localhost"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp clear_config_env! do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&config_env_key?/1)
    |> Enum.each(&System.delete_env/1)
  end

  defp config_env_key?(key) do
    key in ["DATABASE_URL", "MIX_RELEASE_NAME", "PORT", "RELEASE_NAME", "SECRET_KEY_BASE"] or
      String.starts_with?(key, "ORCHARD_")
  end
end
