import assert from "node:assert/strict"
import {test} from "node:test"
import {RequestPayload} from "../js/request_payload.mjs"

test("copy reads current rendered JSON, reports success, and removes its listener", async (t) => {
  const writes = []
  navigator.clipboard = {writeText: async text => writes.push(text)}
  t.after(() => {delete navigator.clipboard})
  const status = {textContent: ""}
  const code = {textContent: '{"output":"first"}'}
  const listeners = new Map()
  const hook = {
    el: {
      querySelector: selector => selector === "pre code" ? code : status,
      addEventListener: (name, fn) => listeners.set(name, fn),
      removeEventListener: (name, fn) => {
        assert.equal(listeners.get(name), fn)
        listeners.delete(name)
      }
    }
  }
  RequestPayload.mounted.call(hook)
  code.textContent = '{"output":"updated & <safe>"}'
  await listeners.get("click")({target: {closest: () => true}})
  assert.deepEqual(writes, [code.textContent])
  assert.equal(status.textContent, "Copied JSON")
  RequestPayload.updated.call(hook)
  assert.equal(status.textContent, "")
  await listeners.get("click")({target: {closest: () => null}})
  assert.equal(writes.length, 1)
  RequestPayload.destroyed.call(hook)
  assert.equal(listeners.size, 0)
})

test("denied clipboard reports recovery without exposing error or payload", async (t) => {
  navigator.clipboard = {writeText: async () => {throw Error("private detail")}}
  t.after(() => {delete navigator.clipboard})
  const status = {textContent: ""}
  const hook = {el: {
    querySelector: selector => selector === "pre code" ? {textContent: "sensitive"} : status,
    addEventListener() {}
  }}
  RequestPayload.mounted.call(hook)
  await hook.onCopy({target: {closest: () => true}})
  assert.equal(status.textContent, "Copy unavailable. Select the JSON to copy it manually.")
})
