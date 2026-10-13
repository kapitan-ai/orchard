defmodule Orchard.NodeAdmissionPreauthorizations do
  @moduledoc """
  Durable cluster admission mode and one-use Enrollment-scoped admission intent.

  This boundary owns preview digests, mutation-time revalidation, terminal
  preauthorization state, and the Controller-membership fence. It never treats
  a bundle field or process-local setting as admission authority.
  """

  import Ecto.Query

  alias Orchard.ControllerInstances
  alias Orchard.ControlPlane
  alias Orchard.DispatchCapacity
  alias Orchard.DispatchCapacity.Authority
  alias Orchard.Governance
  alias Orchard.Governance.{AuditLog, AuditWriter}
  alias Orchard.Nodes.{AdmissionMode, AdmissionPreauthorization, Enrollment, Node}
  alias Orchard.Repo

  @contract_version 1
  @digest_prefix "sha256-"
  @reason_codes [
    :admission_mode_disabled,
    :controller_membership_changed,
    :dispatch_capacity_changed,
    :preauthorization_expired,
    :preauthorization_revoked,
    :bound_admission_predicate_changed
  ]

  @type preview :: %{
          digest: String.t(),
          record: map(),
          warnings: [String.t()]
        }

  @spec get_mode() :: AdmissionMode.t() | nil
  def get_mode, do: Repo.get(AdmissionMode, true)

  @spec preview_mode_change(AdmissionMode.mode(), map()) ::
          {:ok, map()} | {:error, term()}
  def preview_mode_change(mode, attrs) when mode in [:manual, :enrollment_preauthorized] do
    with %AdmissionMode{} = current <- get_mode(),
         {:ok, actor} <- normalize_actor(attrs),
         {:ok, reason} <- required_text(value(attrs, :reason)) do
      intent = %{
        action: "node_admission.mode_changed",
        from: current.mode,
        to: mode,
        expected_version: current.version,
        actor_type: actor.type,
        actor_id: actor.id,
        reason: reason
      }

      {:ok, Map.put(intent, :digest, digest(intent))}
    else
      nil -> {:error, :node_admission_mode_missing}
      {:error, _reason} = error -> error
    end
  end

  def preview_mode_change(_mode, _attrs), do: {:error, :invalid_node_admission_mode}

  @spec change_mode(AdmissionMode.mode(), map(), keyword()) ::
          {:ok, AdmissionMode.t()} | {:error, term()}
  def change_mode(mode, attrs, opts \\ []) do
    with :ok <- ControlPlane.authorize_write_path(:node_admission_mode),
         {:ok, preview} <- preview_mode_change(mode, attrs),
         :ok <- confirm_digest(preview.digest, opts) do
      AuditWriter.transaction(fn -> change_mode_locked(mode, preview, opts) end)
      |> unwrap_transaction()
    end
  end

  @spec preview_issuance(map()) :: {:ok, preview()} | {:error, term()}
  def preview_issuance(attrs) when is_map(attrs) do
    with %AdmissionMode{} = mode <- get_mode(),
         %Authority{} = authority <- DispatchCapacity.get_authority(),
         {:ok, record} <- normalize_issuance(attrs, mode, authority),
         :ok <- validate_preview_membership(record) do
      {:ok,
       %{
         digest: digest(record),
         record: record,
         warnings: [
           "The complete Enrollment Bundle is a one-time credential.",
           "The first valid holder may establish the allocated Node key and reach admission."
         ]
       }}
    else
      nil -> {:error, :node_admission_authority_missing}
      {:error, _reason} = error -> error
    end
  end

  @spec preview_to_map(preview()) :: map()
  def preview_to_map(preview) do
    %{
      "digest" => preview.digest,
      "record" =>
        Map.new(preview.record, fn
          {key, %DateTime{} = value} -> {Atom.to_string(key), DateTime.to_iso8601(value)}
          {key, value} when is_atom(value) -> {Atom.to_string(key), Atom.to_string(value)}
          {key, value} -> {Atom.to_string(key), value}
        end),
      "warnings" => preview.warnings
    }
  end

  @spec restore_preview(map()) :: {:ok, preview()} | {:error, term()}
  def restore_preview(%{"digest" => expected_digest, "record" => record})
      when is_binary(expected_digest) and is_map(record) do
    with {:ok, expires_at, 0} <- DateTime.from_iso8601(record["expires_at"] || ""),
         {:ok, attrs} <- restore_preview_attrs(record, expires_at),
         {:ok, preview} <- preview_issuance(attrs),
         true <- preview.digest == expected_digest do
      {:ok, preview}
    else
      _reason -> {:error, :invalid_node_admission_preauthorization_preview}
    end
  end

  def restore_preview(_preview), do: {:error, :invalid_node_admission_preauthorization_preview}

  @doc "Locks and revalidates a previously rendered issuance preview."
  @spec lock_issuance(preview()) :: {:ok, map()} | {:error, term()}
  def lock_issuance(%{digest: digest, record: record}) do
    with {:ok, authority} <- DispatchCapacity.lock_authority(),
         %AdmissionMode{} = mode <- lock_mode(),
         :ok <- ControllerInstances.lock_membership(),
         controllers <- ControllerInstances.lock_eligible_members(),
         :ok <- validate_locked_issuance(record, digest, authority, mode, controllers) do
      {:ok, %{authority: authority, mode: mode, controllers: controllers}}
    else
      nil -> {:error, :node_admission_mode_missing}
      {:error, _reason} = error -> error
    end
  end

  @doc "Persists the exact authorized intent inside the caller's issuance transaction."
  @spec insert_authorized(Enrollment.t(), preview(), map(), DateTime.t()) ::
          {:ok, AdmissionPreauthorization.t()} | {:error, term()}
  def insert_authorized(enrollment, preview, context, now) do
    record = preview.record
    id = record.id

    with :ok <- validate_enrollment_binding(enrollment, record),
         {:ok, %AuditLog{} = audit} <-
           Governance.insert_cluster_audit_log(%{
             actor_type: record.issuing_actor_type,
             actor_id: record.issuing_actor_id,
             action: "node_admission.preauthorization_issued",
             target_type: "node_admission_preauthorization",
             target_id: id,
             occurred_at: now,
             payload: issuance_audit_payload(record, preview.digest)
           }) do
      %AdmissionPreauthorization{}
      |> AdmissionPreauthorization.changeset(%{
        id: id,
        contract_version: @contract_version,
        cluster_id: enrollment.cluster_id,
        enrollment_id: enrollment.id,
        node_id: enrollment.node_id,
        issuing_controller_id: enrollment.expected_controller_id,
        issuing_actor_type: record.issuing_actor_type,
        issuing_actor_id: record.issuing_actor_id,
        issued_at: now,
        expires_at: record.expires_at,
        state: :authorized,
        pool_id: record.pool_id,
        pool_revision: record.pool_revision,
        routing_policy_id: record.routing_policy_id,
        routing_policy_revision: record.routing_policy_revision,
        controller_dispatch_ceiling: record.controller_dispatch_ceiling,
        capacity_policy_reason: record.capacity_policy_reason,
        dispatch_capacity_phase: context.authority.enforcement_phase,
        dispatch_capacity_revision: context.authority.required_contract_version,
        admission_mode_revision: context.mode.version,
        bound_predicates: record.bound_predicates,
        preview_digest: preview.digest,
        confirmation_evidence: record.confirmation_evidence,
        issuance_audit_log_id: audit.id
      })
      |> Repo.insert()
    end
  end

  @spec fetch(Ecto.UUID.t()) ::
          {:ok, AdmissionPreauthorization.t()} | {:error, :preauthorization_not_found}
  def fetch(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %AdmissionPreauthorization{} = preauthorization <-
           Repo.get(AdmissionPreauthorization, id) do
      {:ok, preauthorization}
    else
      _reason -> {:error, :preauthorization_not_found}
    end
  end

  @spec exists_for_enrollment?(Ecto.UUID.t()) :: boolean()
  def exists_for_enrollment?(enrollment_id) do
    from(preauthorization in AdmissionPreauthorization,
      where: preauthorization.enrollment_id == ^enrollment_id,
      select: 1
    )
    |> Repo.exists?()
  end

  @spec preview_revocation(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  def preview_revocation(id, attrs) do
    with {:ok, preauthorization} <- fetch(id),
         true <- preauthorization.state == :authorized,
         {:ok, actor} <- normalize_actor(attrs),
         {:ok, reason} <- required_text(value(attrs, :reason)) do
      intent = %{
        action: "node_admission.preauthorization_revoked",
        preauthorization_id: preauthorization.id,
        expected_lock_version: preauthorization.lock_version,
        actor_type: actor.type,
        actor_id: actor.id,
        reason: reason
      }

      {:ok, Map.put(intent, :digest, digest(intent))}
    else
      false -> {:error, :preauthorization_not_authorized}
      {:error, _reason} = error -> error
    end
  end

  @spec revoke(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, AdmissionPreauthorization.t()} | {:error, term()}
  def revoke(id, attrs, opts \\ []) do
    with :ok <- ControlPlane.authorize_write_path(:node_admission_preauthorization),
         {:ok, preview} <- preview_revocation(id, attrs),
         :ok <- confirm_digest(preview.digest, opts) do
      AuditWriter.transaction(fn -> revoke_locked(id, preview, opts) end)
      |> unwrap_transaction()
    end
  end

  @doc "Locks capacity, mode, and membership authority for redemption."
  @spec lock_redemption_authority() :: {:ok, map()} | {:error, term()}
  def lock_redemption_authority do
    with {:ok, authority} <- DispatchCapacity.lock_authority(),
         %AdmissionMode{} = mode <- lock_mode(),
         :ok <- ControllerInstances.lock_membership() do
      {:ok,
       %{
         authority: authority,
         mode: mode,
         controllers: ControllerInstances.lock_eligible_members()
       }}
    else
      nil -> {:error, :node_admission_mode_missing}
      {:error, _reason} = error -> error
    end
  end

  @doc "Locks the exact preauthorization after its Enrollment row is locked."
  @spec lock_for_enrollment(Ecto.UUID.t()) :: AdmissionPreauthorization.t() | nil
  def lock_for_enrollment(enrollment_id) do
    AdmissionPreauthorization
    |> where([preauthorization], preauthorization.enrollment_id == ^enrollment_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  @doc "Classifies a locked redemption as admitted, pending review, or rejected."
  @spec classify(AdmissionPreauthorization.t(), map(), map(), Node.t(), DateTime.t()) ::
          {:admit, map()} | {:pending_review, atom()} | {:error, atom()}
  def classify(preauthorization, context, request, node, now) do
    with :ok <- validate_request_binding(preauthorization, request),
         :ok <- validate_runtime_binding(preauthorization, node, request),
         :ok <- validate_current_authority(preauthorization, context, now) do
      {:admit, admission_attrs(preauthorization)}
    else
      {:pending_review, reason} when reason in @reason_codes -> {:pending_review, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Consumes a locked authorization after its admitted outcome is durable."
  @spec consume_admitted(AdmissionPreauthorization.t(), map(), DateTime.t()) ::
          {:ok, AdmissionPreauthorization.t()} | {:error, term()}
  def consume_admitted(preauthorization, execution, now) do
    consume(preauthorization, :consumed_admitted, :preauthorized_admission, execution, now)
  end

  @doc "Consumes or links a locked authorization to a pending-review outcome."
  @spec consume_pending_review(AdmissionPreauthorization.t(), atom(), map(), DateTime.t()) ::
          {:ok, AdmissionPreauthorization.t()} | {:error, term()}
  def consume_pending_review(preauthorization, reason, execution, now)
      when reason in @reason_codes do
    state = pending_state(preauthorization.state, reason)
    consume(preauthorization, state, reason, execution, now)
  end

  defp change_mode_locked(mode, preview, opts) do
    with {:ok, _authority} <- DispatchCapacity.lock_authority(),
         %AdmissionMode{} = current <- lock_mode(),
         true <- current.version == preview.expected_version,
         :ok <- ControllerInstances.lock_membership(),
         {:ok, audit} <-
           Governance.insert_cluster_audit_log(%{
             actor_type: preview.actor_type,
             actor_id: preview.actor_id,
             action: "node_admission.mode_changed",
             target_type: "node_admission_mode",
             target_id: "cluster",
             occurred_at: Keyword.get(opts, :now, DateTime.utc_now()),
             payload: %{
               "from" => Atom.to_string(current.mode),
               "to" => Atom.to_string(mode),
               "reason" => preview.reason,
               "preview_digest" => preview.digest
             }
           }),
         {:ok, updated} <-
           current
           |> AdmissionMode.change_changeset(%{
             mode: mode,
             version: current.version + 1,
             changed_by_actor_type: preview.actor_type,
             changed_by_actor_id: preview.actor_id,
             changed_at: Keyword.get(opts, :now, DateTime.utc_now()),
             change_reason: preview.reason
           })
           |> Repo.update() do
      _audit = audit
      updated
    else
      false -> Repo.rollback(:node_admission_mode_changed_since_preview)
      nil -> Repo.rollback(:node_admission_mode_missing)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp revoke_locked(id, preview, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, _authority} <- DispatchCapacity.lock_authority(),
         %AdmissionMode{} <- lock_mode(),
         :ok <- ControllerInstances.lock_membership(),
         %AdmissionPreauthorization{} = preauthorization <- lock_preauthorization(id),
         true <- preauthorization.state == :authorized,
         true <- preauthorization.lock_version == preview.expected_lock_version,
         {:ok, audit} <- terminal_audit(preauthorization, :preauthorization_revoked, preview, now),
         {:ok, revoked} <-
           update_terminal(preauthorization, :revoked, preview.reason, audit.id, nil, now) do
      revoked
    else
      false -> Repo.rollback(:preauthorization_changed_since_preview)
      nil -> Repo.rollback(:preauthorization_not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp consume(preauthorization, state, reason, execution, now) do
    action =
      if state == :consumed_admitted,
        do: :preauthorization_consumed_admitted,
        else: :preauthorization_consumed_pending_review

    payload = %{
      actor_type: "controller",
      actor_id: execution.controller_id,
      reason: Atom.to_string(reason),
      preview_digest: preauthorization.preview_digest
    }

    with {:ok, audit} <- terminal_audit(preauthorization, action, payload, now) do
      if preauthorization.state in [:revoked, :expired] do
        preauthorization
        |> AdmissionPreauthorization.changeset(%{
          outcome_reason: Atom.to_string(reason),
          executing_controller_id: execution.controller_id,
          redemption_csr_fingerprint: execution.csr_fingerprint,
          pending_review_audit_log_id: audit.id
        })
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update()
      else
        update_terminal(
          preauthorization,
          state,
          Atom.to_string(reason),
          audit.id,
          execution,
          now
        )
      end
    end
  end

  defp update_terminal(preauthorization, state, reason, audit_id, execution, now) do
    execution = execution || %{}

    preauthorization
    |> AdmissionPreauthorization.changeset(%{
      state: state,
      consumed_at: consumed_at(state, now),
      outcome_reason: reason,
      terminal_audit_log_id: audit_id,
      pending_review_audit_log_id: pending_review_audit_id(state, audit_id, execution),
      executing_controller_id: Map.get(execution, :controller_id),
      redemption_csr_fingerprint: Map.get(execution, :csr_fingerprint)
    })
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  end

  defp consumed_at(state, now) when state in [:consumed_admitted, :consumed_pending_review],
    do: now

  defp consumed_at(_state, _now), do: nil

  defp pending_review_audit_id(state, audit_id, execution)
       when state in [:revoked, :expired] and map_size(execution) > 0,
       do: audit_id

  defp pending_review_audit_id(_state, _audit_id, _execution), do: nil

  defp terminal_audit(preauthorization, action, attrs, now) do
    Governance.insert_cluster_audit_log(%{
      actor_type: value(attrs, :actor_type, "controller"),
      actor_id: value(attrs, :actor_id),
      action: "node_admission.#{action}",
      target_type: "node_admission_preauthorization",
      target_id: preauthorization.id,
      occurred_at: now,
      payload: %{
        "cluster_id" => preauthorization.cluster_id,
        "enrollment_id" => preauthorization.enrollment_id,
        "node_id" => preauthorization.node_id,
        "reason" => value(attrs, :reason),
        "preview_digest" => value(attrs, :preview_digest)
      }
    })
  end

  defp normalize_issuance(attrs, mode, authority) do
    with :ok <- require_enabled_mode(mode),
         {:ok, id} <- uuid(value(attrs, :id, Ecto.UUID.generate())),
         {:ok, enrollment_id} <- uuid(value(attrs, :enrollment_id)),
         {:ok, node_id} <- uuid(value(attrs, :node_id)),
         {:ok, cluster_id} <- uuid(value(attrs, :cluster_id)),
         {:ok, controller_id} <- uuid(value(attrs, :issuing_controller_id)),
         {:ok, actor} <- normalize_actor(attrs),
         {:ok, expires_at} <- datetime(value(attrs, :expires_at)),
         {:ok, pool_id} <- required_text(value(attrs, :pool_id)),
         {:ok, pool_revision} <- required_text(value(attrs, :pool_revision, "1")),
         {:ok, routing_policy_id} <- required_text(value(attrs, :routing_policy_id)),
         {:ok, routing_policy_revision} <-
           required_text(value(attrs, :routing_policy_revision, "1")),
         {:ok, ceiling} <- non_negative_integer(value(attrs, :controller_dispatch_ceiling, 1)),
         {:ok, reason} <- required_text(value(attrs, :capacity_policy_reason)),
         {:ok, confirmation_evidence} <- confirmation_evidence(attrs) do
      {:ok,
       %{
         id: id,
         contract_version: @contract_version,
         enrollment_id: enrollment_id,
         node_id: node_id,
         cluster_id: cluster_id,
         issuing_controller_id: controller_id,
         issuing_actor_type: actor.type,
         issuing_actor_id: actor.id,
         expires_at: expires_at,
         pool_id: pool_id,
         pool_revision: pool_revision,
         routing_policy_id: routing_policy_id,
         routing_policy_revision: routing_policy_revision,
         controller_dispatch_ceiling: ceiling,
         capacity_policy_reason: reason,
         dispatch_capacity_phase: authority.enforcement_phase,
         dispatch_capacity_revision: authority.required_contract_version,
         admission_mode_revision: mode.version,
         bound_predicates: normalize_map(value(attrs, :bound_predicates, %{})),
         confirmation_evidence: confirmation_evidence
       }}
    end
  end

  defp validate_enrollment_binding(enrollment, record) do
    valid =
      enrollment.id == record.enrollment_id and enrollment.node_id == record.node_id and
        enrollment.cluster_id == record.cluster_id and
        enrollment.expected_controller_id == record.issuing_controller_id and
        DateTime.compare(record.expires_at, enrollment.expires_at) in [:lt, :eq]

    if valid,
      do: :ok,
      else: {:error, :node_admission_preauthorization_enrollment_mismatch}
  end

  defp restore_preview_attrs(record, expires_at) do
    {:ok,
     %{
       id: record["id"],
       enrollment_id: record["enrollment_id"],
       node_id: record["node_id"],
       cluster_id: record["cluster_id"],
       issuing_controller_id: record["issuing_controller_id"],
       actor_type: record["issuing_actor_type"],
       actor_id: record["issuing_actor_id"],
       expires_at: expires_at,
       pool_id: record["pool_id"],
       pool_revision: record["pool_revision"],
       routing_policy_id: record["routing_policy_id"],
       routing_policy_revision: record["routing_policy_revision"],
       controller_dispatch_ceiling: record["controller_dispatch_ceiling"],
       capacity_policy_reason: record["capacity_policy_reason"],
       bound_predicates: record["bound_predicates"],
       confirmation_evidence: record["confirmation_evidence"]
     }}
  end

  defp confirmation_evidence(attrs) do
    evidence = normalize_map(value(attrs, :confirmation_evidence, %{}))

    if evidence["bundle_theft_consequence_confirmed"] == true,
      do: {:ok, evidence},
      else: {:error, :node_admission_preauthorization_confirmation_missing}
  end

  defp validate_preview_membership(record) do
    case eligible_controller_ids() do
      [controller_id] when controller_id == record.issuing_controller_id -> :ok
      _controllers -> {:error, :controller_membership_not_eligible_for_preauthorization}
    end
  end

  defp validate_locked_issuance(record, expected_digest, authority, mode, controllers) do
    current = %{
      record
      | dispatch_capacity_phase: authority.enforcement_phase,
        dispatch_capacity_revision: authority.required_contract_version,
        admission_mode_revision: mode.version
    }

    controller_ids = Enum.map(controllers, & &1.id)

    cond do
      mode.mode != :enrollment_preauthorized ->
        {:error, :node_admission_preauthorization_disabled}

      controller_ids != [record.issuing_controller_id] ->
        {:error, :controller_membership_changed_since_preview}

      current != record or digest(current) != expected_digest ->
        {:error, :node_admission_preauthorization_changed_since_preview}

      true ->
        :ok
    end
  end

  defp validate_request_binding(preauthorization, request) do
    supplied_id = Map.get(request, :preauthorization_id)
    supplied_digest = Map.get(request, :preauthorization_digest)

    if supplied_id == preauthorization.id and supplied_digest == preauthorization.preview_digest do
      :ok
    else
      {:error, :node_enrollment_rejected}
    end
  end

  defp validate_runtime_binding(preauthorization, node, request) do
    predicates = preauthorization.bound_predicates
    endpoint = request.runtime_endpoint

    matches =
      optional_match?(predicates, "hostname", node.hostname) and
        optional_match?(predicates, "runtime_host", endpoint.host) and
        optional_match?(predicates, "runtime_port", endpoint.port) and
        predicate_validator().(preauthorization, node, request) == :ok

    if matches, do: :ok, else: {:pending_review, :bound_admission_predicate_changed}
  end

  defp validate_current_authority(preauthorization, context, now) do
    checks = [
      state_authority(preauthorization),
      expiry_authority(preauthorization, now),
      mode_authority(preauthorization, context.mode),
      capacity_authority(preauthorization, context.authority),
      membership_authority(preauthorization, context.controllers)
    ]

    Enum.find(checks, :ok, &(&1 != :ok))
  end

  defp state_authority(%{state: :authorized}), do: :ok
  defp state_authority(%{state: :revoked}), do: {:pending_review, :preauthorization_revoked}
  defp state_authority(%{state: :expired}), do: {:pending_review, :preauthorization_expired}
  defp state_authority(_preauthorization), do: {:error, :node_enrollment_rejected}

  defp expiry_authority(preauthorization, now) do
    if DateTime.compare(now, preauthorization.expires_at) == :lt,
      do: :ok,
      else: {:pending_review, :preauthorization_expired}
  end

  defp mode_authority(preauthorization, mode) do
    if mode.mode == :enrollment_preauthorized and
         mode.version == preauthorization.admission_mode_revision,
       do: :ok,
       else: {:pending_review, :admission_mode_disabled}
  end

  defp capacity_authority(preauthorization, authority) do
    if authority.enforcement_phase == preauthorization.dispatch_capacity_phase and
         authority.required_contract_version == preauthorization.dispatch_capacity_revision,
       do: :ok,
       else: {:pending_review, :dispatch_capacity_changed}
  end

  defp membership_authority(preauthorization, controllers) do
    if Enum.map(controllers, & &1.id) == [preauthorization.issuing_controller_id],
      do: :ok,
      else: {:pending_review, :controller_membership_changed}
  end

  defp admission_attrs(preauthorization) do
    %{
      "pool_id" => preauthorization.pool_id,
      "pool_revision" => preauthorization.pool_revision,
      "routing_policy_id" => preauthorization.routing_policy_id,
      "routing_policy_revision" => preauthorization.routing_policy_revision,
      "trust_evidence_ref" => "node-certificate:#{preauthorization.enrollment_id}",
      "controller_dispatch_ceiling" => preauthorization.controller_dispatch_ceiling,
      "capacity_policy_reason" => preauthorization.capacity_policy_reason,
      "preauthorization_id" => preauthorization.id
    }
  end

  defp issuance_audit_payload(record, preview_digest) do
    %{
      "cluster_id" => record.cluster_id,
      "enrollment_id" => record.enrollment_id,
      "node_id" => record.node_id,
      "expires_at" => DateTime.to_iso8601(record.expires_at),
      "pool_id" => record.pool_id,
      "pool_revision" => record.pool_revision,
      "routing_policy_id" => record.routing_policy_id,
      "routing_policy_revision" => record.routing_policy_revision,
      "controller_dispatch_ceiling" => record.controller_dispatch_ceiling,
      "capacity_policy_reason" => record.capacity_policy_reason,
      "preview_digest" => preview_digest,
      "bundle_theft_consequence_confirmed" => true
    }
  end

  defp pending_state(:authorized, :preauthorization_expired), do: :expired
  defp pending_state(:authorized, _reason), do: :consumed_pending_review
  defp pending_state(state, _reason) when state in [:revoked, :expired], do: state

  defp lock_mode do
    AdmissionMode
    |> where([mode], mode.singleton == true)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_preauthorization(id) do
    AdmissionPreauthorization
    |> where([preauthorization], preauthorization.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp eligible_controller_ids do
    ControllerInstances.ControllerInstance
    |> where([instance], instance.status in [:enrolled, :operational])
    |> order_by([instance], asc: instance.id)
    |> select([instance], instance.id)
    |> Repo.all()
  end

  defp require_enabled_mode(%AdmissionMode{mode: :enrollment_preauthorized}), do: :ok

  defp require_enabled_mode(%AdmissionMode{}),
    do: {:error, :node_admission_preauthorization_disabled}

  defp normalize_actor(attrs) do
    with {:ok, type} <-
           required_text(value(attrs, :actor_type, value(attrs, :issuing_actor_type))),
         {:ok, id} <- required_text(value(attrs, :actor_id, value(attrs, :issuing_actor_id))) do
      {:ok, %{type: type, id: id}}
    end
  end

  defp confirm_digest(expected, opts) do
    if Keyword.get(opts, :confirmation_digest) == expected,
      do: :ok,
      else: {:error, :confirmation_digest_mismatch}
  end

  defp digest(value) do
    encoded = value |> canonical() |> :erlang.term_to_binary([:deterministic])
    @digest_prefix <> Base.url_encode64(:crypto.hash(:sha256, encoded), padding: false)
  end

  defp canonical(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, entry} -> {to_string(key), canonical(entry)} end)
    |> Enum.sort()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value

  defp predicate_validator do
    Application.get_env(
      :orchard_controller,
      :node_admission_preauthorization_predicate_validator,
      fn _preauthorization, _node, _request -> :ok end
    )
  end

  defp optional_match?(map, key, actual) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, expected} -> expected == actual
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_node_admission_preauthorization}
    end
  end

  defp datetime(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :microsecond)}
  defp datetime(_value), do: {:error, :invalid_node_admission_preauthorization}

  defp required_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_node_admission_preauthorization}
      text -> {:ok, text}
    end
  end

  defp required_text(_value), do: {:error, :invalid_node_admission_preauthorization}

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_value), do: {:error, :invalid_node_admission_preauthorization}

  defp normalize_map(value) when is_map(value) do
    Map.new(value, fn {key, entry} -> {to_string(key), entry} end)
  end

  defp normalize_map(_value), do: %{}

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
