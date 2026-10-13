alias Orchard.Governance
alias Orchard.Models.Access
alias Orchard.Models.Importer

usage = "usage: mix run scripts/kap112_setup_fixture.exs BUNDLE_DIR TOKEN_FILE"

proof_root =
  System.get_env("ORCHARD_KAP112_POC_ROOT")
  |> case do
    nil -> raise "ORCHARD_KAP112_POC_ROOT is required"
    value -> Path.expand(value)
  end

unless Mix.env() == :dev and System.get_env("ORCHARD_KAP112_DISPOSABLE_DB") == "1" do
  raise "KAP-112 fixture setup requires MIX_ENV=dev and ORCHARD_KAP112_DISPOSABLE_DB=1"
end

pg_port =
  case Integer.parse(System.get_env("PGPORT") || "") do
    {port, ""} when port in 1..65_535 -> port
    _other -> raise "KAP-112 fixture setup requires an explicit valid PGPORT"
  end

unless System.get_env("PGHOST") == "127.0.0.1" and
         System.get_env("PGDATABASE") == "orchard_kap112_poc" do
  raise "KAP-112 fixture setup requires the explicit loopback disposable database"
end

repo_config = Application.fetch_env!(:orchard_controller, Orchard.Repo)

unless repo_config[:hostname] == "127.0.0.1" and repo_config[:port] == pg_port and
         repo_config[:database] == "orchard_kap112_poc" do
  raise "configured Repo does not match the KAP-112 disposable database"
end

inside_proof_root? = fn path ->
  expanded = Path.expand(path)
  expanded == proof_root or String.starts_with?(expanded, proof_root <> "/")
end

{bundle_dir, token_file} =
  case System.argv() do
    [bundle_dir, token_file] -> {Path.expand(bundle_dir), Path.expand(token_file)}
    _args -> raise usage
  end

unless inside_proof_root?.(bundle_dir) and inside_proof_root?.(token_file) do
  raise "bundle and token paths must remain inside ORCHARD_KAP112_POC_ROOT"
end

artifacts_root = Path.join(proof_root, "artifacts")
reasoning_contract_path =
  System.get_env("ORCHARD_KAP112_REASONING_CONTRACT")
  |> case do
    nil -> raise "ORCHARD_KAP112_REASONING_CONTRACT is required"
    value -> Path.expand(value)
  end

unless inside_proof_root?.(reasoning_contract_path) do
  raise "KAP-112 reasoning contract must remain inside the proof root"
end

if File.exists?(token_file) or File.exists?(reasoning_contract_path) do
  raise "refusing to replace existing KAP-112 credential or reasoning contract"
end

with {:ok, model} <-
       Importer.import_bundle(bundle_dir,
         artifacts_root: artifacts_root,
         activate: true
       ),
     {:ok, tenant} <-
       Governance.create_tenant(%{
         slug: "kap112-poc",
         name: "KAP-112 disposable proof"
       }),
     {:ok, %{api_key: api_key, token: token}} <-
       Governance.create_api_key(tenant, %{name: "kap112-poc"}),
     {:ok, %{outcome: access_outcome}} <-
       Access.grant_model_access(tenant, model, nil,
         actor_type: "operator",
         surface: "kap112_source_poc"
       ),
     {:ok, contract_template_bytes} <-
       File.read(Path.join(bundle_dir, "reasoning_contract_template.json")),
     {:ok, contract_template} <- Jason.decode(contract_template_bytes),
     runtime_contract = Map.put(contract_template, "model_artifact_digest", model.artifact_sha256),
     :ok <-
       File.write(reasoning_contract_path, Jason.encode!(runtime_contract), [:exclusive]),
     :ok <- File.chmod(reasoning_contract_path, 0o600),
     :ok <- File.write(token_file, token, [:exclusive]),
     :ok <- File.chmod(token_file, 0o600) do
  IO.puts(
    Jason.encode!(%{
      tenant_id: tenant.id,
      api_key_id: api_key.id,
      model: "#{model.model_id}@#{model.version}",
      model_state: model.state,
      access_outcome: access_outcome,
      reasoning_contract_path: reasoning_contract_path,
      reasoning_contract_sha256:
        :crypto.hash(:sha256, Jason.encode!(runtime_contract))
        |> Base.encode16(case: :lower),
      token_file: token_file
    })
  )
else
  {:error, reason} -> raise "KAP-112 disposable fixture setup failed: #{inspect(reason)}"
end
