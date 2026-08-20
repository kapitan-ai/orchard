defmodule OrchardConsole.PlaygroundAccessTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Models.Access
  alias OrchardConsole.Playground

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    console_config =
      previous
      |> Keyword.merge(
        playground_orchestrator_impl: __MODULE__.StubOrchestrator,
        playground_runtime_impl: __MODULE__.StubRuntime
      )
      |> Keyword.delete(:playground_models_impl)

    Application.put_env(:orchard_controller, :console, console_config)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
      :persistent_term.erase({__MODULE__, :loaded})
      :persistent_term.erase({__MODULE__, :test_pid})
    end)

    :persistent_term.put({__MODULE__, :test_pid}, self())

    model = create_model!(%{state: :active})

    :persistent_term.put({__MODULE__, :loaded}, [
      %{model_id: model.model_id, version: model.version}
    ])

    %{model: model}
  end

  test "SPEC.md §7.2.3 hides active Models the console Tenant is not granted", %{model: model} do
    assert {:ok, []} = Playground.list_models()

    ref = make_ref()
    {:ok, _pid} = Playground.start_stream(self(), ref, params_for(model))

    assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
    assert error.phase == :prepare
    assert error.code == "model_not_ready"
    assert error.message =~ "orchardctl models access grant"

    refute_receive {:playground, ^ref, :started, _}, 100
    refute_receive {:prepare_called, _caller_context}, 100
  end

  test "reports a non-active catalog Model as unavailable rather than ungranted" do
    inactive = create_model!(%{state: :registered})

    ref = make_ref()
    {:ok, _pid} = Playground.start_stream(self(), ref, params_for(inactive))

    assert_receive {:playground, ^ref, :finished, {:error, error}}, 1000
    assert error.code == "model_not_ready"
    assert error.message =~ "not an active catalog model"
    refute error.message =~ "orchardctl models access grant"
    refute_receive {:prepare_called, _caller_context}, 100
  end

  test "SPEC.md §5.2 lists and runs a Model granted to the console Tenant", %{model: model} do
    grant_model_access!(Playground.effective_tenant_id(), model)

    assert {:ok, [option]} = Playground.list_models()
    assert option.model_id == model.model_id
    assert option.version == model.version
    assert option.inference_ready == true

    ref = make_ref()
    {:ok, _pid} = Playground.start_stream(self(), ref, params_for(model))

    assert_receive {:prepare_called, caller_context}, 1000
    assert Keyword.get(caller_context, :tenant_id) == Playground.effective_tenant_id()

    assert_receive {:playground, ^ref, :started, _}, 1000
    assert_receive {:playground, ^ref, :finished, {:ok, _summary}}, 1000
  end

  test "SPEC.md §5.2 drops a Model from the picker once its grant is disabled", %{model: model} do
    grant_model_access!(Playground.effective_tenant_id(), model)
    assert {:ok, [_option]} = Playground.list_models()

    assert {:ok, %{outcome: :disabled}} =
             Access.disable_model_access(Playground.effective_tenant_id(), model)

    assert {:ok, []} = Playground.list_models()
  end

  defp params_for(model) do
    %{
      "model" => "#{model.model_id}@#{model.version}",
      "messages" => [%{"role" => "user", "content" => "hello"}]
    }
  end

  defmodule StubRuntime do
    def cluster_snapshot(_opts \\ []) do
      loaded = :persistent_term.get({OrchardConsole.PlaygroundAccessTest, :loaded}, [])
      [%{status: :ok, loaded_models: loaded}]
    end
  end

  defmodule StubOrchestrator do
    def prepare(_params, caller_context) do
      test_pid = :persistent_term.get({OrchardConsole.PlaygroundAccessTest, :test_pid}, nil)

      if test_pid, do: send(test_pid, {:prepare_called, caller_context})

      {:ok, %{public_id: "chatcmpl-console"}, %{}}
    end

    def execute(canonical, _model, _opts), do: {:ok, canonical, []}
  end
end
