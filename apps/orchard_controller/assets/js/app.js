// Orchard Console — LiveView client entry point

import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// ===========================================================================
// LiveView Hooks
// ===========================================================================

let Hooks = {}

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
