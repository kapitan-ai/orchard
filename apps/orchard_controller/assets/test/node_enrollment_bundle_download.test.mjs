import assert from "node:assert/strict"
import test from "node:test"

import {
  downloadNodeEnrollmentBundle,
  nodeEnrollmentBundleAcknowledgement,
  validNodeEnrollmentBundle
} from "../js/node_enrollment_bundle_download.mjs"

const ENROLLMENT_ID = "11111111-1111-4111-8111-111111111111"

function environment({throwOnClick = false, throwOnDefer = false, throwOnRemove = false, throwOnRevoke = false} = {}) {
  let observed = {
    appended: false,
    blob: null,
    clicked: false,
    link: null,
    removed: false,
    revoked: null,
    scheduled: []
  }

  class BlobStub {
    constructor(parts, options) {
      this.parts = parts
      this.options = options
      observed.blob = this
    }
  }

  let link = {
    click() {
      if (throwOnClick) throw new Error("download blocked")
      observed.clicked = true
    },
    remove() {
      if (throwOnRemove) throw new Error("link removal failed")
      observed.removed = true
    }
  }

  let documentRef = {
    body: {
      appendChild(item) {
        observed.appended = item === link
      }
    },
    createElement(tag) {
      assert.equal(tag, "a")
      observed.link = link
      return link
    }
  }

  let urlApi = {
    createObjectURL(blob) {
      assert.equal(blob, observed.blob)
      return "blob:orchard-enrollment"
    },
    revokeObjectURL(url) {
      if (throwOnRevoke) throw new Error("object URL revocation failed")
      observed.revoked = url
    }
  }

  let defer = callback => {
    if (throwOnDefer) throw new Error("timer scheduling failed")
    observed.scheduled.push(callback)
  }

  return {BlobImpl: BlobStub, defer, documentRef, observed, urlApi}
}

test("downloads JSON with a sanitized filename and clears transient content", async () => {
  let payload = {
    contents: "{\"token\":\"one-time-secret\"}\n",
    enrollment_id: ENROLLMENT_ID,
    filename: "orchard-render-node-03-enrollment.json"
  }
  let env = environment()

  let result = downloadNodeEnrollmentBundle(payload, env)
  assert.deepEqual(env.observed.blob.options, {type: "application/json"})
  assert.equal(env.observed.link.download, "orchard-render-node-03-enrollment.json")
  assert.equal(env.observed.link.href, "blob:orchard-enrollment")
  assert.equal(env.observed.link.rel, "noopener")
  assert.equal(env.observed.appended, true)
  assert.equal(env.observed.clicked, true)
  assert.equal(env.observed.removed, true)
  assert.equal(env.observed.revoked, null)
  assert.equal(payload.contents, null)

  assert.equal(env.observed.scheduled.length, 1)
  env.observed.scheduled.shift()()
  assert.deepEqual(await result, {ok: true, enrollmentId: ENROLLMENT_ID})
  assert.equal(env.observed.revoked, "blob:orchard-enrollment")
})

test("reports failure with only the enrollment identifier and still cleans up", async () => {
  let payload = {
    contents: "{\"token\":\"one-time-secret\"}\n",
    enrollment_id: ENROLLMENT_ID,
    filename: "orchard-worker-enrollment.json"
  }
  let env = environment({throwOnClick: true})

  let result = await downloadNodeEnrollmentBundle(payload, env)

  assert.deepEqual(result, {ok: false, enrollmentId: ENROLLMENT_ID})
  assert.equal(JSON.stringify(result).includes("one-time-secret"), false)
  assert.equal(env.observed.removed, true)
  assert.equal(env.observed.revoked, "blob:orchard-enrollment")
  assert.equal(payload.contents, null)
})

test("rejects unsafe filenames without constructing a Blob", async () => {
  let payload = {
    contents: "secret",
    enrollment_id: ENROLLMENT_ID,
    filename: "../../enrollment.json"
  }
  let env = environment()

  assert.equal(validNodeEnrollmentBundle(payload), false)
  assert.deepEqual(await downloadNodeEnrollmentBundle(payload, env), {
    ok: false,
    enrollmentId: ENROLLMENT_ID
  })
  assert.equal(env.observed.blob, null)
  assert.equal(payload.contents, null)
})

test("clears content immediately and later revokes the URL when link removal fails", async () => {
  let payload = {
    contents: "{\"token\":\"one-time-secret\"}\n",
    enrollment_id: ENROLLMENT_ID,
    filename: "orchard-worker-enrollment.json"
  }
  let env = environment({throwOnRemove: true})

  let result = downloadNodeEnrollmentBundle(payload, env)
  assert.equal(env.observed.revoked, null)
  assert.equal(payload.contents, null)
  env.observed.scheduled.shift()()
  assert.deepEqual(await result, {ok: true, enrollmentId: ENROLLMENT_ID})
  assert.equal(env.observed.revoked, "blob:orchard-enrollment")
})

test("fails closed and clears content when deferred revocation fails", async () => {
  let payload = {
    contents: "{\"token\":\"one-time-secret\"}\n",
    enrollment_id: ENROLLMENT_ID,
    filename: "orchard-worker-enrollment.json"
  }
  let env = environment({throwOnRevoke: true})

  let result = downloadNodeEnrollmentBundle(payload, env)
  assert.equal(env.observed.removed, true)
  assert.equal(payload.contents, null)
  assert.doesNotThrow(() => env.observed.scheduled.shift()())
  assert.deepEqual(await result, {ok: false, enrollmentId: ENROLLMENT_ID})
})

test("fails closed and revokes synchronously when cleanup scheduling fails", async () => {
  let payload = {
    contents: "{\"token\":\"one-time-secret\"}\n",
    enrollment_id: ENROLLMENT_ID,
    filename: "orchard-worker-enrollment.json"
  }
  let env = environment({throwOnDefer: true})

  let result = await downloadNodeEnrollmentBundle(payload, env)

  assert.deepEqual(result, {ok: false, enrollmentId: ENROLLMENT_ID})
  assert.equal(env.observed.revoked, "blob:orchard-enrollment")
  assert.equal(env.observed.scheduled.length, 0)
  assert.equal(payload.contents, null)
  assert.deepEqual(nodeEnrollmentBundleAcknowledgement(result), {
    event: "node_enrollment_bundle_download_failed",
    payload: {enrollment_id: ENROLLMENT_ID}
  })
})

test("rejects an unbounded enrollment identifier without creating an acknowledgement", async () => {
  let payload = {
    contents: "secret",
    enrollment_id: "1".repeat(1024),
    filename: "orchard-worker-enrollment.json"
  }
  let env = environment()

  let result = await downloadNodeEnrollmentBundle(payload, env)

  assert.deepEqual(result, {ok: false, enrollmentId: null})
  assert.equal(nodeEnrollmentBundleAcknowledgement(result), null)
  assert.equal(env.observed.blob, null)
  assert.equal(payload.contents, null)
})

test("rejects filenames beyond the filesystem component byte limit", async () => {
  let payload = {
    contents: "secret",
    enrollment_id: ENROLLMENT_ID,
    filename: `orchard-${"a".repeat(240)}-enrollment.json`
  }
  let env = environment()

  assert.equal(validNodeEnrollmentBundle(payload), false)
  assert.deepEqual(await downloadNodeEnrollmentBundle(payload, env), {
    ok: false,
    enrollmentId: ENROLLMENT_ID
  })
  assert.equal(env.observed.blob, null)
})

test("measures the one-time payload by encoded UTF-8 bytes", async () => {
  let payload = {
    contents: "é".repeat(600000),
    enrollment_id: ENROLLMENT_ID,
    filename: "orchard-worker-enrollment.json"
  }
  let env = environment()

  assert.equal(payload.contents.length < 1048576, true)
  assert.equal(validNodeEnrollmentBundle(payload), false)
  assert.equal((await downloadNodeEnrollmentBundle(payload, env)).ok, false)
  assert.equal(env.observed.blob, null)
})

test("rejects payloads above the orchardctl enrollment-file limit", async () => {
  let payload = {
    contents: "a".repeat(65537),
    enrollment_id: ENROLLMENT_ID,
    filename: "orchard-worker-enrollment.json"
  }
  let env = environment()

  assert.equal(validNodeEnrollmentBundle(payload), false)
  assert.equal((await downloadNodeEnrollmentBundle(payload, env)).ok, false)
  assert.equal(env.observed.blob, null)
})

test("builds acknowledgements only for validated canonical enrollment identifiers", () => {
  assert.deepEqual(
    nodeEnrollmentBundleAcknowledgement({ok: true, enrollmentId: ENROLLMENT_ID}),
    {
      event: "node_enrollment_bundle_downloaded",
      payload: {enrollment_id: ENROLLMENT_ID}
    }
  )
  assert.deepEqual(
    nodeEnrollmentBundleAcknowledgement({ok: false, enrollmentId: ENROLLMENT_ID}),
    {
      event: "node_enrollment_bundle_download_failed",
      payload: {enrollment_id: ENROLLMENT_ID}
    }
  )
  assert.equal(
    nodeEnrollmentBundleAcknowledgement({ok: false, enrollmentId: "not-a-uuid"}),
    null
  )
})
