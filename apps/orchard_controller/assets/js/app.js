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

// Keep this client contract aligned with docs/DESIGN.md §13.1 and ThemeInitial.
const THEME_COOKIE_KEY = "orchard_console_theme"
const THEME_MODES = ["system", "light", "dark"]
const THEME_COOKIE_OPTIONS = {
  path: "/console",
  sameSite: "Lax",
  maxAge: 31536000,
  validValues: THEME_MODES
}
const THEME_MEDIA_QUERY = "(prefers-color-scheme: dark)"

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

function writeStringCookie(key, value, options = THEME_COOKIE_OPTIONS) {
  // Blank values delete the cookie for future reset/clear affordances.
  let shouldDelete = value === null || value === undefined || value === ""
  if (!shouldDelete && options.validValues && !options.validValues.includes(String(value))) return false

  let cookieValue = shouldDelete ? "" : encodeURIComponent(String(value))
  let parts = [
    `${key}=${cookieValue}`,
    `Path=${options.path}`,
    `SameSite=${options.sameSite}`,
    `Max-Age=${shouldDelete ? 0 : options.maxAge}`
  ]

  if (window.location.protocol === "https:") parts.push("Secure")

  document.cookie = parts.join("; ")
  return true
}

/**
 * ThemeToggle — switches the Console between System, Light, and Dark modes.
 */
Hooks.ThemeToggle = {
  mounted() {
    this.mediaQuery = window.matchMedia ? window.matchMedia(THEME_MEDIA_QUERY) : null
    this._refreshSegments()

    this._onClick = (event) => {
      let segment = event.target.closest("[data-theme-mode]")
      if (!segment || !this.el.contains(segment)) return

      event.preventDefault()
      this._selectMode(segment.dataset.themeMode, {focus: true})
    }

    this._onKeydown = (event) => {
      let segment = event.target.closest("[data-theme-mode]")
      if (!segment || !this.el.contains(segment)) return

      let currentIndex = this.segments.indexOf(segment)
      if (currentIndex === -1) return

      let nextIndex = null
      switch (event.key) {
        case "ArrowLeft":
        case "ArrowUp":
          nextIndex = (currentIndex - 1 + this.segments.length) % this.segments.length
          break
        case "ArrowRight":
        case "ArrowDown":
          nextIndex = (currentIndex + 1) % this.segments.length
          break
        case "Home":
          nextIndex = 0
          break
        case "End":
          nextIndex = this.segments.length - 1
          break
        case " ":
        case "Spacebar":
        case "Enter":
          event.preventDefault()
          this._selectMode(segment.dataset.themeMode, {focus: true})
          return
        default:
          return
      }

      event.preventDefault()
      this._selectMode(this.segments[nextIndex].dataset.themeMode, {focus: true})
    }

    this._onMediaChange = () => {
      if (this._currentMode() === "system") this._applyMode("system", {persist: false})
    }

    this.el.addEventListener("click", this._onClick)
    this.el.addEventListener("keydown", this._onKeydown)
    this._addMediaListener()
    this._applyMode(this._currentMode(), {persist: false})
  },

  updated() {
    this._refreshSegments()
    this._syncSegments(this._currentMode())
  },

  destroyed() {
    this.el.removeEventListener("click", this._onClick)
    this.el.removeEventListener("keydown", this._onKeydown)
    this._removeMediaListener()
  },

  _refreshSegments() {
    this.segments = Array.from(this.el.querySelectorAll("[data-theme-mode]"))
      .filter((segment) => this._validMode(segment.dataset.themeMode))
  },

  _validMode(mode) {
    return THEME_MODES.includes(mode)
  },

  _currentMode() {
    let mode = document.documentElement.dataset.themeMode
    return this._validMode(mode) ? mode : "system"
  },

  _selectMode(mode, {focus = false} = {}) {
    if (!this._validMode(mode)) return

    this._applyMode(mode)
    if (focus) this._focusMode(mode)
  },

  _applyMode(mode, {persist = true} = {}) {
    if (!this._validMode(mode)) return

    if (persist) writeStringCookie(THEME_COOKIE_KEY, mode, THEME_COOKIE_OPTIONS)

    document.documentElement.dataset.themeMode = mode
    document.documentElement.dataset.theme = this._resolvedTheme(mode)
    this._syncSegments(mode)
  },

  _resolvedTheme(mode) {
    if (mode === "system") {
      return this.mediaQuery && this.mediaQuery.matches ? "dark" : "light"
    }

    return mode
  },

  _syncSegments(activeMode) {
    this._refreshSegments()

    this.segments.forEach((segment) => {
      let selected = segment.dataset.themeMode === activeMode
      segment.setAttribute("aria-checked", selected ? "true" : "false")
      // Marker class for browser smoke/devtools; styling is driven by aria-checked variants.
      segment.classList.toggle("theme-toggle-active", selected)
      segment.tabIndex = selected ? 0 : -1
    })
  },

  _focusMode(mode) {
    let segment = this.segments.find((item) => item.dataset.themeMode === mode)
    if (segment) segment.focus()
  },

  _addMediaListener() {
    if (!this.mediaQuery) return

    if (this.mediaQuery.addEventListener) {
      this.mediaQuery.addEventListener("change", this._onMediaChange)
    } else if (this.mediaQuery.addListener) {
      this.mediaQuery.addListener(this._onMediaChange)
    }
  },

  _removeMediaListener() {
    if (!this.mediaQuery) return

    if (this.mediaQuery.removeEventListener) {
      this.mediaQuery.removeEventListener("change", this._onMediaChange)
    } else if (this.mediaQuery.removeListener) {
      this.mediaQuery.removeListener(this._onMediaChange)
    }
  }
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
 * requestSubmitForm - submits through the browser form contract.
 * Returns false when submission should fall back or stay suppressed.
 */
function requestSubmitForm(form, submitter) {
  if (!form) return false
  if (submitter && submitter.disabled) return false

  let validSubmitter = submitter && submitter.form === form ? submitter : undefined

  if (typeof form.requestSubmit !== "function") return false

  form.requestSubmit(validSubmitter)
  return true
}

/**
 * PlaygroundSubmitClick - routes Send clicks through LiveView form submission.
 * Attach to the wrapper that contains `#playground-form` and `#playground-send`.
 */
Hooks.PlaygroundSubmitClick = {
  mounted() {
    this._onClick = (event) => {
      let btn = event.target.closest("#playground-send")
      if (!btn || !this.el.contains(btn) || btn.disabled) return

      let form = btn.form || btn.closest("form")
      if (requestSubmitForm(form, btn)) event.preventDefault()
    }

    this.el.addEventListener("click", this._onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this._onClick)
  }
}

/**
 * SubmitOnModEnter - submits the enclosing form on Cmd/Ctrl+Enter.
 * Attach to a textarea with `phx-hook="SubmitOnModEnter"`.
 */
Hooks.SubmitOnModEnter = {
  mounted() {
    this._onKeydown = (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter" && !event.isComposing) {
        event.preventDefault()
        let form = this.el.closest("form")
        if (!form) return

        let btn = form.querySelector("#playground-send")
        if (btn && btn.disabled) return

        if (!requestSubmitForm(form, btn) && btn) btn.click()
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

    this._onOpenGuide = () => {
      if (!this._detailsEl) return
      if (!this._detailsEl.open) {
        this._detailsEl.open = true
      }
      let prefersReducedMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches
      this._detailsEl.scrollIntoView({behavior: prefersReducedMotion ? "auto" : "smooth", block: "nearest"})
      let summary = this._detailsEl.querySelector("summary")
      if (summary) summary.focus()
    }

    this.el.addEventListener("orchard:quickstart-guide:open", this._onOpenGuide)
    this._bindDetails()
  },

  updated() {
    if (this.el.dataset.guideSeen === "true") this.guideSeen = true
    this._bindDetails()
  },

  destroyed() {
    this.el.removeEventListener("orchard:quickstart-guide:open", this._onOpenGuide)
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

/**
 * LocalTime — formats <time> elements to the browser's local timezone.
 * Reads `datetime` (ISO 8601) and `data-local-time-format` attrs set by the
 * CoreComponents.local_time/1 server component. On mount and LiveView patch,
 * replaces the UTC fallback text with a locally-formatted string.
 *
 * Uses Intl.DateTimeFormat().formatToParts() to extract calendar parts, then
 * reassembles them into Orchard's fixed YYYY-MM-DD HH:MM:SS layout so the
 * output is consistent regardless of browser locale.
 *
 * If parsing fails or Intl is unavailable, the server-rendered UTC fallback
 * text is left untouched.
 */
Hooks.LocalTime = {
  mounted()  { this._formatTime() },
  updated()  { this._formatTime() },

  _formatTime() {
    let iso = this.el.getAttribute("datetime")
    let fmt = this.el.dataset.localTimeFormat
    if (!iso || !fmt) return

    let date = new Date(iso)
    if (isNaN(date.getTime())) return

    try {
      let text = this._format(date, fmt)
      if (text) this.el.textContent = text
    } catch (_e) {
      // leave fallback text untouched
    }
  },

  _format(date, fmt) {
    let opts = FORMAT_OPTIONS[fmt]
    if (!opts) return null

    let parts = new Intl.DateTimeFormat(undefined, opts).formatToParts(date)
    let p = {}
    for (let part of parts) p[part.type] = part.value

    // Verify all required parts are present before assembling
    switch (fmt) {
      case "datetime_minute":
        if (!p.year || !p.month || !p.day || !p.hour || !p.minute) return null
        return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}`
      case "datetime_second":
        if (!p.year || !p.month || !p.day || !p.hour || !p.minute || !p.second) return null
        return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`
      case "time_second":
        if (!p.hour || !p.minute || !p.second) return null
        return `${p.hour}:${p.minute}:${p.second}`
      case "date":
        if (!p.year || !p.month || !p.day) return null
        return `${p.year}-${p.month}-${p.day}`
      default:
        return null
    }
  }
}

const FORMAT_OPTIONS = {
  datetime_minute: {
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit",
    hour12: false, hourCycle: "h23",
    calendar: "gregory", numberingSystem: "latn"
  },
  datetime_second: {
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
    hour12: false, hourCycle: "h23",
    calendar: "gregory", numberingSystem: "latn"
  },
  time_second: {
    hour: "2-digit", minute: "2-digit", second: "2-digit",
    hour12: false, hourCycle: "h23",
    calendar: "gregory", numberingSystem: "latn"
  },
  date: {
    year: "numeric", month: "2-digit", day: "2-digit",
    calendar: "gregory", numberingSystem: "latn"
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
