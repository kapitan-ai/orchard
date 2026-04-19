defmodule Orchard.Licensing do
  @moduledoc """
  Shared local licensing inspection and installation primitives for Orchard's
  minimal licensing v0 bundle contract.
  """

  alias Orchard.Licensing.LocalStore
  alias Orchard.Licensing.Validator
  alias Orchard.NodeIdentityFile

  @type state ::
          :valid
          | :missing_bundle
          | :identity_missing
          | :expired
          | :not_yet_valid
          | :fingerprint_mismatch
          | :invalid_license_signature
          | :invalid_machine_signature
          | :malformed_bundle
          | :malformed_license_certificate
          | :malformed_machine_certificate
          | :config_error
          | :read_error

  @type enforcement :: :off | :warn | :hard

  @type tracking_metadata :: %{
          program: String.t() | nil,
          reference: String.t() | nil
        }

  @type t :: %__MODULE__{
          state: state(),
          message: String.t(),
          bundle_path: String.t(),
          fingerprint: String.t() | nil,
          local_node_fingerprint: String.t() | nil,
          expires_at: DateTime.t() | nil,
          license_id: String.t() | nil,
          machine_id: String.t() | nil,
          licensee: String.t() | nil,
          max_machines: pos_integer() | nil,
          metadata: tracking_metadata() | nil
        }

  defstruct state: :missing_bundle,
            message: "",
            bundle_path: "",
            fingerprint: nil,
            local_node_fingerprint: nil,
            expires_at: nil,
            license_id: nil,
            machine_id: nil,
            licensee: nil,
            max_machines: nil,
            metadata: nil

  @doc """
  Inspect the Orchard-owned local licensing bundle and return a normalized
  status struct.
  """
  @spec inspect_local(Keyword.t()) :: t()
  def inspect_local(opts \\ []) do
    case resolve_config(opts) do
      {:ok, config} -> inspect_local_with_config(config)
      {:error, %__MODULE__{} = status} -> status
    end
  end

  @doc """
  Offline-validate and atomically install a candidate Orchard licensing pair.
  """
  @spec install_pair(
          %{license_certificate: String.t(), machine_certificate: String.t()},
          Keyword.t()
        ) ::
          {:ok, t()} | {:error, t() | {:write_failed, File.posix()}}
  def install_pair(bundle_pair, opts \\ []) do
    case resolve_config(opts) do
      {:ok, config} -> install_pair_with_config(bundle_pair, config)
      {:error, %__MODULE__{} = status} -> {:error, status}
    end
  end

  @doc """
  Produce a JSON-ready summary suitable for health/status surfaces.
  """
  @type health_summary :: %{
          required(:status) => String.t(),
          required(:reason) => String.t() | nil,
          required(:message) => String.t(),
          required(:expires_at) => String.t() | nil,
          optional(:tracking) => tracking_metadata()
        }

  @spec health_summary(t()) :: health_summary()
  def health_summary(%__MODULE__{} = status) do
    summary = %{
      status: health_status(status.state),
      reason: health_reason(status.state),
      message: status.message,
      expires_at: iso8601_or_nil(status.expires_at)
    }

    if is_map(status.metadata) do
      Map.put(summary, :tracking, status.metadata)
    else
      summary
    end
  end

  @doc """
  Returns stable telemetry dimensions from licensing status.

  This helper does not emit telemetry events; it prepares callers for future
  observational enrichment.
  """
  @spec telemetry_dimensions(t()) :: %{
          license_state: String.t(),
          tracking_program: String.t() | nil,
          tracking_reference: String.t() | nil
        }
  def telemetry_dimensions(%__MODULE__{} = status) do
    %{
      license_state: Atom.to_string(status.state),
      tracking_program: tracking_field(status.metadata, :program),
      tracking_reference: tracking_field(status.metadata, :reference)
    }
  end

  @doc """
  Map a licensing status plus enforcement mode into a startup decision.
  """
  @spec startup_decision(t(), enforcement()) :: :allow | {:warn, String.t()} | {:deny, String.t()}
  def startup_decision(%__MODULE__{state: :valid}, mode) when mode in [:off, :warn, :hard],
    do: :allow

  def startup_decision(%__MODULE__{} = _status, :off), do: :allow
  def startup_decision(%__MODULE__{message: message}, :warn), do: {:warn, message}
  def startup_decision(%__MODULE__{message: message}, :hard), do: {:deny, message}

  def startup_decision(%__MODULE__{}, mode) do
    raise ArgumentError, "unsupported license enforcement mode: #{inspect(mode)}"
  end

  defp resolve_config(opts) do
    shared_config = Application.get_env(:orchard_shared, :licensing, [])

    config = %{
      bundle_path: Keyword.get(opts, :bundle_path, Keyword.get(shared_config, :bundle_path)),
      node_identity_path:
        Keyword.get(opts, :node_identity_path, Keyword.get(shared_config, :node_identity_path)),
      keygen_public_key:
        Keyword.get(opts, :keygen_public_key, Keyword.get(shared_config, :keygen_public_key)),
      now: Keyword.get(opts, :now, DateTime.utc_now())
    }

    cond do
      not is_binary(config.bundle_path) or config.bundle_path == "" ->
        {:error, status(:config_error, "Licensing bundle path is not configured.", "")}

      not is_binary(config.node_identity_path) or config.node_identity_path == "" ->
        {:error,
         status(:config_error, "Node identity path is not configured.", config.bundle_path)}

      not is_binary(config.keygen_public_key) or config.keygen_public_key == "" ->
        {:error,
         status(:config_error, "Keygen public key is not configured.", config.bundle_path)}

      not match?(%DateTime{}, config.now) ->
        {:error, status(:config_error, "Current time must be a DateTime.", config.bundle_path)}

      true ->
        {:ok, config}
    end
  end

  defp read_bundle(bundle_path) do
    case LocalStore.read(bundle_path) do
      {:ok, bundle} ->
        {:ok, bundle}

      {:error, :enoent} ->
        {:error, status(:missing_bundle, "No local license bundle is installed.", bundle_path)}

      {:error, {:malformed_bundle, message}} ->
        {:error,
         status(:malformed_bundle, "Licensing bundle is malformed: #{message}.", bundle_path)}

      {:error, {:read_failed, reason}} ->
        {:error,
         status(:read_error, "Cannot read licensing bundle: #{inspect(reason)}.", bundle_path)}
    end
  end

  defp read_node_identity(node_identity_path, bundle_path) do
    case NodeIdentityFile.read(node_identity_path) do
      {:ok, node_id} ->
        {:ok, node_id}

      {:error, :enoent} ->
        {:error, status(:identity_missing, "Local node identity is missing.", bundle_path)}

      {:error, {:invalid_uuid, value}} ->
        {:error,
         status(
           :identity_missing,
           "Local node identity is invalid: #{inspect(value)}.",
           bundle_path
         )}

      {:error, {:read_failed, reason}} ->
        {:error,
         status(:read_error, "Cannot read node identity file: #{inspect(reason)}.", bundle_path)}
    end
  end

  defp normalize_bundle_pair(
         %{license_certificate: license, machine_certificate: machine},
         _bundle_path
       )
       when is_binary(license) and is_binary(machine) do
    {:ok, %{license_certificate: license, machine_certificate: machine}}
  end

  defp normalize_bundle_pair(_pair, bundle_path) do
    {:error,
     status(
       :malformed_bundle,
       "Licensing bundle must include string license_certificate and machine_certificate fields.",
       bundle_path
     )}
  end

  defp inspect_local_with_config(config) do
    with {:ok, bundle} <- read_bundle(config.bundle_path),
         {:ok, node_id} <- read_node_identity(config.node_identity_path, config.bundle_path),
         {:ok, claims} <- Validator.validate_pair(bundle, config.keygen_public_key) do
      claims_to_status(claims, node_id, config.bundle_path, config.now)
    else
      {:error, %__MODULE__{} = status} ->
        status

      {:error, {state, message}} ->
        status(state, message, config.bundle_path)
    end
  end

  defp install_pair_with_config(bundle_pair, config) do
    with {:ok, pair} <- normalize_bundle_pair(bundle_pair, config.bundle_path),
         {:ok, node_id} <- read_node_identity(config.node_identity_path, config.bundle_path),
         {:ok, claims} <- Validator.validate_pair(pair, config.keygen_public_key),
         %__MODULE__{} = status <-
           claims_to_status(claims, node_id, config.bundle_path, config.now),
         :ok <- ensure_installable(status),
         :ok <- LocalStore.write(config.bundle_path, pair) do
      {:ok, status}
    else
      {:error, %__MODULE__{} = status} ->
        {:error, status}

      {:error, {:write_failed, _reason} = error} ->
        {:error, error}

      {:error, {state, message}} ->
        {:error, status(state, message, config.bundle_path)}
    end
  end

  defp claims_to_status(claims, node_id, bundle_path, now) do
    base_status =
      status(
        :valid,
        "License bundle is valid.",
        bundle_path,
        fingerprint: claims.fingerprint,
        local_node_fingerprint: node_id,
        expires_at: claims.expires_at,
        license_id: claims.license_id,
        machine_id: claims.machine_id,
        licensee: claims.licensee,
        max_machines: claims.max_machines,
        metadata: claims.metadata
      )

    cond do
      claims.fingerprint != node_id ->
        %{
          base_status
          | state: :fingerprint_mismatch,
            message: "Machine certificate fingerprint does not match the local node identity."
        }

      match?(%DateTime{}, claims.not_before) and DateTime.compare(now, claims.not_before) == :lt ->
        %{base_status | state: :not_yet_valid, message: "License bundle is not yet valid."}

      match?(%DateTime{}, claims.expires_at) and DateTime.compare(now, claims.expires_at) == :gt ->
        %{base_status | state: :expired, message: "License bundle has expired."}

      true ->
        base_status
    end
  end

  defp ensure_installable(%__MODULE__{state: :valid}), do: :ok
  defp ensure_installable(%__MODULE__{} = status), do: {:error, status}

  defp health_status(:valid), do: "valid"
  defp health_status(state) when state in [:missing_bundle, :identity_missing], do: "missing"
  defp health_status(_state), do: "invalid"

  defp health_reason(:valid), do: nil

  defp health_reason(state)
       when state in [
              :malformed_bundle,
              :malformed_license_certificate,
              :malformed_machine_certificate
            ] do
    "malformed_bundle"
  end

  defp health_reason(state), do: Atom.to_string(state)

  defp iso8601_or_nil(nil), do: nil
  defp iso8601_or_nil(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp tracking_field(metadata, key) when is_map(metadata) do
    Map.get(metadata, key)
  end

  defp tracking_field(_metadata, _key), do: nil

  defp status(state, message, bundle_path, fields \\ []) do
    struct!(
      __MODULE__,
      Keyword.merge([state: state, message: message, bundle_path: bundle_path], fields)
    )
  end
end
