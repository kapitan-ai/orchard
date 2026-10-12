defmodule OrchardCLI.TransportFixture do
  @moduledoc false

  alias OrchardCLI.TestTemp

  @spec base_dir() :: String.t()
  def base_dir do
    case :os.type() do
      {:unix, :darwin} -> "/private/tmp"
      _other -> canonical(System.tmp_dir!())
    end
  end

  @spec support_root!() :: String.t()
  def support_root! do
    [base: base_dir(), prefix: "orchard-transport-test"]
    |> TestTemp.create_run!()
    |> TestTemp.root()
  end

  @spec helper(:production | :test) :: String.t()
  def helper(:production), do: priv_path("orchard-transport-publish")
  def helper(:test), do: priv_path("orchard-transport-publish-test")

  @spec umask_wrapper(non_neg_integer()) :: [String.t()]
  def umask_wrapper(umask) do
    mask = Integer.to_string(umask, 8) |> String.pad_leading(4, "0")
    ["/bin/sh", "-c", ~s(umask #{mask} && exec "$0" "$@")]
  end

  @spec mode(String.t()) :: non_neg_integer()
  def mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.lstat(path)
    Bitwise.band(mode, 0o7777)
  end

  @spec stage_entries(String.t()) :: [String.t()]
  def stage_entries(support_root) do
    support_root
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".orchard-public-stage-"))
  end

  defp priv_path(name), do: Path.join(List.to_string(:code.priv_dir(:orchard_cli)), name)

  defp canonical(path) do
    {resolved, 0} = System.cmd("/bin/pwd", ["-P"], cd: path)
    String.trim(resolved)
  end
end
