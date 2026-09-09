const LEGACY_SECTIONS = new Map([
  ["tenant-summary-card", "overview"],
  ["tenant-access-boundaries", "overview"],
  ["tenant-model-access-card", "model_access"],
  ["tenant-portal-invite-card", "portal_users"],
  ["tenant-portal-invite-url-card", "portal_users"],
  ["tenant-portal-users-card", "portal_users"],
  ["tenant-portal-access-card", "portal_users"],
  ["tenant-api-key-create-card", "api_credentials"],
  ["tenant-api-key-secret-card", "api_credentials"],
  ["tenant-api-keys-card", "api_credentials"],
  ["tenant-api-clients-card", "api_credentials"]
])

export function legacyWorkspaceSection(hash) {
  return LEGACY_SECTIONS.get(hash.replace(/^#/, "")) ?? null
}

export const WorkspaceSections = {
  mounted() {
    this.onWorkspaceHashChange = () => {
      const section = legacyWorkspaceSection(window.location.hash)
      if (section) this.pushEvent("legacy_section", {section})
    }
    window.addEventListener("hashchange", this.onWorkspaceHashChange)
    this.onWorkspaceHashChange()
  },

  destroyed() {
    window.removeEventListener("hashchange", this.onWorkspaceHashChange)
  }
}
