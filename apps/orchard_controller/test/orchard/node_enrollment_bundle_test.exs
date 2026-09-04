defmodule Orchard.NodeEnrollmentBundleTest do
  use ExUnit.Case, async: true

  alias Orchard.NodeEnrollmentBundle

  test "rejects invalid shared issuance attributes before trust or persistence work" do
    cases = [
      {%{}, :surface, :invalid_format},
      {%{expiry_seconds: 0}, :expiry_seconds, :out_of_range},
      {%{expiry_seconds: 86_401}, :expiry_seconds, :out_of_range},
      {%{pool_id: "general pool"}, :pool_id, :invalid_format},
      {%{pool_id: String.duplicate("a", 65)}, :pool_id, :too_long},
      {%{surface: String.duplicate("a", 65)}, :surface, :too_long},
      {%{display_name: "render\nnode"}, :display_name, :invalid_format},
      {%{display_name: String.duplicate("é", 65)}, :display_name, :too_long}
    ]

    for {attrs, field, reason} <- cases do
      assert {:error, {:invalid_enrollment_bundle_attrs, errors}} =
               NodeEnrollmentBundle.issue(attrs)

      assert {field, reason} in errors
    end
  end

  test "normalizes valid shared issuance attributes" do
    assert {:ok, attrs} =
             NodeEnrollmentBundle.validate_attrs(%{
               "display_name" => "  render-node-03  ",
               "expiry_seconds" => 3_600,
               "pool_id" => "general",
               "surface" => "console"
             })

    assert attrs.display_name == "render-node-03"
    assert attrs.expiry_seconds == 3_600
    assert attrs.pool_id == "general"
    assert attrs.surface == "console"
  end

  test "keeps the CLI auto-generated display name contract" do
    assert {:ok, attrs} =
             NodeEnrollmentBundle.validate_attrs(%{
               display_name: nil,
               surface: "local_orchardctl"
             })

    assert attrs.display_name == nil
    assert attrs.pool_id == "general"
    assert attrs.surface == "local_orchardctl"
    assert attrs.expiry_seconds == 3_600
  end
end
