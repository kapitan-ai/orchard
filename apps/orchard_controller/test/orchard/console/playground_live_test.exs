defmodule OrchardConsole.PlaygroundLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.InferenceEvent

  @moduletag :live
  @moduletag :db

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous, playground_impl: __MODULE__.PlaygroundStub)
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
      :persistent_term.erase({__MODULE__, :models})
      :persistent_term.erase({__MODULE__, :test_pid})
    end)

    Sandbox.mode(Orchard.Repo, {:shared, self()})

    # Store test pid so stub can notify us
    :persistent_term.put({__MODULE__, :test_pid}, self())

    stub_models([
      %{model_id: "test-model", version: "v1"},
      %{model_id: "test-model", version: "v2"}
    ])

    :ok
  end

  # ===========================================================================
  # Loading & Form
  # ===========================================================================

  describe "loading and form" do
    test "renders form with model picker, system prompt, and user prompt", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ "playground-model"
      assert html =~ "playground-system"
      assert html =~ "playground-prompt"
      assert html =~ "playground-send"
    end

    test "connected mount loads models and auto-selects first", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ "test-model@v1"
      assert html =~ "test-model@v2"
    end

    test "shows error when no models available", %{conn: conn} do
      stub_models([])
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ "No active models available."
    end

    test "shows error when model loading fails", %{conn: conn} do
      stub_models(:error)
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ "Active model list unavailable."
    end

    test "has correct page title and nav", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ "Playground \u2014 Orchard Console"
    end
  end

  # ===========================================================================
  # Validation & Submission
  # ===========================================================================

  describe "validation and submission" do
    test "rejects blank prompt with error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")

      html =
        view
        |> form("#playground-form", playground: %{model: "test-model@v1", prompt: ""})
        |> render_submit()

      assert html =~ "Please enter a prompt"
    end

    test "valid submission appends user message to transcript", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      _ref = submit_prompt(view, "Hello AI")

      html = render(view)
      assert html =~ "Hello AI"
      assert html =~ "User"
      assert html =~ "Assistant"
    end

    test "submit transitions to starting status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      _ref = submit_prompt(view)

      html = render(view)
      assert html =~ "Starting"
    end
  end

  # ===========================================================================
  # Streaming & Transcript
  # ===========================================================================

  describe "streaming and transcript" do
    test ":started message stores request_id and renders deep-link", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      send(view.pid, {:playground, ref, :started, %{request_id: "req_play_123"}})
      html = render(view)

      assert html =~ "playground-request-link"
      assert html =~ "req_play_123"
      assert html =~ "/console/requests/req_play_123"
    end

    test "OutputTextDelta events append to assistant message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      send(view.pid, {:playground, ref, :started, %{request_id: "r1"}})
      send(view.pid, {:playground, ref, :event, InferenceEvent.output_text_delta("Hello ")})
      send(view.pid, {:playground, ref, :event, InferenceEvent.output_text_delta("world!")})
      html = render(view)

      assert html =~ "Hello world!"
      assert html =~ "streaming"
    end

    test "UsageUpdate events update usage summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      usage = %InferenceEvent.Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15}
      send(view.pid, {:playground, ref, :event, InferenceEvent.usage_update(usage)})
      html = render(view)

      assert html =~ "playground-usage"
      assert html =~ "10"
      assert html =~ "5"
      assert html =~ "15"
    end

    test ":finished {:ok, summary} finalizes run", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      send(view.pid, {:playground, ref, :started, %{request_id: "r1"}})
      send(view.pid, {:playground, ref, :event, InferenceEvent.output_text_delta("Done")})

      completed =
        InferenceEvent.completed(:finish_reason_stop, %InferenceEvent.Usage{
          input_tokens: 20,
          output_tokens: 10,
          total_tokens: 30
        })

      send(view.pid, {:playground, ref, :event, completed})
      send(view.pid, {:playground, ref, :finished, {:ok, %{events: []}}})
      html = render(view)

      assert html =~ "Completed"
      assert html =~ "30"
    end

    test ":finished {:error, error} shows error message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      error = %{
        phase: :prepare,
        type: "invalid_request_error",
        code: "model_not_found",
        message: "Model not found: missing@v1",
        param: "model"
      }

      send(view.pid, {:playground, ref, :finished, {:error, error}})
      html = render(view)

      assert html =~ "playground-error"
      assert html =~ "Model not found: missing@v1"
      assert html =~ "Error"
    end

    test "stale run_ref messages are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      stale_ref = make_ref()

      send(view.pid, {:playground, stale_ref, :started, %{request_id: "stale_req"}})
      send(view.pid, {:playground, stale_ref, :event, InferenceEvent.output_text_delta("stale")})
      html = render(view)

      refute html =~ "stale_req"
      refute html =~ ">stale<"

      # Current ref should still work
      send(view.pid, {:playground, ref, :started, %{request_id: "current_req"}})
      html = render(view)
      assert html =~ "current_req"
    end
  end

  # ===========================================================================
  # Controls & Reset
  # ===========================================================================

  describe "controls and reset" do
    test "send and reset are disabled during active run", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      _ref = submit_prompt(view)

      html = render(view)
      # Both buttons should have disabled attribute
      assert html =~ ~s(id="playground-send")
      assert html =~ ~s(id="playground-reset")
      assert html =~ "disabled"
    end

    test "new chat clears transcript and resets state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      complete_run(view, ref)

      # Click New Chat
      view |> element("#playground-reset") |> render_click()
      html = render(view)

      # Transcript should be cleared
      refute html =~ "playground-usage"
      refute html =~ "playground-request-link"
      assert html =~ "Ready"
      assert html =~ "Send a message"
    end

    test "new chat preserves model selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      complete_run(view, ref)

      view |> element("#playground-reset") |> render_click()
      html = render(view)

      # Models should still be loaded
      assert html =~ "test-model@v1"
    end
  end

  # ===========================================================================
  # Deep-link & Summary
  # ===========================================================================

  describe "deep-link and summary" do
    test "deep-link appears after started with request_id", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      send(view.pid, {:playground, ref, :started, %{request_id: "req_deep"}})
      html = render(view)

      assert html =~ "/console/requests/req_deep"
      assert html =~ "View request req_deep"
    end

    test "deep-link persists after failure when request_id was set", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      send(view.pid, {:playground, ref, :started, %{request_id: "req_fail"}})

      error = %{
        phase: :execute,
        type: "server_error",
        code: "internal_error",
        message: "Something broke",
        param: nil
      }

      send(view.pid, {:playground, ref, :finished, {:error, error}})
      html = render(view)

      assert html =~ "req_fail"
      assert html =~ "Something broke"
    end

    test "usage summary shows token counts", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      completed =
        InferenceEvent.completed(:finish_reason_stop, %InferenceEvent.Usage{
          input_tokens: 42,
          output_tokens: 18,
          total_tokens: 60
        })

      send(view.pid, {:playground, ref, :event, completed})
      send(view.pid, {:playground, ref, :finished, {:ok, %{events: []}}})
      html = render(view)

      assert html =~ "42"
      assert html =~ "18"
      assert html =~ "60"
    end
  end

  # ===========================================================================
  # Stub module
  # ===========================================================================

  defmodule PlaygroundStub do
    def list_models do
      case :persistent_term.get({OrchardConsole.PlaygroundLiveTest, :models}, []) do
        :error ->
          {:error,
           %{
             status: :error,
             code: "models_unavailable",
             message: "Active model list unavailable."
           }}

        models when is_list(models) ->
          {:ok, models}
      end
    end

    def start_stream(_owner, run_ref, _params, _caller_context \\ []) do
      # Notify the test process of the run_ref
      test_pid = :persistent_term.get({OrchardConsole.PlaygroundLiveTest, :test_pid}, nil)
      if test_pid, do: send(test_pid, {:stub_run_ref, run_ref})

      # Return a dummy task pid — the test will drive messages manually
      {:ok, spawn(fn -> :timer.sleep(:infinity) end)}
    end
  end

  # ===========================================================================
  # Test helpers
  # ===========================================================================

  defp stub_models(data) do
    :persistent_term.put({__MODULE__, :models}, data)
  end

  defp submit_prompt(view, prompt \\ "Test prompt") do
    view
    |> form("#playground-form", playground: %{model: "test-model@v1", prompt: prompt})
    |> render_submit()

    assert_receive {:stub_run_ref, ref}, 1000
    ref
  end

  defp complete_run(view, ref) do
    send(view.pid, {:playground, ref, :started, %{request_id: "r1"}})
    send(view.pid, {:playground, ref, :event, InferenceEvent.output_text_delta("Response")})

    completed =
      InferenceEvent.completed(:finish_reason_stop, %InferenceEvent.Usage{
        input_tokens: 5,
        output_tokens: 3,
        total_tokens: 8
      })

    send(view.pid, {:playground, ref, :event, completed})
    send(view.pid, {:playground, ref, :finished, {:ok, %{events: []}}})
    render(view)
  end
end
