defmodule OrchardConsole.LayoutsTest do
  use Orchard.ConnCase, async: true

  alias OrchardConsole.Layouts

  describe "page_content_class/1" do
    test "defaults to the standard wrapper tokens" do
      assert Layouts.page_content_class(nil) ==
               "mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-6"
    end

    test "returns the standard wrapper tokens" do
      assert Layouts.page_content_class(:standard) ==
               "mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-6"
    end

    test "returns the wide wrapper tokens" do
      assert Layouts.page_content_class(:wide) ==
               "mx-auto max-w-[96rem] px-4 sm:px-6 lg:px-8 py-6"
    end

    test "returns the workspace wrapper tokens" do
      assert Layouts.page_content_class(:workspace) ==
               "max-w-none px-6 sm:px-8 lg:px-10 py-6"
    end

    test "treats reserved detail mode as standard until detail rollout" do
      assert Layouts.page_content_class(:detail) == Layouts.page_content_class(:standard)
    end
  end

  describe "page_title_class/1" do
    test "defaults to the standard title tokens" do
      assert Layouts.page_title_class(nil) ==
               "text-lg font-semibold text-slate-900 dark:text-slate-100"
    end

    test "returns the standard title tokens" do
      assert Layouts.page_title_class(:standard) ==
               "text-lg font-semibold text-slate-900 dark:text-slate-100"
    end

    test "returns the wide title tokens" do
      assert Layouts.page_title_class(:wide) ==
               "text-xl font-semibold text-slate-900 dark:text-slate-100"
    end

    test "returns the workspace title tokens" do
      assert Layouts.page_title_class(:workspace) ==
               "text-xl font-semibold text-slate-900 dark:text-slate-100"
    end

    test "treats reserved detail mode as standard until detail rollout" do
      assert Layouts.page_title_class(:detail) == Layouts.page_title_class(:standard)
    end
  end
end
