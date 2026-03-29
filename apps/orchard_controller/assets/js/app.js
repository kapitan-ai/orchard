// Orchard Console — LiveView client entry point

import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// ===========================================================================
// LiveView Hooks
// ===========================================================================

let Hooks = {}

const QUICKSTART_COOKIE_OPTIONS = {
  path: "/console",
  sameSite: "Lax",
  maxAge: 31536000
}

function readBooleanCookie(key) {
  let cookie = document.cookie
    .split(";")
    .map((entry) => entry.trim())
    .find((entry) => entry.startsWith(`${key}=`))

  if (!cookie) return false

  let value = cookie.slice(key.length + 1)
  return value === "1"
}

function writeBooleanCookie(key, enabled, options = QUICKSTART_COOKIE_OPTIONS) {
  let parts = [
    `${key}=${enabled ? "1" : ""}`,
    `Path=${options.path}`,
    `SameSite=${options.sameSite}`,
    `Max-Age=${enabled ? options.maxAge : 0}`
  ]

  if (window.location.protocol === "https:") parts.push("Secure")

  document.cookie = parts.join("; ")
}

/**
 * AutoScrollBottom — keeps a scrollable container pinned to the bottom
 * during LiveView updates, but only when:
 *   1. data-auto-scroll="true" (active run in progress)
 *   2. The user was already near the bottom before the DOM patch
 *
 * Attach to a container with `phx-hook="AutoScrollBottom"`.
 */
Hooks.AutoScrollBottom = {
  mounted() {
    this.thresholdPx = 48
    this.wasNearBottom = true

    this._onScroll = () => {
      this.wasNearBottom = this._isNearBottom()
    }
    this.el.addEventListener("scroll", this._onScroll, {passive: true})
  },

  beforeUpdate() {
    this.wasNearBottom = this._isNearBottom()
  },

  updated() {
    if (this.el.dataset.autoScroll !== "true") return
    if (!this.wasNearBottom) return

    // Cancel any pending scroll to avoid stacking rAF callbacks
    if (this._rafId) cancelAnimationFrame(this._rafId)

    this._rafId = requestAnimationFrame(() => {
      this._rafId = null
      // Re-check: user may have scrolled away between patch and frame
      if (this._isNearBottom()) {
        this.el.scrollTop = this.el.scrollHeight
      }
    })
  },

  destroyed() {
    this.el.removeEventListener("scroll", this._onScroll)
    if (this._rafId) cancelAnimationFrame(this._rafId)
  },

  _isNearBottom() {
    let distance = this.el.scrollHeight - this.el.clientHeight - this.el.scrollTop
    return distance < this.thresholdPx
  }
}

/**
 * SubmitOnModEnter — submits the enclosing form on Cmd/Ctrl+Enter.
 * Attach to a textarea with `phx-hook="SubmitOnModEnter"`.
 */
Hooks.SubmitOnModEnter = {
  mounted() {
    this._onKeydown = (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter" && !event.isComposing) {
        event.preventDefault()
        let form = this.el.closest("form")
        if (!form) return

        // Respect the disabled state of the submit button
        let btn = form.querySelector("#playground-send")
        if (btn && btn.disabled) return

        if (typeof form.requestSubmit === "function") {
          form.requestSubmit(btn || undefined)
        } else if (btn) {
          btn.click()
        }
      }
    }
    this.el.addEventListener("keydown", this._onKeydown)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown)
  }
}

/**
 * OverviewQuickstart — loads quickstart client preferences and persists dismiss/recover.
 * Attach to the stable quickstart root with `phx-hook="OverviewQuickstart"`.
 */
Hooks.OverviewQuickstart = {
  mounted() {
    this.dismissedCookieKey = "orchard_console_quickstart_dismissed"
    this.guideSeenCookieKey = "orchard_console_quickstart_guide_seen"

    this._handleDismissedRef = this.handleEvent("overview_quickstart:set_dismissed", ({dismissed}) => {
      writeBooleanCookie(this.dismissedCookieKey, dismissed === true)
    })

    this._onClick = (event) => {
      let actionEl = event.target.closest("[data-quickstart-action]")
      if (!actionEl || !this.el.contains(actionEl)) return

      let action = actionEl.dataset.quickstartAction
      if (action === "dismiss") {
        event.preventDefault()
        this.pushEvent("quickstart_dismiss", {})
      } else if (action === "recover") {
        event.preventDefault()
        this.pushEvent("quickstart_recover", {})
      }
    }

    this.el.addEventListener("click", this._onClick)
    this.pushEvent("quickstart_client_state_loaded", {
      dismissed: readBooleanCookie(this.dismissedCookieKey),
      guide_seen: readBooleanCookie(this.guideSeenCookieKey)
    })
  },

  destroyed() {
    this.el.removeEventListener("click", this._onClick)
    if (this._handleDismissedRef) this.removeHandleEvent(this._handleDismissedRef)
  }
}

/**
 * QuickstartGuide — marks the guide as seen on first open and persists that cookie.
 * Attach to a stable wrapper that contains the guide disclosure.
 */
Hooks.QuickstartGuide = {
  mounted() {
    this.cookieKey = "orchard_console_quickstart_guide_seen"
    this.guideSeen = readBooleanCookie(this.cookieKey) || this.el.dataset.guideSeen === "true"
    this._detailsEl = null

    this._onToggle = () => {
      if (!this._detailsEl || !this._detailsEl.open || this.guideSeen) return

      this.guideSeen = true
      this.el.dataset.guideSeen = "true"
      writeBooleanCookie(this.cookieKey, true)
      this.pushEvent("quickstart_guide_seen", {})
    }

    this._bindDetails()
  },

  updated() {
    if (this.el.dataset.guideSeen === "true") this.guideSeen = true
    this._bindDetails()
  },

  destroyed() {
    this._unbindDetails()
  },

  _bindDetails() {
    let nextDetailsEl = this.el.querySelector("details")
    if (this._detailsEl === nextDetailsEl) return

    this._unbindDetails()
    this._detailsEl = nextDetailsEl

    if (this._detailsEl) {
      this._detailsEl.addEventListener("toggle", this._onToggle)
    }
  },

  _unbindDetails() {
    if (!this._detailsEl) return

    this._detailsEl.removeEventListener("toggle", this._onToggle)
    this._detailsEl = null
  }
}

/**
 * CopyGeneratedSecret — copies a one-time API key secret to the clipboard.
 * Attach to a button with `phx-hook="CopyGeneratedSecret"`.
 * Required data attributes: `data-copy-text`, `data-api-key-id`.
 */
Hooks.CopyGeneratedSecret = {
  mounted() {
    this._onClick = () => {
      let sourceId = this.el.dataset.secretSource
      let sourceEl = sourceId && document.getElementById(sourceId)
      let text = sourceEl ? sourceEl.textContent.trim() : ""
      let apiKeyId = this.el.dataset.apiKeyId

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text)
          .then(() => this.pushEvent("generated_secret_copied", {api_key_id: apiKeyId}))
          .catch(() => this.pushEvent("generated_secret_copy_failed", {api_key_id: apiKeyId}))
      } else {
        this.pushEvent("generated_secret_copy_failed", {api_key_id: apiKeyId})
      }
    }
    this.el.addEventListener("click", this._onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this._onClick)
  }
}

// ===========================================================================
// LiveSocket Setup
// ===========================================================================

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  hooks: Hooks,
  params: {_csrf_token: csrfToken}
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#1565C0"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop",  _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// ===========================================================================
// Connection State Tracking
// ===========================================================================
// Track websocket connection lifecycle via body data attributes.
// CSS selectors on body[data-lv-*] drive the reconnect banner visibility.
// Initial state is set server-side in root.html.heex:
//   data-lv-connected-once="false"  data-lv-connection-state="connecting"

let rawSocket = liveSocket.socket
if (rawSocket) {
  rawSocket.onOpen(() => {
    document.body.dataset.lvConnectedOnce = "true"
    document.body.dataset.lvConnectionState = "connected"
  })

  rawSocket.onClose(() => {
    if (document.body.dataset.lvConnectedOnce === "true") {
      document.body.dataset.lvConnectionState = "disconnected"
    }
  })

  rawSocket.onError(() => {
    if (document.body.dataset.lvConnectedOnce === "true") {
      document.body.dataset.lvConnectionState = "disconnected"
    }
  })
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
