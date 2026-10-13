defmodule Orchard.RuntimeEndpoint.RevokedCookieTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.RevokedCookie

  test "KAP-82 obsolete peer authority uses one unpredictable process-local atom" do
    cookie = RevokedCookie.value()

    assert is_atom(cookie)
    assert Atom.to_string(cookie) =~ ~r/^orchard_revoked_[A-Za-z0-9_-]{43}$/
    assert RevokedCookie.value() == cookie
  end
end
