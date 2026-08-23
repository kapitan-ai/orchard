defmodule Orchard.Config.ControllerTransport do
  @moduledoc false

  @loopback_proxies [{{127, 0, 0, 1}, 32}, {{0, 0, 0, 0, 0, 0, 0, 1}, 128}]

  @type cidr :: {:inet.ip_address(), non_neg_integer()}
  @type reverse_proxy_config :: %{
          listener: keyword(),
          url: keyword(),
          check_origin: [String.t()],
          trusted_proxies: [cidr()]
        }

  @spec source_dev_mode!(String.t() | nil) :: :plain_http_localhost | :reverse_proxy
  def source_dev_mode!(nil), do: :plain_http_localhost
  def source_dev_mode!("plain_http_localhost"), do: :plain_http_localhost
  def source_dev_mode!("reverse_proxy"), do: :reverse_proxy

  def source_dev_mode!("direct_https") do
    raise "ORCHARD_TRANSPORT_MODE=direct_https is release-only; source dev supports plain_http_localhost|reverse_proxy"
  end

  def source_dev_mode!(value) do
    raise "ORCHARD_TRANSPORT_MODE must be plain_http_localhost|reverse_proxy in source dev, got: #{inspect(value)}"
  end

  @spec reverse_proxy!(keyword()) :: reverse_proxy_config()
  def reverse_proxy!(opts) do
    bind_ip = ip!("ORCHARD_API_BIND_IP", opts[:bind_ip], "127.0.0.1")
    trusted_proxy_value = opts[:trusted_proxies]
    trusted_proxies = trusted_proxy_cidrs!(trusted_proxy_value)

    if not loopback_ip?(bind_ip) and not explicitly_set?(trusted_proxy_value) do
      raise "ORCHARD_TRUSTED_PROXIES must be set when reverse_proxy binds to a non-loopback address"
    end

    backend_port = Keyword.fetch!(opts, :backend_port)
    public_host = Keyword.fetch!(opts, :public_host)
    public_port = Keyword.fetch!(opts, :public_port)

    %{
      listener: [http: [ip: bind_ip, port: backend_port]],
      url: [host: public_host, port: public_port, scheme: "https"],
      check_origin: [public_origin(public_host, public_port)],
      trusted_proxies: trusted_proxies
    }
  end

  @spec ip!(String.t(), String.t() | nil, String.t()) :: :inet.ip_address()
  def ip!(env_name, value, default) do
    ip_string = value || default

    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} ->
        ip_tuple

      {:error, _reason} ->
        raise "environment variable #{env_name} must be a valid IP address, got: #{inspect(ip_string)}"
    end
  end

  defp trusted_proxy_cidrs!(nil), do: @loopback_proxies

  defp trusted_proxy_cidrs!(value) do
    cidrs =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if cidrs == [] do
      raise "ORCHARD_TRUSTED_PROXIES must contain at least one CIDR when set"
    end

    Enum.map(cidrs, &parse_trusted_proxy_cidr!/1)
  end

  defp parse_trusted_proxy_cidr!(cidr) do
    with [ip_string, prefix_string] <- String.split(cidr, "/", parts: 2),
         {:ok, ip_tuple} <- :inet.parse_address(String.to_charlist(ip_string)),
         {prefix, ""} <- Integer.parse(prefix_string),
         max_prefix = if(tuple_size(ip_tuple) == 4, do: 32, else: 128),
         true <- prefix in 0..max_prefix do
      {ip_tuple, prefix}
    else
      _other ->
        raise "ORCHARD_TRUSTED_PROXIES contains invalid CIDR #{inspect(cidr)}"
    end
  end

  defp public_origin(public_host, 443), do: "https://#{public_host}"
  defp public_origin(public_host, public_port), do: "https://#{public_host}:#{public_port}"

  defp explicitly_set?(nil), do: false
  defp explicitly_set?(value), do: String.trim(value) != ""

  defp loopback_ip?({127, _b, _c, _d}), do: true
  defp loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_ip?(_ip), do: false
end
