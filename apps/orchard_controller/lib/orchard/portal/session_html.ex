defmodule Orchard.Portal.SessionHTML do
  @moduledoc false

  use Orchard.Portal, :html

  embed_templates("session_html/*")
end
