defmodule OrchardCLI.NodeIdentity.Store do
  @moduledoc false

  import Bitwise, only: [band: 2]

  alias Orchard.NodeEnrollment.PKI
  alias Orchard.TransportTLS.CertificateIdentity

  @directory_mode 0o700
  @file_mode 0o600
  @spec prepare(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare(root, bundle) do
    case load_current(root) do
      {:ok, material} -> ensure_bundle_match(material, bundle)
      {:error, :not_found} -> generate_and_publish(root, bundle)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec finalize(String.t(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def finalize(root, prepared, response) do
    with {:ok, current} <- load_current(root),
         :ok <- ensure_same_prepared_identity(current, prepared),
         :ok <- ensure_response_matches(current, response, []) do
      material =
        current
        |> Map.merge(%{
          generation_id: Ecto.UUID.generate(),
          state: "registered",
          certificate_identifier: response["certificate_identifier"],
          controller_certificate_identifier: response["controller_certificate_identifier"],
          controller_certificate_fingerprint: response["controller_certificate_fingerprint"],
          controller_certificate_pem: response["controller_certificate_pem"],
          node_certificate_pem: response["node_certificate_pem"],
          runtime_ca_certificate_pem: response["runtime_ca_certificate_pem"],
          controller_id: response["controller_id"],
          controller_uri_san: response["controller_uri_san"],
          node_uri_san: response["node_uri_san"],
          runtime_trust_spki_sha256: response["runtime_trust_spki_sha256"]
        })

      with {:ok, _published} <- publish_generation(root, material, :replace) do
        load_current(root)
      end
    end
  end

  @spec prepare_staged(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def prepare_staged(root, opts \\ []) do
    with {:ok, current} <- load_current(root),
         true <- current.state == "registered",
         {:error, :not_found} <- load_staged(root),
         {:ok, generated} <- PKI.generate_csr(current.cluster_id, current.node_id) do
      material =
        Map.merge(generated, %{
          generation_id: Ecto.UUID.generate(),
          state: "prepared",
          enrollment_id: current.enrollment_id,
          cluster_id: current.cluster_id,
          node_id: current.node_id,
          controller_id: current.controller_id,
          controller_uri_san: current.controller_uri_san,
          runtime_trust_spki_sha256: current.runtime_trust_spki_sha256,
          controller_certificate_identifier: nil,
          controller_certificate_fingerprint: nil,
          controller_certificate_pem: nil,
          certificate_identifier: nil,
          credential_generation_id: nil,
          node_certificate_pem: nil,
          runtime_ca_certificate_pem: nil
        })

      with {:ok, _published} <- publish_generation(root, material, :staged_initial, opts) do
        load_staged(root)
      end
    else
      {:ok, _staged} -> {:error, :node_identity_rotation_in_progress}
      false -> {:error, :node_identity_storage_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec finalize_staged(String.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def finalize_staged(root, prepared, response, opts \\ []) do
    with {:ok, staged} <- load_staged(root, opts),
         :ok <- ensure_same_prepared_identity(staged, prepared),
         :ok <- ensure_response_matches(staged, response, opts),
         {:ok, credential_generation_id} <-
           Ecto.UUID.cast(response["credential_generation_id"]) do
      material =
        staged
        |> Map.merge(%{
          generation_id: Ecto.UUID.generate(),
          state: "registered",
          credential_generation_id: credential_generation_id,
          certificate_identifier: response["certificate_identifier"],
          controller_certificate_identifier: response["controller_certificate_identifier"],
          controller_certificate_fingerprint: response["controller_certificate_fingerprint"],
          controller_certificate_pem: response["controller_certificate_pem"],
          node_certificate_pem: response["node_certificate_pem"],
          runtime_ca_certificate_pem: response["runtime_ca_certificate_pem"]
        })

      with {:ok, _published} <- publish_generation(root, material, :staged_replace, opts) do
        load_staged(root, opts)
      end
    else
      _other -> {:error, :node_identity_binding_mismatch}
    end
  end

  @spec load_staged(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | atom()}
  def load_staged(root, opts \\ []) do
    with :ok <- validate_private_directory(root),
         {:ok, root_stat} <- File.stat(root) do
      load_pointer(root, "staged", root_stat.uid, opts)
    else
      {:error, :enoent} -> {:error, :not_found}
      _other -> {:error, :node_identity_storage_invalid}
    end
  rescue
    _error -> {:error, :node_identity_storage_invalid}
  catch
    _kind, _reason -> {:error, :node_identity_storage_invalid}
  end

  @spec activate_staged(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def activate_staged(root, opts \\ []) do
    with {:ok, current} <- load_current(root, opts),
         {:ok, staged} <- load_staged(root, opts),
         true <- current.state == "registered" and staged.state == "registered",
         true <- same_stable_identity?(current, staged),
         :ok <- publish_pointer(root, "current", staged.generation_id, :replace),
         :ok <- remove_pointer(root, "staged") do
      {:ok, staged}
    else
      _other -> {:error, :node_identity_storage_invalid}
    end
  end

  @spec load_current(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | atom()}
  def load_current(root, opts \\ []) do
    case validate_private_directory(root) do
      :ok -> load_initialized_root(root, opts)
      {:error, :enoent} -> {:error, :not_found}
      _reason -> {:error, :node_identity_storage_invalid}
    end
  rescue
    _error -> {:error, :node_identity_storage_invalid}
  catch
    _kind, _reason -> {:error, :node_identity_storage_invalid}
  end

  defp load_initialized_root(root, opts) do
    case File.stat(root) do
      {:ok, root_stat} -> load_current_pointer(root, root_stat.uid, opts)
      _result -> {:error, :node_identity_storage_invalid}
    end
  end

  defp load_current_pointer(root, expected_uid, opts) do
    case read_pointer(root, "current", expected_uid) do
      {:ok, generation_id} -> load_generation(root, generation_id, expected_uid, opts)
      {:error, :enoent} -> missing_current_result(root, expected_uid)
      _reason -> {:error, :node_identity_storage_invalid}
    end
  end

  defp load_generation(root, generation_id, expected_uid, opts) do
    generation_root = Path.join([root, "generations", generation_id])

    with :ok <- validate_private_directory(generation_root, expected_uid),
         {:ok, material} <- read_generation(generation_root, expected_uid, opts),
         true <- material.generation_id == generation_id do
      {:ok, material}
    else
      _reason -> {:error, :node_identity_storage_invalid}
    end
  end

  defp missing_current_result(root, expected_uid) do
    if pristine_store?(root, expected_uid) do
      {:error, :not_found}
    else
      {:error, :node_identity_storage_invalid}
    end
  end

  defp pristine_store?(root, expected_uid) do
    case File.ls(root) do
      {:ok, []} ->
        true

      {:ok, ["generations"]} ->
        generations = Path.join(root, "generations")

        validate_private_directory(generations, expected_uid) == :ok and
          File.ls(generations) == {:ok, []}

      _result ->
        false
    end
  end

  defp generate_and_publish(root, bundle) do
    with {:ok, generated} <- PKI.generate_csr(bundle.cluster_id, bundle.node_id) do
      material =
        Map.merge(generated, %{
          generation_id: Ecto.UUID.generate(),
          state: "prepared",
          enrollment_id: bundle.enrollment_id,
          cluster_id: bundle.cluster_id,
          node_id: bundle.node_id,
          controller_id: bundle.controller_id,
          controller_uri_san: bundle.controller_uri_san,
          runtime_trust_spki_sha256: bundle.runtime_trust_spki_sha256,
          controller_certificate_identifier: nil,
          controller_certificate_fingerprint: nil,
          controller_certificate_pem: nil,
          certificate_identifier: nil,
          node_certificate_pem: nil,
          runtime_ca_certificate_pem: nil
        })

      with {:ok, _published} <- publish_generation(root, material, :initial) do
        load_current(root)
      end
    end
  end

  defp publish_generation(root, material, mode, opts \\ []) do
    staging_root = Path.join(root, ".staging-#{material.generation_id}")
    generation_root = Path.join([root, "generations", material.generation_id])

    with :ok <- prepare_root(root),
         :ok <- validate_publish_mode(root, mode),
         :ok <- create_private_directory(staging_root),
         :ok <- write_generation(staging_root, material),
         :ok <- sync_directory(staging_root),
         :ok <- File.rename(staging_root, generation_root),
         :ok <- sync_directory(Path.join(root, "generations")),
         :ok <- publish_generation_pointer(root, material.generation_id, mode),
         :ok <- after_pointer_publish(opts) do
      {:ok, material}
    else
      _reason -> cleanup_publish_failure(root, material)
    end
  rescue
    _error -> cleanup_publish_failure(root, material)
  catch
    _kind, _reason -> cleanup_publish_failure(root, material)
  end

  defp after_pointer_publish(opts) do
    case Keyword.get(opts, :after_pointer_publish) do
      callback when is_function(callback, 0) -> callback.()
      _other -> :ok
    end
  end

  defp prepare_root(root) do
    root_existed? = File.dir?(root)
    generations = Path.join(root, "generations")
    generations_existed? = File.dir?(generations)

    with :ok <- create_or_validate_private_directory(root),
         :ok <- sync_new_directory_entry(root, root_existed?),
         {:ok, root_stat} <- File.stat(root),
         :ok <- create_or_validate_private_directory(generations, root_stat.uid),
         :ok <- sync_new_directory_entry(generations, generations_existed?) do
      sync_directory(root)
    end
  end

  defp sync_new_directory_entry(_path, true), do: :ok
  defp sync_new_directory_entry(path, false), do: path |> Path.dirname() |> sync_directory()

  defp validate_publish_mode(root, :initial) do
    case File.lstat(Path.join(root, "current")) do
      {:error, :enoent} -> :ok
      _other -> {:error, :already_present}
    end
  end

  defp validate_publish_mode(root, :replace) do
    with {:ok, root_stat} <- File.stat(root) do
      validate_private_file(Path.join(root, "current"), root_stat.uid)
    end
  end

  defp validate_publish_mode(root, :staged_initial) do
    case File.lstat(Path.join(root, "staged")) do
      {:error, :enoent} -> :ok
      _other -> {:error, :already_present}
    end
  end

  defp validate_publish_mode(root, :staged_replace) do
    with {:ok, root_stat} <- File.stat(root) do
      validate_private_file(Path.join(root, "staged"), root_stat.uid)
    end
  end

  defp publish_generation_pointer(root, generation_id, :initial),
    do: publish_pointer(root, "current", generation_id, :initial)

  defp publish_generation_pointer(root, generation_id, :replace),
    do: publish_pointer(root, "current", generation_id, :replace)

  defp publish_generation_pointer(root, generation_id, :staged_initial),
    do: publish_pointer(root, "staged", generation_id, :initial)

  defp publish_generation_pointer(root, generation_id, :staged_replace),
    do: publish_pointer(root, "staged", generation_id, :replace)

  defp create_or_validate_private_directory(path, expected_uid \\ nil) do
    case File.lstat(path) do
      {:ok, _stat} -> validate_private_directory(path, expected_uid)
      {:error, :enoent} -> create_private_directory(path, expected_uid)
      _other -> {:error, :node_identity_storage_failed}
    end
  end

  defp create_private_directory(path, expected_uid \\ nil) do
    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, @directory_mode),
         :ok <- validate_private_directory(path, expected_uid) do
      :ok
    else
      _reason -> {:error, :node_identity_storage_failed}
    end
  end

  defp validate_private_directory(path, expected_uid \\ nil) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         true <- band(stat.mode, 0o777) == @directory_mode,
         true <- is_nil(expected_uid) or stat.uid == expected_uid do
      :ok
    else
      {:error, :enoent} -> {:error, :enoent}
      _reason -> {:error, :node_identity_storage_invalid}
    end
  end

  defp write_generation(root, material) do
    metadata =
      material
      |> Map.take([
        :generation_id,
        :state,
        :enrollment_id,
        :cluster_id,
        :node_id,
        :controller_id,
        :controller_uri_san,
        :controller_certificate_identifier,
        :controller_certificate_fingerprint,
        :node_uri_san,
        :runtime_trust_spki_sha256,
        :csr_fingerprint,
        :public_key_fingerprint,
        :certificate_identifier,
        :credential_generation_id
      ])
      |> Jason.encode!()

    files = %{
      "node-private-key.pem" => material.private_key_pem,
      "node-csr.pem" => material.csr_pem,
      "metadata.json" => metadata
    }

    files =
      if material.state == "registered" do
        Map.merge(files, %{
          "controller-certificate.pem" => material.controller_certificate_pem,
          "node-certificate.pem" => material.node_certificate_pem,
          "runtime-ca-certificate.pem" => material.runtime_ca_certificate_pem
        })
      else
        files
      end

    Enum.reduce_while(files, :ok, fn {filename, contents}, :ok ->
      case write_private_file(Path.join(root, filename), contents) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp publish_pointer(root, name, generation_id, :initial) do
    temporary = Path.join(root, ".#{name}-#{Ecto.UUID.generate()}")
    pointer = Path.join(root, name)

    with :ok <- write_private_file(temporary, generation_id <> "\n"),
         :ok <- File.ln(temporary, pointer),
         :ok <- File.rm(temporary),
         :ok <- sync_directory(root) do
      :ok
    else
      _reason ->
        File.rm(temporary)
        {:error, :node_identity_storage_failed}
    end
  end

  defp publish_pointer(root, name, generation_id, :replace) do
    temporary = Path.join(root, ".#{name}-#{Ecto.UUID.generate()}")
    pointer = Path.join(root, name)

    with :ok <- write_private_file(temporary, generation_id <> "\n"),
         :ok <- File.rename(temporary, pointer),
         :ok <- sync_directory(root) do
      :ok
    else
      _reason ->
        File.rm(temporary)
        {:error, :node_identity_storage_failed}
    end
  end

  defp write_private_file(path, contents) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} -> write_open_file(path, file, contents)
      {:error, _reason} -> {:error, :node_identity_storage_failed}
    end
  end

  defp write_open_file(path, file, contents) do
    write_result =
      with :ok <- File.chmod(path, @file_mode),
           :ok <- IO.binwrite(file, contents),
           :ok <- :file.sync(file) do
        :ok
      else
        _reason -> {:error, :node_identity_storage_failed}
      end

    close_result = File.close(file)

    if write_result == :ok and close_result == :ok do
      :ok
    else
      File.rm(path)
      {:error, :node_identity_storage_failed}
    end
  end

  defp read_pointer(root, name, expected_uid) do
    pointer = Path.join(root, name)

    with :ok <- validate_private_file(pointer, expected_uid),
         {:ok, contents} <- File.read(pointer) do
      contents
      |> String.trim()
      |> Ecto.UUID.cast()
    end
  end

  defp read_generation(root, expected_uid, opts) do
    with {:ok, metadata_json} <- read_private_file(root, "metadata.json", expected_uid),
         {:ok, metadata} <- Jason.decode(metadata_json),
         {:ok, private_key_pem} <-
           read_private_file(root, "node-private-key.pem", expected_uid),
         {:ok, csr_pem} <- read_private_file(root, "node-csr.pem", expected_uid),
         {:ok, certificate_fields} <- read_certificate_fields(root, metadata, expected_uid),
         material <-
           generation_material(metadata, private_key_pem, csr_pem, certificate_fields),
         :ok <- validate_generation(material, opts) do
      {:ok, material}
    end
  end

  defp generation_material(metadata, private_key_pem, csr_pem, certificate_fields) do
    %{
      generation_id: metadata["generation_id"],
      state: metadata["state"],
      enrollment_id: metadata["enrollment_id"],
      cluster_id: metadata["cluster_id"],
      node_id: metadata["node_id"],
      controller_id: metadata["controller_id"],
      controller_uri_san: metadata["controller_uri_san"],
      controller_certificate_identifier: metadata["controller_certificate_identifier"],
      controller_certificate_fingerprint: metadata["controller_certificate_fingerprint"],
      node_uri_san: metadata["node_uri_san"],
      runtime_trust_spki_sha256: metadata["runtime_trust_spki_sha256"],
      csr_fingerprint: metadata["csr_fingerprint"],
      public_key_fingerprint: metadata["public_key_fingerprint"],
      certificate_identifier: metadata["certificate_identifier"],
      credential_generation_id: metadata["credential_generation_id"],
      private_key_pem: private_key_pem,
      csr_pem: csr_pem,
      controller_certificate_pem: certificate_fields.controller_certificate_pem,
      node_certificate_pem: certificate_fields.node_certificate_pem,
      runtime_ca_certificate_pem: certificate_fields.runtime_ca_certificate_pem
    }
  end

  defp validate_generation(%{state: "prepared"} = material, _opts) do
    with true <- is_nil(material.controller_certificate_identifier),
         true <- is_nil(material.controller_certificate_fingerprint),
         true <- is_nil(material.controller_certificate_pem),
         true <- is_nil(material.certificate_identifier),
         true <- is_nil(material.node_certificate_pem),
         true <- is_nil(material.runtime_ca_certificate_pem) do
      validate_local_identity(material)
    else
      _reason -> {:error, :node_identity_storage_invalid}
    end
  end

  defp validate_generation(%{state: "registered"} = material, opts) do
    authority_id = material.credential_generation_id || material.enrollment_id
    identity = PKI.certificate_identity(authority_id, material.csr_fingerprint)

    validation_attrs = %{
      certificate_identifier: material.certificate_identifier,
      certificate_serial: Integer.to_string(identity.serial),
      cluster_id: material.cluster_id,
      csr_fingerprint: material.csr_fingerprint,
      enrollment_id: authority_id,
      node_id: material.node_id,
      node_certificate_pem: material.node_certificate_pem,
      public_key_fingerprint: material.public_key_fingerprint,
      runtime_ca_certificate_pem: material.runtime_ca_certificate_pem,
      runtime_trust_spki_sha256: material.runtime_trust_spki_sha256
    }

    validation_attrs = maybe_put_now(validation_attrs, opts)

    with :ok <- validate_local_identity(material),
         :ok <- validate_controller_certificate(material),
         true <- material.certificate_identifier == identity.identifier,
         :ok <- PKI.validate_issued_identity(validation_attrs) do
      :ok
    else
      _reason -> {:error, :node_identity_storage_invalid}
    end
  end

  defp validate_generation(_material, _opts), do: {:error, :node_identity_storage_invalid}

  defp validate_controller_certificate(%{
         controller_certificate_identifier: nil,
         controller_certificate_fingerprint: nil,
         controller_certificate_pem: nil
       }),
       do: :ok

  defp validate_controller_certificate(material) do
    with {:ok, certificate} <-
           CertificateIdentity.from_pem(material.controller_certificate_pem),
         true <- material.controller_certificate_identifier == "serial:#{certificate.serial}",
         true <- material.controller_certificate_fingerprint == certificate.fingerprint,
         true <- certificate.uri_sans == [material.controller_uri_san],
         true <-
           CertificateIdentity.signed_by?(
             material.controller_certificate_pem,
             material.runtime_ca_certificate_pem
           ) do
      :ok
    else
      _reason -> {:error, :node_identity_storage_invalid}
    end
  end

  defp validate_local_identity(material) do
    with {:ok, derived} <-
           PKI.verify_local_identity(
             material.private_key_pem,
             material.csr_pem,
             material.cluster_id,
             material.node_id
           ),
         true <- derived.csr_fingerprint == material.csr_fingerprint,
         true <- derived.public_key_fingerprint == material.public_key_fingerprint,
         true <-
           derived.private_key_public_key_fingerprint == material.public_key_fingerprint,
         true <- derived.node_uri_san == material.node_uri_san do
      :ok
    else
      _reason -> {:error, :node_identity_storage_invalid}
    end
  end

  defp read_certificate_fields(root, %{"state" => "registered"}, expected_uid) do
    with {:ok, node_certificate_pem} <-
           read_private_file(root, "node-certificate.pem", expected_uid),
         {:ok, runtime_ca_certificate_pem} <-
           read_private_file(root, "runtime-ca-certificate.pem", expected_uid),
         {:ok, controller_certificate_pem} <-
           read_controller_certificate(root, expected_uid) do
      {:ok,
       %{
         controller_certificate_pem: controller_certificate_pem,
         node_certificate_pem: node_certificate_pem,
         runtime_ca_certificate_pem: runtime_ca_certificate_pem
       }}
    end
  end

  defp read_certificate_fields(_root, %{"state" => "prepared"}, _expected_uid) do
    {:ok,
     %{
       controller_certificate_pem: nil,
       node_certificate_pem: nil,
       runtime_ca_certificate_pem: nil
     }}
  end

  defp read_certificate_fields(_root, _metadata, _expected_uid) do
    {:error, :node_identity_storage_invalid}
  end

  defp read_controller_certificate(root, expected_uid) do
    case read_private_file(root, "controller-certificate.pem", expected_uid) do
      {:ok, certificate} -> {:ok, certificate}
      {:error, :enoent} -> {:ok, nil}
      _other -> {:error, :node_identity_storage_invalid}
    end
  end

  defp read_private_file(root, filename, expected_uid) do
    path = Path.join(root, filename)

    with :ok <- validate_private_file(path, expected_uid) do
      File.read(path)
    end
  end

  defp validate_private_file(path, expected_uid) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         true <- stat.uid == expected_uid,
         true <- band(stat.mode, 0o777) == @file_mode do
      :ok
    else
      {:error, :enoent} -> {:error, :enoent}
      _reason -> {:error, :node_identity_storage_invalid}
    end
  end

  defp ensure_bundle_match(material, bundle) do
    if material.enrollment_id == bundle.enrollment_id and
         material.cluster_id == bundle.cluster_id and
         material.node_id == bundle.node_id and
         material.controller_id == bundle.controller_id and
         material.controller_uri_san == bundle.controller_uri_san and
         material.runtime_trust_spki_sha256 == bundle.runtime_trust_spki_sha256 do
      {:ok, material}
    else
      {:error, :node_identity_binding_mismatch}
    end
  end

  defp ensure_same_prepared_identity(current, prepared) do
    identity_fields = [
      :generation_id,
      :enrollment_id,
      :cluster_id,
      :node_id,
      :controller_id,
      :controller_uri_san,
      :node_uri_san,
      :runtime_trust_spki_sha256,
      :csr_fingerprint,
      :public_key_fingerprint
    ]

    valid =
      current.state == "prepared" and prepared.state == "prepared" and
        Map.take(current, identity_fields) == Map.take(prepared, identity_fields)

    if valid, do: :ok, else: {:error, :node_identity_binding_mismatch}
  end

  defp ensure_response_matches(current, response, opts) do
    if response_bindings_match?(current, response) and
         response_certificate_valid?(current, response, opts) do
      :ok
    else
      {:error, :node_identity_binding_mismatch}
    end
  end

  defp response_bindings_match?(current, response) do
    expected = %{
      "cluster_id" => current.cluster_id,
      "controller_id" => current.controller_id,
      "controller_uri_san" => current.controller_uri_san,
      "node_id" => current.node_id,
      "node_uri_san" => current.node_uri_san,
      "runtime_trust_spki_sha256" => current.runtime_trust_spki_sha256
    }

    Map.take(response, Map.keys(expected)) == expected and response_material_present?(response)
  end

  defp response_material_present?(response) do
    [
      response["certificate_identifier"],
      response["certificate_serial"],
      response["controller_certificate_identifier"],
      response["controller_certificate_fingerprint"],
      response["controller_certificate_pem"],
      response["node_certificate_pem"],
      response["runtime_ca_certificate_pem"]
    ]
    |> Enum.all?(&is_binary/1)
  end

  defp response_certificate_valid?(current, response, opts) do
    with {:ok, controller_certificate} <-
           CertificateIdentity.from_pem(response["controller_certificate_pem"]),
         true <-
           response["controller_certificate_identifier"] ==
             "serial:#{controller_certificate.serial}",
         true <-
           response["controller_certificate_fingerprint"] ==
             controller_certificate.fingerprint,
         true <- controller_certificate.uri_sans == [current.controller_uri_san],
         true <-
           CertificateIdentity.signed_by?(
             response["controller_certificate_pem"],
             response["runtime_ca_certificate_pem"]
           ) do
      attrs = %{
        certificate_identifier: response["certificate_identifier"],
        certificate_serial: response["certificate_serial"],
        cluster_id: current.cluster_id,
        csr_fingerprint: current.csr_fingerprint,
        enrollment_id: response["credential_generation_id"] || current.enrollment_id,
        node_id: current.node_id,
        node_certificate_pem: response["node_certificate_pem"],
        public_key_fingerprint: current.public_key_fingerprint,
        runtime_ca_certificate_pem: response["runtime_ca_certificate_pem"],
        runtime_trust_spki_sha256: current.runtime_trust_spki_sha256
      }

      attrs = maybe_put_now(attrs, opts)

      PKI.validate_issued_identity(attrs) == :ok
    else
      _other -> false
    end
  end

  defp load_pointer(root, name, expected_uid, opts) do
    case read_pointer(root, name, expected_uid) do
      {:ok, generation_id} -> load_generation(root, generation_id, expected_uid, opts)
      {:error, :enoent} -> {:error, :not_found}
      _other -> {:error, :node_identity_storage_invalid}
    end
  end

  defp maybe_put_now(attrs, opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> Map.put(attrs, :now, now)
      _other -> attrs
    end
  end

  defp remove_pointer(root, name) do
    path = Path.join(root, name)

    with {:ok, root_stat} <- File.stat(root),
         :ok <- validate_private_file(path, root_stat.uid),
         :ok <- File.rm(path),
         :ok <- sync_directory(root) do
      :ok
    else
      _other -> {:error, :node_identity_storage_failed}
    end
  end

  defp same_stable_identity?(left, right) do
    fields = [
      :enrollment_id,
      :cluster_id,
      :node_id,
      :controller_id,
      :controller_uri_san,
      :runtime_trust_spki_sha256
    ]

    Map.take(left, fields) == Map.take(right, fields)
  end

  defp cleanup_publish_failure(root, material) do
    root
    |> Path.join(".staging-#{material.generation_id}")
    |> File.rm_rf()

    unless pointer_references_generation?(root, "current", material.generation_id) or
             pointer_references_generation?(root, "staged", material.generation_id) do
      [root, "generations", material.generation_id]
      |> Path.join()
      |> File.rm_rf()
    end

    {:error, :node_identity_storage_failed}
  end

  defp pointer_references_generation?(root, name, generation_id) do
    case File.read(Path.join(root, name)) do
      {:ok, contents} -> String.trim(contents) == generation_id
      _result -> false
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, file} ->
        sync_result = :file.sync(file)
        close_result = :file.close(file)

        if sync_result == :ok and close_result == :ok do
          :ok
        else
          {:error, :node_identity_storage_failed}
        end

      {:error, _reason} ->
        {:error, :node_identity_storage_failed}
    end
  end
end
