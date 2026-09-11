export const RequestPayload = {
  mounted() {
    this.onCopy = async (event) => {
      if (!event.target.closest("[data-copy-json]")) return
      const status = this.el.querySelector("[data-copy-status]")
      try {
        await navigator.clipboard.writeText(this.el.querySelector("pre code").textContent)
        status.textContent = "Copied JSON"
      } catch {
        status.textContent = "Copy unavailable. Select the JSON to copy it manually."
      }
    }
    this.el.addEventListener("click", this.onCopy)
  },
  updated() {
    this.el.querySelector("[data-copy-status]").textContent = ""
  },
  destroyed() {
    this.el.removeEventListener("click", this.onCopy)
  }
}
