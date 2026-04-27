defmodule Orchard.Licensing.GateCache do
  @moduledoc """
  Short-lived cache for local Orchard license inspection.

  The cache is process-local to the shared application and depends only on
  `Orchard.Licensing.inspect_local/1`. It does not depend on the controller
  Repo, endpoint, or application context.
  """

  use GenServer

  alias Orchard.Licensing

  @default_ttl_seconds 5
  @volatile_opts [:cache_now_ms, :cache_key]

  @type cache_key :: term()
  @type file_marker ::
          :not_configured
          | {:error, File.posix()}
          | %{size: non_neg_integer(), inode: integer() | nil, mtime: term(), ctime: term()}
  @type cache_entry :: %{
          status: Licensing.t(),
          expires_at_ms: integer(),
          bundle_marker: file_marker(),
          node_identity_marker: file_marker()
        }
  @type state :: %{optional(cache_key()) => cache_entry()}

  @doc false
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return the cached local license status, re-inspecting when the TTL has expired.
  """
  @spec status(Keyword.t()) :: Licensing.t()
  def status(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> Licensing.inspect_local(inspect_opts(opts))
      _pid -> GenServer.call(__MODULE__, {:status, opts})
    end
  end

  @doc """
  Clear all cached license statuses.
  """
  @spec refresh() :: :ok
  def refresh do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :refresh)
    end
  end

  @doc """
  Alias for `refresh/0` for tests and activation paths that use invalidation terminology.
  """
  @spec invalidate() :: :ok
  def invalidate, do: refresh()

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:status, opts}, _from, state) do
    key = cache_key(opts)
    now_ms = cache_now_ms(opts)
    marker = bundle_marker(opts)
    identity_marker = node_identity_marker(opts)

    case Map.fetch(state, key) do
      {:ok, cache_entry} ->
        if cache_hit?(cache_entry, now_ms, marker, identity_marker, opts) do
          {:reply, cache_entry.status, state}
        else
          refreshed_reply(state, key, now_ms, marker, identity_marker, opts)
        end

      _miss_or_expired_or_changed ->
        refreshed_reply(state, key, now_ms, marker, identity_marker, opts)
    end
  end

  def handle_call(:refresh, _from, _state), do: {:reply, :ok, %{}}

  defp refreshed_reply(state, key, now_ms, marker, identity_marker, opts) do
    status = Licensing.inspect_local(inspect_opts(opts))

    entry = %{
      status: status,
      expires_at_ms: now_ms + ttl_ms(),
      bundle_marker: marker,
      node_identity_marker: identity_marker
    }

    {:reply, status, Map.put(state, key, entry)}
  end

  defp cache_hit?(
         %{
           status: %Licensing{} = status,
           expires_at_ms: expires_at_ms,
           bundle_marker: cached_marker,
           node_identity_marker: cached_identity_marker
         },
         now_ms,
         marker,
         identity_marker,
         opts
       ) do
    expires_at_ms > now_ms and cached_marker == marker and
      cached_identity_marker == identity_marker and not cached_valid_expired?(status, opts)
  end

  defp cache_hit?(_cache_entry, _now_ms, _marker, _identity_marker, _opts), do: false

  defp cached_valid_expired?(
         %Licensing{state: :valid, expires_at: %DateTime{} = expires_at},
         opts
       ) do
    case inspection_now(opts) do
      %DateTime{} = now -> DateTime.compare(now, expires_at) == :gt
      :invalid -> true
    end
  end

  defp cached_valid_expired?(_status, _opts), do: false

  defp inspection_now(opts) do
    case Keyword.fetch(opts, :now) do
      {:ok, %DateTime{} = now} -> now
      {:ok, _invalid_now} -> :invalid
      :error -> DateTime.utc_now()
    end
  end

  defp cache_key(opts) do
    Keyword.get_lazy(opts, :cache_key, fn ->
      shared_config = shared_config()

      {
        Keyword.get(opts, :bundle_path, Keyword.get(shared_config, :bundle_path)),
        Keyword.get(opts, :node_identity_path, Keyword.get(shared_config, :node_identity_path)),
        Keyword.get(opts, :keygen_public_key, Keyword.get(shared_config, :keygen_public_key))
      }
    end)
  end

  defp inspect_opts(opts), do: Keyword.drop(opts, @volatile_opts)

  defp cache_now_ms(opts),
    do: Keyword.get(opts, :cache_now_ms, System.monotonic_time(:millisecond))

  defp bundle_marker(opts) do
    opts
    |> Keyword.get(:bundle_path, Keyword.get(shared_config(), :bundle_path))
    |> file_marker()
  end

  defp node_identity_marker(opts) do
    opts
    |> Keyword.get(:node_identity_path, Keyword.get(shared_config(), :node_identity_path))
    |> file_marker()
  end

  defp file_marker(path) when is_binary(path) and path != "" do
    case File.stat(path) do
      {:ok, stat} ->
        %{size: stat.size, inode: stat.inode, mtime: stat.mtime, ctime: stat.ctime}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp file_marker(_path), do: :not_configured

  defp ttl_ms do
    shared_config()
    |> Keyword.get(:gate_cache_ttl_seconds, @default_ttl_seconds)
    |> seconds_to_ms()
  end

  defp shared_config, do: Application.get_env(:orchard_shared, :licensing, [])

  defp seconds_to_ms(seconds) when is_integer(seconds) and seconds >= 0, do: seconds * 1_000

  defp seconds_to_ms(seconds) when is_float(seconds) and seconds >= 0 do
    seconds
    |> Kernel.*(1_000)
    |> round()
  end

  defp seconds_to_ms(_seconds), do: @default_ttl_seconds * 1_000
end
