defmodule Orchard.Tokenizer.Client do
  @moduledoc """
  Injectable tokenizer seam for controller-side prompt rendering and token counting.
  """

  @callback tokenize(term(), keyword()) :: {:ok, map()} | {:error, term()}

  def tokenize(request, opts \\ []) do
    case Orchard.Inference.tokenizer_client() do
      __MODULE__ -> default_tokenize(request, opts)
      module -> module.tokenize(request, opts)
    end
  end

  def mode, do: Orchard.Inference.tokenizer_mode()
  def executable, do: Orchard.Inference.tokenizer_executable()

  defp default_tokenize(_request, _opts), do: {:error, :not_implemented}
end
