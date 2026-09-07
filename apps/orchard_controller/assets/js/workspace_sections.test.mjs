import test from "node:test"
import assert from "node:assert/strict"
import {legacyWorkspaceSection, WorkspaceSections} from "./workspace_sections.mjs"

test("legacy anchors map only to known Workspace sections", () => {
  assert.equal(legacyWorkspaceSection("#tenant-summary-card"), "overview")
  assert.equal(legacyWorkspaceSection("#tenant-model-access-card"), "model_access")
  assert.equal(legacyWorkspaceSection("#tenant-portal-invite-url-card"), "portal_users")
  assert.equal(legacyWorkspaceSection("#tenant-api-clients-card"), "api_credentials")
  for (const hash of ["", "#unknown", "#constructor", "#__proto__", "#portal_users", "#tenant-api-clients-card?tenant=other"]) {
    assert.equal(legacyWorkspaceSection(hash), null)
  }
})

test("mount bridges the initial fragment without accepting Workspace identity from the URL", () => {
  const events = []
  const listeners = new Map()
  globalThis.window = {
    location: {hash: "#tenant-portal-users-card"},
    addEventListener: (name, listener) => listeners.set(name, listener),
    removeEventListener: (name, listener) => {
      assert.equal(listeners.get(name), listener)
      listeners.delete(name)
    }
  }
  const hook = {pushEvent: (name, payload) => events.push([name, payload])}
  try {
    WorkspaceSections.mounted.call(hook)
    assert.deepEqual(events, [["legacy_section", {section: "portal_users"}]])
    window.location.hash = "#unknown"
    listeners.get("hashchange")()
    assert.equal(events.length, 1)
    window.location.hash = "#tenant-api-keys-card"
    listeners.get("hashchange")()
    assert.deepEqual(events.at(-1), ["legacy_section", {section: "api_credentials"}])
    WorkspaceSections.destroyed.call(hook)
    assert.equal(listeners.size, 0)
  } finally {
    delete globalThis.window
  }
})
