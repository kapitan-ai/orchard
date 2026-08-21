defmodule OrchardConsole.PlaygroundTest do
  use ExUnit.Case, async: false

  alias Orchard.InferenceEvent
  alias OrchardConsole.Playground

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        playground_models_impl: __MODULE__.StubModels,
        playground_orchestrator_impl: __MODULE__.StubOrchestrator,
        playground_runtime_impl: __MODULE__.StubRuntime
      )
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
      :persistent_term.erase({__MODULE__, :models})
      :persistent_term.erase({__MODULE__, :catalog})
      :persistent_term.erase({__MODULE__, :runtime})
      :persistent_term.erase({__MODULE__, :orchestrator})
      :persistent_term.erase({__MODULE__, :test_pid})
    end)

    :persistent_term.put({__MODULE__, :test_pid}, self())
    :ok
  end

  # ===========================================================================
  # list_models/0
  # ===========================================================================

  describe "list_models/0" do
    test "projects and sorts active models with readiness facts" do
      stub_models([
        %{model_id: "z-model", version: "v2"},
        %{model_id: "a-model", version: "v1"},
        %{model_id: "a-model", version: "main"}
      ])

      stub_runtime([
        %{
          status: :ok,
          loaded_models: [%{model_id: "a-model", version: "v1"}]
        }
      ])

      assert {:ok, models} = Playground.list_models()

      assert [
               %{
                 model_id: "a-model",
                 version: "main",
                 catalog_state: :active,
                 inference_ready: false,
                 placement_state: :none,
                 loaded: false
               },
               %{
                 model_id: "a-model",
                 version: "v1",
                 catalog_state: :active,
                 inference_ready: true,
                 placement_state: :loaded,
                 loaded: true,
                 remote_availability: :present,
                 not_ready_reason: nil
               },
               %{
                 model_id: "z-model",
                 version: "v2",
                 catalog_state: :active,
                 inference_ready: false,
                 placement_state: :none,
                 loaded: false
               }
             ] = models
    end

    test "marks catalog-active models non-ready when no loaded placement exists" do
      stub_models([%{model_id: "test-model", version: "v1"}])
      stub_runtime([%{status: :ok, loaded_models: []}])

      assert {:ok, [model]} = Playground.list_models()
      assert model.inference_ready == false
      assert model.placement_state == :none
      assert model.loaded == false
      assert model.not_ready_reason =~ "no loaded placement"
    end

    test "fails closed when runtime readiness is unknown" do
      stub_models([%{model_id: "test-model", version: "v1"}])
      stub_runtime(:error)

      assert {:ok, [model]} = Playground.list_models()
      assert model.inference_ready == false
      assert model.placement_state == :unknown
      assert model.not_ready_reason =~ "Readiness unknown"
    end

    test "marks absence unknown when only some runtime targets respond" do
      stub_models([%{model_id: "test-model", version: "v1"}])

      stub_runtime([
        %{status: :error, loaded_models: [%{model_id: "test-model", version: "v1"}]},
        %{status: :ok, loaded_models: []}
      ])

      assert {:ok, [model]} = Playground.list_models()
      assert model.inference_ready == false
      assert model.placement_state == :unknown
      assert model.not_ready_reason =~ "partially observed"
    end

    test "accepts an exact loaded match from a successful target during partial outage" do
      stub_models([%{model_id: "test-model", version: "v1"}])

      stub_runtime([
        %{status: :error, loaded_models: []},
        %{status: :ok, loaded_models: [%{model_id: "test-model", version: "v1"}]}
      ])

      assert {:ok, [model]} = Playground.list_models()
      assert model.inference_ready == true
      assert model.placement_state == :loaded
    end

    test "returns empty list when no active models" do
      stub_models([])
      stub_runtime([%{status: :ok, loaded_models: []}])

      assert {:ok, []} = Playground.list_models()
    end

    test "lists only models granted to the effective tenant" do
      stub_models(%{
        Playground.effective_tenant_id() => [%{model_id: "granted-model", version: "v1"}],
        Ecto.UUID.generate() => [%{model_id: "other-tenant-model", version: "v1"}]
      })

      stub_runtime([%{status: :ok, loaded_models: []}])

      assert {:ok, [%{model_id: "granted-model", version: "v1"}]} = Playground.list_models()
    end

    test "returns no models when the effective tenant has no grants" do
      stub_models(%{Ecto.UUID.generate() => [%{model_id: "other-tenant-model", version: "v1"}]})
      stub_runtime([%{status: :ok, loaded_models: []}])

      assert {:ok, []} = Playground.list_models()
    end

    test "normalizes non-binary identity fields defensively" do
      stub_models([%{model_id: nil, version: 42}])
      stub_runtime([%{status: :ok, loaded_models: []}])

      assert {:ok, [%{model_id: "", version: "", inference_ready: false}]} =
               Playground.list_models()
    end

    test "returns normalized error on source exception" do
      stub_models(:raise)
      stub_runtime([%{status: :ok, loaded_models: []}])

      assert {:error, error} = Playground.list_models()
      assert error.code == "models_unavailable"
      assert error.message == "Active model list unavailable."
    end
  end

  # ===========================================================================
  # start_stream/4
  # ===========================================================================

  describe "start_stream/4" do
    setup do
      stub_models([%{model_id: "test-model", version: "v1"}])

      stub_runtime([
        %{status: :ok, loaded_models: [%{model_id: "test-model", version: "v1"}]}
      ])

      :ok
    end

    test "returns {:ok, pid} immediately" do
      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []}
      )

      assert {:ok, pid} = Playground.start_stream(self(), make_ref(), valid_params())
      assert is_pid(pid)
    end

    test "task is not linked to the caller" do
      ref = make_ref()

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []}
      )

      {:ok, pid} = Playground.start_stream(self(), ref, valid_params())

      {:links, links} = Process.info(self(), :links)
      refute pid in links

      assert_receive {:playground, ^ref, :finished, {:ok, _}}, 1000
    end

    test "sends :started after prepare succeeds" do
      ref = make_ref()

      stub_orchestrator(
        prepare: {:ok, fake_canonical("req_123"), %{}},
        execute: {:ok, fake_canonical("req_123"), []}
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :started, %{request_id: "req_123"}}, 1000
    end

    test "bridges inference events to owner" do
      ref = make_ref()
      delta_event = InferenceEvent.output_text_delta("Hello")

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []},
        events: [delta_event]
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :event, ^delta_event}, 1000
    end

    test "rejects non-ready models before prepare or execute" do
      stub_runtime([%{status: :ok, loaded_models: []}])
      ref = make_ref()

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []},
        capture_opts: true
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
      assert error.phase == :prepare
      assert error.code == "model_not_ready"
      assert error.message =~ "no loaded placement"
      refute_receive {:playground, ^ref, :started, _}, 100
      refute_receive {:captured_opts, _}, 100
    end

    test "normalizes prepare errors" do
      ref = make_ref()

      stub_orchestrator(prepare: {:error, :invalid_request})

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
      assert error.phase == :prepare
    end

    test "normalizes execute errors after started" do
      ref = make_ref()

      stub_orchestrator(
        prepare: {:ok, fake_canonical("req_exec"), %{}},
        execute: {:error, :model_busy}
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :started, %{request_id: "req_exec"}}, 1000
      assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
      assert error.phase == :execute
      assert error.code == "model_busy"
    end

    test "passes caller option to orchestrator execute" do
      ref = make_ref()
      owner = self()

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []},
        capture_opts: true
      )

      {:ok, _pid} = Playground.start_stream(owner, ref, valid_params())

      assert_receive {:captured_opts, opts}, 1000
      assert Keyword.get(opts, :caller) == owner
    end

    test "refuses to run an active model the effective tenant is not granted" do
      stub_models(%{Ecto.UUID.generate() => [%{model_id: "test-model", version: "v1"}]})
      stub_catalog([%{model_id: "test-model", version: "v1", state: :active}])
      ref = make_ref()

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []},
        capture_opts: true
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
      assert error.phase == :prepare
      assert error.code == "model_not_ready"
      assert error.message =~ "orchardctl models access grant"
      refute_receive {:playground, ^ref, :started, _}, 100
      refute_receive {:captured_opts, _}, 100
      refute_receive :list_active_models_called, 100
    end

    test "reports a missing or deleted catalog model distinctly" do
      stub_models(%{})
      stub_catalog([])
      ref = make_ref()

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []},
        capture_opts: true
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
      assert error.phase == :prepare
      assert error.code == "model_not_ready"
      assert error.message =~ "not an active catalog model"
      refute error.message =~ "orchardctl models access grant"
      refute_receive {:captured_opts, _}, 100
      refute_receive :list_active_models_called, 100
    end

    test "reports a non-active catalog model distinctly" do
      stub_models(%{})
      stub_catalog([%{model_id: "test-model", version: "v1", state: :deprecated}])
      ref = make_ref()

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []},
        capture_opts: true
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
      assert error.phase == :prepare
      assert error.code == "model_not_ready"
      assert error.message =~ "not an active catalog model"
      refute error.message =~ "orchardctl models access grant"
      refute_receive {:captured_opts, _}, 100
      refute_receive :list_active_models_called, 100
    end

    test "fails closed when the targeted catalog lookup raises or exits" do
      stub_models(%{})

      Enum.each([:raise, :exit], fn failure ->
        stub_catalog(failure)
        ref = make_ref()

        stub_orchestrator(
          prepare: {:ok, fake_canonical(), %{}},
          execute: {:ok, fake_canonical(), []},
          capture_opts: true
        )

        {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

        assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
        assert error.phase == :prepare
        assert error.code == "model_not_ready"
        refute error.code == "internal_error"
        assert error.message =~ "not an active catalog model"
        refute_receive {:captured_opts, _}, 100
      end)

      refute_receive :list_active_models_called, 100
    end

    test "passes the effective tenant through the preparation caller context" do
      ref = make_ref()

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []},
        capture_caller_context: true
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:captured_caller_context, caller_context}, 1000
      assert Keyword.get(caller_context, :tenant_id) == Playground.effective_tenant_id()
    end

    test "keeps an explicit caller tenant context" do
      ref = make_ref()
      tenant_id = Ecto.UUID.generate()

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []},
        capture_caller_context: true
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params(), tenant_id: tenant_id)

      assert_receive {:captured_caller_context, caller_context}, 1000
      assert Keyword.get(caller_context, :tenant_id) == tenant_id
    end

    test "rescues unexpected task exceptions" do
      ref = make_ref()
      stub_orchestrator(prepare: :raise)

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
      assert error.code == "internal_error"
    end
  end

  # ===========================================================================
  # Stub modules
  # ===========================================================================

  defmodule StubModels do
    def list_active_models_for_tenant(tenant_id) do
      case stubbed_models() do
        :raise ->
          raise "DB unavailable"

        models when is_list(models) ->
          models

        grants when is_map(grants) ->
          Map.get(grants, tenant_id, [])
      end
    end

    def get_model_by_identity(model_id, version) do
      case :persistent_term.get({OrchardConsole.PlaygroundTest, :catalog}, :derive) do
        :raise -> raise "catalog lookup unavailable"
        :exit -> exit(:catalog_lookup_unavailable)
        :derive -> find_by_identity(derived_catalog(), model_id, version)
        models when is_list(models) -> find_by_identity(models, model_id, version)
      end
    end

    def list_active_models do
      send(
        :persistent_term.get({OrchardConsole.PlaygroundTest, :test_pid}),
        :list_active_models_called
      )

      raise "full catalog enumeration is forbidden"
    end

    defp find_by_identity(models, model_id, version) do
      Enum.find(models, &(&1.model_id == model_id and &1.version == version))
    end

    defp derived_catalog do
      case stubbed_models() do
        models when is_list(models) ->
          Enum.map(models, &Map.put_new(&1, :state, :active))

        grants when is_map(grants) ->
          grants |> Map.values() |> List.flatten() |> derived_catalog()

        _other ->
          []
      end
    end

    defp derived_catalog(models), do: Enum.map(models, &Map.put_new(&1, :state, :active))

    defp stubbed_models do
      :persistent_term.get({OrchardConsole.PlaygroundTest, :models}, [])
    end
  end

  defmodule StubRuntime do
    def cluster_snapshot(_opts \\ []) do
      case :persistent_term.get({OrchardConsole.PlaygroundTest, :runtime}, []) do
        :error -> raise "runtime unavailable"
        :exit -> exit(:runtime_unavailable)
        snapshots when is_list(snapshots) -> snapshots
      end
    end
  end

  defmodule StubOrchestrator do
    def prepare(_params, caller_context) do
      config = :persistent_term.get({OrchardConsole.PlaygroundTest, :orchestrator}, [])
      test_pid = :persistent_term.get({OrchardConsole.PlaygroundTest, :test_pid}, nil)

      if config[:capture_caller_context] && test_pid do
        send(test_pid, {:captured_caller_context, caller_context})
      end

      case config[:prepare] do
        :raise -> raise "Prepare exploded"
        result -> result
      end
    end

    def execute(canonical, _model, opts) do
      config = :persistent_term.get({OrchardConsole.PlaygroundTest, :orchestrator}, [])
      test_pid = :persistent_term.get({OrchardConsole.PlaygroundTest, :test_pid}, nil)

      if config[:capture_opts] && test_pid do
        send(test_pid, {:captured_opts, opts})
      end

      event_handler = Keyword.get(opts, :event_handler)

      if event_handler && config[:events] do
        Enum.each(config[:events], fn event ->
          event_handler.(canonical.public_id, event)
        end)
      end

      case config[:execute] do
        nil -> {:ok, canonical, []}
        result -> result
      end
    end
  end

  # ===========================================================================
  # Stub helpers
  # ===========================================================================

  defp stub_models(data) do
    :persistent_term.put({__MODULE__, :models}, data)
  end

  defp stub_catalog(data) do
    :persistent_term.put({__MODULE__, :catalog}, data)
  end

  defp stub_runtime(data) do
    :persistent_term.put({__MODULE__, :runtime}, data)
  end

  defp stub_orchestrator(config) do
    :persistent_term.put({__MODULE__, :orchestrator}, config)
  end

  defp valid_params do
    %{
      "model" => "test-model@v1",
      "messages" => [%{"role" => "user", "content" => "hello"}]
    }
  end

  defp fake_canonical(public_id \\ "req_test") do
    %{public_id: public_id}
  end
end
