defmodule OrchardConsole.Layouts do
  @moduledoc """
  Layout components for the Orchard Console.
  """

  use OrchardConsole, :html

  embed_templates("layouts/*")
end
