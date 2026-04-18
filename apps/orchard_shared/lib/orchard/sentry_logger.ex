defmodule Orchard.SentryLogger do
  @moduledoc """
  Shared installer for the VM-global Sentry logger handler.
  """

  @handler Sentry.LoggerHandler
  @handler_config %{
    config: %{
      capture_log_messages: false,
      metadata: [:request_id, :worker_model],
      rate_limiting: [max_events: 50, interval: 60_000]
    }
  }

  @spec install_handler() :: :ok | {:error, term()}
  def install_handler do
    if dsn_configured?() do
      case :global.trans({__MODULE__, @handler}, fn -> ensure_handler_installed() end) do
        {:aborted, reason} -> {:error, reason}
        result -> result
      end
    else
      :ok
    end
  end

  defp dsn_configured? do
    case Application.get_env(:sentry, :dsn) do
      nil -> false
      dsn -> String.trim(dsn) != ""
    end
  end

  defp ensure_handler_installed do
    case :logger.get_handler_config(@handler) do
      {:ok, _config} ->
        :ok

      {:error, :not_found} ->
        add_handler()

      {:error, {:not_found, _handler}} ->
        add_handler()
    end
  end

  defp add_handler do
    case :logger.add_handler(@handler, Sentry.LoggerHandler, @handler_config) do
      :ok ->
        :ok

      {:error, {:already_exist, _handler}} ->
        :ok

      {:error, {:already_exists, _handler}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
