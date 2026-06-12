defmodule OrchardConsole.OrchardMarkSvgTest do
  use ExUnit.Case, async: true

  @svg_path Application.app_dir(:orchard_controller, "priv/static/images/orchard-mark.svg")

  describe "standalone orchard-mark.svg" do
    setup do
      svg = File.read!(@svg_path)
      {:ok, svg: svg}
    end

    test "uses direct per-circle forest fills", %{svg: svg} do
      assert length(Regex.scan(~r/fill="#1B5E20"/, svg)) == 8
    end

    test "uses direct gold fill on focal dot", %{svg: svg} do
      assert length(Regex.scan(~r/fill="#FDD835"/, svg)) == 1
    end

    test "preserves canonical Grove Focal geometry", %{svg: svg} do
      assert svg =~ ~r/cx="32"[^>]*cy="12"[^>]*r="6"/
    end

    test "preserves orchard-dot class for theme/animation overrides", %{svg: svg} do
      assert svg =~ "orchard-dot"
      assert svg =~ "orchard-dot--gold"
    end

    test "retains internal media-query block for standalone favicon dark mode", %{svg: svg} do
      assert svg =~ "@media (prefers-color-scheme: dark)"
    end
  end
end
