defmodule Orchard.NodeCredentials do
  @moduledoc """
  Owns durable transport-neutral Node certificate authority generations.

  This context records public certificate authority only. It never receives or
  persists a Node private key and does not create runtime or scheduling authority.
  """

  import Ecto.Query

  alias Orchard.BeamDisconnectObligations
  alias Orchard.BeamPeerGrants.Grant
  alias Orchard.ControlPlane
  alias Orchard.Governance
  alias Orchard.Governance.AuditWriter
  alias Orchard.NodeCredentials.Generation
  alias Orchard.NodeEnrollment.PKI
  alias Orchard.Nodes.{Enrollment, Node}
  alias Orchard.NodeTrust
  alias Orchard.Repo
  alias Orchard.TransportTLS.CertificateIdentity

  @certificate_lifetime_days 90
  @renewal_lead_days 30
  @overlap_days 7
  @maximum_clock_uncertainty_seconds 300

  @type authority_error ::
          :node_credential_not_found
          | :node_credential_not_current
          | :node_credential_renewal_not_due
          | :node_credential_rotation_in_progress
          | :node_credential_clock_uncertainty_invalid
          | :node_credential_invalid

  @doc """
  Persists the initial public credential generation inside enrollment redemption.

  The caller owns the surrounding audit transaction.
  """
  @spec register_initial(Enrollment.t(), map(), map(), DateTime.t()) ::
          {:ok, Generation.t()} | {:error, term()}
  def register_initial(enrollment, response, csr, now) do
    attrs = generation_attrs(enrollment, response, csr, Ecto.UUID.generate(), 1, :current, now)

    with {:ok, generation} <- insert_generation(attrs),
         {:ok, _audit} <- audit(generation, "node_enrollment.credential_activated", now) do
      {:ok, generation}
    end
  end

  @spec current(Ecto.UUID.t(), keyword()) ::
          {:ok, Generation.t()} | {:error, authority_error()}
  def current(node_id, opts \\ []) do
    with {:ok, node_id} <- Ecto.UUID.cast(node_id),
         {:ok, uncertainty} <- clock_uncertainty(opts),
         %Generation{} = generation <- generation_by_state(node_id, :current),
         now = now(opts),
         :ok <- ensure_certainly_current(generation, now, uncertainty),
         :ok <- ensure_overlap_current(node_id, now, uncertainty) do
      {:ok, generation}
    else
      nil -> {:error, :node_credential_not_found}
      :error -> {:error, :node_credential_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec authorize_peer(Ecto.UUID.t(), String.t(), String.t(), keyword()) ::
          {:ok, Generation.t()} | {:error, authority_error()}
  def authorize_peer(node_id, certificate_identifier, certificate_fingerprint, opts \\ []) do
    with {:ok, node_id} <- Ecto.UUID.cast(node_id),
         {:ok, uncertainty} <- clock_uncertainty(opts),
         %Generation{} = generation <-
           accepted_generation(node_id, certificate_identifier, certificate_fingerprint),
         now = now(opts),
         :ok <- ensure_certainly_current(generation, now, uncertainty),
         :ok <- ensure_overlap_current(node_id, now, uncertainty) do
      {:ok, generation}
    else
      _reason -> {:error, :node_credential_not_current}
    end
  end

  @doc """
  Locks and verifies the exact accepted credential inside a caller-owned transaction.
  """
  @spec authorize_peer_in_transaction(Ecto.UUID.t(), String.t(), String.t(), keyword()) ::
          {:ok, Generation.t()} | {:error, authority_error()}
  def authorize_peer_in_transaction(
        node_id,
        certificate_identifier,
        certificate_fingerprint,
        opts
      )
      when is_list(opts) do
    with true <- Repo.in_transaction?(),
         {:ok, node_id} <- Ecto.UUID.cast(node_id),
         {:ok, uncertainty} <- clock_uncertainty(opts),
         %Generation{} = generation <-
           lock_accepted_generation(node_id, certificate_identifier, certificate_fingerprint),
         now = now(opts),
         :ok <- ensure_certainly_current(generation, now, uncertainty),
         :ok <- ensure_overlap_current(node_id, now, uncertainty) do
      {:ok, generation}
    else
      _reason -> {:error, :node_credential_not_current}
    end
  end

  @spec stage_renewal(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, Generation.t()} | {:error, term()}
  def stage_renewal(node_id, csr_pem, opts \\ []) when is_binary(csr_pem) do
    with :ok <- ControlPlane.authorize_write_path(:node_enrollment),
         {:ok, node_id} <- Ecto.UUID.cast(node_id),
         {:ok, uncertainty} <- clock_uncertainty(opts) do
      AuditWriter.transaction(fn ->
        stage_renewal_locked(node_id, csr_pem, uncertainty, opts)
      end)
      |> unwrap_transaction()
    end
  end

  @spec activate_staged(Ecto.UUID.t(), pos_integer(), keyword()) ::
          {:ok, Generation.t()} | {:error, term()}
  def activate_staged(node_id, generation, opts \\ [])
      when is_integer(generation) and generation > 0 do
    with :ok <- ControlPlane.authorize_write_path(:node_enrollment),
         {:ok, node_id} <- Ecto.UUID.cast(node_id),
         {:ok, uncertainty} <- clock_uncertainty(opts) do
      AuditWriter.transaction(fn ->
        activate_staged_locked(node_id, generation, uncertainty, opts)
      end)
      |> unwrap_transaction()
    end
  end

  @doc """
  Activates a staged credential inside a caller-owned audit transaction.

  This is the atomic composition seam for certificate-bound Peer Grant cutover.
  """
  @spec activate_staged_in_transaction(Ecto.UUID.t(), pos_integer(), keyword()) ::
          {:ok, Generation.t()} | {:error, term()}
  def activate_staged_in_transaction(node_id, generation, opts)
      when is_integer(generation) and generation > 0 and is_list(opts) do
    with true <- Repo.in_transaction?(),
         {:ok, node_id} <- Ecto.UUID.cast(node_id),
         {:ok, uncertainty} <- clock_uncertainty(opts) do
      activate_staged_locked(node_id, generation, uncertainty, opts)
      |> then(&{:ok, &1})
    else
      _other -> {:error, :node_credential_not_current}
    end
  end

  @spec revoke(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, [Generation.t()]} | {:error, term()}
  def revoke(node_id, reason, opts \\ []) when is_binary(reason) and reason != "" do
    with :ok <- ControlPlane.authorize_write_path(:node_enrollment),
         {:ok, node_id} <- Ecto.UUID.cast(node_id) do
      AuditWriter.transaction(fn -> revoke_locked(node_id, reason, opts) end)
      |> unwrap_transaction()
    end
  end

  @doc """
  Revokes credential and bound grant authority inside a caller-owned transaction.
  """
  @spec revoke_in_transaction(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, [Generation.t()]} | {:error, term()}
  def revoke_in_transaction(node_id, reason, opts)
      when is_binary(reason) and reason != "" and is_list(opts) do
    with true <- Repo.in_transaction?(),
         {:ok, node_id} <- Ecto.UUID.cast(node_id),
         %Node{} <- lock_node(node_id) do
      now = now(opts)

      case revoke_authority(node_id, reason, now, opts) do
        {:ok, revoked} -> {:ok, revoked}
        {:error, :node_credential_not_found} -> {:ok, []}
      end
    else
      _other -> {:error, :node_credential_invalid}
    end
  end

  defp stage_renewal_locked(node_id, csr_pem, uncertainty, opts) do
    now = now(opts)

    with %Node{} <- lock_node(node_id),
         %Generation{} = current <- lock_generation(node_id, :current),
         nil <- lock_generation(node_id, :staged),
         :ok <- ensure_certainly_current(current, now, uncertainty),
         :ok <- ensure_renewal_due(current, now, uncertainty),
         %Enrollment{} = enrollment <- lock_enrollment(current.enrollment_id),
         {:ok, csr} <- PKI.verify_csr(csr_pem, current.cluster_id, node_id),
         id = Ecto.UUID.generate(),
         identity = PKI.certificate_identity(id, csr.csr_fingerprint),
         {:ok, issued} <- issue_renewal(enrollment, csr_pem, identity, now),
         response =
           enrollment
           |> renewal_response(issued)
           |> Map.put("credential_generation_id", id),
         attrs =
           generation_attrs(
             enrollment,
             response,
             csr,
             id,
             current.generation + 1,
             :staged,
             now,
             overlap_end(now, current.not_after_at)
           ),
         {:ok, staged} <- insert_generation(attrs),
         {:ok, _audit} <- audit(staged, "node_enrollment.credential_staged", now) do
      staged
    else
      %Generation{} -> Repo.rollback(:node_credential_rotation_in_progress)
      nil -> Repo.rollback(:node_credential_not_found)
      {:error, reason} -> Repo.rollback(reason)
      _reason -> Repo.rollback(:node_credential_invalid)
    end
  end

  defp activate_staged_locked(node_id, generation, uncertainty, opts) do
    now = now(opts)

    with %Node{} <- lock_node(node_id),
         %Generation{} = current <- lock_generation(node_id, :current),
         %Generation{generation: ^generation} = staged <- lock_generation(node_id, :staged),
         :ok <- ensure_certainly_current(staged, now, uncertainty),
         :ok <- ensure_overlap_current(node_id, now, uncertainty),
         {:ok, _superseded} <- transition(current, :superseded, now, opts),
         {:ok, activated} <- transition(staged, :current, now, opts),
         {:ok, _audit} <- audit(activated, "node_enrollment.credential_activated", now) do
      activated
    else
      nil -> Repo.rollback(:node_credential_not_found)
      {:error, reason} -> Repo.rollback(reason)
      _reason -> Repo.rollback(:node_credential_not_current)
    end
  end

  defp revoke_locked(node_id, reason, opts) do
    now = now(opts)

    with %Node{} <- lock_node(node_id),
         {:ok, revoked} <- revoke_authority(node_id, reason, now, opts) do
      revoked
    else
      nil -> Repo.rollback(:node_credential_not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp revoke_authority(node_id, reason, now, opts) do
    case lock_authoritative_generations(node_id) do
      [] ->
        {:error, :node_credential_not_found}

      generations ->
        grants = lock_bound_grants(node_id, generations)
        revoked = revoke_generations(generations, reason, now, opts)
        revoke_grants(grants, generations, reason, now)
        {:ok, revoked}
    end
  end

  defp revoke_generations(generations, reason, now, opts) do
    Enum.map(generations, fn generation ->
      evidence = transition_evidence(opts) |> Map.put("reason", reason)
      {:ok, revoked} = transition(generation, :revoked, now, evidence)
      {:ok, _audit} = audit(revoked, "node_enrollment.credential_revoked", now)
      revoked
    end)
  end

  defp revoke_grants(grants, generations, reason, now) do
    credential_ids = Map.new(generations, &{&1.certificate_identifier, &1.id})

    Enum.each(grants, fn grant ->
      evidence = %{"reason" => reason, "source" => "credential_revocation"}

      {:ok, revoked} =
        grant
        |> Ecto.Changeset.change(
          state: :revoked,
          revoked_at: now,
          revocation_evidence: evidence
        )
        |> Repo.update()

      credential_id = Map.fetch!(credential_ids, grant.node_certificate_identifier)

      {:ok, _obligation} =
        BeamDisconnectObligations.enqueue_in_transaction(
          revoked,
          credential_id,
          "credential_revoked",
          now
        )
    end)
  end

  defp issue_renewal(enrollment, csr_pem, identity, now) do
    NodeTrust.issue_node_certificate(%{
      certificate_identifier: identity.identifier,
      cluster_id: enrollment.cluster_id,
      controller_id: enrollment.expected_controller_id,
      csr_pem: csr_pem,
      node_id: enrollment.node_id,
      now: now,
      serial: identity.serial,
      trust_authority_id: enrollment.trust_authority_id
    })
  end

  defp renewal_response(enrollment, issued) do
    %{
      "certificate_identifier" => issued.certificate_identifier,
      "certificate_serial" => issued.certificate_serial,
      "cluster_id" => enrollment.cluster_id,
      "controller_certificate_identifier" => issued.controller_certificate_identifier,
      "controller_certificate_fingerprint" => issued.controller_certificate_fingerprint,
      "controller_certificate_pem" => issued.controller_certificate_pem,
      "controller_id" => issued.controller_id,
      "controller_uri_san" => issued.controller_uri_san,
      "node_certificate_pem" => issued.certificate_pem,
      "node_id" => enrollment.node_id,
      "node_uri_san" => issued.node_uri_san,
      "not_after" => issued.not_after,
      "runtime_ca_certificate_pem" => issued.runtime_ca_certificate_pem,
      "runtime_trust_spki_sha256" => issued.runtime_trust_spki_sha256,
      "trust_authority_id" => issued.trust_authority_id
    }
  end

  defp generation_attrs(
         enrollment,
         response,
         csr,
         id,
         generation,
         state,
         now,
         overlap_ends_at \\ nil
       ) do
    {:ok, not_after, 0} = DateTime.from_iso8601(response["not_after"])
    {:ok, certificate} = CertificateIdentity.from_pem(response["node_certificate_pem"])

    %{
      id: id,
      node_id: enrollment.node_id,
      enrollment_id: enrollment.id,
      generation: generation,
      state: state,
      cluster_id: enrollment.cluster_id,
      controller_id: enrollment.expected_controller_id,
      trust_authority_id: enrollment.trust_authority_id,
      certificate_identifier: response["certificate_identifier"],
      certificate_fingerprint_sha256: certificate.fingerprint,
      csr_fingerprint_sha256: csr.csr_fingerprint,
      public_key_fingerprint_sha256: csr.public_key_fingerprint,
      certificate_result: response,
      issued_at: now,
      not_before_at: DateTime.add(now, -60, :second),
      not_after_at: not_after,
      renew_after_at: DateTime.add(not_after, -@renewal_lead_days, :day),
      staged_at: if(state == :staged, do: now),
      overlap_ends_at: overlap_ends_at,
      activated_at: if(state == :current, do: now),
      transition_evidence: %{
        "certificate_lifetime_days" => @certificate_lifetime_days,
        "clock_uncertainty_limit_seconds" => @maximum_clock_uncertainty_seconds,
        "renewal_lead_days" => @renewal_lead_days
      }
    }
  end

  defp transition(generation, state, now, opts_or_evidence) do
    evidence =
      if is_map(opts_or_evidence),
        do: opts_or_evidence,
        else: transition_evidence(opts_or_evidence)

    timestamps =
      case state do
        :current -> %{activated_at: now}
        :superseded -> %{superseded_at: now}
        :revoked -> %{revoked_at: now}
      end

    generation
    |> Generation.changeset(
      timestamps
      |> Map.put(:state, state)
      |> Map.put(:transition_evidence, evidence)
    )
    |> Repo.update()
  end

  defp insert_generation(attrs) do
    %Generation{}
    |> Generation.changeset(attrs)
    |> Repo.insert()
  end

  defp ensure_renewal_due(generation, now, uncertainty) do
    if DateTime.compare(DateTime.add(now, uncertainty, :second), generation.renew_after_at) in [
         :eq,
         :gt
       ] do
      :ok
    else
      {:error, :node_credential_renewal_not_due}
    end
  end

  defp ensure_certainly_current(generation, now, uncertainty) do
    certainly_after_start =
      DateTime.compare(DateTime.add(now, -uncertainty, :second), generation.not_before_at) != :lt

    certainly_before_expiry =
      DateTime.compare(DateTime.add(now, uncertainty, :second), generation.not_after_at) == :lt

    if generation.state in [:current, :staged] and certainly_after_start and
         certainly_before_expiry do
      :ok
    else
      {:error, :node_credential_not_current}
    end
  end

  defp ensure_overlap_current(node_id, now, uncertainty) do
    case generation_by_state(node_id, :staged) do
      nil ->
        :ok

      %Generation{overlap_ends_at: %DateTime{} = deadline} ->
        if DateTime.compare(DateTime.add(now, uncertainty, :second), deadline) == :lt,
          do: :ok,
          else: {:error, :node_credential_not_current}

      %Generation{} ->
        {:error, :node_credential_not_current}
    end
  end

  defp clock_uncertainty(opts) do
    uncertainty = Keyword.get(opts, :clock_uncertainty_seconds, 0)

    if is_integer(uncertainty) and uncertainty in 0..@maximum_clock_uncertainty_seconds do
      {:ok, uncertainty}
    else
      {:error, :node_credential_clock_uncertainty_invalid}
    end
  end

  defp accepted_generation(node_id, identifier, fingerprint) do
    Generation
    |> where([generation], generation.node_id == ^node_id)
    |> where([generation], generation.state in [:current, :staged])
    |> where([generation], generation.certificate_identifier == ^identifier)
    |> where([generation], generation.certificate_fingerprint_sha256 == ^fingerprint)
    |> Repo.one()
  end

  defp lock_accepted_generation(node_id, identifier, fingerprint) do
    Generation
    |> where([generation], generation.node_id == ^node_id)
    |> where([generation], generation.state in [:current, :staged])
    |> where([generation], generation.certificate_identifier == ^identifier)
    |> where([generation], generation.certificate_fingerprint_sha256 == ^fingerprint)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_bound_grants(node_id, generations) do
    identifiers = Enum.map(generations, & &1.certificate_identifier)

    Grant
    |> where([grant], grant.node_id == ^node_id)
    |> where([grant], grant.node_certificate_identifier in ^identifiers)
    |> where([grant], grant.state in [:pending_delivery, :staged, :active, :delivery_failed])
    |> order_by([grant], asc: grant.generation)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp generation_by_state(node_id, state) do
    Generation
    |> where([generation], generation.node_id == ^node_id and generation.state == ^state)
    |> Repo.one()
  end

  defp lock_generation(node_id, state) do
    Generation
    |> where([generation], generation.node_id == ^node_id and generation.state == ^state)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_authoritative_generations(node_id) do
    Generation
    |> where([generation], generation.node_id == ^node_id)
    |> where([generation], generation.state in [:current, :staged])
    |> order_by([generation], asc: generation.generation)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp lock_node(node_id) do
    Node
    |> where([node], node.id == ^node_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_enrollment(enrollment_id) do
    Enrollment
    |> where([enrollment], enrollment.id == ^enrollment_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp overlap_end(now, predecessor_not_after) do
    proposed = DateTime.add(now, @overlap_days, :day)

    if DateTime.compare(proposed, predecessor_not_after) == :lt,
      do: proposed,
      else: predecessor_not_after
  end

  defp transition_evidence(opts) do
    opts
    |> Keyword.get(:evidence, %{})
    |> Map.take(["request_id", "reason", "surface"])
  end

  defp audit(generation, action, now) do
    Governance.insert_cluster_audit_log(%{
      actor_type: "node",
      actor_id: generation.node_id,
      action: action,
      target_type: "node_credential_generation",
      target_id: generation.id,
      occurred_at: now,
      payload: %{
        "certificate_identifier" => generation.certificate_identifier,
        "generation" => generation.generation,
        "node_id" => generation.node_id,
        "state" => Atom.to_string(generation.state)
      }
    })
  end

  defp now(opts),
    do: opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
