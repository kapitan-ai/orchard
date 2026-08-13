defmodule Orchard.Portal.Layouts do
  @moduledoc """
  Isolated portal layouts. These must not render Console chrome.
  """

  use Orchard.Portal, :html

  embed_templates("layouts/*")
end
