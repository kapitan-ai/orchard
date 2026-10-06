defmodule Orchard.API.ModelsControllerTest do
  use Orchard.ConnCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Inference.ReasoningEffort
  alias Orchard.Models.Access
  alias Orchard.Models.ModelRenderAssets

  @artifact "48ba838e9c9c86b10ab68630ec0d8e1b6dfd760c98c2111432c56f94804d5af9"
  @template "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"

  setup do
    previous = Application.fetch_env!(:orchard_controller, :inference)
    root = Path.join(System.tmp_dir!(), unique_slug("effort-discovery"))
    File.mkdir!(root)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous,
        tokenizer_mode: :port,
        tokenizer_safe_mode: :off,
        tokenizer_executable: "/nonexistent/discovery-must-not-start-a-helper"
      )
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous)
      File.rm_rf!(root)
    end)

    %{bundle_root: root}
  end

  describe "GET /v1/models" do
    @describetag :db

    test "SPEC.md §7.2.7 returns 401 when bearer auth is missing" do
      conn = request_models(nil)

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["type"] == "authentication_error"
    end

    test "SPEC.md §7.2.3 returns empty list when the Tenant has no authorized active Models" do
      %{token: token} = create_direct_token!("models-empty")
      _ungranted = create_model!(%{state: :active})

      conn = request_models(token)
      body = Jason.decode!(conn.resp_body)

      assert conn.status == 200
      assert body == %{"object" => "list", "data" => []}
    end

    test "SPEC.md §7.2.3 returns OpenAI-shaped objects only for active granted Models" do
      %{tenant: tenant, token: token} = create_direct_token!("models-granted")

      model =
        create_model!(%{
          model_id: "llama-3.1-8b-instruct",
          version: "mlx-q4-v1",
          state: :active,
          artifact_uri: "file:///models/llama-3.1-8b"
        })

      assert {:ok, %{outcome: :created}} = Access.grant_model_access(tenant, model)

      conn = request_models(token)
      body = Jason.decode!(conn.resp_body)

      assert conn.status == 200
      assert body["object"] == "list"
      assert length(body["data"]) == 1

      [model_obj] = body["data"]
      assert model_obj["id"] == "llama-3.1-8b-instruct@mlx-q4-v1"
      assert model_obj["object"] == "model"
      assert is_integer(model_obj["created"])
      assert model_obj["owned_by"] == "local"

      refute Map.has_key?(model_obj, "artifact_source_uri")
      refute Map.has_key?(model_obj, "artifact_uri")
      refute Map.has_key?(model_obj, "artifact_sha256")
    end

    test "SPEC.md §7.2.3 excludes inactive, disabled, revoked, ungranted, and other-Tenant Models" do
      %{tenant: tenant, token: token} = create_direct_token!("models-scope-a")
      %{tenant: other_tenant, token: other_token} = create_direct_token!("models-scope-b")

      visible = create_model!(%{state: :active})
      inactive = create_model!(%{state: :retired})
      disabled = create_model!(%{state: :active})
      revoked = create_model!(%{state: :active})
      _ungranted = create_model!(%{state: :active})

      assert {:ok, _result} = Access.grant_model_access(tenant, visible)
      assert {:ok, _result} = Access.grant_model_access(tenant, inactive)
      assert {:ok, _result} = Access.grant_model_access(tenant, disabled)
      assert {:ok, _result} = Access.disable_model_access(tenant, disabled)
      assert {:ok, _result} = Access.grant_model_access(tenant, revoked)
      assert {:ok, _result} = Access.revoke_model_access(tenant, revoked)
      assert {:ok, _result} = Access.grant_model_access(other_tenant, disabled)

      assert model_ids(request_models(token)) == ["#{visible.model_id}@#{visible.version}"]

      assert model_ids(request_models(other_token)) == [
               "#{disabled.model_id}@#{disabled.version}"
             ]
    end

    test "SPEC.md §5.2 uses the same effective Tenant for direct and Service Account credentials" do
      %{tenant: tenant, token: direct_token} = create_direct_token!("models-principals")
      service_token = create_service_account_token!(tenant)
      model = create_model!(%{state: :active})

      assert {:ok, _result} = Access.grant_model_access(tenant, model)

      expected = ["#{model.model_id}@#{model.version}"]
      assert model_ids(request_models(direct_token)) == expected
      assert model_ids(request_models(service_token)) == expected
    end

    test "SPEC §7.2.3 discovery and binding share exact values, native mappings and default",
         ctx do
      %{tenant: tenant, token: token} = create_direct_token!("effort-visible")
      model = registered_model(ctx.bundle_root)
      grant_model_access!(tenant, model)
      [visible] = Jason.decode!(request_models(token).resp_body)["data"]
      effort = visible["orchard_reasoning_effort"]

      assert effort == %{
               "status" => "available",
               "supported_values" => ["high", "low", "medium", "xhigh"],
               "native_mapping" => %{
                 "low" => "low",
                 "medium" => "medium",
                 "high" => "xhigh",
                 "xhigh" => "xhigh"
               },
               "default" => "xhigh",
               "omission" => %{"behavior" => "preserve_model_default", "native_effort" => "xhigh"}
             }

      File.rm!(Path.join(ctx.bundle_root, "tool_capability_evidence.json"))
      {:ok, opts} = ModelRenderAssets.load(model)
      manifest = Keyword.fetch!(opts, :manifest)

      for value <- effort["supported_values"] do
        assert {:ok, reasoning} =
                 ReasoningEffort.resolve(
                   value,
                   model.artifact_sha256,
                   manifest.chat_template.sha256
                 )

        assert reasoning.effective_contract.native_effort == effort["native_mapping"][value]
      end

      assert {:error, :unsupported_reasoning_control} =
               ReasoningEffort.resolve(
                 "max",
                 model.artifact_sha256,
                 manifest.chat_template.sha256
               )

      refute Map.has_key?(visible, "artifact_uri")
      refute Map.has_key?(visible, "artifact_sha256")
      refute Map.has_key?(effort, "model_artifact_digest")

      %{token: other_token} = create_direct_token!("effort-hidden")
      assert model_ids(request_models(other_token)) == []
      Access.disable_model_access(tenant, model)
      assert model_ids(request_models(token)) == []
    end

    test "SPEC §7.2.3 unavailable proof or routes never fabricate effort support", ctx do
      %{tenant: tenant, token: token} = create_direct_token!("effort-unavailable")
      model = registered_model(ctx.bundle_root)
      grant_model_access!(tenant, model)

      previous = Application.fetch_env!(:orchard_controller, :inference)

      for overrides <- [
            tokenizer_mode: :fake,
            tokenizer_safe_mode: :on,
            tokenizer_safe_mode: :reject
          ] do
        Application.put_env(:orchard_controller, :inference, Keyword.merge(previous, [overrides]))
        assert_unavailable(request_models(token))
      end

      Application.put_env(:orchard_controller, :inference, previous)

      manifest_path = Path.join(ctx.bundle_root, "manifest.json")
      original = File.read!(manifest_path)
      manifest = Jason.decode!(original)

      File.write!(
        manifest_path,
        Jason.encode!(put_in(manifest["chat_template"]["sha256"], String.duplicate("b", 64)))
      )

      assert_unavailable(request_models(token))
      File.write!(manifest_path, Jason.encode!(Map.delete(manifest, "chat_template")))
      assert_unavailable(request_models(token))

      for replacement <- [
            Map.put(manifest, "tokenizer", "not an object"),
            Map.put(manifest, "safe_tokenization", %{"control_tokens" => 1})
          ] do
        File.write!(manifest_path, Jason.encode!(replacement))
        assert_unavailable(request_models(token))
      end

      File.write!(manifest_path, "not JSON")
      assert_unavailable(request_models(token))
      File.rm!(manifest_path)
      assert_unavailable(request_models(token))
    end
  end

  defp registered_model(root) do
    model =
      create_model!(%{state: :active, artifact_uri: "file://#{root}", artifact_sha256: @artifact})

    manifest = %{
      "model_id" => model.model_id,
      "version" => model.version,
      "format" => "mlx",
      "artifact_layout" => "directory",
      "entrypoint" => "weights/",
      "capabilities" => ["chat"],
      "tokenizer" => model.tokenizer,
      "chat_template" => %{"path" => "chat_template.jinja", "sha256" => @template},
      "runtime_requirements" => model.runtime_requirements
    }

    File.write!(Path.join(root, "manifest.json"), Jason.encode!(manifest))

    # An invalid sidecar would fail the preparation preflight; discovery reads no sidecar or helper.
    File.write!(Path.join(root, "tool_capability_evidence.json"), "not JSON")
    model
  end

  defp assert_unavailable(conn) do
    assert conn.status == 200
    [visible] = Jason.decode!(conn.resp_body)["data"]

    assert visible["orchard_reasoning_effort"] == %{
             "status" => "unavailable",
             "supported_values" => [],
             "native_mapping" => %{},
             "default" => nil,
             "omission" => %{"behavior" => "preserve_model_default", "native_effort" => nil}
           }
  end

  defp request_models(nil) do
    build_conn(:get, "/v1/models")
    |> put_req_header("accept", "application/json")
    |> Router.call(Router.init([]))
  end

  defp request_models(token) do
    build_conn(:get, "/v1/models")
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(Router.init([]))
  end

  defp model_ids(conn) do
    conn.resp_body
    |> Jason.decode!()
    |> Map.fetch!("data")
    |> Enum.map(&Map.fetch!(&1, "id"))
  end

  defp create_direct_token!(prefix) do
    slug = unique_slug(prefix)
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})
    {:ok, %{token: token}} = Governance.create_api_key(tenant.id, %{name: "Primary"})
    %{tenant: tenant, token: token}
  end

  defp create_service_account_token!(tenant) do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "models-client-#{System.unique_integer([:positive])}",
        owner_contact: "owner@example.com"
      })

    {:ok, _role_binding} = Governance.ensure_inference_client_access(api_client, tenant)

    {:ok, %{token: token}} =
      Governance.create_api_client_api_token(api_client, %{name: "Primary"})

    token
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
