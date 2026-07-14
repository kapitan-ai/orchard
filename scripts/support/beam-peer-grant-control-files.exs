defmodule Orchard.BeamPeerGrantControlFiles do
  @moduledoc false

  import Bitwise, only: [band: 2]

  @spec validate_root(String.t()) :: :ok | {:error, :beam_peer_grant_control_root_invalid}
  def validate_root(root) when is_binary(root) do
    with true <- Path.type(root) == :absolute,
         {:ok, running_uid} <- running_uid(),
         {:ok, %{type: :directory, uid: ^running_uid} = stat} <- File.lstat(root),
         true <- band(stat.mode, 0o777) == 0o700 do
      :ok
    else
      _other -> {:error, :beam_peer_grant_control_root_invalid}
    end
  end

  def validate_root(_root), do: {:error, :beam_peer_grant_control_root_invalid}

  @spec publish_ready(String.t()) :: :ok | {:error, :beam_peer_grant_control_ready_invalid}
  def publish_ready(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, io} <- File.open(path, [:write, :exclusive, :binary]) do
      result = write_ready(io, path)
      File.close(io)

      if result == :ok do
        :ok
      else
        File.rm(path)
        {:error, :beam_peer_grant_control_ready_invalid}
      end
    else
      _other -> {:error, :beam_peer_grant_control_ready_invalid}
    end
  end

  def publish_ready(_path), do: {:error, :beam_peer_grant_control_ready_invalid}

  @spec wait_for_stop(String.t(), non_neg_integer()) ::
          :ok | {:error, :beam_peer_grant_control_stop_timeout}
  def wait_for_stop(path, timeout_ms)
      when is_binary(path) and is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_stop(path, deadline)
  end

  defp do_wait_for_stop(path, deadline) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        :ok

      _other ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error, :beam_peer_grant_control_stop_timeout}
        else
          Process.sleep(min(50, remaining_ms))
          do_wait_for_stop(path, deadline)
        end
    end
  end

  defp write_ready(io, path) do
    with :ok <- File.chmod(path, 0o600),
         :ok <- IO.binwrite(io, "ready\n") do
      :file.sync(io)
    end
  end

  defp running_uid do
    probe =
      Path.join(
        System.tmp_dir!(),
        ".orchard-peer-grant-control-owner-#{System.unique_integer([:positive, :monotonic])}"
      )

    try do
      with :ok <- File.write(probe, "", [:exclusive]),
           {:ok, %{type: :regular, uid: uid}} <- File.lstat(probe) do
        {:ok, uid}
      else
        _other -> {:error, :owner_probe_failed}
      end
    after
      File.rm(probe)
    end
  end
end
