defmodule OrchardCLI.HTTP do
  @moduledoc false

  @spec request(keyword(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def request(req_opts, request_opts \\ []) when is_list(req_opts) and is_list(request_opts) do
    with {:ok, _started_apps} <- Application.ensure_all_started(:req) do
      Req.request(Req.new(req_opts), request_opts)
    end
  end
end
