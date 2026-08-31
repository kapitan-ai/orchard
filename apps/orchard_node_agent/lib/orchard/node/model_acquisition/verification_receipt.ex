defmodule Orchard.Node.ModelAcquisition.VerificationReceipt do
  @moduledoc """
  Persists path-bound filesystem evidence for a previously verified model artifact.

  A receipt is an acceleration hint only. The Catalog digest remains authoritative,
  and any missing or mismatched evidence must fall back to a full tree hash.
  """

  alias Orchard.FS
  alias Orchard.Node.ModelAcquisition.Request

  @receipt_version 1
  @receipt_dir ".verification"
  @normalized_mtime 946_684_800

  @type inventory_evidence :: %{
          fingerprint: String.t(),
          descendant_fingerprint: String.t()
        }

  @type verified_evidence :: %{
          fingerprint: String.t(),
          descendant_fingerprint: String.t(),
          verified_at: integer()
        }

  @type miss_reason ::
          :receipt_missing
          | :receipt_unreadable
          | :receipt_invalid
          | :receipt_version_mismatch
          | :artifact_digest_mismatch
          | :path_mismatch
          | :inventory_changed
          | :inventory_unreadable

  @spec check(Request.t()) :: :match | {:miss, miss_reason()}
  def check(%Request{} = request) do
    with {:ok, receipt} <- read_receipt(request),
         :ok <- validate_receipt(receipt, request),
         {:ok, evidence} <- inventory_evidence(request.final_path),
         :ok <- validate_evidence(receipt, evidence) do
      :match
    else
      {:error, reason} -> {:miss, reason}
    end
  end

  @spec record(Request.t(), verified_evidence()) :: :ok | {:error, term()}
  def record(%Request{} = request, verified_evidence) do
    with {:ok, promoted_evidence} <- inventory_evidence(request.final_path),
         true <- promotion_descendants_stable?(verified_evidence, promoted_evidence),
         {:ok, final_evidence} <- inventory_evidence(request.final_path),
         true <- promotion_descendants_stable?(verified_evidence, final_evidence),
         true <- promoted_evidence.fingerprint == final_evidence.fingerprint,
         :ok <- write_receipt(request, final_evidence, System.system_time(:second)) do
      :ok
    else
      false -> {:error, :inventory_changed_after_verification}
      {:error, _reason} = error -> error
    end
  end

  @spec record_verified(Request.t(), verified_evidence()) :: :ok | {:error, term()}
  def record_verified(%Request{} = request, verified_evidence),
    do: publish_verified_receipt(request, verified_evidence)

  @spec invalidate(Request.t()) :: :ok | {:error, :receipt_invalidation_failed}
  def invalidate(%Request{} = request) do
    case File.rm(receipt_path(request)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, :receipt_invalidation_failed}
    end
  end

  @spec inventory_fingerprint(String.t()) :: {:ok, String.t()} | {:error, term()}
  def inventory_fingerprint(root_path) do
    with {:ok, evidence} <- inventory_evidence(root_path) do
      {:ok, evidence.fingerprint}
    end
  end

  @doc """
  Captures the complete filesystem inventory used to bind a verification receipt.

  Symlinks, unsupported entries, and unreadable inventory fail closed.
  """
  @spec inventory_evidence(String.t(), keyword()) ::
          {:ok, inventory_evidence()} | {:error, term()}
  def inventory_evidence(root_path, opts \\ []) do
    require_normalized_mtime? = Keyword.get(opts, :require_normalized_mtime?, false)

    with {:ok, entries} <-
           collect_inventory(root_path, root_path, [], require_normalized_mtime?) do
      fingerprint =
        entries
        |> Enum.sort()
        |> :erlang.term_to_binary([:deterministic])
        |> sha256_hex()

      descendant_entries = Enum.reject(entries, &root_entry?/1)

      descendant_fingerprint =
        descendant_entries
        |> Enum.sort()
        |> :erlang.term_to_binary([:deterministic])
        |> sha256_hex()

      {:ok,
       %{
         fingerprint: fingerprint,
         descendant_fingerprint: descendant_fingerprint
       }}
    end
  end

  @doc """
  Normalizes bundle modification times and captures stable inventory evidence.

  The reserved modification time makes a later ordinary write visible even when the
  filesystem reports change times only to whole-second resolution.
  """
  @spec prepare_for_verification(String.t()) ::
          {:ok, inventory_evidence(), integer()} | {:error, term()}
  def prepare_for_verification(root_path) do
    with :ok <- normalize_mtimes(root_path),
         {:ok, evidence} <- inventory_evidence(root_path, require_normalized_mtime?: true) do
      {:ok, evidence, System.system_time(:second)}
    end
  end

  defp read_receipt(request) do
    case File.read(receipt_path(request)) do
      {:ok, encoded} -> decode_receipt(encoded)
      {:error, :enoent} -> {:error, :receipt_missing}
      {:error, _reason} -> {:error, :receipt_unreadable}
    end
  end

  defp decode_receipt(encoded) do
    case Jason.decode(encoded) do
      {:ok, receipt} when is_map(receipt) -> {:ok, receipt}
      _other -> {:error, :receipt_invalid}
    end
  end

  defp validate_receipt(receipt, request) do
    cond do
      receipt["version"] != @receipt_version -> {:error, :receipt_version_mismatch}
      receipt["artifact_sha256"] != request.artifact_sha256 -> {:error, :artifact_digest_mismatch}
      receipt["path_sha256"] != request_path_sha256(request) -> {:error, :path_mismatch}
      not valid_fingerprint?(receipt["inventory_sha256"]) -> {:error, :receipt_invalid}
      not valid_verification_time?(receipt["verified_at_posix"]) -> {:error, :receipt_invalid}
      true -> :ok
    end
  end

  defp validate_evidence(receipt, evidence),
    do: equality_result(receipt["inventory_sha256"], evidence.fingerprint, :inventory_changed)

  defp valid_fingerprint?(value) do
    is_binary(value) and byte_size(value) == 64 and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_verification_time?(value) do
    is_integer(value) and value > 0 and value <= System.system_time(:second)
  end

  defp publish_verified_receipt(request, verified_evidence) do
    with {:ok, current_evidence} <- inventory_evidence(request.final_path),
         true <- verified_evidence_stable?(verified_evidence, current_evidence),
         :ok <- write_receipt(request, current_evidence, verified_evidence.verified_at) do
      :ok
    else
      false -> {:error, :inventory_changed_after_verification}
      {:error, _reason} = error -> error
    end
  end

  defp verified_evidence_stable?(verified_evidence, current_evidence) do
    current_evidence.fingerprint == verified_evidence.fingerprint
  end

  defp promotion_descendants_stable?(verified_evidence, current_evidence) do
    current_evidence.descendant_fingerprint == verified_evidence.descendant_fingerprint
  end

  defp equality_result(value, value, _reason), do: :ok
  defp equality_result(_left, _right, reason), do: {:error, reason}

  defp root_entry?(
         {relative_path, _type, _size, _mode, _links, _major, _minor, _inode, _uid, _gid, _mtime,
          _ctime}
       ),
       do: relative_path == "."

  defp write_receipt(request, evidence, verified_at) do
    path = receipt_path(request)

    receipt = %{
      "version" => @receipt_version,
      "artifact_sha256" => request.artifact_sha256,
      "path_sha256" => request_path_sha256(request),
      "inventory_sha256" => evidence.fingerprint,
      "verified_at_posix" => verified_at
    }

    try do
      File.mkdir_p!(Path.dirname(path))

      FS.atomic_write!(path, Jason.encode!(receipt),
        modes: [:binary, :write],
        permissions: 0o600
      )

      :ok
    rescue
      File.Error -> {:error, :receipt_write_failed}
    end
  end

  defp receipt_path(request) do
    identity =
      sha256_hex(request_path_sha256(request) <> <<0>> <> request.artifact_sha256)

    Path.join([request.models_root, @receipt_dir, identity <> ".json"])
  end

  defp request_path_sha256(request) do
    request.models_root
    |> canonical_path()
    |> Path.join(Path.relative_to(request.final_path, request.models_root))
    |> Path.expand()
    |> sha256_hex()
  end

  defp sha256_hex(data),
    do: data |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp canonical_path(path) do
    case Orchard.PathUtils.resolve_realpath(path) do
      {:ok, canonical} -> canonical
      {:error, _reason} -> Path.expand(path)
    end
  end

  defp collect_inventory(path, root_path, acc, require_normalized_mtime?) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        with :ok <- validate_normalized_mtime(stat, require_normalized_mtime?),
             {:ok, entries} <- File.ls(path) do
          next_acc = [inventory_entry(path, root_path, stat) | acc]
          collect_children(entries, path, root_path, next_acc, require_normalized_mtime?)
        else
          {:error, :inventory_changed_after_normalization} = error -> error
          {:error, _reason} -> {:error, :inventory_unreadable}
        end

      {:ok, %File.Stat{type: :regular} = stat} ->
        with :ok <- validate_normalized_mtime(stat, require_normalized_mtime?) do
          {:ok, [inventory_entry(path, root_path, stat) | acc]}
        end

      {:ok, %File.Stat{}} ->
        {:error, :inventory_unreadable}

      {:error, _reason} ->
        {:error, :inventory_unreadable}
    end
  end

  defp normalize_mtimes(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        with {:ok, entries} <- File.ls(path),
             :ok <- normalize_children_mtimes(entries, path),
             :ok <- normalize_mtime(path, stat) do
          :ok
        else
          {:error, _reason} -> {:error, :inventory_unreadable}
        end

      {:ok, %File.Stat{type: :regular} = stat} ->
        normalize_mtime(path, stat)

      {:ok, %File.Stat{}} ->
        {:error, :inventory_unreadable}

      {:error, _reason} ->
        {:error, :inventory_unreadable}
    end
  end

  defp normalize_children_mtimes([], _parent), do: :ok

  defp normalize_children_mtimes([entry | rest], parent) do
    with :ok <- normalize_mtimes(Path.join(parent, entry)) do
      normalize_children_mtimes(rest, parent)
    end
  end

  defp normalize_mtime(_path, %File.Stat{mtime: @normalized_mtime}), do: :ok

  defp normalize_mtime(path, _stat) do
    case File.touch(path, @normalized_mtime) do
      :ok -> :ok
      {:error, _reason} -> {:error, :inventory_unreadable}
    end
  end

  defp validate_normalized_mtime(_stat, false), do: :ok

  defp validate_normalized_mtime(%File.Stat{mtime: @normalized_mtime}, true), do: :ok

  defp validate_normalized_mtime(%File.Stat{}, true),
    do: {:error, :inventory_changed_after_normalization}

  defp collect_children([], _parent, _root_path, acc, _require_normalized_mtime?),
    do: {:ok, acc}

  defp collect_children(
         [entry | rest],
         parent,
         root_path,
         acc,
         require_normalized_mtime?
       ) do
    case collect_inventory(
           Path.join(parent, entry),
           root_path,
           acc,
           require_normalized_mtime?
         ) do
      {:ok, next_acc} ->
        collect_children(rest, parent, root_path, next_acc, require_normalized_mtime?)

      {:error, _reason} = error ->
        error
    end
  end

  defp inventory_entry(path, root_path, stat) do
    relative_path = Path.relative_to(path, root_path)

    entry =
      {
        relative_path,
        stat.type,
        stat.size,
        stat.mode,
        stat.links,
        stat.major_device,
        stat.minor_device,
        stat.inode,
        stat.uid,
        stat.gid,
        stat.mtime,
        stat.ctime
      }

    entry
  end
end
