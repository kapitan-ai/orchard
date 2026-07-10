import Darwin
import Foundation
import OrchardServiceLifecycle

private func environmentURL(_ name: String) -> URL? {
  guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
    return nil
  }
  return URL(fileURLWithPath: value)
}

private func bundledResource(_ relativePath: String) -> URL {
  let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    .standardizedFileURL
  return
    executable
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/\(relativePath)")
}

private func blockerValue(_ blocker: LifecycleBlocker) -> String {
  switch blocker {
  case .packageReceipt(let identifier):
    return "package_receipt:\(identifier)"
  case .partialTLSState:
    return "partial_tls_state"
  }
}

private func emit(_ result: LifecycleResult, operation: LifecycleOperation) throws {
  let object: [String: Any] = [
    "operation": operation.rawValue,
    "role": result.status.role?.rawValue ?? NSNull(),
    "installation_source": result.status.installationSource.rawValue,
    "loaded_services": result.status.loadedServices.sorted(),
    "retained_paths": result.status.retainedPaths,
    "blockers": result.status.blockers.map(blockerValue),
    "plan": result.plan,
  ]
  let data = try JSONSerialization.data(
    withJSONObject: object,
    options: [.sortedKeys]
  )
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
}

private func failureDetails(_ error: Error) -> (code: String, status: Int32) {
  if let invocationError = error as? LifecycleError {
    switch invocationError {
    case .rootPrivilegesRequired:
      return ("authorization_required", 77)
    default:
      return ("invalid_invocation", 64)
    }
  }
  if let serviceError = error as? LifecycleServiceError {
    switch serviceError {
    case .lifecycleLocked:
      return ("lifecycle_locked", 75)
    case .rollbackFailed:
      return ("rollback_failed", 70)
    case .invalidTransactionManifest, .invalidLifecycleLock:
      return ("invalid_lifecycle_state", 65)
    case .launchdFailure:
      return ("launchd_failure", 69)
    case .partialTLSState, .packageReceiptPresent, .insecureRoleRequest,
      .insecureRoleFile, .commandLinkConflict, .unsafeManagedPath,
      .unsafePayloadPath, .missingPayloadPath:
      return ("preflight_failed", 78)
    case .unsupportedOperation, .missingRole, .invalidRoleFile:
      return ("invalid_invocation", 64)
    case .injectedFailure, .simulatedAbruptTermination,
      .failureInjectionRequiresNonSystemRoot, .transactionAlreadyExists:
      return ("lifecycle_failed", 70)
    }
  }
  return ("internal_error", 1)
}

private func fail(_ error: Error) -> Never {
  let details = failureDetails(error)
  let object = [
    "code": details.code,
    "message": String(describing: error),
  ]
  if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
    FileHandle.standardError.write(data)
    FileHandle.standardError.write(Data("\n".utf8))
  }
  exit(details.status)
}

do {
  let invocation = try LifecycleInvocation.parse(
    arguments: Array(CommandLine.arguments.dropFirst()),
    effectiveUserID: geteuid()
  )
  let payloadRoot =
    environmentURL("ORCHARD_APP_PAYLOAD_ROOT")
    ?? bundledResource("payload")
  let contractURL =
    environmentURL("ORCHARD_APP_CONTRACT_PATH")
    ?? bundledResource("service-lifecycle.json")
  let failurePoint = ProcessInfo.processInfo.environment["ORCHARD_APP_TEST_FAIL_AFTER"]
    .flatMap(LifecycleFailurePoint.init(rawValue:))
  let result = try LifecycleService(
    contract: InstallContract.load(from: contractURL),
    payloadRoot: payloadRoot,
    failurePoint: failurePoint
  ).execute(invocation)
  try emit(result, operation: invocation.operation)
} catch {
  fail(error)
}
