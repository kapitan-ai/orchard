defmodule OrchardConsole.LicenseGateTest do
  use ExUnit.Case, async: false

  import Orchard.TestSupport.LicenseGateHelpers

  alias Orchard.Licensing

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous, licensing_impl: __MODULE__.LicensingMissingStub)
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)

    :ok
  end

  test "ok mode runs the guarded thunk" do
    put_gate_impl(__MODULE__.AllowGate)
    socket = socket()
    test_pid = self()

    assert {:noreply, ^socket} =
             OrchardConsole.LicenseGate.guard(socket, fn ->
               send(test_pid, :called)
               {:noreply, socket}
             end)

    assert_receive :called
  end

  test "denial returns noreply with activation flash and does not run the thunk" do
    put_gate_impl(__MODULE__.DenyGate)
    test_pid = self()

    assert {:noreply, socket} =
             OrchardConsole.LicenseGate.guard(socket(), fn ->
               send(test_pid, :called)
               {:noreply, socket()}
             end)

    refute_receive :called, 50
    assert socket.assigns.flash["error"] =~ license_required_message()
    assert socket.assigns.flash["error"] =~ activation_guidance()
    assert socket.assigns.license_status.activation_guidance == activation_guidance()
  end

  test "shared gate allows off and warn modes without running local validation" do
    for mode <- [:off, :warn] do
      set_license_enforcement(mode)
      socket = socket()
      test_pid = self()

      assert {:noreply, ^socket} =
               OrchardConsole.LicenseGate.guard(socket, fn ->
                 send(test_pid, {:called, mode})
                 {:noreply, socket}
               end)

      assert_receive {:called, ^mode}
    end
  end

  defmodule AllowGate do
    @moduledoc false

    def check(_opts), do: :ok
  end

  defmodule DenyGate do
    @moduledoc false

    def check(_opts) do
      {:error,
       %Licensing{
         state: :missing_bundle,
         message: "No local license bundle is installed.",
         bundle_path: "/tmp/current.json"
       }}
    end
  end

  defmodule LicensingMissingStub do
    @moduledoc false

    def inspect_local do
      %Licensing{
        state: :missing_bundle,
        message: "No local license bundle is installed.",
        bundle_path: "/tmp/current.json"
      }
    end
  end

  defp put_gate_impl(gate_impl) do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.put(previous, :gate_impl, gate_impl)
    )
  end

  defp socket do
    socket = %Phoenix.LiveView.Socket{}
    %{socket | assigns: Map.put(socket.assigns, :flash, %{})}
  end
end
