defmodule OrchardConsole.PlaygroundLive do
  @moduledoc """
  Console playground page — streaming chat UI for operator inference testing.
  """

  use OrchardConsole, :live_view

  alias Orchard.Inference.ChatError
  alias Orchard.InferenceEvent

  @sample_prompts [
    %{
      id: "orchard-summary",
      label: "Orchard summary",
      system: "You are a concise assistant. Answer in 2 short sentences.",
      prompt: "What does Orchard do, and why would a support engineer use it?"
    },
    %{
      id: "deployment-brief",
      label: "Deployment brief",
      system:
        "You are an operations analyst. Respond in markdown with exactly three sections: Summary, Risks, Next steps.",
      prompt:
        "A 12-person support team wants to deploy a local LLM gateway for internal troubleshooting. Provide a brief covering latency, reliability, and auditability."
    }
  ]

  # ===========================================================================
  # Mount
  # ===========================================================================

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Playground", active_nav: :playground)
      |> assign_defaults()

    if connected?(socket) do
      {:ok, load_models(socket)}
    else
      {:ok, socket}
    end
  end

  defp assign_defaults(socket) do
    assign(socket,
      models: [],
      models_status: :idle,
      models_error: nil,
      form: to_form(%{"model" => "", "system" => "", "prompt" => ""}, as: :playground),
      form_errors: %{},
      transcript: [],
      active_run: nil,
      run_status: :idle,
      request_id: nil,
      usage: nil,
      run_error: nil,
      msg_seq: 0,
      run_metrics: nil
    )
  end

  # ===========================================================================
  # Model loading
  # ===========================================================================

  defp load_models(socket) do
    case playground_impl().list_models() do
      {:ok, []} ->
        assign(socket,
          models: [],
          models_status: :empty,
          models_error: "No active models available."
        )

      {:ok, models} ->
        options = Enum.map(models, &model_option/1)
        first = hd(options).value
        form_data = current_form_data(socket) |> Map.put("model", first)

        socket
        |> assign(models: options, models_status: :ok, models_error: nil)
        |> assign(form: to_form(form_data, as: :playground))

      {:error, error} ->
        assign(socket,
          models: [],
          models_status: :error,
          models_error: error.message || "Active model list unavailable."
        )
    end
  rescue
    _ ->
      assign(socket,
        models: [],
        models_status: :error,
        models_error: "Active model list unavailable."
      )
  end

  defp model_option(%{model_id: model_id, version: version}) do
    label = "#{model_id}@#{version}"
    %{label: label, value: label}
  end

  # ===========================================================================
  # Events — form validation & submit
  # ===========================================================================

  @impl true
  def handle_event("validate", %{"playground" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :playground), form_errors: %{})}
  end

  def handle_event("submit", %{"playground" => params}, socket) do
    OrchardConsole.LicenseGate.guard(socket, fn ->
      cond do
        socket.assigns.active_run != nil ->
          {:noreply, socket}

        socket.assigns.models == [] ->
          {:noreply, socket}

        true ->
          handle_submit(socket, params)
      end
    end)
  end

  def handle_event("reset", _params, socket) do
    if socket.assigns.active_run != nil do
      {:noreply, socket}
    else
      model = current_form_data(socket)["model"]

      socket =
        socket
        |> assign(
          form: to_form(%{"model" => model, "system" => "", "prompt" => ""}, as: :playground),
          form_errors: %{},
          transcript: [],
          active_run: nil,
          run_status: :idle,
          request_id: nil,
          usage: nil,
          run_error: nil,
          msg_seq: 0,
          run_metrics: nil
        )

      {:noreply, socket}
    end
  end

  def handle_event("apply_sample_prompt", %{"sample_id" => sample_id}, socket) do
    if socket.assigns.active_run != nil do
      {:noreply, socket}
    else
      case Enum.find(@sample_prompts, &(&1.id == sample_id)) do
        nil ->
          {:noreply, socket}

        sample ->
          form_data =
            current_form_data(socket)
            |> Map.put("system", sample.system)
            |> Map.put("prompt", sample.prompt)

          {:noreply,
           assign(socket,
             form: to_form(form_data, as: :playground),
             form_errors: %{}
           )}
      end
    end
  end

  defp handle_submit(socket, params) do
    model = String.trim(params["model"] || "")
    prompt = String.trim(params["prompt"] || "")
    system = String.trim(params["system"] || "")

    errors =
      %{}
      |> maybe_error(model == "", :model, "Please select a model")
      |> maybe_error(prompt == "", :prompt, "Please enter a prompt")

    if errors != %{} do
      {:noreply,
       assign(socket,
         form: to_form(params, as: :playground),
         form_errors: errors
       )}
    else
      do_submit(socket, model, system, prompt, params)
    end
  end

  defp do_submit(socket, model, system, prompt, params) do
    seq = socket.assigns.msg_seq
    user_id = "msg-#{seq}"
    assistant_id = "msg-#{seq + 1}"

    user_entry = %{id: user_id, role: :user, content: prompt, status: :complete}
    assistant_entry = %{id: assistant_id, role: :assistant, content: "", status: :streaming}

    messages = build_messages(socket.assigns.transcript, system, prompt)

    chat_params = %{
      "model" => model,
      "messages" => messages,
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }

    run_ref = make_ref()

    socket =
      socket
      |> assign(
        transcript: socket.assigns.transcript ++ [user_entry, assistant_entry],
        active_run: %{
          ref: run_ref,
          user_id: user_id,
          assistant_id: assistant_id,
          terminal_seen: false,
          accepted: false
        },
        run_status: :starting,
        request_id: nil,
        usage: nil,
        run_error: nil,
        form: to_form(Map.put(params, "prompt", ""), as: :playground),
        form_errors: %{},
        msg_seq: seq + 2,
        run_metrics: new_run_metrics()
      )

    case playground_impl().start_stream(self(), run_ref, chat_params) do
      {:ok, _pid} ->
        {:noreply, socket}

      _ ->
        socket =
          socket
          |> put_run_metric_once(:finished_at_ms)
          |> assign(
            active_run: nil,
            run_status: :error,
            run_error: %{message: "Unable to start playground stream."},
            transcript:
              socket.assigns.transcript
              |> remove_entry(assistant_id)
              |> remove_entry(user_id)
          )

        {:noreply, socket}
    end
  end

  defp build_messages(transcript, system, prompt) do
    messages = if system != "", do: [%{"role" => "system", "content" => system}], else: []

    prior =
      transcript
      |> Enum.filter(fn entry ->
        entry.status == :complete and entry.content != ""
      end)
      |> Enum.map(fn entry ->
        %{"role" => to_string(entry.role), "content" => entry.content}
      end)

    messages ++ prior ++ [%{"role" => "user", "content" => prompt}]
  end

  # ===========================================================================
  # Events — stream messages
  # ===========================================================================

  @impl true
  def handle_info({:playground, ref, type, payload}, socket)
      when type in [:started, :event, :finished] do
    if match_run?(socket, ref) do
      handle_stream(type, payload, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp handle_stream(:started, %{request_id: request_id}, socket) do
    socket =
      socket
      |> assign(request_id: request_id)
      |> put_run_metric_once(:accepted_at_ms)
      |> put_in([Access.key(:assigns), :active_run, :accepted], true)

    {:noreply, socket}
  end

  defp handle_stream(:event, %InferenceEvent{} = event, socket) do
    # Once a terminal event has been seen, ignore late non-terminal events
    # to prevent run_status from reverting (e.g. late :usage after :completed).
    if socket.assigns.active_run.terminal_seen and
         InferenceEvent.kind(event) not in [:completed, :failed] do
      {:noreply, socket}
    else
      handle_event_by_kind(InferenceEvent.kind(event), event, socket)
    end
  end

  defp handle_stream(:finished, {:ok, _summary}, socket) do
    socket =
      if socket.assigns.active_run.terminal_seen do
        socket
      else
        socket
        |> put_run_metric_once(:finished_at_ms)
        |> assign(run_status: :completed)
        |> mark_assistant(:complete)
      end

    {:noreply, assign(socket, active_run: nil)}
  end

  defp handle_stream(:finished, {:error, error}, socket) do
    socket =
      if socket.assigns.active_run.terminal_seen do
        socket
      else
        socket
        |> put_run_metric_once(:finished_at_ms)
        |> assign(run_status: :error, run_error: error)
        |> handle_failed_assistant()
        |> maybe_remove_unaccepted_user()
      end

    {:noreply, assign(socket, active_run: nil)}
  end

  # ===========================================================================
  # Stream event dispatch (called from handle_stream :event)
  # ===========================================================================

  defp handle_event_by_kind(:output_text_delta, event, socket) do
    delta = event.event.delta

    socket =
      if delta != "",
        do: put_run_metric_once(socket, :first_token_at_ms),
        else: socket

    {:noreply, append_delta(socket, delta)}
  end

  defp handle_event_by_kind(:usage, event, socket) do
    usage = map_usage(event.event.usage)
    {:noreply, assign(socket, usage: usage, run_status: :streaming)}
  end

  defp handle_event_by_kind(:completed, event, socket) do
    usage =
      if event.event.usage, do: map_usage(event.event.usage), else: socket.assigns.usage

    socket =
      socket
      |> put_run_metric_once(:finished_at_ms)
      |> assign(usage: usage, run_status: :completed)
      |> mark_assistant(:complete)
      |> put_in([Access.key(:assigns), :active_run, :terminal_seen], true)

    {:noreply, socket}
  end

  defp handle_event_by_kind(:failed, event, socket) do
    error = normalize_failed_event(event)

    socket =
      socket
      |> put_run_metric_once(:finished_at_ms)
      |> assign(run_status: :error, run_error: error)
      |> handle_failed_assistant()
      |> put_in([Access.key(:assigns), :active_run, :terminal_seen], true)

    {:noreply, socket}
  end

  defp handle_event_by_kind(_kind, _event, socket) do
    # Ignore :accepted, :progress, :tool_call_delta
    {:noreply, assign(socket, run_status: :streaming)}
  end

  # ===========================================================================
  # Transcript helpers
  # ===========================================================================

  defp append_delta(socket, delta) do
    aid = socket.assigns.active_run.assistant_id

    transcript =
      Enum.map(socket.assigns.transcript, fn entry ->
        if entry.id == aid, do: %{entry | content: entry.content <> delta}, else: entry
      end)

    assign(socket, transcript: transcript, run_status: :streaming)
  end

  defp mark_assistant(socket, status) do
    aid = socket.assigns.active_run.assistant_id

    transcript =
      Enum.map(socket.assigns.transcript, fn entry ->
        if entry.id == aid, do: %{entry | status: status}, else: entry
      end)

    assign(socket, transcript: transcript)
  end

  defp handle_failed_assistant(socket) do
    aid = socket.assigns.active_run.assistant_id

    transcript =
      socket.assigns.transcript
      |> Enum.map(&failed_assistant_entry(&1, aid))
      |> Enum.reject(&is_nil/1)

    assign(socket, transcript: transcript)
  end

  defp failed_assistant_entry(%{id: id, content: ""}, id), do: nil
  defp failed_assistant_entry(%{id: id} = entry, id), do: %{entry | status: :error}
  defp failed_assistant_entry(entry, _assistant_id), do: entry

  defp remove_entry(transcript, id) do
    Enum.reject(transcript, &(&1.id == id))
  end

  defp maybe_remove_unaccepted_user(socket) do
    if socket.assigns.active_run.accepted do
      socket
    else
      user_id = socket.assigns.active_run.user_id
      assign(socket, transcript: remove_entry(socket.assigns.transcript, user_id))
    end
  end

  # ===========================================================================
  # Content display
  # ===========================================================================

  @think_block_re ~r/<think>.*?<\/think>\s*/s
  @think_open_re ~r/\A<think>[\s\S]*\z/
  @model_turn_tag_re ~r/<end_of_turn>\s*$/

  defp display_content(entry) do
    content = strip_model_artifacts(entry.content)

    if content == "" and entry.status == :streaming do
      "Waiting for response\u2026"
    else
      content
    end
  end

  defp strip_model_artifacts(text) do
    text
    |> then(&Regex.replace(@think_block_re, &1, ""))
    |> then(&Regex.replace(@think_open_re, &1, ""))
    |> then(&Regex.replace(@model_turn_tag_re, &1, ""))
    |> String.trim_leading()
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp match_run?(socket, ref) do
    socket.assigns.active_run != nil and socket.assigns.active_run.ref == ref
  end

  defp map_usage(%{input_tokens: i, output_tokens: o, total_tokens: t}) do
    %{prompt_tokens: i, completion_tokens: o, total_tokens: t}
  end

  defp map_usage(_), do: nil

  defp normalize_failed_event(event) do
    mapping = event |> ChatError.from_failed_event() |> ChatError.api_mapping()

    %{
      phase: :stream,
      type: mapping.type,
      code: mapping.code,
      message: mapping.message,
      param: mapping.param
    }
  end

  defp maybe_error(errors, true, field, msg), do: Map.put(errors, field, msg)
  defp maybe_error(errors, false, _field, _msg), do: errors

  defp current_form_data(socket) do
    %{
      "model" => socket.assigns.form.params["model"] || "",
      "system" => socket.assigns.form.params["system"] || "",
      "prompt" => socket.assigns.form.params["prompt"] || ""
    }
  end

  defp sample_prompts, do: @sample_prompts

  defp playground_impl do
    console_config()[:playground_impl] || OrchardConsole.Playground
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end

  # ===========================================================================
  # Timing helpers
  # ===========================================================================

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp new_run_metrics do
    %{
      submitted_at_ms: now_ms(),
      accepted_at_ms: nil,
      first_token_at_ms: nil,
      finished_at_ms: nil
    }
  end

  defp put_run_metric_once(socket, key) do
    case socket.assigns.run_metrics do
      %{^key => nil} = metrics ->
        assign(socket, run_metrics: %{metrics | key => now_ms()})

      _ ->
        socket
    end
  end

  defp duration_ms(nil, _key), do: nil

  defp duration_ms(metrics, key) do
    case Map.get(metrics, key) do
      nil -> nil
      ts -> ts - metrics.submitted_at_ms
    end
  end

  defp format_duration(nil), do: "\u2014"
  defp format_duration(ms) when ms < 1000, do: "#{ms} ms"

  defp format_duration(ms) do
    seconds = ms / 1000
    :erlang.float_to_binary(seconds, decimals: 1) <> " s"
  end

  defp generation_duration_ms(nil), do: nil

  defp generation_duration_ms(%{first_token_at_ms: nil}), do: nil
  defp generation_duration_ms(%{finished_at_ms: nil}), do: nil

  defp generation_duration_ms(%{first_token_at_ms: first, finished_at_ms: finished})
       when finished >= first,
       do: finished - first

  defp generation_duration_ms(_), do: nil

  defp tokens_per_second(nil, _generation_ms), do: nil
  defp tokens_per_second(_usage, nil), do: nil
  defp tokens_per_second(_usage, generation_ms) when generation_ms <= 0, do: nil

  defp tokens_per_second(%{completion_tokens: tokens}, _) when tokens in [nil, 0], do: nil

  defp tokens_per_second(%{completion_tokens: tokens}, generation_ms) do
    tokens / (generation_ms / 1000.0)
  end

  defp format_rate(nil), do: "\u2014"

  defp format_rate(rate) do
    :erlang.float_to_binary(rate / 1.0, decimals: 1)
  end

  defp result_rail_visible?(assigns) do
    assigns.run_metrics != nil or assigns.request_id != nil or
      assigns.usage != nil or assigns.run_error != nil
  end

  defp terminal_cta_visible?(assigns) do
    assigns.request_id != nil and assigns.active_run == nil and
      assigns.run_status in [:completed, :error]
  end

  # ===========================================================================
  # Render
  # ===========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="grid gap-6 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]">
        <%!-- Control Panel --%>
        <.card>
          <:title>
            <div class="flex items-center gap-3">
              <span>Chat</span>
              <.badge tone={status_tone(@run_status)}>{status_label(@run_status)}</.badge>
            </div>
          </:title>
          <:actions>
            <.button
              id="playground-reset"
              variant={:ghost}
              size={:sm}
              phx-click="reset"
              disabled={@active_run != nil}
            >
              New chat
            </.button>
          </:actions>

          <div class="space-y-4">
            <.state_message
              :if={@models_status == :empty}
              id="playground-models-empty"
              kind={:empty}
              layout={:compact}
              title={@models_error}
              body="Download and import a model from Model Hub, then return here to send your first test message."
            >
              <:action>
                <.link
                  id="playground-browse-model-hub"
                  navigate={~p"/console/model-hub"}
                  class="inline-flex items-center rounded-md bg-navy px-3 py-1.5 text-xs font-medium text-white hover:bg-navy-700 dark:bg-sky-500 dark:hover:bg-sky-400"
                >
                  Browse Model Hub
                </.link>
              </:action>
            </.state_message>

            <.state_message
              :if={@models_status == :error}
              id="playground-models-error"
              kind={:error}
              layout={:compact}
              title={@models_error}
            />

            <.state_message
              :if={@run_error}
              id="playground-error"
              kind={:error}
              layout={:compact}
              title={@run_error.message}
            />

            <.simple_form
              id="playground-form"
              for={@form}
              phx-change="validate"
              phx-submit="submit"
            >
              <.input
                id="playground-model"
                field={@form[:model]}
                type="select"
                label="Model"
                size={:lg}
                options={Enum.map(@models, &{&1.label, &1.value})}
                errors={List.wrap(@form_errors[:model])}
                disabled={@active_run != nil}
              />
              <p
                :if={present_text?(@form[:model].value)}
                id="playground-model-selected"
                aria-live="polite"
                class="-mt-3 font-mono text-xs text-slate-500 dark:text-slate-400 break-all"
              >
                Selected: {@form[:model].value}
              </p>
              <.input
                id="playground-system"
                field={@form[:system]}
                type="textarea"
                label="System prompt (optional)"
                rows={2}
                disabled={@active_run != nil}
              />
              <div id="playground-sample-prompts" class="flex flex-wrap items-center gap-2">
                <span class="text-xs text-slate-500 dark:text-slate-400">Sample prompts:</span>
                <.button
                  :for={sample <- sample_prompts()}
                  id={"playground-sample-prompt-#{sample.id}"}
                  type="button"
                  variant={:secondary}
                  size={:sm}
                  phx-click="apply_sample_prompt"
                  phx-value-sample_id={sample.id}
                  disabled={@active_run != nil}
                >
                  {sample.label}
                </.button>
              </div>
              <.input
                id="playground-prompt"
                field={@form[:prompt]}
                type="textarea"
                label="Message"
                size={:lg}
                rows={3}
                errors={List.wrap(@form_errors[:prompt])}
                phx-hook="SubmitOnModEnter"
              />
              <p id="playground-submit-hint" class="-mt-2 text-xs text-slate-500 dark:text-slate-400">
                Press Cmd/Ctrl + Enter to send.
              </p>
              <:actions>
                <.button
                  id="playground-send"
                  type="submit"
                  disabled={@active_run != nil || @models == []}
                >
                  Send
                </.button>
              </:actions>
            </.simple_form>
          </div>
        </.card>

        <%!-- Transcript --%>
        <.card>
          <:title>Transcript</:title>

          <div
            id="playground-transcript"
            phx-hook="AutoScrollBottom"
            data-auto-scroll={to_string(@active_run != nil)}
            class="playground-transcript-scroll space-y-4 min-h-[200px]"
            aria-live="polite"
          >
            <.state_message
              :if={@transcript == []}
              id="playground-transcript-empty"
              kind={:empty}
              layout={:compact}
              body="Send a prompt to start a conversation. Streamed responses appear here in real time."
            />

            <div :for={entry <- @transcript} id={"playground-message-#{entry.id}"} class={[
              "rounded-lg p-3 text-base",
              entry.role == :user && "bg-slate-50 dark:bg-slate-900/60",
              entry.role == :assistant && "bg-navy/5 dark:bg-sky-500/5"
            ]}>
              <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400 mb-1">
                {if(entry.role == :user, do: "User", else: "Assistant")}
                <span :if={entry.status == :streaming} class="ml-1 text-violet-500 dark:text-violet-400">
                  ● streaming
                </span>
              </p>
              <div class="whitespace-pre-wrap break-words text-slate-900 dark:text-slate-100">
                {display_content(entry)}
              </div>
              <p :if={entry.status == :error} class="mt-2 text-xs text-red-600 dark:text-red-400">
                Response interrupted.
              </p>
            </div>
          </div>

          <%!-- Result Rail --%>
          <div :if={result_rail_visible?(assigns)} id="playground-result-rail" class="mt-4 border-t border-slate-200 dark:border-slate-700 pt-3">
            <div class="playground-result-grid">
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Request ID</p>
                <p id="playground-result-request-id" class="font-mono text-sm text-slate-900 dark:text-slate-100 truncate">
                  {@request_id || "\u2014"}
                </p>
              </div>
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Accepted</p>
                <p id="playground-result-accepted" class="font-mono text-sm text-slate-900 dark:text-slate-100">
                  {format_duration(duration_ms(@run_metrics, :accepted_at_ms))}
                </p>
              </div>
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">TTFT</p>
                <p id="playground-result-first-token" class="font-mono text-sm text-slate-900 dark:text-slate-100">
                  {format_duration(duration_ms(@run_metrics, :first_token_at_ms))}
                </p>
              </div>
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Generation</p>
                <p id="playground-result-generation" class="font-mono text-sm text-slate-900 dark:text-slate-100">
                  {format_duration(generation_duration_ms(@run_metrics))}
                </p>
              </div>
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Total latency</p>
                <p id="playground-result-total" class="font-mono text-sm text-slate-900 dark:text-slate-100">
                  {format_duration(duration_ms(@run_metrics, :finished_at_ms))}
                </p>
              </div>
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Prompt tokens</p>
                <p id="playground-result-prompt-tokens" class="font-mono text-sm text-slate-900 dark:text-slate-100">
                  {if @usage, do: @usage.prompt_tokens, else: "\u2014"}
                </p>
              </div>
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Completion</p>
                <p id="playground-result-completion-tokens" class="font-mono text-sm text-slate-900 dark:text-slate-100">
                  {if @usage, do: @usage.completion_tokens, else: "\u2014"}
                </p>
              </div>
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Total tokens</p>
                <p id="playground-result-total-tokens" class="font-mono text-sm text-slate-900 dark:text-slate-100">
                  {if @usage, do: @usage.total_tokens, else: "\u2014"}
                </p>
              </div>
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Tok/s</p>
                <p id="playground-result-tokens-per-second" class="font-mono text-sm text-slate-900 dark:text-slate-100">
                  {format_rate(tokens_per_second(@usage, generation_duration_ms(@run_metrics)))}
                </p>
              </div>
            </div>

            <div :if={terminal_cta_visible?(assigns)} class="mt-3">
              <.link
                id="playground-view-request"
                navigate={"/console/requests/#{@request_id}"}
                class="inline-flex items-center rounded-md bg-navy px-3 py-1.5 text-sm font-medium text-white hover:bg-navy-700 dark:bg-sky-500 dark:hover:bg-sky-400"
              >
                View request {@request_id} →
              </.link>
            </div>
          </div>
        </.card>
      </div>
    </div>
    """
  end

  # ===========================================================================
  # Status helpers
  # ===========================================================================

  defp status_tone(:idle), do: :neutral
  defp status_tone(:starting), do: :warning
  defp status_tone(:streaming), do: :processing
  defp status_tone(:completed), do: :success
  defp status_tone(:error), do: :error

  defp status_label(:idle), do: "Ready"
  defp status_label(:starting), do: "Starting"
  defp status_label(:streaming), do: "Streaming"
  defp status_label(:completed), do: "Completed"
  defp status_label(:error), do: "Error"

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false
end
