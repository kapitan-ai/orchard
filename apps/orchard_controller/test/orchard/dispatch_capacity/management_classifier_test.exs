defmodule Orchard.DispatchCapacity.ManagementClassifierTest do
  use ExUnit.Case, async: true

  alias Orchard.DispatchCapacity.ManagementClassifier
  alias Orchard.DispatchCapacity.ManagementClassifier.Input

  describe "classify/1" do
    test "admitted inventory forces production management for every target shape" do
      targets = [
        %{transport: :beam, address: :orchard_node_agent@localhost},
        %{transport: :grpc_compat, address: [host: "127.0.0.1", port: 50_071]},
        {:static_reference, "node-a"}
      ]

      declarations = [
        [:unmanaged_source_development],
        [:unmanaged_compatibility],
        [:unmanaged_source_development, :unmanaged_compatibility],
        :malformed
      ]

      for target <- targets, declared_classes <- declarations do
        input =
          input(%{
            target_reference: target,
            inventory_resolution: :admitted,
            declared_classes: declared_classes,
            controller_mode: :invalid,
            compatibility_enabled?: :invalid
          })

        assert {:ok, :production_managed} = ManagementClassifier.classify(input)
      end
    end

    test "accepts source-development only from explicit mode-valid configuration" do
      assert {:ok, :unmanaged_source_development} =
               ManagementClassifier.classify(
                 input(%{
                   controller_mode: :source_development,
                   declared_classes: [:unmanaged_source_development]
                 })
               )

      assert {:error, :runtime_endpoint_management_class_invalid} =
               ManagementClassifier.classify(
                 input(%{declared_classes: [:unmanaged_source_development]})
               )
    end

    test "accepts compatibility only when explicitly enabled" do
      for mode <- [:production, :source_development] do
        assert {:ok, :unmanaged_compatibility} =
                 ManagementClassifier.classify(
                   input(%{
                     controller_mode: mode,
                     declared_classes: [:unmanaged_compatibility],
                     compatibility_enabled?: true
                   })
                 )
      end

      assert {:error, :runtime_endpoint_management_class_invalid} =
               ManagementClassifier.classify(
                 input(%{declared_classes: [:unmanaged_compatibility]})
               )
    end

    test "returns typed missing and invalid results" do
      assert {:error, :runtime_endpoint_management_class_missing} =
               ManagementClassifier.classify(input(%{declared_classes: []}))

      invalid_overrides = [
        %{inventory_resolution: :unresolved},
        %{inventory_resolution: :unknown},
        %{declared_classes: :malformed},
        %{declared_classes: [:production_managed]},
        %{declared_classes: [:unmanaged_compatibility, :unmanaged_source_development]},
        %{declared_classes: [:unmanaged_compatibility, :unmanaged_compatibility]},
        %{controller_mode: :unknown, declared_classes: [:unmanaged_source_development]},
        %{compatibility_enabled?: :unknown, declared_classes: [:unmanaged_source_development]}
      ]

      for overrides <- invalid_overrides do
        assert {:error, :runtime_endpoint_management_class_invalid} =
                 overrides
                 |> input()
                 |> ManagementClassifier.classify()
      end
    end

    test "target transport, address, metadata, and probe facts cannot affect classification" do
      references = [
        %{transport: :beam, probe: :failed, telemetry: %{management: :production}},
        %{transport: :grpc_compat, address: "production.example", adapter_fallback: true},
        %{metadata: %{capacity_management_class: :production_managed}}
      ]

      results =
        Enum.map(references, fn reference ->
          reference
          |> then(&input(%{target_reference: &1, declared_classes: []}))
          |> ManagementClassifier.classify()
        end)

      assert Enum.uniq(results) == [{:error, :runtime_endpoint_management_class_missing}]
    end
  end

  defp input(overrides) do
    defaults = %{
      target_reference: :opaque,
      inventory_resolution: :not_admitted,
      controller_mode: :production,
      declared_classes: [],
      compatibility_enabled?: false
    }

    struct!(Input, Map.merge(defaults, overrides))
  end
end
