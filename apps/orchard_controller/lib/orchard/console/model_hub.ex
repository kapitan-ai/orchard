defmodule OrchardConsole.ModelHub do
  @moduledoc """
  Console-facing async seam for the Model Hub browse/detail experience.

  Wraps synchronous `Orchard.Models.HubClient` calls in unlinked tasks and
  sends ref-tagged completion messages back to the owner process.

  This seam is intentionally thin for B1: it forwards `HubClient` success/error
  results as-is and only normalizes unexpected task failures (including
  exceptions, throws, and exits) to a generic HF error map before sending one
  completion message for the task.

  The module is injectable via `:model_hub_impl` in the
  `:orchard_controller, :console` config for testing. The underlying client
  module is injectable via `:model_hub_client_impl`.

  ## Message Contract

  `start_search/3` sends one completion message:

      {:model_hub, ref, :search_finished, {:ok, %{query: query, results: results}}}
      {:model_hub, ref, :search_finished, {:error, error_map}}

  `start_detail/3` sends one completion message:

      {:model_hub, ref, :detail_finished, {:ok, detail}}
      {:model_hub, ref, :detail_finished, {:error, error_map}}
  """

  alias Orchard.Models.HubClient

  @type error_map :: %{
          status: atom(),
          code: String.t(),
          message: String.t()
        }

  @doc """
  Starts an async model search and returns `{:ok, pid}` immediately.
  """
  @spec start_search(pid(), term(), String.t() | nil) :: {:ok, pid()}
  def start_search(owner, ref, query) do
    client = model_hub_client_impl()
    Task.start(fn -> run_search(client, owner, ref, query) end)
  end

  @doc """
  Starts an async model detail lookup and returns `{:ok, pid}` immediately.
  """
  @spec start_detail(pid(), term(), String.t()) :: {:ok, pid()}
  def start_detail(owner, ref, repo_id) do
    client = model_hub_client_impl()
    Task.start(fn -> run_detail(client, owner, ref, repo_id) end)
  end

  defp run_search(client, owner, ref, query) do
    result =
      protect_result(fn ->
        case client.search_models(query, []) do
          {:ok, results} -> {:ok, %{query: query, results: results}}
          {:error, %{} = error} -> {:error, error}
          _other -> {:error, unexpected_error()}
        end
      end)

    send(owner, {:model_hub, ref, :search_finished, result})
  end

  defp run_detail(client, owner, ref, repo_id) do
    result =
      protect_result(fn ->
        case client.get_model_detail(repo_id) do
          {:ok, detail} -> {:ok, detail}
          {:error, %{} = error} -> {:error, error}
          _other -> {:error, unexpected_error()}
        end
      end)

    send(owner, {:model_hub, ref, :detail_finished, result})
  end

  defp protect_result(fun) do
    fun.()
  rescue
    _exception -> {:error, unexpected_error()}
  catch
    :throw, _value -> {:error, unexpected_error()}
    :exit, _reason -> {:error, unexpected_error()}
  end

  defp unexpected_error do
    %{
      status: :error,
      code: "hf_error",
      message: "Hugging Face request failed."
    }
  end

  defp model_hub_client_impl do
    console_config()
    |> Keyword.get(:model_hub_client_impl, HubClient)
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end
end
