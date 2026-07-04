defmodule OrchardConsole.LicenseStatusTest do
  use ExUnit.Case, async: false

  alias OrchardConsole.LicenseStatus

  describe "fetch/0" do
    test "returns a safe hard-mode summary instead of raising when licensing config is malformed" do
      previous = Application.get_env(:orchard_shared, :licensing, [])
      on_exit(fn -> Application.put_env(:orchard_shared, :licensing, previous) end)

      Application.put_env(:orchard_shared, :licensing, %{enforcement_mode: :off})

      summary = LicenseStatus.fetch()

      assert is_map(summary)
      refute LicenseStatus.valid?(summary)
      assert LicenseStatus.visible?(summary)
    end
  end
end
