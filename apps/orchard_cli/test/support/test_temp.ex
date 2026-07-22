defmodule OrchardCLI.TestTemp do
  @moduledoc false

  @create_attempts 10

  @enforce_keys [:root]
  defstruct [:root]

  @opaque t :: %__MODULE__{root: String.t()}

  @spec create_run!(keyword()) :: t()
  def create_run!(opts \\ []) do
    base = Keyword.get(opts, :base, System.tmp_dir!())
    prefix = Keyword.fetch!(opts, :prefix)

    create_owned_root!(base, prefix, @create_attempts)
  end

  @spec create_child!(t(), keyword()) :: t()
  def create_child!(%__MODULE__{root: root}, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    create_owned_root!(root, prefix, @create_attempts)
  end

  @spec root(t()) :: String.t()
  def root(%__MODULE__{root: root}), do: root

  @spec path(t(), String.t()) :: String.t()
  def path(%__MODULE__{root: root}, name), do: Path.join(root, name)

  @spec cleanup!(t()) :: :ok
  def cleanup!(%__MODULE__{root: root}) do
    File.rm_rf!(root)
    :ok
  end

  @spec atomic_write!(String.t(), iodata()) :: :ok
  def atomic_write!(path, contents) do
    tmp = "#{path}.tmp-#{random_suffix()}"
    File.write!(tmp, contents)
    File.rename!(tmp, path)
    :ok
  end

  defp create_owned_root!(_base, _prefix, 0) do
    raise File.Error,
      reason: :eexist,
      action: "create uniquely owned test run directory",
      path: ""
  end

  defp create_owned_root!(base, prefix, attempts_left) do
    root = Path.join(base, "#{prefix}-#{random_suffix()}")

    case File.mkdir(root) do
      :ok ->
        make_private_owner!(root)

      {:error, :eexist} ->
        create_owned_root!(base, prefix, attempts_left - 1)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create test run directory", path: root
    end
  end

  defp make_private_owner!(root) do
    case File.chmod(root, 0o700) do
      :ok ->
        %__MODULE__{root: root}

      {:error, reason} ->
        File.rmdir(root)
        raise File.Error, reason: reason, action: "make test run directory private", path: root
    end
  end

  defp random_suffix do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end

defmodule OrchardCLI.TestTempProcess do
  @moduledoc false

  alias OrchardCLI.TestTemp

  @arm_timeout_ms 60_000
  @hold_timeout_ms 60_000

  @spec main([String.t()]) :: :ok
  def main(["run", base, label, cleanup]) do
    owner = create_marked_run!(base, label)
    root = TestTemp.root(owner)

    if cleanup == "cleanup" do
      TestTemp.cleanup!(owner)
    end

    IO.write(root)
  end

  def main(["hold", base, label, ready, armed, release]) do
    owner = create_marked_run!(base, label)

    try do
      TestTemp.atomic_write!(ready, TestTemp.root(owner))

      case await_signal!(armed, "armed", deadline(@arm_timeout_ms)) do
        :ok -> await_signal!(release, "cleanup", deadline(hold_timeout_ms()))
        :timeout -> :ok
      end
    after
      TestTemp.cleanup!(owner)
    end
  end

  defp hold_timeout_ms do
    case System.get_env("ORCHARD_TEST_TEMP_HOLD_TIMEOUT_MS") do
      nil -> @hold_timeout_ms
      value -> String.to_integer(value)
    end
  end

  defp create_marked_run!(base, label) do
    {:ok, _apps} = Application.ensure_all_started(:crypto)
    owner = TestTemp.create_run!(base: base, prefix: "run")
    File.write!(TestTemp.path(owner, "owner-marker"), label)
    owner
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp await_signal!(path, expected, deadline) do
    case File.read(path) do
      {:ok, ^expected} ->
        :ok

      {:error, :enoent} ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(10)
          await_signal!(path, expected, deadline)
        end

      {:ok, command} ->
        raise "unexpected test-temp process command in #{path}: #{inspect(command)}"

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read test-temp process command", path: path
    end
  end
end
