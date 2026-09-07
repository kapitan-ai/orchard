defmodule OrchardConsole.WorkspacePresentation do
  @moduledoc "Workspace display names over the existing Tenant identity."

  @default_id "00000000-0000-0000-0000-000000000000"

  @spec default?(map()) :: boolean()
  def default?(%{id: @default_id}), do: true
  def default?(_tenant), do: false

  @spec display_name(map()) :: String.t()
  def display_name(%{id: @default_id, name: "Legacy Single Tenant"}), do: "Default workspace"
  def display_name(%{name: name}) when is_binary(name), do: name
end
