defmodule Orchard.NodeEnrollments do
  @moduledoc """
  Creates and reads durable Node Enrollment records.
  """

  import Ecto.Query

  alias Orchard.ControlPlane
  alias Orchard.Governance
  alias Orchard.NodeEnrollment.PKI
  alias Orchard.Nodes, as: NodeInventory
  alias Orchard.Nodes.{Enrollment, EnrollmentToken, Node}
  alias Orchard.NodeTrust
  alias Orchard.Repo

  @sensitive_audit_key_fragments [
    "credential",
    "dsn",
    "password",
    "private_key",
    "secret",
    "token"
  ]
  @resume_window_seconds 600
  @pending_publication_stale_after_seconds 300
  @pending_publication_reconcile_limit 100

  @type creation_result :: %{
          bootstrap_token: String.t(),
          enrollment: Enrollment.t()
        }

  @spec create(map(), keyword()) :: {:ok, creation_result()} | {:error, term()}
  def create(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with :ok <- ControlPlane.authorize_write_path(:node_enrollment) do
      create_authorized(attrs, opts)
    end
  end

  @spec fetch(Ecto.UUID.t()) :: {:ok, Enrollment.t()} | {:error, :enrollment_not_found}
  def fetch(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Enrollment{} = enrollment <- Repo.get(Enrollment, id) do
      {:ok, Repo.preload(enrollment, :node)}
    else
      _reason -> {:error, :enrollment_not_found}
    end
  end

  @spec mark_output_failed(Ecto.UUID.t(), keyword()) ::
          {:ok, Enrollment.t()}
          | {:error, :enrollment_not_found | :invalid_enrollment_state | term()}
  def mark_output_failed(id, opts \\ []) when is_list(opts) do
    with :ok <- ControlPlane.authorize_write_path(:node_enrollment),
         {:ok, id} <- cast_enrollment_id(id) do
      mark_output_failed_transaction(id, opts)
    end
  end

  @spec mark_issued(Ecto.UUID.t(), keyword()) ::
          {:ok, Enrollment.t()}
          | {:error, :enrollment_not_found | :invalid_enrollment_state | term()}
  def mark_issued(id, opts \\ []) when is_list(opts) do
    with :ok <- ControlPlane.authorize_write_path(:node_enrollment),
         {:ok, id} <- cast_enrollment_id(id) do
      mark_issued_transaction(id, opts)
    end
  end

  @spec reconcile_stale_pending_publications(keyword()) ::
          {:ok, %{reconciled: non_neg_integer()}} | {:error, term()}
  def reconcile_stale_pending_publications(opts \\ []) when is_list(opts) do
    with :ok <- ControlPlane.authorize_write_path(:node_enrollment) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      stale_after_seconds =
        Keyword.get(opts, :stale_after_seconds, @pending_publication_stale_after_seconds)

      limit = Keyword.get(opts, :limit, @pending_publication_reconcile_limit)
      cutoff = DateTime.add(now, -stale_after_seconds, :second)

      reconcile_pending_transaction(cutoff, now, limit)
    end
  end

  @spec redeem(Ecto.UUID.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def redeem(id, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with :ok <- ControlPlane.authorize_write_path(:node_enrollment),
         {:ok, id} <- cast_enrollment_id(id),
         {:ok, request} <- normalize_redemption(attrs) do
      redeem_transaction(id, request, opts)
    end
  end

  defp create_authorized(attrs, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    enrollment_id = Ecto.UUID.generate()
    node_id = Ecto.UUID.generate()
    generated_token = EnrollmentToken.generate()

    Repo.transaction(fn ->
      with {:ok, node} <- insert_provisioned_node(node_id, value(attrs, :node)),
           {:ok, enrollment} <-
             insert_enrollment(
               enrollment_id,
               node,
               attrs,
               now,
               generated_token
             ),
           {:ok, _audit} <- insert_pending_publication_audit(enrollment, attrs, now) do
        %{
          enrollment: Repo.preload(enrollment, :node),
          bootstrap_token: generated_token.bootstrap_token
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  defp redeem_transaction(id, request, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.transaction(fn ->
      with %Enrollment{} = enrollment <- lock_enrollment(id),
           %Node{} = node <- lock_node(enrollment.node_id) do
        redeem_locked(enrollment, node, request, now, opts)
      else
        _reason -> Repo.rollback(:node_enrollment_rejected)
      end
    end)
    |> unwrap_transaction()
  end

  defp redeem_locked(enrollment, node, request, now, opts) do
    with :ok <- validate_redemption_bindings(enrollment, request),
         true <- EnrollmentToken.verify(request.token, enrollment.token_hash) do
      redeem_state(enrollment, node, request, now, opts)
    else
      _reason -> Repo.rollback(:node_enrollment_rejected)
    end
  end

  defp redeem_state(%Enrollment{state: :issued} = enrollment, node, request, now, opts) do
    with :ok <- validate_first_redemption(enrollment, node, now),
         :ok <- run_fault_checkpoint(opts, :before_token_consumption),
         {:ok, pending} <- persist_pending_consumption(enrollment, request, now),
         :ok <-
           run_fault_checkpoint(opts, :after_token_consumption_before_certificate_issuance),
         {:ok, response} <- issue_redemption_certificate(pending, request, now),
         {:ok, updated} <- persist_issued_certificate(pending, response),
         {:ok, registered_node} <- register_node(node, request.runtime_endpoint, now),
         {:ok, _candidate} <-
           NodeInventory.ensure_pending_admission_candidate(registered_node),
         {:ok, _audit} <- insert_consumed_audit(updated, response, now, opts) do
      response
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp redeem_state(
         %Enrollment{state: :consumed} = enrollment,
         _node,
         request,
         now,
         _opts
       ) do
    if valid_resume?(enrollment, request, now) do
      enrollment.certificate_result
    else
      Repo.rollback(:node_enrollment_rejected)
    end
  end

  defp redeem_state(_enrollment, _node, _request, _now, _opts) do
    Repo.rollback(:node_enrollment_rejected)
  end

  defp valid_resume?(enrollment, request, now) do
    metadata = enrollment.resume_verifier_metadata

    with resume_until_text when is_binary(resume_until_text) <- metadata["resume_until"],
         {:ok, resume_until, 0} <- DateTime.from_iso8601(resume_until_text) do
      DateTime.compare(now, resume_until) == :lt and
        enrollment.certificate_issuance_outcome == :issued and
        enrollment.csr_fingerprint == request.csr.csr_fingerprint and
        metadata["csr_fingerprint"] == request.csr.csr_fingerprint and
        metadata["public_key_fingerprint"] == request.csr.public_key_fingerprint and
        map_size(enrollment.certificate_result) > 0
    else
      _reason -> false
    end
  end

  defp validate_first_redemption(enrollment, node, now) do
    valid =
      DateTime.compare(enrollment.expires_at, now) == :gt and node.state == :provisioned

    if valid, do: :ok, else: {:error, :node_enrollment_rejected}
  end

  defp run_fault_checkpoint(opts, checkpoint) do
    case Keyword.get(opts, :test_fault_injector) do
      injector when is_function(injector, 1) ->
        injector.(checkpoint)
        :ok

      _other ->
        :ok
    end
  end

  defp issue_redemption_certificate(enrollment, request, now) do
    identity = PKI.certificate_identity(enrollment.id, request.csr.csr_fingerprint)

    with {:ok, issued} <-
           NodeTrust.issue_node_certificate(%{
             certificate_identifier: identity.identifier,
             cluster_id: enrollment.cluster_id,
             controller_id: enrollment.expected_controller_id,
             csr_pem: request.csr_pem,
             node_id: enrollment.node_id,
             now: now,
             serial: identity.serial,
             trust_authority_id: enrollment.trust_authority_id
           }) do
      {:ok,
       %{
         "certificate_identifier" => issued.certificate_identifier,
         "certificate_serial" => issued.certificate_serial,
         "cluster_id" => enrollment.cluster_id,
         "controller_id" => issued.controller_id,
         "controller_uri_san" => issued.controller_uri_san,
         "node_certificate_pem" => issued.certificate_pem,
         "node_id" => enrollment.node_id,
         "node_uri_san" => issued.node_uri_san,
         "not_after" => issued.not_after,
         "runtime_ca_certificate_pem" => issued.runtime_ca_certificate_pem,
         "runtime_trust_spki_sha256" => issued.runtime_trust_spki_sha256,
         "trust_authority_id" => issued.trust_authority_id
       }}
    end
  end

  defp persist_pending_consumption(enrollment, request, now) do
    enrollment
    |> Enrollment.changeset(%{
      state: :consumed,
      consumed_at: now,
      csr_fingerprint: request.csr.csr_fingerprint,
      resume_verifier_metadata: resume_verifier_metadata(enrollment, request, now),
      certificate_issuance_outcome: :pending
    })
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp persist_issued_certificate(enrollment, response) do
    enrollment
    |> Enrollment.changeset(%{
      certificate_issuance_outcome: :issued,
      certificate_identifier: response["certificate_identifier"],
      certificate_result: response
    })
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp resume_verifier_metadata(enrollment, request, now) do
    %{
      "algorithm" => "pkcs10-sha256",
      "csr_fingerprint" => request.csr.csr_fingerprint,
      "public_key_fingerprint" => request.csr.public_key_fingerprint,
      "resume_until" => enrollment |> resume_until(now) |> DateTime.to_iso8601(),
      "version" => 1
    }
  end

  defp register_node(
         %Node{id: node_id, state: :provisioned},
         %{host: host, hostname: hostname, port: port},
         now
       ) do
    query =
      from(node in Node,
        where: node.id == ^node_id and node.state == :provisioned
      )

    updates = [
      state: :registered,
      hostname: hostname,
      advertise_addr: host,
      rpc_port: port,
      connect_host: host,
      connect_port: port,
      updated_at: now
    ]

    case Repo.update_all(query, set: updates) do
      {1, nil} -> {:ok, Repo.get!(Node, node_id)}
      _result -> {:error, :node_enrollment_rejected}
    end
  end

  defp register_node(_node, _runtime_endpoint, _now),
    do: {:error, :node_enrollment_rejected}

  defp resume_until(enrollment, now) do
    proposed = DateTime.add(now, @resume_window_seconds, :second)

    if DateTime.compare(proposed, enrollment.expires_at) == :gt do
      enrollment.expires_at
    else
      proposed
    end
  end

  defp insert_consumed_audit(enrollment, response, now, opts) do
    Governance.insert_cluster_audit_log(%{
      actor_type: "node",
      actor_id: enrollment.node_id,
      action: "node_enrollment.consumed",
      target_type: "node_enrollment",
      target_id: enrollment.id,
      occurred_at: now,
      payload: %{
        "certificate_identifier" => response["certificate_identifier"],
        "cluster_id" => enrollment.cluster_id,
        "csr_fingerprint" => enrollment.csr_fingerprint,
        "node_id" => enrollment.node_id,
        "surface" => Keyword.get(opts, :surface, "bootstrap_https")
      }
    })
  end

  defp normalize_redemption(attrs) do
    with {:ok, node_id} <- cast_required_uuid(value(attrs, :node_id)),
         {:ok, cluster_id} <- cast_required_uuid(value(attrs, :cluster_id)),
         {:ok, controller_id} <- cast_required_uuid(value(attrs, :controller_id)),
         token when is_binary(token) <- value(attrs, :token),
         csr_pem when is_binary(csr_pem) <- value(attrs, :csr_pem),
         {:ok, csr} <- PKI.verify_csr(csr_pem, cluster_id, node_id),
         {:ok, runtime_endpoint} <- normalize_runtime_endpoint(value(attrs, :runtime_endpoint)) do
      {:ok,
       %{
         cluster_id: cluster_id,
         controller_id: controller_id,
         csr: csr,
         csr_pem: csr_pem,
         node_id: node_id,
         runtime_endpoint: runtime_endpoint,
         token: token
       }}
    else
      _reason -> {:error, :node_enrollment_rejected}
    end
  end

  defp normalize_runtime_endpoint(endpoint) when is_map(endpoint) do
    host = value(endpoint, :host)
    hostname = value(endpoint, :hostname)
    port = value(endpoint, :port)

    if valid_runtime_host?(host) and valid_runtime_hostname?(hostname) and
         valid_runtime_port?(port) do
      {:ok, %{host: host, hostname: hostname, port: port}}
    else
      {:error, :node_enrollment_rejected}
    end
  end

  defp normalize_runtime_endpoint(_endpoint), do: {:error, :node_enrollment_rejected}

  defp valid_runtime_host?(host) do
    is_binary(host) and host not in ["", "0.0.0.0", "::", "[::]"] and
      byte_size(host) <= 253 and not String.match?(host, ~r/[\s\/]/)
  end

  defp valid_runtime_hostname?(hostname) do
    is_binary(hostname) and hostname != "" and byte_size(hostname) <= 253 and
      not String.match?(hostname, ~r/[\s\/]/)
  end

  defp valid_runtime_port?(port), do: is_integer(port) and port in 1..65_535

  defp cast_required_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :node_enrollment_rejected}
    end
  end

  defp validate_redemption_bindings(enrollment, request) do
    valid =
      enrollment.node_id == request.node_id and
        enrollment.cluster_id == request.cluster_id and
        enrollment.expected_controller_id == request.controller_id

    if valid, do: :ok, else: {:error, :node_enrollment_rejected}
  end

  defp mark_output_failed_transaction(id, opts) do
    Repo.transaction(fn ->
      with {:ok, enrollment, changed?} <- mark_locked_output_failed(id, opts),
           {:ok, _audit} <- maybe_insert_output_failed_audit(enrollment, changed?, opts) do
        enrollment
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  defp reconcile_pending_transaction(cutoff, now, limit) do
    Repo.transaction(fn ->
      enrollments =
        Enrollment
        |> where([enrollment], enrollment.state == :pending_publication)
        |> where([enrollment], enrollment.issued_at <= ^cutoff)
        |> order_by([enrollment], asc: enrollment.issued_at, asc: enrollment.id)
        |> limit(^limit)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()

      Enum.each(enrollments, &reconcile_pending_enrollment(&1, now))

      %{reconciled: length(enrollments)}
    end)
    |> unwrap_transaction()
  end

  defp reconcile_pending_enrollment(enrollment, now) do
    with {:ok, failed} <- fail_pending_enrollment(enrollment, now),
         {:ok, _audit} <-
           insert_output_failed_audit(failed,
             actor_type: "system",
             actor_id: "pending-publication-reconciler",
             now: now,
             reason: "publication_confirmation_timeout"
           ) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp fail_pending_enrollment(enrollment, now) do
    enrollment
    |> Enrollment.changeset(%{state: :output_failed, output_failed_at: now})
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp mark_issued_transaction(id, opts) do
    Repo.transaction(fn ->
      with {:ok, enrollment, changed?} <- mark_locked_issued(id, opts),
           {:ok, _audit} <- maybe_insert_issued_audit(enrollment, changed?, opts) do
        enrollment
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  defp mark_locked_issued(id, opts) do
    case lock_enrollment(id) do
      nil ->
        {:error, :enrollment_not_found}

      %Enrollment{state: :issued} = enrollment ->
        {:ok, enrollment, false}

      %Enrollment{state: :pending_publication} = enrollment ->
        now = Keyword.get(opts, :now, DateTime.utc_now())

        enrollment
        |> Enrollment.changeset(%{state: :issued, published_at: now})
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, updated, true}
          {:error, reason} -> {:error, reason}
        end

      %Enrollment{} ->
        {:error, :invalid_enrollment_state}
    end
  end

  defp mark_locked_output_failed(id, opts) do
    case lock_enrollment(id) do
      nil ->
        {:error, :enrollment_not_found}

      %Enrollment{state: :output_failed} = enrollment ->
        {:ok, enrollment, false}

      %Enrollment{state: :pending_publication} = enrollment ->
        now = Keyword.get(opts, :now, DateTime.utc_now())

        fail_pending_enrollment(enrollment, now)
        |> case do
          {:ok, updated} -> {:ok, updated, true}
          {:error, reason} -> {:error, reason}
        end

      %Enrollment{} ->
        {:error, :invalid_enrollment_state}
    end
  end

  defp lock_enrollment(id) do
    Enrollment
    |> where([enrollment], enrollment.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_node(id) do
    Node
    |> where([node], node.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp insert_provisioned_node(node_id, node_attrs) do
    node_attrs = normalize_map(node_attrs)
    display_name = value(node_attrs, :display_name, "provisioned-#{String.slice(node_id, 0, 8)}")

    node_attrs =
      Map.merge(node_attrs, %{
        id: node_id,
        display_name: display_name,
        state: :provisioned,
        health: :unreachable,
        capabilities: %{},
        tool_readiness: %{}
      })

    %Node{}
    |> Node.provisioning_changeset(node_attrs)
    |> Repo.insert()
  end

  defp insert_enrollment(enrollment_id, node, attrs, now, generated_token) do
    %Enrollment{}
    |> Enrollment.changeset(%{
      id: enrollment_id,
      format_version: 1,
      node_id: node.id,
      cluster_id: value(attrs, :cluster_id),
      expected_controller_id: value(attrs, :expected_controller_id),
      trust_authority_id: value(attrs, :trust_authority_id),
      token_prefix: generated_token.token_prefix,
      token_hash: generated_token.token_hash,
      state: :pending_publication,
      creator_type: value(attrs, :creator_type),
      creator_id: value(attrs, :creator_id),
      issued_at: now,
      expires_at: value(attrs, :expires_at),
      resume_verifier_metadata: attrs |> value(:resume_verifier_metadata, %{}) |> normalize_map(),
      certificate_issuance_outcome: :not_started,
      certificate_result: %{},
      audit_metadata: attrs |> value(:audit_metadata, %{}) |> sanitize_audit_metadata()
    })
    |> Repo.insert()
  end

  defp insert_pending_publication_audit(enrollment, attrs, now) do
    Governance.insert_cluster_audit_log(%{
      actor_type: value(attrs, :creator_type, "operator"),
      actor_id: value(attrs, :creator_id),
      action: "node_enrollment.publication_pending",
      target_type: "node_enrollment",
      target_id: enrollment.id,
      occurred_at: now,
      payload: %{
        "cluster_id" => enrollment.cluster_id,
        "expires_at" => DateTime.to_iso8601(enrollment.expires_at),
        "node_id" => enrollment.node_id,
        "surface" => enrollment.audit_metadata["surface"]
      }
    })
  end

  defp maybe_insert_issued_audit(_enrollment, false, _opts), do: {:ok, :unchanged}

  defp maybe_insert_issued_audit(enrollment, true, opts) do
    Governance.insert_cluster_audit_log(%{
      actor_type: Keyword.get(opts, :actor_type, "operator"),
      actor_id: Keyword.get(opts, :actor_id),
      action: "node_enrollment.issued",
      target_type: "node_enrollment",
      target_id: enrollment.id,
      occurred_at: Keyword.get(opts, :now, DateTime.utc_now()),
      payload: %{
        "cluster_id" => enrollment.cluster_id,
        "expires_at" => DateTime.to_iso8601(enrollment.expires_at),
        "node_id" => enrollment.node_id,
        "surface" => enrollment.audit_metadata["surface"]
      }
    })
  end

  defp maybe_insert_output_failed_audit(_enrollment, false, _opts), do: {:ok, :unchanged}

  defp maybe_insert_output_failed_audit(enrollment, true, opts) do
    insert_output_failed_audit(enrollment, opts)
  end

  defp insert_output_failed_audit(enrollment, opts) do
    Governance.insert_cluster_audit_log(%{
      actor_type: Keyword.get(opts, :actor_type, "operator"),
      actor_id: Keyword.get(opts, :actor_id),
      action: "node_enrollment.output_failed",
      target_type: "node_enrollment",
      target_id: enrollment.id,
      occurred_at: Keyword.get(opts, :now, DateTime.utc_now()),
      payload: %{
        "cluster_id" => enrollment.cluster_id,
        "node_id" => enrollment.node_id,
        "reason" => Keyword.get(opts, :reason, "bundle_publication_failed")
      }
    })
  end

  defp cast_enrollment_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, cast_id} -> {:ok, cast_id}
      :error -> {:error, :enrollment_not_found}
    end
  end

  defp sanitize_audit_metadata(metadata) do
    metadata
    |> normalize_map()
    |> Enum.reduce(%{}, fn {key, entry}, sanitized ->
      key = to_string(key)

      if sensitive_audit_key?(key) do
        sanitized
      else
        Map.put(sanitized, key, sanitize_audit_value(entry))
      end
    end)
  end

  defp sanitize_audit_value(value) when is_map(value), do: sanitize_audit_metadata(value)

  defp sanitize_audit_value(value) when is_list(value),
    do: Enum.map(value, &sanitize_audit_value/1)

  defp sanitize_audit_value(value), do: value

  defp sensitive_audit_key?(key) do
    normalized = String.downcase(key)
    Enum.any?(@sensitive_audit_key_fragments, &String.contains?(normalized, &1))
  end

  defp value(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, found} -> found
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end

  defp normalize_map(nil), do: %{}
  defp normalize_map(value) when is_map(value), do: value

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
