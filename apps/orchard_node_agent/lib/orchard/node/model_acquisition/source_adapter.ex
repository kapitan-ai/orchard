defmodule Orchard.Node.ModelAcquisition.SourceAdapter do
  @moduledoc """
  Behaviour for model acquisition source adapters.

  Each adapter materializes model files from a specific URI scheme
  (e.g. `file://`, `hf://`, `s3://`) into a staging directory.
  """

  alias Orchard.Node.ModelAcquisition.Request

  @doc """
  Materialize model files into the request's staging path.

  The staging path (`request.staging_path`) already exists as an empty directory.
  The adapter must populate it with the model bundle files.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback materialize(Request.t()) :: :ok | {:error, term()}
end
