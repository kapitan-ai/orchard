defmodule Orchard.TestSupport.GnuTimeoutGuardian do
  @moduledoc """
  Requires the GNU coreutils `timeout` guardian for real host-inventory probe
  tests.

  These tests run on every host, so a missing or unverified guardian fails them
  with an actionable message instead of skipping them. Discovery checks only
  fixed absolute paths, never `PATH`, and installs nothing.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Orchard.Node.HostInventory.Command

  # Linux coreutils, then Homebrew coreutils on Apple silicon and Intel Macs:
  # the optional unprefixed alias, the g-prefixed name, and the gnubin path.
  @candidates [
    "/usr/bin/timeout",
    "/opt/homebrew/bin/timeout",
    "/usr/local/bin/timeout",
    "/opt/homebrew/bin/gtimeout",
    "/usr/local/bin/gtimeout",
    "/opt/homebrew/opt/coreutils/libexec/gnubin/timeout",
    "/usr/local/opt/coreutils/libexec/gnubin/timeout"
  ]

  @requirement """
  GNU coreutils `timeout` is required for host-inventory probe tests.
  Linux: install coreutils so /usr/bin/timeout is GNU timeout.
  macOS: brew install coreutils.
  Checked, in order: #{Enum.join(@candidates, ", ")}.
  """

  @doc """
  Returns the first fixed candidate under `root` that is verified GNU `timeout`,
  or `nil`. `root` exists so tests can lay out a synthetic filesystem.
  """
  @spec discover(Path.t()) :: String.t() | nil
  def discover(root \\ "/") do
    # Command.guardian/1 checks only the first resolvable path in a list, so
    # each candidate is verified on its own.
    Enum.find_value(@candidates, fn candidate ->
      case Command.guardian([Path.join(root, candidate)]) do
        {:ok, guardian} -> guardian
        {:error, :guardian_unavailable} -> nil
      end
    end)
  end

  @doc "Returns the verified guardian path, or fails the calling test with install guidance."
  @spec verified!(String.t() | nil) :: String.t()
  def verified!(candidate) do
    case Command.guardian(List.wrap(candidate)) do
      {:ok, guardian} -> guardian
      {:error, :guardian_unavailable} -> flunk(@requirement <> "Found: #{inspect(candidate)}")
    end
  end
end
