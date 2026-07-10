defmodule Orchard.NodeTrust.PKITest do
  use ExUnit.Case, async: true

  alias Orchard.NodeTrust.PKI

  # Controller certificate lifetime (SPEC task 2.x deterministic issuance): 90 days.
  @controller_lifetime_seconds 7_776_000

  defp generate!(now) do
    assert {:ok, material} =
             PKI.generate(
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               now
             )

    material
  end

  test "valid_material? accepts material whose certificate window contains the reference time" do
    now = DateTime.utc_now()
    material = generate!(now)

    assert PKI.valid_material?(material, now)
  end

  test "valid_material? rejects material after the controller certificate has expired" do
    now = DateTime.utc_now()
    material = generate!(now)

    expired_at = DateTime.add(now, @controller_lifetime_seconds + 1, :second)

    refute PKI.valid_material?(material, expired_at)
  end

  test "valid_material? rejects material before the certificate is valid" do
    now = DateTime.utc_now()
    material = generate!(now)

    before_valid = DateTime.add(now, -120, :second)

    refute PKI.valid_material?(material, before_valid)
  end
end
