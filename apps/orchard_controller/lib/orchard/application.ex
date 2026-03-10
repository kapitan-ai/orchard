defmodule Orchard.Application do
  @moduledoc false

  use Application

  alias Orchard.API.Endpoint

  @impl true
  def start(_type, _args) do
    children =
      []
      |> maybe_add_repo()
      |> maybe_add_inference_stack()
      |> maybe_add_endpoint_stack()

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

  defp maybe_add_endpoint_stack(children) do
    if Application.get_env(:orchard_controller, :start_endpoint, true) do
      children ++ [{Phoenix.PubSub, name: Orchard.PubSub}, Endpoint]
    else
      children
    end
  end
end
