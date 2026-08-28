defmodule Orchard.Portal.KeysLive do
  @moduledoc """
  Authenticated developer-portal key list, mint, and revoke surface.
  """

  use Orchard.Portal, :live_view

  alias Orchard.Governance

  @revalidate_ms 5_000

  @impl true
  def mount(%{"organization_slug" => slug}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "API keys")
      |> assign(:organization_slug, slug)
      |> assign(:keys, [])
      |> assign(:active_portal_count, 0)
      |> assign(:mint_open?, false)
      |> assign(:revoke_key, nil)
      |> assign(:revoke_confirmation, "")
      |> assign(:generated_secret, nil)
      |> assign(:copy_status, :idle)
      |> assign(:stored_ack, false)
      |> assign(:mint_error, nil)
      |> assign(:revoke_error, nil)
      |> assign(:focus_cap_status?, false)
      |> assign(:key_name, "")
      |> refresh_keys()

    if connected?(socket) do
      Process.send_after(self(), :revalidate_portal_session, @revalidate_ms)
    end

    {:ok, socket, temporary_assigns: [focus_cap_status?: false]}
  end

  @impl true
  def handle_event("open_mint", _params, socket) do
    if socket.assigns.active_portal_count >= 10 do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:mint_open?, true)
       |> assign(:mint_error, nil)
       |> assign(:key_name, "")}
    end
  end

  def handle_event("close_mint", _params, socket) do
    {:noreply,
     socket
     |> assign(:mint_open?, false)
     |> assign(:mint_error, nil)
     |> assign(:key_name, "")}
  end

  def handle_event("mint_key", %{"key" => %{"name" => name}}, socket) do
    name = String.trim(name || "")

    case Governance.create_portal_api_key(
           socket.assigns.portal_token,
           socket.assigns.organization_slug,
           %{
             name: name
           }
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:mint_open?, false)
         |> assign(:generated_secret, result)
         |> assign(:copy_status, :idle)
         |> assign(:stored_ack, false)
         |> assign(:mint_error, nil)
         |> refresh_keys()}

      {:error, :portal_key_limit_reached} ->
        {:noreply,
         socket
         |> assign(:key_name, name)
         |> reconcile_key_limit()}

      {:error, :invalid_session} ->
        {:noreply, expire_session(socket)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:key_name, name)
         |> assign(:mint_error, first_error(changeset))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:key_name, name)
         |> assign(:mint_error, "Could not mint that key.")}
    end
  end

  def handle_event("acknowledge_secret", %{"ack" => value}, socket) do
    {:noreply, assign(socket, :stored_ack, value in ["true", "on"])}
  end

  def handle_event("dismiss_secret", _params, socket) do
    if dismiss_allowed?(socket.assigns) do
      {:noreply, assign(socket, :generated_secret, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("generated_secret_copied", %{"api_key_id" => api_key_id}, socket) do
    if matching_secret?(socket.assigns.generated_secret, api_key_id) do
      {:noreply, assign(socket, :copy_status, :copied)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("generated_secret_copy_failed", %{"api_key_id" => api_key_id}, socket) do
    if matching_secret?(socket.assigns.generated_secret, api_key_id) do
      {:noreply, assign(socket, :copy_status, :failed)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_revoke", %{"id" => id}, socket) do
    key = Enum.find(socket.assigns.keys, &(&1.id == id and &1.revocable?))

    {:noreply,
     socket
     |> assign(:revoke_key, key)
     |> assign(:revoke_confirmation, "")
     |> assign(:revoke_error, nil)}
  end

  def handle_event("update_revoke_confirmation", params, socket) do
    confirmation = Map.get(params, "confirmation", "")
    {:noreply, assign(socket, :revoke_confirmation, confirmation)}
  end

  def handle_event("close_revoke", _params, socket) do
    {:noreply,
     socket
     |> assign(:revoke_key, nil)
     |> assign(:revoke_error, nil)}
  end

  def handle_event("revoke_key", _params, socket) do
    key = socket.assigns.revoke_key

    cond do
      is_nil(key) ->
        {:noreply, socket}

      socket.assigns.revoke_confirmation != key.name ->
        {:noreply, socket}

      true ->
        case Governance.revoke_portal_api_key(
               socket.assigns.portal_token,
               socket.assigns.organization_slug,
               key.id
             ) do
          {:ok, _api_key} ->
            {:noreply,
             socket
             |> assign(:revoke_key, nil)
             |> assign(:revoke_confirmation, "")
             |> assign(:revoke_error, nil)
             |> refresh_keys()}

          {:error, :invalid_session} ->
            {:noreply, expire_session(socket)}

          {:error, _reason} ->
            {:noreply, assign(socket, :revoke_error, "Could not revoke that key.")}
        end
    end
  end

  @impl true
  def handle_info(:revalidate_portal_session, socket) do
    case Governance.validate_portal_session(
           socket.assigns.portal_token,
           socket.assigns.organization_slug,
           touch: false
         ) do
      {:ok, _result} ->
        Process.send_after(self(), :revalidate_portal_session, @revalidate_ms)
        {:noreply, socket}

      {:error, :invalid_session} ->
        {:noreply, expire_session(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="portal-keys" class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-lg font-semibold text-slate-50">API keys</h1>
          <p class="mt-1 text-sm text-slate-400">
            Tenant-direct keys for <span class="font-mono text-slate-300">{@organization_slug}</span>
          </p>
        </div>
        <div class="flex items-center gap-3">
          <span class="font-mono text-sm text-slate-300">{@active_portal_count} / 10</span>
          <button
            type="button"
            id="portal-mint-button"
            phx-click="open_mint"
            disabled={@active_portal_count >= 10}
            class="rounded-md bg-sky-500 px-3 py-2 text-sm font-medium text-slate-950 transition-colors hover:bg-sky-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400/40 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-900 disabled:cursor-not-allowed disabled:bg-slate-600 disabled:text-slate-300"
          >
            {if @keys == [], do: "Mint your first key", else: "Mint key"}
          </button>
        </div>
      </div>

      <p
        id="portal-key-cap-message"
        class="text-sm text-slate-400"
        role="status"
        aria-atomic="true"
        tabindex="-1"
      >
        <span
          :if={@active_portal_count >= 10}
          phx-mounted={
            if @focus_cap_status?,
              do: Phoenix.LiveView.JS.focus(to: "#portal-key-cap-message")
          }
        >
          Portal cap reached — revoke a key to mint a new one.
        </span>
      </p>

      <div
        :if={@keys == []}
        id="portal-keys-empty"
        class="rounded-lg border border-slate-700 bg-slate-800 px-6 py-12 text-center"
      >
        <h2 class="text-base font-medium text-slate-50">No API keys yet</h2>
        <p class="mt-2 text-sm text-slate-400">
          Mint a key to call the Orchard inference API from your app or agent.
        </p>
      </div>

      <div
        :if={@keys != []}
        id="portal-keys-list"
        class="overflow-x-auto rounded-lg border border-slate-700 bg-slate-800"
      >
        <table class="min-w-full text-left text-sm">
          <thead class="border-b border-slate-700 text-slate-400">
            <tr>
              <th class="px-4 py-3 font-medium">Name</th>
              <th class="px-4 py-3 font-medium">Prefix</th>
              <th class="px-4 py-3 font-medium">Created</th>
              <th class="px-4 py-3 font-medium">Last used</th>
              <th class="px-4 py-3 text-right font-medium">Requests</th>
              <th class="px-4 py-3 font-medium">Status</th>
              <th class="px-4 py-3 font-medium">Action</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={key <- @keys}
              id={"portal-key-#{key.id}"}
              class={["border-t border-slate-700", key.status != :active && "opacity-75"]}
            >
              <td class="px-4 py-3 font-medium text-slate-100">{key.name}</td>
              <td class="px-4 py-3 font-mono text-slate-300">{key.token_prefix}</td>
              <td class="px-4 py-3 font-mono text-slate-400">{format_time(key.inserted_at)}</td>
              <td class="px-4 py-3 font-mono text-slate-400">{format_time(key.last_used_at)}</td>
              <td class="px-4 py-3 text-right font-mono text-slate-300">{key.request_count}</td>
              <td class="px-4 py-3">
                <span class={status_class(key.status)}>{status_label(key.status)}</span>
              </td>
              <td class="px-4 py-3">
                <button
                  :if={key.revocable?}
                  type="button"
                  id={"portal-revoke-#{key.id}"}
                  phx-click="open_revoke"
                  phx-value-id={key.id}
                  class="text-sm text-red-400 transition-colors hover:text-red-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400/40 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-800"
                >
                  Revoke
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <div
      :if={@mint_open?}
      id="portal-mint-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="portal-mint-title"
      class="fixed inset-0 z-40 flex items-center justify-center bg-slate-950/70 px-4"
    >
      <form
        phx-submit="mint_key"
        class="w-full max-w-md rounded-lg border border-slate-600 bg-slate-700 p-6"
      >
        <h2 id="portal-mint-title" class="text-base font-semibold text-slate-50">Mint key</h2>
        <label for="portal-key-name" class="mt-4 block text-sm font-medium text-slate-200">
          Key name
        </label>
        <input
          id="portal-key-name"
          type="text"
          name="key[name]"
          placeholder="production-agent"
          required
          value={@key_name}
          aria-invalid={if @mint_error, do: "true"}
          aria-describedby={if @mint_error, do: "portal-mint-error"}
          class={[
            "mt-1 block w-full rounded-md bg-slate-900/60 px-3 py-2 text-sm text-slate-50 shadow-inner focus-visible:outline-none focus-visible:ring-2",
            if(@mint_error,
              do: "border border-red-400 ring-1 ring-red-400/30 focus-visible:border-red-400 focus-visible:ring-red-400/40",
              else: "border border-slate-600 focus-visible:ring-sky-400/40"
            )
          ]}
        />
        <p
          :if={@mint_error}
          id="portal-mint-error"
          role="alert"
          class="mt-1 text-xs text-red-400"
        >
          {@mint_error}
        </p>
        <p class="mt-2 text-sm text-slate-400">Name it after the app or agent that will hold it.</p>
        <div class="mt-6 flex justify-end gap-3">
          <button type="button" phx-click="close_mint" class="text-sm text-slate-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400/40 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-700">Cancel</button>
          <button
            type="submit"
            class="rounded-md bg-sky-500 px-3 py-2 text-sm font-medium text-slate-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400/40 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-700"
          >
            Mint key
          </button>
        </div>
      </form>
    </div>

    <div
      :if={@generated_secret}
      id="portal-secret-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="portal-secret-title"
      class="fixed inset-0 z-40 flex items-center justify-center bg-slate-950/70 px-4"
    >
      <div class="w-full max-w-xl rounded-lg border border-slate-600 bg-slate-700 p-6">
        <h2 id="portal-secret-title" class="text-base font-semibold text-slate-50">Copy your key now</h2>
        <p class="mt-2 text-sm text-slate-300">
          This is the only time Orchard will show this key. It can't be retrieved later — not even by your operator. If you lose it, revoke it and mint a replacement.
        </p>
        <p class="mt-4 text-sm text-slate-200">
          {@generated_secret.api_key.name}
          <span class="ml-2 font-mono text-slate-400">{@generated_secret.api_key.token_prefix}</span>
        </p>
        <div
          id="portal-secret-value"
          class="mt-3 break-all rounded-md bg-slate-900/60 p-3 font-mono text-sm text-slate-100 shadow-inner"
        >
          {@generated_secret.token}
        </div>
        <div class="mt-3 flex items-center gap-3">
          <button
            id="portal-copy-key"
            type="button"
            phx-hook="CopyGeneratedSecret"
            data-secret-source="portal-secret-value"
            data-api-key-id={@generated_secret.api_key.id}
            class="rounded-md bg-sky-500 px-3 py-1.5 text-sm font-medium text-slate-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400/40 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-700"
          >
            Copy key
          </button>
          <p id="portal-copy-status" class={copy_status_class(@copy_status)} aria-live="polite">
            {copy_status_text(@copy_status)}
          </p>
        </div>

        <div class="mt-6">
          <h3 class="text-sm font-semibold text-slate-50">Make your first request</h3>
          <div
            :if={@generated_secret.curl}
            id="portal-curl-value"
            class="mt-2 overflow-x-auto whitespace-pre-wrap break-all rounded-md bg-slate-900/60 p-3 font-mono text-xs text-slate-100 shadow-inner"
          >
            {@generated_secret.curl}
          </div>
          <p
            :if={!@generated_secret.curl}
            id="portal-no-curl"
            class="mt-2 rounded-md border border-sky-400/30 bg-sky-400/10 px-3 py-2 text-sm text-sky-200"
          >
            No test curl is available yet because this Organization has no proven callable model. Your key was still minted.
          </p>
        </div>

        <form phx-change="acknowledge_secret" class="mt-6">
          <label class="flex items-start gap-2 text-sm text-slate-200">
            <input type="checkbox" name="ack" value="true" checked={@stored_ack} class="focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400/40 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-700" />
            I've stored this key. Orchard will not show it again.
          </label>
        </form>
        <div class="mt-4 flex justify-end">
          <button
            type="button"
            id="portal-secret-done"
            phx-click="dismiss_secret"
            disabled={!dismiss_allowed?(assigns)}
            class="rounded-md bg-slate-500 px-3 py-2 text-sm font-medium text-slate-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400/40 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-700 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Done
          </button>
        </div>
      </div>
    </div>

    <div
      :if={@revoke_key}
      id="portal-revoke-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="portal-revoke-title"
      class="fixed inset-0 z-40 flex items-center justify-center bg-slate-950/70 px-4"
    >
      <form
        phx-change="update_revoke_confirmation"
        phx-submit="revoke_key"
        class="w-full max-w-md rounded-lg border border-slate-600 bg-slate-700 p-6"
      >
        <h2 id="portal-revoke-title" class="text-base font-semibold text-slate-50">Revoke key</h2>
        <p class="mt-2 text-sm text-slate-300">
          The next request that presents this key will fail. Type
          <span class="font-medium text-slate-100">{@revoke_key.name}</span>
          to confirm.
        </p>
        <p class="mt-2 font-mono text-xs text-slate-400">{@revoke_key.token_prefix}</p>
        <input
          id="portal-revoke-confirmation"
          type="text"
          name="confirmation"
          autocomplete="off"
          phx-change="update_revoke_confirmation"
          value={@revoke_confirmation}
          class="mt-4 block w-full rounded-md border border-slate-600 bg-slate-900/60 px-3 py-2 text-sm text-slate-50 shadow-inner focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400/40 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-700"
        />
        <p :if={@revoke_error} id="portal-revoke-error" role="alert" class="mt-1 text-xs text-red-400">
          {@revoke_error}
        </p>
        <div class="mt-6 flex justify-end gap-3">
          <button type="button" phx-click="close_revoke" class="text-sm text-slate-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sky-400/40 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-700">Cancel</button>
          <button
            type="submit"
            id="portal-revoke-confirm"
            disabled={@revoke_confirmation != @revoke_key.name}
            class="rounded-md bg-red-500 px-3 py-2 text-sm font-medium text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400/40 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-700 disabled:cursor-not-allowed disabled:bg-slate-600"
          >
            Revoke key
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp refresh_keys(socket) do
    case Governance.list_portal_api_keys(
           socket.assigns.portal_token,
           socket.assigns.organization_slug
         ) do
      {:ok, listing} ->
        socket
        |> assign(:keys, listing.keys)
        |> assign(:active_portal_count, listing.active_portal_count)

      {:error, _reason} ->
        assign(socket, :keys, [])
    end
  end

  defp reconcile_key_limit(socket) do
    socket = refresh_keys(socket)

    if socket.assigns.active_portal_count >= 10 do
      socket
      |> assign(:mint_open?, false)
      |> assign(:mint_error, nil)
      |> assign(:key_name, "")
      |> assign(:focus_cap_status?, true)
    else
      socket
      |> assign(:mint_open?, true)
      |> assign(:mint_error, "Key capacity changed. Review the current keys and try again.")
    end
  end

  defp expire_session(socket) do
    Phoenix.LiveView.redirect(socket, to: "/portal/#{socket.assigns.organization_slug}")
  end

  defp matching_secret?(%{api_key: %{id: id}}, api_key_id), do: id == api_key_id
  defp matching_secret?(_secret, _api_key_id), do: false

  defp dismiss_allowed?(assigns) do
    assigns.stored_ack or assigns.copy_status == :copied
  end

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Map.values()
    |> List.flatten()
    |> List.first() || "Could not mint that key."
  end

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  defp status_label(:active), do: "Active"
  defp status_label(:revoked), do: "Revoked"
  defp status_label(:expired), do: "Expired"

  defp status_class(:active), do: "text-emerald-400"
  defp status_class(:revoked), do: "text-slate-400"
  defp status_class(:expired), do: "text-slate-400"

  defp copy_status_text(:idle), do: "Not copied yet"
  defp copy_status_text(:copied), do: "Copied"
  defp copy_status_text(:failed), do: "Copy failed — select the key and copy it manually."

  defp copy_status_class(:idle), do: "text-sm text-amber-300"
  defp copy_status_class(:copied), do: "text-sm text-emerald-400"
  defp copy_status_class(:failed), do: "text-sm text-red-400"
end
