defmodule OrchardConsole.Layouts do
  @moduledoc """
  Layout components for the Orchard Console.
  """

  use OrchardConsole, :html

  @standard_page_content_class "mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-6"
  @standard_page_title_class "text-lg font-semibold text-slate-900 dark:text-slate-100"
  @wide_page_title_class "text-xl font-semibold text-slate-900 dark:text-slate-100"

  @doc """
  Returns the page content wrapper class for a Console page mode.

  `nil` and `:standard` preserve the pre-PR2 wrapper byte-for-byte. `:detail`
  is reserved for a future rollout and deliberately falls back to `:standard`
  until that rollout updates this helper and `docs/DESIGN.md` together.
  """
  @spec page_content_class(nil | :standard | :wide | :workspace | :detail) :: String.t()
  def page_content_class(mode \\ nil)
  def page_content_class(nil), do: @standard_page_content_class
  def page_content_class(:standard), do: @standard_page_content_class
  def page_content_class(:wide), do: "mx-auto max-w-[96rem] px-4 sm:px-6 lg:px-8 py-6"
  def page_content_class(:workspace), do: "max-w-none px-6 sm:px-8 lg:px-10 py-6"
  def page_content_class(:detail), do: @standard_page_content_class

  @doc """
  Returns the page title class for a Console page mode.

  `nil` and `:standard` preserve the pre-PR2 title byte-for-byte. `:detail`
  is reserved for a future rollout and deliberately falls back to `:standard`
  until that rollout updates this helper and `docs/DESIGN.md` together.
  """
  @spec page_title_class(nil | :standard | :wide | :workspace | :detail) :: String.t()
  def page_title_class(mode \\ nil)
  def page_title_class(nil), do: @standard_page_title_class
  def page_title_class(:standard), do: @standard_page_title_class
  def page_title_class(:wide), do: @wide_page_title_class
  def page_title_class(:workspace), do: @wide_page_title_class
  def page_title_class(:detail), do: @standard_page_title_class

  embed_templates("layouts/*")
end
