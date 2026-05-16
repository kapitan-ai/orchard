defmodule Orchard.API.ForwardedHeadersTest do
  use Orchard.ConnCase, async: false

  @moduletag :live

  alias Orchard.API.Endpoint

  setup do
    original_mode = Application.get_env(:orchard_controller, :transport_mode)
    original_endpoint = Application.get_env(:orchard_controller, Endpoint, [])

    Application.put_env(
      :orchard_controller,
      Endpoint,
      Keyword.put(original_endpoint, :trusted_proxies, [
        {{127, 0, 0, 1}, 32},
        {{0, 0, 0, 0, 0, 0, 0, 1}, 128}
      ])
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :transport_mode, original_mode)
      Application.put_env(:orchard_controller, Endpoint, original_endpoint)
    end)
  end

  test "SPEC 10.7: reverse_proxy trusts forwarded headers from loopback proxy" do
    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)

    conn =
      {127, 0, 0, 1}
      |> forwarded_conn()
      |> Endpoint.call([])

    assert conn.status == 200
    assert conn.scheme == :https
    assert conn.host == "orchard.example.test"
    assert conn.port == 443
    assert conn.remote_ip == {203, 0, 113, 10}
  end

  test "SPEC 10.7: reverse_proxy ignores spoofed forwarded headers from untrusted peer" do
    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)

    conn =
      {198, 51, 100, 24}
      |> forwarded_conn()
      |> Endpoint.call([])

    assert conn.status == 200
    assert conn.scheme == :http
    refute conn.host == "orchard.example.test"
    refute conn.port == 443
    assert conn.remote_ip == {198, 51, 100, 24}
  end

  test "SPEC 10.7: reverse_proxy ignores spoofed leftmost X-Forwarded-For entries" do
    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)

    conn =
      {127, 0, 0, 1}
      |> forwarded_conn("198.51.100.200, 203.0.113.10")
      |> Endpoint.call([])

    assert conn.status == 200
    assert conn.remote_ip == {203, 0, 113, 10}
  end

  test "SPEC 10.7: reverse_proxy rejects malformed rewrite headers even with valid X-Forwarded-For" do
    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)

    cases = [
      {:proto, "ftp"},
      {:proto, "https, http"},
      {:host, "orchard.example.test, attacker.example.test"},
      {:host, ""},
      {:port, "not-a-port"},
      {:port, "0"},
      {:port, "65536"}
    ]

    for {header, value} <- cases do
      conn =
        {127, 0, 0, 1}
        |> forwarded_conn()
        |> put_forwarded_header(header, value)
        |> Endpoint.call([])

      assert conn.status == 200
      assert conn.scheme == :http
      refute conn.host == "orchard.example.test"
      refute conn.port == 443
      assert conn.remote_ip == {127, 0, 0, 1}
    end
  end

  test "SPEC 10.7: reverse_proxy rejects whitespace-padded rewrite headers atomically" do
    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)

    cases = [
      {:proto, " https "},
      {:host, " orchard.example.test "},
      {:port, " 443 "}
    ]

    for {header, value} <- cases do
      conn =
        {127, 0, 0, 1}
        |> forwarded_conn()
        |> put_forwarded_header(header, value)
        |> Endpoint.call([])

      assert conn.status == 200
      assert conn.scheme == :http
      refute conn.host == "orchard.example.test"
      refute conn.port == 443
      assert conn.remote_ip == {127, 0, 0, 1}
    end
  end

  test "SPEC 10.7: reverse_proxy rejects duplicate rewrite headers even with valid X-Forwarded-For" do
    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)

    for header <- [:proto, :host, :port] do
      conn =
        {127, 0, 0, 1}
        |> forwarded_conn()
        |> duplicate_forwarded_header(header, "attacker.example.test")
        |> Endpoint.call([])

      assert conn.status == 200
      assert conn.scheme == :http
      refute conn.host == "orchard.example.test"
      refute conn.port == 443
      assert conn.remote_ip == {127, 0, 0, 1}
    end
  end

  test "SPEC 10.7: reverse_proxy ignores duplicate X-Forwarded-For ambiguity" do
    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)

    conn =
      Phoenix.ConnTest.build_conn(:get, "/health/live")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.200")
      |> Map.update!(:req_headers, &[{"x-forwarded-for", "203.0.113.10"} | &1])
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> Plug.Conn.put_req_header("x-forwarded-host", "orchard.example.test")
      |> Plug.Conn.put_req_header("x-forwarded-port", "443")
      |> Endpoint.call([])

    assert conn.status == 200
    assert conn.scheme == :http
    refute conn.host == "orchard.example.test"
    refute conn.port == 443
    assert conn.remote_ip == {127, 0, 0, 1}
  end

  test "SPEC 10.7: reverse_proxy ignores malformed X-Forwarded-For ambiguity" do
    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)

    conn =
      {127, 0, 0, 1}
      |> forwarded_conn("malformed, 203.0.113.10")
      |> Endpoint.call([])

    assert conn.status == 200
    assert conn.scheme == :http
    refute conn.host == "orchard.example.test"
    refute conn.port == 443
    assert conn.remote_ip == {127, 0, 0, 1}
  end

  test "SPEC 10.7: non-reverse-proxy modes ignore forwarded headers from loopback" do
    Application.put_env(:orchard_controller, :transport_mode, :direct_https)

    conn =
      {127, 0, 0, 1}
      |> forwarded_conn()
      |> Endpoint.call([])

    assert conn.status == 200
    assert conn.scheme == :http
    refute conn.host == "orchard.example.test"
    refute conn.port == 443
    assert conn.remote_ip == {127, 0, 0, 1}
  end

  defp put_forwarded_header(conn, :proto, value),
    do: Plug.Conn.put_req_header(conn, "x-forwarded-proto", value)

  defp put_forwarded_header(conn, :host, value),
    do: Plug.Conn.put_req_header(conn, "x-forwarded-host", value)

  defp put_forwarded_header(conn, :port, value),
    do: Plug.Conn.put_req_header(conn, "x-forwarded-port", value)

  defp duplicate_forwarded_header(conn, :proto, value),
    do: duplicate_header(conn, "x-forwarded-proto", value)

  defp duplicate_forwarded_header(conn, :host, value),
    do: duplicate_header(conn, "x-forwarded-host", value)

  defp duplicate_forwarded_header(conn, :port, value),
    do: duplicate_header(conn, "x-forwarded-port", value)

  defp duplicate_header(conn, header, value) do
    Map.update!(conn, :req_headers, &[{header, value} | &1])
  end

  defp forwarded_conn(peer_ip, forwarded_for \\ "203.0.113.10") do
    Phoenix.ConnTest.build_conn(:get, "/health/live")
    |> Map.put(:remote_ip, peer_ip)
    |> Plug.Conn.put_req_header("x-forwarded-for", forwarded_for)
    |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
    |> Plug.Conn.put_req_header("x-forwarded-host", "orchard.example.test")
    |> Plug.Conn.put_req_header("x-forwarded-port", "443")
  end
end
