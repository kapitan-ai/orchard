const MAX_BUNDLE_BYTES = 65536
const MAX_FILENAME_BYTES = 255
const FILENAME_PATTERN = /^orchard-[a-z0-9-]+-enrollment\.json$/
const ENROLLMENT_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

function utf8Bytes(value) {
  return new TextEncoder().encode(value).byteLength
}

function validEnrollmentId(enrollmentId) {
  return typeof enrollmentId === "string" && ENROLLMENT_ID_PATTERN.test(enrollmentId)
}

export function validNodeEnrollmentBundle(payload) {
  try {
    return payload &&
      validEnrollmentId(payload.enrollment_id) &&
      typeof payload.filename === "string" && FILENAME_PATTERN.test(payload.filename) &&
      utf8Bytes(payload.filename) <= MAX_FILENAME_BYTES &&
      typeof payload.contents === "string" && utf8Bytes(payload.contents) > 0 &&
      utf8Bytes(payload.contents) <= MAX_BUNDLE_BYTES
  } catch (_error) {
    return false
  }
}

export function nodeEnrollmentBundleAcknowledgement(result) {
  if (!result || !validEnrollmentId(result.enrollmentId)) return null

  return {
    event: result.ok
      ? "node_enrollment_bundle_downloaded"
      : "node_enrollment_bundle_download_failed",
    payload: {enrollment_id: result.enrollmentId}
  }
}

export async function downloadNodeEnrollmentBundle(payload, environment = {}) {
  let enrollmentId = payload && validEnrollmentId(payload.enrollment_id)
    ? payload.enrollment_id
    : null
  let contents = payload && payload.contents
  let objectUrl = null
  let link = null
  let ok = false
  let urlApi = environment.urlApi || URL

  try {
    if (!validNodeEnrollmentBundle(payload)) return {ok: false, enrollmentId}

    let BlobImpl = environment.BlobImpl || Blob
    let documentRef = environment.documentRef || document
    let blob = new BlobImpl([contents], {type: "application/json"})

    objectUrl = urlApi.createObjectURL(blob)
    link = documentRef.createElement("a")
    link.href = objectUrl
    link.download = payload.filename
    link.rel = "noopener"
    documentRef.body.appendChild(link)
    link.click()
    ok = true
  } catch (_error) {
    ok = false
  } finally {
    try {
      if (link) link.remove()
    } catch (_error) {
      // Cleanup is best effort; later cleanup steps must still run.
    }

    contents = null
    if (payload && typeof payload === "object") payload.contents = null

    if (objectUrl && ok) {
      let defer = environment.defer || setTimeout

      ok = await new Promise(resolve => {
        try {
          defer(() => {
            try {
              urlApi.revokeObjectURL(objectUrl)
              resolve(true)
            } catch (_error) {
              resolve(false)
            }
          }, 0)
        } catch (_error) {
          try {
            urlApi.revokeObjectURL(objectUrl)
          } catch (_revokeError) {
            // The scheduling failure already makes the result fail closed.
          }

          resolve(false)
        }
      })
    } else if (objectUrl) {
      try {
        urlApi.revokeObjectURL(objectUrl)
      } catch (_error) {
        ok = false
      }
    }

  }

  return {ok, enrollmentId}
}
