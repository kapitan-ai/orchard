defmodule OrchardCLI.Commands.ModelsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Governance.AuditLog
  alias Orchard.Models
  alias Orchard.Models.{RoutingPolicy, TenantModelAccess}
  alias Orchard.Repo
  alias OrchardCLI.Commands.Models, as: ModelsCmd

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # -- Local test helpers --

  defp create_model!(overrides) do
    suffix = System.unique_integer([:positive, :monotonic])

    attrs =
      Map.merge(
        %{
          model_id: "test-org/cli-model-#{suffix}",
          version: "main",
          state: :registered,
          format: "mlx",
          capabilities: ["chat"],
          tokenizer: %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
          artifact_uri: "file:///tmp/cli-model-#{suffix}",
          artifact_source_uri: "file:///tmp/cli-model-#{suffix}",
          artifact_sha256: String.duplicate("a", 64),
          artifact_size_bytes: 1024,
          resident_memory_bytes: 2048,
          kv_cache_bytes_per_token: 16,
          prefill_workspace_bytes_per_token: 8,
          max_context_tokens: 32_768,
          default_parameters: %{"temperature" => 0.7},
          runtime_requirements: %{"adapter" => "mlx_lm", "min_agent_capability" => "mlx"}
        },
        overrides
      )

    case Models.create_model(attrs) do
      {:ok, model} -> model
      {:error, cs} -> raise "create_model! failed: #{inspect(cs.errors)}"
    end
  end

  defp create_request!(overrides) do
    suffix = System.unique_integer([:positive, :monotonic])

    attrs =
      Map.merge(
        %{
          public_id: "req_cli_#{suffix}",
          endpoint: :chat_completions,
          tenant_id: Ecto.UUID.generate(),
          requested_model: "test@main",
          state: :received,
          stream: true,
          payload_capture_mode: :metadata,
          sampling_params: %{"temperature" => 0.7},
          response_format: %{"type" => "text"},
          input_tokens: 0,
          output_tokens: 0,
          reserved_output_tokens: 128,
          timeout_at: DateTime.utc_now() |> DateTime.add(120_000, :millisecond)
        },
        overrides
      )

    case Orchard.Requests.create_request(attrs) do
      {:ok, req} -> req
      {:error, cs} -> raise "create_request! failed: #{inspect(cs.errors)}"
    end
  end

  # -- Parsing and usage --

  describe "delete parsing" do
    test "missing identity shows usage" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete"])
      assert msg =~ "missing model identity"
      assert msg =~ "orchardctl models delete <model_id@version>"
    end

    test "too many args shows usage" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete", "a@b", "extra"])
      assert msg =~ "expected exactly one model identity"
      assert msg =~ "orchardctl models delete <model_id@version>"
    end

    test "identity without @ shows format error" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete", "org/model"])
      assert msg =~ "expected model identity in the form"
    end

    test "identity with empty version shows format error" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete", "org/model@"])
      assert msg =~ "expected model identity in the form"
    end

    test "identity with empty model_id shows format error" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete", "@v1"])
      assert msg =~ "expected model identity in the form"
    end
  end

  describe "group usage" do
    test "models without subcommand includes delete" do
      assert {:error, msg, 1} = ModelsCmd.run([])
      assert msg =~ "<import|list|delete|access|routing-policy>"
    end
  end

  # -- DB-backed delete behavior --

  describe "delete execution" do
    test "deletes retired model" do
      model = create_model!(%{model_id: "org/deletable", version: "v1", state: :retired})

      assert {:ok, msg} = ModelsCmd.run(["delete", "org/deletable@v1"])
      assert msg == "Deleted org/deletable@v1"

      assert Models.get_model_by_identity("org/deletable", "v1") == nil
      assert Repo.get(Orchard.Models.Model, model.id) == nil
    end

    test "unknown model returns not found" do
      assert {:error, msg, 1} = ModelsCmd.run(["delete", "no-such/model@v1"])
      assert msg =~ "model not found"
      assert msg =~ "no-such/model@v1"
    end

    test "non-retired model returns not-retired error" do
      _model = create_model!(%{model_id: "org/active-model", version: "v1", state: :active})

      assert {:error, msg, 1} = ModelsCmd.run(["delete", "org/active-model@v1"])
      assert msg =~ "only retired models can be deleted"
      assert msg =~ "org/active-model@v1"
    end

    test "model with non-terminal requests returns in-use error" do
      model = create_model!(%{model_id: "org/busy-model", version: "v1", state: :retired})

      _running =
        create_request!(%{
          model_id: model.id,
          requested_model: "org/busy-model@v1",
          state: :running
        })

      assert {:error, msg, 1} = ModelsCmd.run(["delete", "org/busy-model@v1"])
      assert msg =~ "1 non-terminal request(s) still reference it"

      # Model still exists
      assert Models.get_model_by_identity("org/busy-model", "v1") != nil
    end

    test "already-deleted model returns not found" do
      model = create_model!(%{model_id: "org/gone-model", version: "v1", state: :retired})
      {:ok, _} = Models.delete_model(model.id)

      assert {:error, msg, 1} = ModelsCmd.run(["delete", "org/gone-model@v1"])
      assert msg =~ "model not found"
    end
  end

  describe "tenant Model access commands" do
    test "command groups return focused lifecycle usage" do
      assert {:error, access_usage, 1} = ModelsCmd.run(["access"])
      assert access_usage =~ "models access grant"
      assert access_usage =~ "models access inspect"

      assert {:error, policy_usage, 1} = ModelsCmd.run(["routing-policy"])
      assert policy_usage =~ "models routing-policy create"
      assert policy_usage =~ "models routing-policy inspect"
    end

    test "SPEC.md §10.9 grants, inspects, disables, and revokes by Tenant slug" do
      tenant = create_tenant!("cli-access")
      model = create_model!(%{model_id: "org/access-model", version: "v1", state: :active})
      identity = "#{model.model_id}@#{model.version}"

      assert {:ok, message} =
               ModelsCmd.run(["access", "grant", identity, "--tenant", tenant.slug])

      assert message =~ "Granted #{identity}"
      assert message =~ "routing=defaults"

      assert {:ok, repeated} =
               ModelsCmd.run(["access", "grant", identity, "--tenant", tenant.slug])

      assert repeated =~ "Already granted"

      assert {:ok, inspected} =
               ModelsCmd.run(["access", "inspect", identity, "--tenant", tenant.id])

      assert inspected =~ "state=enabled"
      assert inspected =~ "routing=defaults"

      assert {:ok, listed} = ModelsCmd.run(["access", "list", "--tenant", tenant.slug])
      assert listed =~ identity

      assert {:ok, disabled} =
               ModelsCmd.run(["access", "disable", identity, "--tenant", tenant.slug])

      assert disabled =~ "Disabled"

      assert {:ok, already_disabled} =
               ModelsCmd.run(["access", "disable", identity, "--tenant", tenant.slug])

      assert already_disabled =~ "Already disabled"

      assert {:ok, revoked} =
               ModelsCmd.run(["access", "revoke", identity, "--tenant", tenant.slug])

      assert revoked =~ "Revoked"

      assert {:ok, not_granted} =
               ModelsCmd.run(["access", "revoke", identity, "--tenant", tenant.slug])

      assert not_granted =~ "No grant"
      refute Repo.get_by(TenantModelAccess, tenant_id: tenant.id, model_id: model.id)

      audits =
        Repo.all(from(audit in AuditLog, where: audit.target_type == "tenant_model_access"))

      assert length(audits) == 3
      assert Enum.all?(audits, &(&1.payload["surface"] == "orchardctl"))
    end

    test "requires exact Tenant and Model identities" do
      assert {:error, message, 1} =
               ModelsCmd.run(["access", "grant", "missing@v1", "--tenant", "missing"])

      assert message =~ "tenant not found"

      assert {:error, usage, 1} = ModelsCmd.run(["access", "grant", "missing@v1"])
      assert usage =~ "--tenant is required"
    end
  end

  describe "routing policy commands" do
    test "SPEC.md §10.9 creates Tenant and global policies and attaches one explicitly" do
      tenant = create_tenant!("cli-policy")
      model = create_model!(%{model_id: "org/policy-model", version: "v1", state: :active})

      assert {:ok, created} =
               ModelsCmd.run([
                 "routing-policy",
                 "create",
                 "--tenant",
                 tenant.slug,
                 "--name",
                 "loaded-only",
                 "--residency-preference",
                 "required_loaded",
                 "--max-cold-start-ms",
                 "0",
                 "--max-queue-wait-ms",
                 "800"
               ])

      policy = Repo.get_by!(RoutingPolicy, tenant_id: tenant.id, name: "loaded-only")
      assert created =~ policy.id
      assert created =~ "residency=required_loaded"

      assert {:ok, grant} =
               ModelsCmd.run([
                 "access",
                 "grant",
                 "#{model.model_id}@#{model.version}",
                 "--tenant",
                 tenant.slug,
                 "--routing-policy-id",
                 policy.id
               ])

      assert grant =~ "routing=#{policy.id}"

      assert {:ok, global_created} =
               ModelsCmd.run([
                 "routing-policy",
                 "create",
                 "--global",
                 "--name",
                 "shared-default",
                 "--residency-preference",
                 "allow_cold_load"
               ])

      assert global_created =~ "global"
      assert {:ok, global_list} = ModelsCmd.run(["routing-policy", "list", "--global"])
      assert global_list =~ "shared-default"
      assert {:ok, inspected} = ModelsCmd.run(["routing-policy", "inspect", "--id", policy.id])
      assert inspected =~ "loaded-only"
    end

    test "rejects another Tenant's policy without creating access" do
      tenant = create_tenant!("cli-policy-target")
      other = create_tenant!("cli-policy-owner")
      model = create_model!(%{model_id: "org/scoped-policy-model", version: "v1"})

      {:ok, _created} =
        ModelsCmd.run([
          "routing-policy",
          "create",
          "--tenant",
          other.slug,
          "--name",
          "private",
          "--residency-preference",
          "prefer_loaded"
        ])

      policy = Repo.get_by!(RoutingPolicy, tenant_id: other.id, name: "private")

      assert {:error, message, 1} =
               ModelsCmd.run([
                 "access",
                 "grant",
                 "#{model.model_id}@#{model.version}",
                 "--tenant",
                 tenant.slug,
                 "--routing-policy-id",
                 policy.id
               ])

      assert message =~ "routing_policy_scope_mismatch"
      refute Repo.get_by(TenantModelAccess, tenant_id: tenant.id, model_id: model.id)
    end
  end

  defp create_tenant!(prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    {:ok, tenant} = Governance.create_tenant(%{slug: "#{prefix}-#{suffix}", name: prefix})
    tenant
  end
end
