defmodule Orchard.TestSupport.GnuTimeoutGuardian do
  @moduledoc """
  Requires the GNU coreutils `timeout` guardian for real host-inventory probe
  tests.

  These tests run on every host, so a missing or unverified guardian fails them
  with an actionable message instead of skipping them.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Orchard.Node.HostInventory.Command

  @requirement """
  GNU coreutils `timeout` is required for host-inventory probe tests.
  Linux: install coreutils so /usr/bin/timeout is GNU timeout.
  macOS: brew install coreutils (provides /opt/homebrew/bin/timeout or /usr/local/bin/timeout).
  """

  @doc "Returns the verified guardian path, or fails the calling test with install guidance."
  @spec verified!(String.t() | nil) :: String.t()
  def verified!(candidate) do
    case Command.guardian(List.wrap(candidate)) do
      {:ok, guardian} -> guardian
      {:error, :guardian_unavailable} -> flunk(@requirement <> "Found: #{inspect(candidate)}")
    end
  end
end
