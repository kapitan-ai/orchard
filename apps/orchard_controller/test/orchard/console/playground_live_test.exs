defmodule OrchardConsole.PlaygroundLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Orchard.TestSupport.LicenseGateHelpers

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
      {:ok, view, html} = live(conn, "/console/playground")

      assert html =~ "No active models available."
      assert html =~ "playground-models-empty"
      assert html =~ "Download and import a model from Model Hub"
      assert has_element?(view, ~s|#playground-browse-model-hub[href="/console/model-hub"]|)
      assert html =~ "Browse Model Hub"
    end

    test "shows error when model loading fails", %{conn: conn} do
      stub_models(:error)
      {:ok, view, html} = live(conn, "/console/playground")

      assert html =~ "Active model list unavailable."
      assert html =~ "playground-models-error"
      refute has_element?(view, "#playground-browse-model-hub")
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
    test "hard mode denies submit before starting a stream", %{conn: conn} do
      set_license_enforcement(:hard)
      {:ok, view, _html} = live(conn, "/console/playground")

      html =
        view
        |> form("#playground-form", playground: %{model: "test-model@v1", prompt: "Hello"})
        |> render_submit()

      assert_license_denial(html)
      assert has_element?(view, "#playground-form")
      refute_receive {:stub_run_ref, _}, 100
    end

    test "warn mode permits submit", %{conn: conn} do
      set_license_enforcement(:warn)
      {:ok, view, _html} = live(conn, "/console/playground")

      _ref = submit_prompt(view, "Hello in warn mode")

      assert render(view) =~ "Hello in warn mode"
    end

    test "rejects blank prompt with error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")

      html =
        view
        |> form("#playground-form", playground: %{model: "test-model@v1", prompt: ""})
        |> render_submit()

      assert html =~ "Please enter a prompt"
      assert html =~ ~s(id="playground-prompt")
      assert html =~ "border-red-500"
      refute html =~ ~s(id="playground-prompt-error")
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
    test ":started message stores request_id in result rail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      send(view.pid, {:playground, ref, :started, %{request_id: "req_play_123"}})
      html = render(view)

      assert html =~ "playground-result-rail"
      assert html =~ "playground-result-request-id"
      assert html =~ "req_play_123"
      # Terminal CTA should NOT appear yet (still streaming)
      refute html =~ "playground-view-request"
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

    test "UsageUpdate events update usage in result rail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      usage = %InferenceEvent.Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15}
      send(view.pid, {:playground, ref, :event, InferenceEvent.usage_update(usage)})
      html = render(view)

      assert html =~ "playground-result-rail"
      assert html =~ "playground-result-prompt-tokens"
      assert html =~ "playground-result-completion-tokens"
      assert html =~ "playground-result-total-tokens"
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

      # Transcript and result rail should be cleared
      refute html =~ "playground-result-rail"
      assert html =~ "Ready"
      assert html =~ "Send a prompt to start a conversation"
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
    test "request ID appears in rail after :started, CTA only after terminal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      send(view.pid, {:playground, ref, :started, %{request_id: "req_deep"}})
      html = render(view)

      # Request ID visible in rail
      assert html =~ "playground-result-request-id"
      assert html =~ "req_deep"
      # CTA should NOT appear while run is active
      refute html =~ "playground-view-request"

      # Complete the run
      send(view.pid, {:playground, ref, :event, InferenceEvent.output_text_delta("done")})

      completed =
        InferenceEvent.completed(:finish_reason_stop, %InferenceEvent.Usage{
          input_tokens: 5,
          output_tokens: 3,
          total_tokens: 8
        })

      send(view.pid, {:playground, ref, :event, completed})
      send(view.pid, {:playground, ref, :finished, {:ok, %{events: []}}})
      html = render(view)

      # Now CTA should appear
      assert html =~ "playground-view-request"
      assert html =~ "/console/requests/req_deep"
    end

    test "failure preserves partial assistant content", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      send(view.pid, {:playground, ref, :started, %{request_id: "req_partial_fail"}})
      send(view.pid, {:playground, ref, :event, InferenceEvent.output_text_delta("Partial")})

      error = %{
        phase: :execute,
        type: "server_error",
        code: "internal_error",
        message: "Backend stream failed.",
        param: nil
      }

      send(view.pid, {:playground, ref, :finished, {:error, error}})
      html = render(view)
      assistant = view |> element("#playground-message-msg-1") |> render()

      assert html =~ "Backend stream failed."
      assert assistant =~ "Partial"
      assert assistant =~ "Response interrupted."
    end

    test "CTA appears after failure when request_id was set", %{conn: conn} do
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
      # CTA should appear because run is terminal and request_id exists
      assert html =~ "playground-view-request"
      assert html =~ "/console/requests/req_fail"
    end

    test "usage summary shows token counts in result rail", %{conn: conn} do
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

      assert html =~ "playground-result-rail"
      assert html =~ "42"
      assert html =~ "18"
      assert html =~ "60"
    end
  end

  # ===========================================================================
  # Result Rail & Hooks
  # ===========================================================================

  describe "result rail and hooks" do
    test "submit shows result rail with timing placeholders", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      _ref = submit_prompt(view)

      html = render(view)
      assert html =~ "playground-result-rail"
      assert html =~ "playground-result-request-id"
      assert html =~ "playground-result-accepted"
      assert html =~ "playground-result-first-token"
      assert html =~ "playground-result-generation"
      assert html =~ "playground-result-total"
      assert html =~ "playground-result-tokens-per-second"
      # Verify renamed labels
      assert html =~ "TTFT"
      assert html =~ "Total latency"
      assert html =~ "Tok/s"
    end

    test "first token timing cell populates after output delta", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      send(view.pid, {:playground, ref, :started, %{request_id: "r1"}})
      send(view.pid, {:playground, ref, :event, InferenceEvent.output_text_delta("Hi")})

      # First token timing should show a value (ms or s), not a dash
      first_token_el = element(view, "#playground-result-first-token") |> render()
      assert first_token_el =~ ~r/(ms| s)/
    end

    test "transcript container has auto-scroll hook", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ ~s(phx-hook="AutoScrollBottom")
      assert html =~ ~s(data-auto-scroll="false")
    end

    test "transcript auto-scroll enabled during active run", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      _ref = submit_prompt(view)

      html = render(view)
      assert html =~ ~s(data-auto-scroll="true")
    end

    test "prompt textarea has submit shortcut hook and hint", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ ~s(phx-hook="SubmitOnModEnter")
      assert html =~ "playground-submit-hint"
      assert html =~ "Cmd/Ctrl + Enter"
    end

    test "completed run populates generation time and tok/s", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      # Drive events with a small gap so generation_ms > 0
      send(view.pid, {:playground, ref, :started, %{request_id: "r1"}})
      send(view.pid, {:playground, ref, :event, InferenceEvent.output_text_delta("Hi")})
      Process.sleep(2)

      completed =
        InferenceEvent.completed(:finish_reason_stop, %InferenceEvent.Usage{
          input_tokens: 5,
          output_tokens: 3,
          total_tokens: 8
        })

      send(view.pid, {:playground, ref, :event, completed})
      send(view.pid, {:playground, ref, :finished, {:ok, %{events: []}}})
      render(view)

      # Generation time should show a duration value (ms or s), not a dash
      generation_el = element(view, "#playground-result-generation") |> render()
      assert generation_el =~ ~r/(ms| s)/

      # Tok/s should show a numeric value, not a dash
      tps_el = element(view, "#playground-result-tokens-per-second") |> render()
      assert tps_el =~ ~r/\d+\.\d/
      refute tps_el =~ "\u2014"
    end

    test "generation time and tok/s show dash when no first token", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      # Complete without any output delta — no first_token_at_ms recorded
      send(view.pid, {:playground, ref, :started, %{request_id: "r1"}})

      completed =
        InferenceEvent.completed(:finish_reason_stop, %InferenceEvent.Usage{
          input_tokens: 5,
          output_tokens: 0,
          total_tokens: 5
        })

      send(view.pid, {:playground, ref, :event, completed})
      send(view.pid, {:playground, ref, :finished, {:ok, %{events: []}}})

      render(view)

      # Generation and Tok/s should show em dash
      generation_el = element(view, "#playground-result-generation") |> render()
      assert generation_el =~ "\u2014"

      tps_el = element(view, "#playground-result-tokens-per-second") |> render()
      assert tps_el =~ "\u2014"
    end

    test "reset clears result rail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")
      ref = submit_prompt(view)

      complete_run(view, ref)
      html = render(view)
      assert html =~ "playground-result-rail"

      # Reset
      view |> element("#playground-reset") |> render_click()
      html = render(view)
      refute html =~ "playground-result-rail"
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
  # Sample prompt chips (Task 7)
  # ===========================================================================

  describe "sample prompt chips" do
    test "renders chip row with stable IDs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")

      chips = view |> element("#playground-sample-prompts") |> render()
      assert chips =~ "Sample prompts:"
      assert chips =~ "playground-sample-prompt-orchard-summary"
      assert chips =~ "playground-sample-prompt-deployment-brief"
      assert chips =~ "Orchard summary"
      assert chips =~ "Deployment brief"
    end

    test "clicking a chip fills system and prompt fields, preserves model", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")

      # Select model v2 first
      view
      |> form("#playground-form", playground: %{model: "test-model@v2"})
      |> render_change()

      # Click the deployment brief chip
      view
      |> element("#playground-sample-prompt-deployment-brief")
      |> render_click()

      html = render(view)

      # Sample content is filled
      assert html =~ "operations analyst"
      assert html =~ "12-person support team"

      # Model is preserved
      assert html =~ "test-model@v2"

      # No stream started (no auto-submit)
      refute_receive {:stub_run_ref, _}, 100
    end

    test "clicking a chip clears form errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")

      # Submit with blank prompt to trigger error
      view
      |> form("#playground-form", playground: %{model: "test-model@v1", prompt: ""})
      |> render_submit()

      html = render(view)
      assert html =~ "Please enter a prompt"

      # Click a chip — error should clear
      view
      |> element("#playground-sample-prompt-orchard-summary")
      |> render_click()

      html = render(view)
      refute html =~ "Please enter a prompt"
    end

    test "chips are disabled during active run", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/playground")

      # Start a run
      _ref = submit_prompt(view)

      # Check chip is disabled
      chip = view |> element("#playground-sample-prompt-orchard-summary") |> render()
      assert chip =~ "disabled"
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
