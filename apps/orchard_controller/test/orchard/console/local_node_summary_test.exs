defmodule OrchardConsole.LocalNodeSummaryTest.RuntimeStub do
  @moduledoc false
  def cluster_snapshot(_opts),
    do: Application.fetch_env!(:orchard_controller, :local_node_test_snapshot)
end

defmodule OrchardConsole.LocalNodeSummaryTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :live

  alias Orchard.RuntimeEndpoint.Target
  alias OrchardConsole.{LocalNodeCard, LocalNodeSummary}

  @node "22222222-2222-4222-8222-222222222222"
  @other "44444444-4444-4444-8444-444444444444"

  setup do
    identity = %{
      node_id: @node,
      enrollment_id: "33333333-3333-4333-8333-333333333333",
      certificate_identifier: "cert-local"
    }

    node = %{
      id: @node,
      hostname: "orchard-mac.local",
      display_name: "Local",
      state: :active,
      health: :healthy,
      last_heartbeat_at: ~U[2026-09-15 09:41:12Z]
    }

    target =
      Target.beam(@node,
        address: "orchard_node_agent@10.0.0.8",
        metadata: %{
          source: :trusted_node_inventory,
          enrollment_id: identity.enrollment_id,
          certificate_identifier: identity.certificate_identifier
        }
      )

    runtime = %{
      target: target,
      status: :ok,
      node_metadata: %{
        node_id: @node,
        display_name: "Local",
        hostname: "orchard-mac.local",
        listen_host: "10.0.0.8",
        listen_port: 50_061,
        worker_backend: "mlx"
      },
      runtime_health: %{ready: true, health_code: nil, health_message: nil, affected_model: nil},
      loaded_models: []
    }

    inventory = %{
      status: :ok,
      rows: [node],
      statuses: [%{resource: %{id: @node}, freshness: %{status: "fresh"}}]
    }

    %{
      identity: {:ok, identity},
      inventory: inventory,
      cluster: %{status: :ok, targets: [runtime]},
      runtime: runtime
    }
  end

  @tag :db
  @tag :tmp_dir
  test "Nodes Inventory refresh carries local custody through healthy, stale and unavailable states",
       ctx do
    keys = [:console, :local_node_identity_root, :local_node_test_snapshot]
    previous = Map.new(keys, &{&1, Application.get_env(:orchard_controller, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value == nil,
          do: Application.delete_env(:orchard_controller, key),
          else: Application.put_env(:orchard_controller, key, value)
      end)
    end)

    generation = "11111111-1111-4111-8111-111111111111"
    directory = Path.join([ctx.tmp_dir, "generations", generation])
    File.mkdir_p!(directory)
    Enum.each([ctx.tmp_dir, Path.dirname(directory), directory], &File.chmod!(&1, 0o700))
    {:ok, identity} = ctx.identity
    metadata = Map.merge(identity, %{generation_id: generation, state: "registered"})

    for {file, contents} <- [
          {Path.join(ctx.tmp_dir, "current"), generation},
          {Path.join(directory, "metadata.json"), Jason.encode!(metadata)}
        ] do
      File.write!(file, contents)
      File.chmod!(file, 0o600)
    end

    node =
      struct!(Orchard.Nodes.Node, %{
        hd(ctx.inventory.rows)
        | last_heartbeat_at: DateTime.utc_now()
      })
      |> Orchard.Repo.insert!()

    Application.put_env(:orchard_controller, :local_node_identity_root, ctx.tmp_dir)
    Application.put_env(:orchard_controller, :local_node_test_snapshot, [ctx.runtime])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous.console || [],
        runtime_impl: __MODULE__.RuntimeStub,
        refresh_interval_ms: 60_000
      )
    )

    {:ok, view, html} = live(ctx.conn, "/console/nodes")
    assert html =~ "This machine’s Node is connected and healthy."
    assert has_element?(view, "#nodes-local-machine a", "View Runtime")

    node
    |> Ecto.Changeset.change(last_heartbeat_at: DateTime.add(DateTime.utc_now(), -60))
    |> Orchard.Repo.update!()

    send(view.pid, :refresh_nodes)
    assert render(view) =~ "The last successful Node observation is out of date."

    Application.put_env(:orchard_controller, :local_node_test_snapshot, [
      %{ctx.runtime | status: :timeout}
    ])

    send(view.pid, :refresh_nodes)
    assert render(view) =~ "Current model status is unknown."
    refute render(view) =~ "This machine’s Node is connected and healthy."
  end

  test "SPEC 4.5 healthy local Node with no loaded models is not serving readiness", ctx do
    summary = LocalNodeSummary.build(ctx.identity, ctx.inventory, ctx.cluster)
    assert summary.state == :healthy
    html = render_component(&LocalNodeCard.local_node_card/1, summary: summary)
    assert html =~ "This machine’s Node is connected and healthy."
    assert html =~ "No models loaded."
    assert html =~ "Node health alone"
    assert html =~ "2026-09-15"
    refute html =~ "cert-local"
  end

  test "same hostname and claimed ID cannot substitute for exact trusted binding", ctx do
    target = ctx.runtime.target

    bad_targets = [
      %{target | node_id: @other},
      %{target | metadata: %{target.metadata | source: :configured}},
      %{target | metadata: %{target.metadata | enrollment_id: "another-enrollment"}},
      %{target | metadata: %{target.metadata | certificate_identifier: "another-certificate"}}
    ]

    for bad <- bad_targets do
      cluster = %{ctx.cluster | targets: [%{ctx.runtime | target: bad}]}
      assert LocalNodeSummary.build(ctx.identity, ctx.inventory, cluster).state == :unknown
    end

    mismatch = %{ctx.runtime | node_metadata: %{node_id: @other}}

    assert LocalNodeSummary.build(ctx.identity, ctx.inventory, %{
             ctx.cluster
             | targets: [mismatch]
           }).state == :unknown

    assert LocalNodeSummary.build(ctx.identity, ctx.inventory, %{
             ctx.cluster
             | targets: [ctx.runtime, ctx.runtime]
           }).state == :unknown
  end

  test "stale heartbeat and failed current probe never retain a positive headline", ctx do
    inventory = %{
      ctx.inventory
      | statuses: [%{resource: %{id: @node}, freshness: %{status: "stale"}}]
    }

    stale = LocalNodeSummary.build(ctx.identity, inventory, ctx.cluster)
    assert stale.state == :stale

    refute render_component(&LocalNodeCard.local_node_card/1, summary: stale) =~
             "connected and healthy"

    failed = %{
      ctx.runtime
      | status: :timeout,
        node_metadata: nil,
        loaded_models: [%{model_id: "old", version: "v1"}]
    }

    unavailable =
      LocalNodeSummary.build(ctx.identity, inventory, %{ctx.cluster | targets: [failed]})

    assert unavailable.state == :unavailable
    assert unavailable.runtime == nil
    assert unavailable.node.last_heartbeat_at == ~U[2026-09-15 09:41:12Z]
    html = render_component(&LocalNodeCard.local_node_card/1, summary: unavailable)
    assert html =~ "Current model status is unknown."
    assert html =~ "Last successful observation"
    assert html =~ "Last observed Node health"
    refute html =~ ">Node health</dt>"
    refute html =~ "connected and healthy"
  end

  test "missing custody, inventory failure and incomplete health fail closed", ctx do
    assert LocalNodeSummary.build({:error, :identity_unavailable}, ctx.inventory, ctx.cluster).state ==
             :unknown

    assert LocalNodeSummary.build(ctx.identity, %{status: :error}, ctx.cluster).state == :unknown

    assert LocalNodeSummary.build(ctx.identity, ctx.inventory, %{status: :error}).state ==
             :unknown

    for health <- [nil, %{ready: false}, %{ready: true, health_code: "warning"}] do
      cluster = %{ctx.cluster | targets: [%{ctx.runtime | runtime_health: health}]}
      assert LocalNodeSummary.build(ctx.identity, ctx.inventory, cluster).state == :attention
    end
  end
end
