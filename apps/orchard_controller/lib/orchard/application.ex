defmodule Orchard.Application do
  @moduledoc false

  use Application

  require Logger

  alias Orchard.API.Endpoint
  alias Orchard.Licensing
  alias Orchard.SentryContext

  @impl true
  def start(_type, _args) do
    case Orchard.SentryLogger.install_handler() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Sentry handler install failed, continuing without: #{inspect(reason)}")
    end

    attach_startup_license_context()

    children =
      []
      |> maybe_add_repo()
      |> maybe_add_inference_stack()
      |> add_pubsub_and_coordinator()
      |> maybe_add_endpoint()

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Orchard.Supervisor
    )
  end

  @impl true
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end

  defp attach_startup_license_context do
    status = inspect_startup_license()

    Logger.info(
      "Controller startup license status",
      license_metadata(status, app: :orchard_controller)
    )

    SentryContext.cache_license_status(status)
    SentryContext.apply_license_status(status, :controller)
  end

  defp inspect_startup_license do
    licensing_impl().inspect_local()
  rescue
    _exception -> missing_license_status()
  catch
    _kind, _reason -> missing_license_status()
  end

  defp licensing_impl do
    Application.get_env(:orchard_shared, :licensing, [])[:licensing_impl] || Licensing
  end

  defp missing_license_status do
    %Licensing{
      state: :missing_bundle,
      message: "license inspection failed during controller startup",
      bundle_path: ""
    }
  end

  defp license_metadata(status, extra) do
    status
    |> SentryContext.build_license_extra()
    |> Map.drop([:orchard_licensee])
    |> Map.to_list()
    |> Keyword.merge(extra)
  end

  defp maybe_add_repo(children) do
    if Application.get_env(:orchard_controller, :start_repo, true) do
      children ++ [Orchard.Repo]
    else
      children
    end
  end

  defp maybe_add_inference_stack(children) do
    children ++ [{GRPC.Client.Supervisor, []}, Orchard.Inference]
  end

  defp add_pubsub_and_coordinator(children) do
    children ++
      [
        {Phoenix.PubSub, name: Orchard.PubSub},
        OrchardConsole.ModelHubDownloadCoordinator
      ]
  end

  defp maybe_add_endpoint(children) do
    if Application.get_env(:orchard_controller, :start_endpoint, true) do
      children ++ [Endpoint]
    else
      children
    end
  end
end
