defmodule Orchard.TestSupport.LicenseGateHelpers do
  @moduledoc false

  import ExUnit.Assertions

  alias Orchard.Licensing.Gate

  @license_required_message "Orchard requires an activated license before product use."
  @activation_guidance "Run `orchardctl license activate <key>` or inspect `orchardctl license status`."
  @activation_guidance_html "Run `orchardctl license activate &lt;key&gt;` or inspect `orchardctl license status`."

  def set_license_enforcement(mode) when mode in [:off, :warn, :hard] do
    previous = Application.get_env(:orchard_shared, :licensing, [])

    Application.put_env(
      :orchard_shared,
      :licensing,
      Keyword.put(previous, :enforcement_mode, mode)
    )

    Gate.refresh()

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:orchard_shared, :licensing, previous)
      Gate.refresh()
    end)

    :ok
  end

  def assert_license_denial(html) do
    assert html =~ @license_required_message
    assert html =~ @activation_guidance or html =~ @activation_guidance_html
  end

  def activation_guidance, do: @activation_guidance
  def license_required_message, do: @license_required_message
end
