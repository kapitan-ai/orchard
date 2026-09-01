defmodule Orchard.SentryHandlerTestSupport do
  @moduledoc false

  @spec restore_handler(term()) :: :ok
  def restore_handler({:ok, %{id: id, module: module} = handler_config}) do
    config = restorable_handler_config(handler_config)

    case :logger.add_handler(id, module, config) do
      :ok -> :ok
      {:error, {:already_exist, ^id}} -> :ok
      {:error, {:already_exists, ^id}} -> :ok
    end
  end

  def restore_handler(_not_found), do: :ok

  defp restorable_handler_config(%{config: runtime_config} = handler_config) do
    input_config =
      runtime_config
      |> Map.from_struct()
      |> Map.drop([:backends])

    handler_config
    |> Map.drop([:id, :module])
    |> Map.put(:config, input_config)
  end
end
