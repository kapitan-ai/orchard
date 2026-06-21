defmodule Orchard.API.TrustedForwardedHeaders do
  @moduledoc false

  @behaviour Plug

  import Bitwise
  import Plug.Conn

  @forwarded_headers [
    "x-forwarded-for",
    "x-forwarded-host",
    "x-forwarded-port",
    "x-forwarded-proto"
  ]

  @type cidr :: {:inet.ip_address(), non_neg_integer()}

  @impl true
  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, opts) do
    proxies = Keyword.get_lazy(opts, :proxies, &configured_proxies/0)

    if reverse_proxy?(opts) and trusted_ip?(conn.remote_ip, proxies) do
      trust_forwarded_headers(conn, proxies)
    else
      reject_forwarded_headers(conn)
    end
  end

  @spec trusted_ip?(:inet.ip_address() | nil, [cidr()]) :: boolean()
  def trusted_ip?(nil, _proxies), do: false

  def trusted_ip?(remote_ip, proxies) do
    Enum.any?(proxies, &ip_in_cidr?(remote_ip, &1))
  end

  defp reverse_proxy?(opts) do
    Keyword.get_lazy(opts, :transport_mode, fn ->
      Application.get_env(:orchard_controller, :transport_mode)
    end) == :reverse_proxy
  end

  defp configured_proxies do
    :orchard_controller
    |> Application.get_env(Orchard.API.Endpoint, [])
    |> Keyword.get(:trusted_proxies, [])
  end

  defp trust_forwarded_headers(conn, proxies) do
    with true <- forwarded_rewrite_headers_valid?(conn),
         {:ok, remote_ip} <- forwarded_for_client_ip(conn, proxies) do
      conn
      |> Map.put(:remote_ip, remote_ip)
      |> put_private(:orchard_forwarded_headers_trusted?, true)
    else
      _error -> reject_forwarded_headers(conn)
    end
  end

  defp reject_forwarded_headers(conn) do
    %{
      conn
      | req_headers:
          Enum.reject(conn.req_headers, fn {header, _value} ->
            header in @forwarded_headers
          end)
    }
  end

  defp forwarded_rewrite_headers_valid?(conn) do
    with {:ok, proto} <- single_forwarded_header(conn, "x-forwarded-proto"),
         true <- proto in ["http", "https"],
         {:ok, host} <- single_forwarded_header(conn, "x-forwarded-host"),
         true <- host != "" and not String.contains?(host, ","),
         {:ok, port} <- single_forwarded_header(conn, "x-forwarded-port"),
         true <- valid_port?(port) do
      true
    else
      _error -> false
    end
  end

  defp single_forwarded_header(conn, header) do
    case get_req_header(conn, header) do
      [value] ->
        trimmed = String.trim(value)

        if value == trimmed and not String.contains?(value, ","),
          do: {:ok, value},
          else: :error

      _other ->
        :error
    end
  end

  defp valid_port?(port) do
    case Integer.parse(port) do
      {integer, ""} when integer in 1..65_535 -> true
      _other -> false
    end
  end

  defp forwarded_for_client_ip(conn, proxies) do
    with [header] <- get_req_header(conn, "x-forwarded-for"),
         {:ok, chain} <- parse_forwarded_for(header) do
      chain
      |> Enum.reverse()
      |> Enum.find(&(not trusted_ip?(&1, proxies)))
      |> case do
        nil -> :error
        remote_ip -> {:ok, remote_ip}
      end
    else
      _other -> :error
    end
  end

  defp parse_forwarded_for(header) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case parse_ip(value) do
        {:ok, remote_ip} -> {:cont, {:ok, [remote_ip | acc]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ips} -> {:ok, Enum.reverse(ips)}
      :error -> :error
    end
  end

  defp parse_ip(value) do
    value
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp ip_in_cidr?(ip, {network, prefix}) when tuple_size(ip) == tuple_size(network) do
    bits = if tuple_size(ip) == 4, do: 32, else: 128
    mask = ((1 <<< prefix) - 1) <<< (bits - prefix)
    (ip_to_integer(ip) &&& mask) == (ip_to_integer(network) &&& mask)
  end

  defp ip_in_cidr?(_ip, _cidr), do: false

  defp ip_to_integer({a, b, c, d}) do
    (a <<< 24) + (b <<< 16) + (c <<< 8) + d
  end

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end)
  end
end
