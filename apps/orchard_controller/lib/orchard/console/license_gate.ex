defmodule OrchardConsole.LicenseGate do
  @moduledoc """
  Event-level license guard for Console actions that start product work.

  Console pages, diagnostics, and recovery surfaces remain mountable in hard
  enforcement mode; action handlers call this guard before mutating product
  state or starting inference/model work.
  """

  alias Orchard.Licensing
  alias Orchard.Licensing.Gate
  alias Phoenix.Component
  alias Phoenix.LiveView

  @type guarded_reply :: {:noreply, Phoenix.LiveView.Socket.t()}

  @spec guard(Phoenix.LiveView.Socket.t(), (-> guarded_reply())) :: guarded_reply()
  def guard(socket, fun) when is_function(fun, 0) do
    case gate_impl().check([]) do
      :ok -> fun.()
      {:error, %Licensing{} = status} -> {:noreply, deny(socket, status)}
    end
  end

  defp deny(socket, %Licensing{} = status) do
    denial = Gate.denial(status)

    socket
    |> LiveView.put_flash(:error, denial.message <> " " <> denial.activation_guidance)
    |> Component.assign(:license_status, OrchardConsole.LicenseStatus.fetch())
  end

  defp gate_impl do
    Application.get_env(:orchard_controller, :console, [])
    |> Keyword.get(:gate_impl, Gate)
  end
end
