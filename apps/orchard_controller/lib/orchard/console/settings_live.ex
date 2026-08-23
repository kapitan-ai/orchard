defmodule OrchardConsole.SettingsLive do
  @moduledoc """
  Console Settings page.
  """

  use OrchardConsole, :live_view

  alias Orchard.API.Transport
  alias Orchard.ConsoleSettings

  @empty_defaults %{
    default_model: nil,
    temperature: nil,
    top_p: nil,
    max_completion_tokens: nil
  }
  @inference_default_fields [:default_model, :temperature, :top_p, :max_completion_tokens]
  @inference_default_field_keys Enum.map(@inference_default_fields, &Atom.to_string/1)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Settings", active_nav: :settings)
      |> assign_inference_defaults(@empty_defaults)
      |> assign(
        default_model_options: [],
        default_model_options_status: :idle,
        default_model_options_error: nil,
        inference_defaults_status: :idle,
        inference_defaults_error: nil,
        advanced_debug_snapshot: advanced_debug_loading_snapshot(),
        advanced_debug_refreshing?: false,
        advanced_debug_refresh_ref: nil,
        advanced_debug_refresh_timeout_ref: nil
      )

    if connected?(socket) do
      {:ok, socket |> load_inference_defaults() |> begin_advanced_debug_refresh()}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event(
        "refresh_now",
        _params,
        %{assigns: %{advanced_debug_refreshing?: true}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("refresh_now", _params, socket) do
    {:noreply, begin_advanced_debug_refresh(socket)}
  end

  @impl true
  def handle_event(
        "save_inference_defaults",
        _params,
        %{assigns: %{inference_defaults_status: :error}} = socket
      ) do
    {:noreply, put_flash(socket, :error, "Inference defaults unavailable.")}
  end

  def handle_event("save_inference_defaults", %{"settings_inference_defaults" => params}, socket)
      when is_map(params) do
    params = preserve_omitted_inference_default_fields(params, socket)

    case safe_save_inference_defaults(params) do
      {:ok, defaults} ->
        {:noreply,
         socket
         |> assign(inference_defaults_status: :ok, inference_defaults_error: nil)
         |> assign_inference_defaults(defaults)
         |> assign_default_model_options(defaults.default_model)
         |> put_flash(:info, "Inference defaults saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        restored_fields = restored_inference_default_fields(params)

        socket =
          assign(socket,
            inference_defaults_form:
              params
              |> failed_inference_defaults_form_params(socket)
              |> to_form(
                as: :settings_inference_defaults,
                errors:
                  filter_restored_inference_default_errors(changeset.errors, restored_fields)
              )
          )

        socket = maybe_put_malformed_inference_defaults_flash(socket, restored_fields)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Inference defaults unavailable.")}

      _unexpected ->
        {:noreply, put_flash(socket, :error, "Inference defaults unavailable.")}
    end
  end

  def handle_event("save_inference_defaults", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:advanced_debug_refresh_timeout, ref},
        %{assigns: %{advanced_debug_refresh_ref: ref}} = socket
      ) do
    socket = cancel_async(socket, {:advanced_debug_refresh, ref}, :advanced_debug_refresh_timeout)

    {:noreply,
     assign(socket,
       advanced_debug_snapshot: advanced_debug_timeout_snapshot(),
       advanced_debug_refreshing?: false,
       advanced_debug_refresh_ref: nil,
       advanced_debug_refresh_timeout_ref: nil
     )}
  end

  def handle_info({:advanced_debug_refresh_timeout, _stale_ref}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(
        {:advanced_debug_refresh, ref},
        {:ok, snapshot},
        %{assigns: %{advanced_debug_refresh_ref: ref}} = socket
      ) do
    socket = cancel_advanced_debug_refresh_timeout(socket)

    {:noreply,
     assign(socket,
       advanced_debug_snapshot: snapshot,
       advanced_debug_refreshing?: false,
       advanced_debug_refresh_ref: nil,
       advanced_debug_refresh_timeout_ref: nil
     )}
  end

  def handle_async(
        {:advanced_debug_refresh, ref},
        {:exit, _reason},
        %{assigns: %{advanced_debug_refresh_ref: ref}} = socket
      ) do
    socket = cancel_advanced_debug_refresh_timeout(socket)

    {:noreply,
     assign(socket,
       advanced_debug_snapshot: fallback_advanced_debug_snapshot(),
       advanced_debug_refreshing?: false,
       advanced_debug_refresh_ref: nil,
       advanced_debug_refresh_timeout_ref: nil
     )}
  end

  def handle_async({:advanced_debug_refresh, _stale_ref}, _result, socket), do: {:noreply, socket}

  defp load_inference_defaults(socket) do
    case safe_get_inference_defaults() do
      {:ok, defaults} ->
        socket
        |> assign(inference_defaults_status: :ok, inference_defaults_error: nil)
        |> assign_inference_defaults(defaults)
        |> assign_default_model_options(defaults.default_model)

      {:error, message} ->
        socket
        |> assign(inference_defaults_status: :error, inference_defaults_error: message)
        |> assign_inference_defaults(@empty_defaults)
        |> assign_default_model_options(nil)
    end
  end

  defp safe_get_inference_defaults do
    {:ok, settings_impl().get_playground_defaults()}
  rescue
    _ -> {:error, "Inference defaults unavailable."}
  catch
    :exit, _reason -> {:error, "Inference defaults unavailable."}
    _kind, _reason -> {:error, "Inference defaults unavailable."}
  end

  defp safe_save_inference_defaults(params) do
    settings_impl().save_playground_defaults(params)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, _reason -> {:error, :unavailable}
  end

  defp assign_inference_defaults(socket, defaults) do
    assign(socket,
      inference_defaults_form:
        defaults
        |> inference_defaults_form_params()
        |> to_form(as: :settings_inference_defaults)
    )
  end

  defp inference_defaults_form_params(defaults) do
    %{
      "default_model" => defaults.default_model || "",
      "temperature" => form_value(defaults.temperature),
      "top_p" => form_value(defaults.top_p),
      "max_completion_tokens" => form_value(defaults.max_completion_tokens)
    }
  end

  defp form_value(nil), do: ""
  defp form_value(value), do: to_string(value)

  defp assign_default_model_options(socket, saved_model) do
    case playground_impl().list_models() do
      {:ok, models} ->
        assign(socket,
          default_model_options:
            models
            |> versionless_model_options()
            |> include_saved_model_option(saved_model),
          default_model_options_status: :ok,
          default_model_options_error: nil
        )

      {:error, error} ->
        assign_default_model_options_error(socket, saved_model, error_message(error))
    end
  rescue
    _ -> assign_default_model_options_error(socket, saved_model)
  catch
    :exit, _reason -> assign_default_model_options_error(socket, saved_model)
    _kind, _reason -> assign_default_model_options_error(socket, saved_model)
  end

  defp error_message(%{message: message}), do: message
  defp error_message(_error), do: nil

  defp assign_default_model_options_error(
         socket,
         saved_model,
         message \\ "Active model list unavailable."
       ) do
    assign(socket,
      default_model_options: saved_model_option(saved_model),
      default_model_options_status: :error,
      default_model_options_error: message || "Active model list unavailable."
    )
  end

  defp versionless_model_options(models) do
    models
    |> Enum.map(&Map.get(&1, :model_id))
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
    |> Enum.map(&{&1, &1})
  end

  defp include_saved_model_option(options, saved_model) do
    saved_option = saved_model_option(saved_model)

    with [{_label, value}] <- saved_option,
         false <- Enum.any?(options, fn {_label, option_value} -> option_value == value end) do
      saved_option ++ options
    else
      _saved_option_or_existing_value -> options
    end
  end

  defp saved_model_option(model_id) when is_binary(model_id) do
    model_id = String.trim(model_id)

    if model_id == "" do
      []
    else
      [{model_id, model_id}]
    end
  end

  defp saved_model_option(_model_id), do: []

  defp failed_inference_defaults_form_params(params, socket) do
    Enum.reduce(@inference_default_field_keys, %{}, fn key, acc ->
      value = Map.get(params, key)
      Map.put(acc, key, safe_failed_inference_default_form_value(value, socket, key))
    end)
  end

  defp restored_inference_default_fields(params) do
    params
    |> malformed_inference_default_fields()
    |> MapSet.new()
  end

  defp malformed_inference_default_fields(params) do
    Enum.filter(@inference_default_fields, fn field ->
      value = Map.get(params, Atom.to_string(field))
      not is_binary(value)
    end)
  end

  defp filter_restored_inference_default_errors(errors, restored_fields) do
    Enum.reject(errors, fn {field, _error} -> MapSet.member?(restored_fields, field) end)
  end

  defp maybe_put_malformed_inference_defaults_flash(socket, restored_fields) do
    if MapSet.size(restored_fields) > 0 do
      put_flash(
        socket,
        :error,
        "Some inference defaults were restored because the submitted form data was malformed."
      )
    else
      socket
    end
  end

  defp safe_failed_inference_default_form_value(value, _socket, _key) when is_binary(value),
    do: value

  defp safe_failed_inference_default_form_value(_value, socket, key),
    do: current_inference_default_form_value(socket, key)

  defp preserve_omitted_inference_default_fields(params, socket) do
    Enum.reduce(@inference_default_field_keys, params, fn key, params ->
      Map.put_new(params, key, current_inference_default_form_value(socket, key))
    end)
  end

  defp current_inference_default_form_value(socket, key) do
    socket.assigns.inference_defaults_form.params[key] || ""
  end

  defp begin_advanced_debug_refresh(socket) do
    ref = make_ref()
    live_view = self()

    timeout_ref =
      Process.send_after(
        live_view,
        {:advanced_debug_refresh_timeout, ref},
        advanced_debug_refresh_timeout_ms()
      )

    socket
    |> start_async({:advanced_debug_refresh, ref}, fn -> safe_fetch_advanced_debug_snapshot() end)
    |> assign(
      advanced_debug_refreshing?: true,
      advanced_debug_refresh_ref: ref,
      advanced_debug_refresh_timeout_ref: timeout_ref
    )
  end

  defp cancel_advanced_debug_refresh_timeout(socket) do
    case socket.assigns.advanced_debug_refresh_timeout_ref do
      timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _other -> false
    end

    socket
  end

  defp safe_fetch_advanced_debug_snapshot do
    fetch_advanced_debug_snapshot()
  rescue
    _ -> fallback_advanced_debug_snapshot()
  catch
    :exit, _reason -> fallback_advanced_debug_snapshot()
    _kind, _reason -> fallback_advanced_debug_snapshot()
  end

  defp fetch_advanced_debug_snapshot do
    %{
      runtime: fetch_runtime_snapshot(),
      transport: safe_transport_metadata(),
      refreshed_at: DateTime.utc_now()
    }
  end

  defp fallback_advanced_debug_snapshot do
    %{
      runtime: runtime_error_snapshot("Runtime snapshot unavailable."),
      transport: safe_transport_metadata(),
      refreshed_at: DateTime.utc_now()
    }
  end

  defp advanced_debug_timeout_snapshot do
    %{
      runtime: runtime_error_snapshot("Runtime snapshot timed out."),
      transport: safe_transport_metadata(),
      refreshed_at: DateTime.utc_now()
    }
  end

  defp fetch_runtime_snapshot do
    case runtime_impl().snapshot() do
      {:ok, snapshot} -> normalize_runtime_snapshot(snapshot)
      {:error, error} -> runtime_error_snapshot(error)
    end
  rescue
    _ -> runtime_error_snapshot("Runtime snapshot unavailable.")
  end

  defp normalize_runtime_snapshot(snapshot) do
    %{
      status: :ok,
      message: nil,
      worker_state: Map.get(snapshot, :worker_state, :unknown),
      loaded_models_count: snapshot |> Map.get(:loaded_models, []) |> length(),
      active_request_count: Map.get(snapshot, :active_request_count, 0),
      node_metadata: Map.get(snapshot, :node_metadata),
      runtime_health: Map.get(snapshot, :runtime_health)
    }
  end

  defp runtime_error_snapshot(message) when is_binary(message) do
    %{
      status: :error,
      message: message,
      worker_state: :unknown,
      loaded_models_count: 0,
      active_request_count: 0,
      node_metadata: nil,
      runtime_health: nil
    }
  end

  defp runtime_error_snapshot(error) when is_map(error) do
    %{
      status: Map.get(error, :status, :error),
      message: Map.get(error, :message, "Runtime snapshot unavailable."),
      worker_state: :unknown,
      loaded_models_count: 0,
      active_request_count: 0,
      node_metadata: nil,
      runtime_health: nil
    }
  end

  defp advanced_debug_loading_snapshot do
    %{
      runtime: %{
        status: :loading,
        message: nil,
        worker_state: :unknown,
        loaded_models_count: 0,
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: nil
      },
      transport: safe_transport_metadata(),
      refreshed_at: nil
    }
  end

  defp safe_transport_metadata do
    Transport.metadata()
  rescue
    _ -> unavailable_transport_metadata()
  catch
    _kind, _reason -> unavailable_transport_metadata()
  end

  defp unavailable_transport_metadata do
    %{mode: "unavailable", degraded: true, cert_source: "unavailable"}
  end

  defp runtime_impl do
    console_config()[:runtime_impl] || OrchardConsole.Runtime
  end

  defp playground_impl do
    console_config()[:playground_impl] || OrchardConsole.Playground
  end

  defp settings_impl do
    console_config()[:settings_impl] || ConsoleSettings
  end

  defp advanced_debug_refresh_timeout_ms do
    case console_config()[:advanced_debug_refresh_timeout_ms] do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _other -> 5_000
    end
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end

  defp advanced_runtime_badge_tone(%{status: :loading}), do: :neutral
  defp advanced_runtime_badge_tone(%{status: status}) when status != :ok, do: :error
  defp advanced_runtime_badge_tone(%{runtime_health: %{ready: false}}), do: :error

  defp advanced_runtime_badge_tone(%{runtime_health: %{health_code: code}})
       when is_binary(code) and code != "",
       do: :warning

  defp advanced_runtime_badge_tone(%{worker_state: :idle}), do: :success
  defp advanced_runtime_badge_tone(%{worker_state: :busy}), do: :processing

  defp advanced_runtime_badge_tone(%{worker_state: state}) when state in [:starting, :stopping],
    do: :warning

  defp advanced_runtime_badge_tone(%{worker_state: :failed}), do: :error
  defp advanced_runtime_badge_tone(_runtime), do: :neutral

  defp advanced_runtime_badge_label(%{status: :loading}), do: "Loading"
  defp advanced_runtime_badge_label(%{status: status}) when status != :ok, do: "Unavailable"
  defp advanced_runtime_badge_label(%{runtime_health: %{ready: false}}), do: "Unhealthy"

  defp advanced_runtime_badge_label(%{runtime_health: %{health_code: code}})
       when is_binary(code) and code != "",
       do: "Degraded"

  defp advanced_runtime_badge_label(%{worker_state: state}), do: worker_state_label(state)
  defp advanced_runtime_badge_label(_runtime), do: "Unknown"

  defp worker_state_label(state) when is_atom(state) do
    state
    |> Atom.to_string()
    |> humanize_atom_label()
  end

  defp worker_state_label(_state), do: "Unknown"

  defp runtime_health_label(%{health_code: code}) when is_binary(code) and code != "", do: code

  defp runtime_health_label(%{health_message: message}) when is_binary(message) and message != "",
    do: message

  defp runtime_health_label(%{ready: true}), do: "Ready"
  defp runtime_health_label(%{ready: false}), do: "Unhealthy"
  defp runtime_health_label(nil), do: "—"
  defp runtime_health_label(_health), do: "Unsupported"

  defp node_display_name(metadata) when is_map(metadata) do
    Enum.find_value([:display_name, :hostname, :node_id], "—", fn key ->
      case non_empty(Map.get(metadata, key)) do
        "—" -> nil
        value -> value
      end
    end)
  end

  defp node_display_name(_metadata), do: "—"

  defp node_worker_backend(%{worker_backend: value}), do: non_empty(value)
  defp node_worker_backend(_metadata), do: "—"

  defp non_empty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "—"
      trimmed -> trimmed
    end
  end

  defp non_empty(_value), do: "—"

  defp humanize_atom_label(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <section id="settings-appearance-card">
        <.card variant={:primary}>
          <:title>Appearance</:title>
          <:subtitle>Theme preference is controlled from the sidebar footer.</:subtitle>
          <div class="space-y-4 text-sm text-slate-600 dark:text-slate-300">
            <p>
              Orchard Console supports three appearance modes: <strong>System</strong>,
              <strong>Light</strong>, and <strong>Dark</strong>.
            </p>
            <p>
              The browser stores the selected mode in the <code class="font-mono text-slate-900 dark:text-slate-100">orchard_console_theme</code>
              cookie. This preference has no server-side persistence.
            </p>
            <p>
              Use the existing theme control in the sidebar footer to change modes.
            </p>
          </div>
        </.card>
      </section>

      <section id="settings-inference-defaults-card">
        <.card>
          <:title>Inference Defaults</:title>
          <:subtitle>Defaults applied to new Playground sessions.</:subtitle>

          <div class="space-y-4">
            <.state_message
              :if={@inference_defaults_status == :error}
              id="settings-inference-defaults-error"
              kind={:error}
              layout={:compact}
              title={@inference_defaults_error}
              body="Saved defaults were not loaded, so saving is disabled."
            />

            <.state_message
              :if={@default_model_options_status == :error}
              id="settings-default-models-error"
              kind={:error}
              layout={:compact}
              title={@default_model_options_error}
              body="The saved model value is shown below, but the active model list is unavailable."
            />

            <.simple_form
              id="settings-inference-defaults-form"
              for={@inference_defaults_form}
              phx-submit="save_inference_defaults"
            >
              <.input
                id="settings-default-model"
                field={@inference_defaults_form[:default_model]}
                type="select"
                label="Default model"
                prompt="No default model"
                options={@default_model_options}
                disabled={@inference_defaults_status == :error or @default_model_options_status == :error}
              />
              <.input
                id="settings-temperature"
                field={@inference_defaults_form[:temperature]}
                type="text"
                label="Temperature"
                placeholder="Unset"
                disabled={@inference_defaults_status == :error}
              />
              <.input
                id="settings-top-p"
                field={@inference_defaults_form[:top_p]}
                type="text"
                label="Top P"
                placeholder="Unset"
                disabled={@inference_defaults_status == :error}
              />
              <.input
                id="settings-max-completion-tokens"
                field={@inference_defaults_form[:max_completion_tokens]}
                type="text"
                label="Max completion tokens"
                placeholder="Unset"
                disabled={@inference_defaults_status == :error}
              />
              <:actions>
                <.button
                  id="settings-save-inference-defaults"
                  type="submit"
                  disabled={@inference_defaults_status == :error}
                >
                  Save defaults
                </.button>
              </:actions>
            </.simple_form>
          </div>
        </.card>
      </section>

      <section id="settings-advanced-card">
        <.card padding={:none}>
          <:title>Advanced</:title>
          <:subtitle>Runtime and debugging</:subtitle>

          <.disclosure_section
            id="settings-advanced-debug-disclosure"
            title="Runtime / config snapshot"
            summary_id="settings-advanced-debug-summary"
            default_open={false}
          >
            <:summary>
              Read-only runtime, health, and transport metadata for support diagnostics.
            </:summary>

            <div class="space-y-4">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <.badge tone={advanced_runtime_badge_tone(@advanced_debug_snapshot.runtime)}>
                  {advanced_runtime_badge_label(@advanced_debug_snapshot.runtime)}
                </.badge>
                <.button
                  id="settings-advanced-refresh-now"
                  variant={:ghost}
                  size={:sm}
                  phx-click="refresh_now"
                  disabled={@advanced_debug_refreshing?}
                >
                  {if @advanced_debug_refreshing?, do: "Refreshing…", else: "Refresh now"}
                </.button>
              </div>

              <p
                :if={@advanced_debug_snapshot.runtime.message}
                class="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800 dark:border-amber-800/60 dark:bg-amber-950/30 dark:text-amber-200"
              >
                {@advanced_debug_snapshot.runtime.message}
              </p>

              <dl class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                <div>
                  <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                    Worker state
                  </dt>
                  <dd
                    id="settings-advanced-worker-state"
                    class="mt-1 text-sm font-mono text-slate-900 dark:text-slate-100"
                  >
                    {worker_state_label(@advanced_debug_snapshot.runtime.worker_state)}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                    Loaded models
                  </dt>
                  <dd
                    id="settings-advanced-loaded-models"
                    class="mt-1 text-sm font-mono text-slate-900 dark:text-slate-100"
                  >
                    {@advanced_debug_snapshot.runtime.loaded_models_count}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                    Active requests
                  </dt>
                  <dd
                    id="settings-advanced-active-requests"
                    class="mt-1 text-sm font-mono text-slate-900 dark:text-slate-100"
                  >
                    {@advanced_debug_snapshot.runtime.active_request_count}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                    Runtime health
                  </dt>
                  <dd
                    id="settings-advanced-runtime-health"
                    class="mt-1 text-sm font-mono text-slate-900 dark:text-slate-100"
                  >
                    {runtime_health_label(@advanced_debug_snapshot.runtime.runtime_health)}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                    Node
                  </dt>
                  <dd
                    id="settings-advanced-node"
                    class="mt-1 text-sm font-mono text-slate-900 dark:text-slate-100"
                  >
                    {node_display_name(@advanced_debug_snapshot.runtime.node_metadata)}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                    Worker backend
                  </dt>
                  <dd
                    id="settings-advanced-worker-backend"
                    class="mt-1 text-sm font-mono text-slate-900 dark:text-slate-100"
                  >
                    {node_worker_backend(@advanced_debug_snapshot.runtime.node_metadata)}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                    Transport mode
                  </dt>
                  <dd
                    id="settings-advanced-transport-mode"
                    class="mt-1 text-sm font-mono text-slate-900 dark:text-slate-100"
                  >
                    {@advanced_debug_snapshot.transport.mode}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                    Cert source
                  </dt>
                  <dd
                    id="settings-advanced-cert-source"
                    class="mt-1 text-sm font-mono text-slate-900 dark:text-slate-100"
                  >
                    {@advanced_debug_snapshot.transport.cert_source}
                  </dd>
                </div>
              </dl>
            </div>
          </.disclosure_section>
        </.card>
      </section>
    </div>
    """
  end
end
