defmodule Orchard.SentryRelease do
  @moduledoc """
  Builds static Orchard identity for optional Sentry crash events.

  `runtime_options/1` is also the single place that pins this integration's non-expansion SDK
  settings: source context, both tracing paths, Sentry Logs, dependency inventory, and client
  reports are set explicitly so a future SDK default change cannot silently broaden the payload.
  """

  @release_components %{
    "orchard_controller" => {"orchard_controller", "controller"},
    "orchard_node_agent" => {"orchard_node_agent", "node_agent"},
    "orchard_cli" => {"orchard_cli", "cli"},
    "mix" => {"orchard_dev", "development"}
  }

  @type identity :: %{
          release: String.t(),
          tags: %{
            orchard_app: String.t(),
            orchard_version: String.t(),
            orchard_build_channel: String.t(),
            build_sha: String.t(),
            build_date: String.t()
          }
        }

  @spec identity(String.t() | nil) :: identity()
  def identity(release_name) do
    identity(release_name, OrchardShared.version(),
      build_sha: Orchard.BuildInfo.git_sha(),
      build_date: Orchard.BuildInfo.build_date(),
      build_channel: Orchard.BuildInfo.build_channel()
    )
  end

  @spec runtime_options(String.t() | nil) :: keyword()
  def runtime_options(release_name) do
    identity = identity(release_name)

    [
      release: identity.release,
      before_send: {Orchard.SentryFilter, :filter},
      server_name: "[redacted]",
      tags: identity.tags,
      in_app_otp_apps: [:orchard_controller, :orchard_node_agent, :orchard_shared, :orchard_cli],
      enable_source_code_context: false,
      traces_sample_rate: nil,
      traces_sampler: nil,
      enable_logs: false,
      report_deps: false,
      send_client_reports: false,
      dedup_events: true
    ]
  end

  @spec identity(String.t() | nil, String.t(), keyword()) :: identity()
  def identity(release_name, product_version, build_opts) do
    {safe_release_name, component} =
      Map.get(@release_components, release_name, {"orchard_unknown", "unknown"})

    version = safe_token(product_version)
    build_sha = build_opts |> Keyword.fetch!(:build_sha) |> safe_build_sha()
    build_date = build_opts |> Keyword.fetch!(:build_date) |> safe_build_date()
    build_channel = build_opts |> Keyword.fetch!(:build_channel) |> safe_token()
    release_sha = String.slice(build_sha, 0, 7)

    %{
      release: "#{safe_release_name}@#{version}+#{release_sha}",
      tags: %{
        orchard_app: component,
        orchard_version: version,
        orchard_build_channel: build_channel,
        build_sha: build_sha,
        build_date: build_date
      }
    }
  end

  defp safe_build_sha(value) when is_binary(value) do
    value = String.downcase(value)
    if Regex.match?(~r/\A[0-9a-f]{7,40}\z/, value), do: value, else: "unknown"
  end

  defp safe_build_sha(_value), do: "unknown"

  defp safe_build_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> value
      {:error, _reason} -> "unknown"
    end
  end

  defp safe_build_date(_value), do: "unknown"

  defp safe_token(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9A-Za-z][0-9A-Za-z._-]{0,63}\z/, value), do: value, else: "unknown"
  end

  defp safe_token(_value), do: "unknown"
end
