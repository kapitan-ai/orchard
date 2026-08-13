defmodule Orchard.Governance.PortalPasswordTest do
  use ExUnit.Case, async: true

  alias Orchard.Governance.PortalPassword

  @password "sixteen-chars-ok"

  test "hash encodes a slow password digest and never returns the plaintext" do
    assert {:ok, encoded} = PortalPassword.hash(@password)
    refute encoded == @password
    assert is_binary(encoded)
    assert byte_size(encoded) > 0
  end

  test "verify accepts the original password and rejects a wrong one" do
    assert {:ok, encoded} = PortalPassword.hash(@password)
    assert PortalPassword.verify(@password, encoded) == :ok
    assert PortalPassword.verify("sixteen-chars-no", encoded) == {:error, :invalid_password}
  end

  test "dummy_verify never succeeds" do
    assert PortalPassword.dummy_verify(@password) == {:error, :invalid_password}
    assert PortalPassword.dummy_verify("another-sixteen1") == {:error, :invalid_password}
  end

  test "hash rejects passwords shorter than 16 Unicode code points" do
    assert {:error, :password_too_short} = PortalPassword.hash("short-password")
  end
end
