defmodule Orchard.AssetsTest do
  use ExUnit.Case, async: true

  test "Tailwind scans Portal Elixir and HEEx sources" do
    css_path = Path.expand("../../assets/css/app.css", __DIR__)
    css = File.read!(css_path)

    assert css =~ ~s(@source "../../lib/orchard/portal/**/*.ex";)
    assert css =~ ~s(@source "../../lib/orchard/portal/**/*.heex";)
  end
end
