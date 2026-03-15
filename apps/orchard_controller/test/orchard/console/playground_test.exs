defmodule OrchardConsole.PlaygroundTest do
  use ExUnit.Case, async: false

  alias OrchardConsole.Playground
  alias Orchard.InferenceEvent

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        playground_models_impl: __MODULE__.StubModels,
        playground_orchestrator_impl: __MODULE__.StubOrchestrator
      )
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)
    :ok
  end

  # ===========================================================================
  # list_models/0
  # ===========================================================================

  describe "list_models/0" do
    test "projects and sorts active models deterministically" do
      stub_models([
        %{model_id: "z-model", version: "v2"},
        %{model_id: "a-model", version: "v1"},
        %{model_id: "a-model", version: "main"}
      ])

      assert {:ok, models} = Playground.list_models()

      assert [
               %{model_id: "a-model", version: "main"},
               %{model_id: "a-model", version: "v1"},
               %{model_id: "z-model", version: "v2"}
             ] = models
    end

    test "returns empty list when no active models" do
      stub_models([])

      assert {:ok, []} = Playground.list_models()
    end

    test "normalizes non-binary identity fields defensively" do
      stub_models([%{model_id: nil, version: 42}])

      assert {:ok, [%{model_id: "", version: ""}]} = Playground.list_models()
    end

    test "returns normalized error on source exception" do
      stub_models(:raise)

      assert {:error, error} = Playground.list_models()
      assert error.code == "models_unavailable"
      assert error.message == "Active model list unavailable."
    end
  end

  # ===========================================================================
  # start_stream/4
  # ===========================================================================

  describe "start_stream/4" do
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

      # Verify the task is not in our links
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

    test "sends :finished with {:ok, summary} on success" do
      ref = make_ref()
      canonical = fake_canonical("req_ok")

      stub_orchestrator(
        prepare: {:ok, canonical, %{}},
        execute: {:ok, canonical, []}
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :finished, {:ok, summary}}, 1000
      assert summary.canonical_request == canonical
      assert summary.events == []
    end

    test "passes owner pid as :caller option to execute" do
      ref = make_ref()
      owner = self()

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:ok, fake_canonical(), []},
        capture_opts: true
      )

      {:ok, _pid} = Playground.start_stream(owner, ref, valid_params())

      assert_receive {:captured_opts, opts}, 1000
      assert opts[:caller] == owner
    end

    test "normalizes prepare failure and sends :finished with :error" do
      ref = make_ref()

      stub_orchestrator(prepare: {:error, {:model_not_found, "missing@v1"}})

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
      assert error.phase == :prepare
      assert error.code == "model_not_found"
      assert error.message =~ "missing@v1"

      # Should NOT receive :started
      refute_received {:playground, ^ref, :started, _}
    end

    test "normalizes execute failure and sends :finished with :error" do
      ref = make_ref()

      stub_orchestrator(
        prepare: {:ok, fake_canonical(), %{}},
        execute: {:error, :something_went_wrong}
      )

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
      assert error.phase == :execute
      assert error.type == "api_error"
    end

    test "handles task-body exceptions gracefully" do
      ref = make_ref()

      stub_orchestrator(prepare: :raise)

      {:ok, _pid} = Playground.start_stream(self(), ref, valid_params())

      assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
      assert error.type == "server_error"
      assert error.code == "internal_error"
    end
  end

  # ===========================================================================
  # Stub modules
  # ===========================================================================

  defmodule StubModels do
    def list_active_models do
      [{_pid, config}] =
        Registry.lookup(OrchardConsole.PlaygroundTest.StubRegistry, :models)

      case config do
        :raise -> raise "DB unavailable"
        models -> models
      end
    end
  end

  defmodule StubOrchestrator do
    def prepare(_params, _caller_context) do
      [{_pid, config}] =
        Registry.lookup(OrchardConsole.PlaygroundTest.StubRegistry, :orchestrator)

      case config[:prepare] do
        :raise -> raise "Prepare exploded"
        result -> result
      end
    end

    def execute(canonical, _model, opts) do
      [{_pid, config}] =
        Registry.lookup(OrchardConsole.PlaygroundTest.StubRegistry, :orchestrator)

      # Capture opts if requested
      if config[:capture_opts] do
        [{pid, _}] = Registry.lookup(OrchardConsole.PlaygroundTest.StubRegistry, :orchestrator)
        send(pid, {:captured_opts, opts})
      end

      # Fire events through the handler if provided
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
    ensure_registry()
    Registry.register(__MODULE__.StubRegistry, :models, data)
  end

  defp stub_orchestrator(config) do
    ensure_registry()
    Registry.register(__MODULE__.StubRegistry, :orchestrator, config)
  end

  defp ensure_registry do
    unless Process.whereis(__MODULE__.StubRegistry) do
      start_supervised!({Registry, keys: :duplicate, name: __MODULE__.StubRegistry})
    end
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
