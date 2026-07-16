defmodule Orchard.DispatchCapacity.ManagementClassifier do
  @moduledoc """
  Classifies Runtime Endpoint capacity management from Controller-owned facts.

  Inventory resolution takes precedence over configured exceptions. Target
  identity is deliberately opaque so transport and Node-reported data cannot
  become capacity authority.
  """

  defmodule Input do
    @moduledoc "Controller-owned inputs to capacity management classification."

    @enforce_keys [
      :target_reference,
      :inventory_resolution,
      :controller_mode,
      :declared_classes,
      :compatibility_enabled?
    ]
    defstruct @enforce_keys

    @type inventory_resolution :: :admitted | :not_admitted | :unresolved
    @type controller_mode :: :production | :source_development

    @type t :: %__MODULE__{
            target_reference: term(),
            inventory_resolution: inventory_resolution() | term(),
            controller_mode: controller_mode() | term(),
            declared_classes: [term()] | term(),
            compatibility_enabled?: boolean() | term()
          }
  end

  @type management_class ::
          :production_managed
          | :unmanaged_source_development
          | :unmanaged_compatibility

  @type error_reason ::
          :runtime_endpoint_management_class_missing
          | :runtime_endpoint_management_class_invalid

  @type result :: {:ok, management_class()} | {:error, error_reason()}

  @doc """
  Resolves the capacity management class without inspecting the target.
  """
  @spec classify(Input.t()) :: result()
  def classify(%Input{inventory_resolution: :admitted}), do: {:ok, :production_managed}

  def classify(%Input{inventory_resolution: :not_admitted} = input) do
    classify_declaration(input)
  end

  def classify(%Input{}), do: {:error, :runtime_endpoint_management_class_invalid}

  defp classify_declaration(%Input{declared_classes: []}) do
    {:error, :runtime_endpoint_management_class_missing}
  end

  defp classify_declaration(%Input{
         controller_mode: :source_development,
         declared_classes: [:unmanaged_source_development],
         compatibility_enabled?: compatibility_enabled?
       })
       when is_boolean(compatibility_enabled?) do
    {:ok, :unmanaged_source_development}
  end

  defp classify_declaration(%Input{
         controller_mode: mode,
         declared_classes: [:unmanaged_compatibility],
         compatibility_enabled?: true
       })
       when mode in [:production, :source_development] do
    {:ok, :unmanaged_compatibility}
  end

  defp classify_declaration(%Input{}),
    do: {:error, :runtime_endpoint_management_class_invalid}
end
