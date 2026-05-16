defmodule Orchard.API.Transport do
  @moduledoc false

  @type mode :: :direct_https | :reverse_proxy | :plain_http_localhost | :unknown
  @type cert_source :: :operator_provided | :generated_local_ca | :unknown
  @type metadata :: %{
          mode: String.t(),
          degraded: boolean(),
          cert_source: String.t()
        }

  @https_modes [:direct_https, :reverse_proxy]

  @spec mode() :: mode()
  def mode do
    :orchard_controller
    |> Application.get_env(:transport_mode, :plain_http_localhost)
    |> normalize_mode()
  end

  @spec cert_source() :: cert_source()
  def cert_source, do: mode() |> cert_source_for_mode()

  @spec degraded?() :: boolean()
  def degraded?, do: mode() |> degraded?()

  @spec public_api_https_enabled?() :: boolean()
  def public_api_https_enabled?, do: mode() |> public_api_https_enabled?()

  @spec metadata() :: metadata()
  def metadata do
    mode = mode()

    %{
      mode: Atom.to_string(mode),
      degraded: degraded?(mode),
      cert_source: mode |> cert_source_for_mode() |> Atom.to_string()
    }
  end

  defp normalize_mode(mode) when mode in [:direct_https, :reverse_proxy, :plain_http_localhost],
    do: mode

  defp normalize_mode(mode)
       when mode in ["direct_https", "reverse_proxy", "plain_http_localhost"] do
    String.to_existing_atom(mode)
  end

  defp normalize_mode(_), do: :unknown

  defp degraded?(mode), do: not public_api_https_enabled?(mode)

  defp public_api_https_enabled?(mode), do: mode in @https_modes

  defp cert_source_for_mode(:direct_https) do
    :orchard_controller
    |> Application.get_env(:transport_cert_source, :unknown)
    |> normalize_cert_source()
  end

  defp cert_source_for_mode(_mode), do: :unknown

  defp normalize_cert_source(source)
       when source in [:operator_provided, :generated_local_ca, :unknown],
       do: source

  defp normalize_cert_source(source)
       when source in ["operator_provided", "generated_local_ca", "unknown"] do
    String.to_existing_atom(source)
  end

  defp normalize_cert_source(_), do: :unknown
end
