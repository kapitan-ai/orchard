defmodule OrchardConsole.PlaygroundLive do
  @moduledoc """
  Console playground page — streaming chat UI for operator inference testing.
  """

  use OrchardConsole, :live_view

  alias Orchard.Inference.ChatError
  alias Orchard.InferenceEvent

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
      models_error: nil,
      form: to_form(%{"model" => "", "system" => "", "prompt" => ""}, as: :playground),
      form_errors: %{},
      transcript: [],
      active_run: nil,
      run_status: :idle,
      request_id: nil,
      usage: nil,
      run_error: nil,
      msg_seq: 0
    )
  end

  # ===========================================================================
  # Model loading
  # ===========================================================================

  defp load_models(socket) do
    case playground_impl().list_models() do
      {:ok, []} ->
        assign(socket, models: [], models_error: "No active models available.")

      {:ok, models} ->
        options = Enum.map(models, &model_option/1)
        first = hd(options).value
        form_data = current_form_data(socket) |> Map.put("model", first)

        socket
        |> assign(models: options, models_error: nil)
        |> assign(form: to_form(form_data, as: :playground))

      {:error, error} ->
        assign(socket,
          models: [],
          models_error: error.message || "Active model list unavailable."
        )
    end
  rescue
    _ ->
      assign(socket, models: [], models_error: "Active model list unavailable.")
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
    cond do
      socket.assigns.active_run != nil ->
        {:noreply, socket}

      socket.assigns.models == [] ->
        {:noreply, socket}

      true ->
        handle_submit(socket, params)
    end
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
          msg_seq: 0
        )

      {:noreply, socket}
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
        msg_seq: seq + 2
      )

    case playground_impl().start_stream(self(), run_ref, chat_params) do
      {:ok, _pid} ->
        {:noreply, socket}

      _ ->
        socket =
          socket
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
      |> put_in([Access.key(:assigns), :active_run, :accepted], true)

    {:noreply, socket}
  end

  defp handle_stream(:event, %InferenceEvent{} = event, socket) do
    case InferenceEvent.kind(event) do
      :output_text_delta ->
        delta = event.event.delta
        {:noreply, append_delta(socket, delta)}

      :usage ->
        usage = map_usage(event.event.usage)
        {:noreply, assign(socket, usage: usage, run_status: :streaming)}

      :completed ->
        usage =
          if event.event.usage, do: map_usage(event.event.usage), else: socket.assigns.usage

        socket =
          socket
          |> assign(usage: usage, run_status: :completed)
          |> mark_assistant(:complete)
          |> put_in([Access.key(:assigns), :active_run, :terminal_seen], true)

        {:noreply, socket}

      :failed ->
        error = normalize_failed_event(event)

        socket =
          socket
          |> assign(run_status: :error, run_error: error)
          |> handle_failed_assistant()
          |> put_in([Access.key(:assigns), :active_run, :terminal_seen], true)

        {:noreply, socket}

      _ ->
        # Ignore :accepted, :progress, :tool_call_delta
        {:noreply, assign(socket, run_status: :streaming)}
    end
  end

  defp handle_stream(:finished, {:ok, _summary}, socket) do
    socket =
      if socket.assigns.active_run.terminal_seen do
        socket
      else
        socket |> assign(run_status: :completed) |> mark_assistant(:complete)
      end

    {:noreply, assign(socket, active_run: nil)}
  end

  defp handle_stream(:finished, {:error, error}, socket) do
    socket =
      if socket.assigns.active_run.terminal_seen do
        socket
      else
        socket
        |> assign(run_status: :error, run_error: error)
        |> handle_failed_assistant()
        |> maybe_remove_unaccepted_user()
      end

    {:noreply, assign(socket, active_run: nil)}
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
      Enum.map(socket.assigns.transcript, fn entry ->
        if entry.id == aid do
          if entry.content == "" do
            nil
          else
            %{entry | status: :error}
          end
        else
          entry
        end
      end)
      |> Enum.reject(&is_nil/1)

    assign(socket, transcript: transcript)
  end

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

  defp playground_impl do
    console_config()[:playground_impl] || OrchardConsole.Playground
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end

  # ===========================================================================
  # Render
  # ===========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="grid gap-6 lg:grid-cols-2">
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
            <div :if={@models_error} id="playground-models-error" class="rounded-md bg-amber-50 p-3 text-sm text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
              {@models_error}
            </div>

            <div :if={@run_error} id="playground-error" class="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-900/30 dark:text-red-300">
              {@run_error.message}
            </div>

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
                options={Enum.map(@models, &{&1.label, &1.value})}
                disabled={@active_run != nil}
              />
              <p :if={@form_errors[:model]} id="playground-model-error" class="-mt-2 text-sm text-red-600 dark:text-red-400">
                {@form_errors[:model]}
              </p>
              <.input
                id="playground-system"
                field={@form[:system]}
                type="textarea"
                label="System prompt (optional)"
                rows={2}
                disabled={@active_run != nil}
              />
              <.input
                id="playground-prompt"
                field={@form[:prompt]}
                type="textarea"
                label="Message"
                rows={3}
              />
              <p :if={@form_errors[:prompt]} id="playground-prompt-error" class="-mt-2 text-sm text-red-600 dark:text-red-400">
                {@form_errors[:prompt]}
              </p>
              <:actions>
                <.button
                  id="playground-send"
                  disabled={@active_run != nil || @models == []}
                >
                  Send
                </.button>
              </:actions>
            </.simple_form>

            <div :if={@request_id} id="playground-request-link" class="mt-2">
              <.link
                navigate={"/console/requests/#{@request_id}"}
                class="text-sm font-medium text-navy hover:underline dark:text-sky-400"
              >
                View request {@request_id} →
              </.link>
            </div>
          </div>
        </.card>

        <%!-- Transcript --%>
        <.card>
          <:title>Transcript</:title>

          <div id="playground-transcript" class="space-y-4 min-h-[200px]" aria-live="polite">
            <p :if={@transcript == []} class="text-sm text-slate-400 dark:text-slate-500 italic">
              Send a message to start a conversation.
            </p>

            <div :for={entry <- @transcript} id={"playground-message-#{entry.id}"} class={[
              "rounded-lg p-3 text-sm",
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
                {if(entry.content == "" && entry.status == :streaming, do: "Waiting for response…", else: entry.content)}
              </div>
              <p :if={entry.status == :error} class="mt-2 text-xs text-red-600 dark:text-red-400">
                Response interrupted.
              </p>
            </div>
          </div>

          <div :if={@usage} id="playground-usage" class="mt-4 border-t border-slate-200 dark:border-slate-700 pt-3">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400 mb-2">
              Usage
            </p>
            <div class="grid grid-cols-3 gap-2 text-center">
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Prompt</p>
                <p class="font-mono text-sm text-slate-900 dark:text-slate-100">{@usage.prompt_tokens}</p>
              </div>
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Completion</p>
                <p class="font-mono text-sm text-slate-900 dark:text-slate-100">{@usage.completion_tokens}</p>
              </div>
              <div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Total</p>
                <p class="font-mono text-sm text-slate-900 dark:text-slate-100">{@usage.total_tokens}</p>
              </div>
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
end
