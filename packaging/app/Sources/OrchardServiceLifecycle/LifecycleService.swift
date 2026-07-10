import Darwin
import Foundation

public enum InstallationSource: String, Equatable, Sendable {
  case none
  case app
  case package
}

public enum LifecycleBlocker: Equatable, Sendable {
  case packageReceipt(String)
  case partialTLSState
}

public struct LifecycleStatus: Equatable, Sendable {
  public let role: InstallRole?
  public let loadedServices: Set<String>
  public let installationSource: InstallationSource
  public let retainedPaths: [String]
  public let blockers: [LifecycleBlocker]
}

public struct LifecycleResult: Equatable, Sendable {
  public let status: LifecycleStatus
  public let plan: [String]
}

public enum LifecycleFailurePoint: String, CaseIterable, Equatable, Sendable {
  case afterServicesStopped
  case afterPayload
  case afterPlists
  case afterCommandLinks
  case afterRoleMarker
}

public enum LifecycleServiceError: Error, Equatable, Sendable {
  case unsupportedOperation(LifecycleOperation)
  case missingPayloadPath(String)
  case missingRole
  case injectedFailure(LifecycleFailurePoint)
  case failureInjectionRequiresNonSystemRoot
  case transactionAlreadyExists(String)
  case rollbackFailed(String)
  case partialTLSState
  case packageReceiptPresent(String)
  case invalidRoleFile(String, String)
  case insecureRoleRequest(String)
  case insecureRoleFile(String)
  case commandLinkConflict(String)
  case unsafeManagedPath(String)
  case unsafePayloadPath(String)
  case lifecycleLocked(String)
  case invalidLifecycleLock(String)
  case launchdFailure(String, String, Int32)
  case simulatedAbruptTermination(LifecycleFailurePoint)
  case invalidTransactionManifest(String)
}

public final class LifecycleService {
  let contract: InstallContract
  let payloadRoot: URL
  let fileManager: FileManager
  let failurePoint: LifecycleFailurePoint?
  let abruptFailurePoint: LifecycleFailurePoint?

  public init(
    contract: InstallContract,
    payloadRoot: URL,
    fileManager: FileManager = .default,
    failurePoint: LifecycleFailurePoint? = nil,
    abruptFailurePoint: LifecycleFailurePoint? = nil
  ) {
    self.contract = contract
    self.payloadRoot = payloadRoot
    self.fileManager = fileManager
    self.failurePoint = failurePoint
    self.abruptFailurePoint = abruptFailurePoint
  }

  public func execute(_ invocation: LifecycleInvocation) throws -> LifecycleResult {
    let paths = LifecyclePaths(root: URL(fileURLWithPath: invocation.root), contract: contract)
    if invocation.operation == .status {
      return try status(at: paths)
    }
    if invocation.operation == .uninstall {
      return try uninstall(invocation, at: paths)
    }
    guard invocation.operation == .install || invocation.operation == .update else {
      throw LifecycleServiceError.unsupportedOperation(invocation.operation)
    }
    try validateManagedPaths(at: paths)
    let role = try resolveRole(invocation.role, at: paths)

    try preflightTarget(at: paths)
    try validateCommandLinkOwnership(at: paths)
    var plan = installPlan(role: role, paths: paths)
    if invocation.dryRun {
      try validatePayload()
      if itemExists(paths.transactionRoot) {
        plan.insert("recover interrupted app transaction", at: 0)
      }
      return LifecycleResult(
        status: try status(at: paths).status,
        plan: plan
      )
    }

    if (failurePoint != nil || abruptFailurePoint != nil) && paths.isSystemRoot {
      throw LifecycleServiceError.failureInjectionRequiresNonSystemRoot
    }

    let lock = try acquireLifecycleLock(at: paths)
    defer { lock.release() }
    try recoverTransactionIfNeeded(at: paths)
    try validateManagedPaths(at: paths)
    try preflightTarget(at: paths)
    try validateCommandLinkOwnership(at: paths)
    try validatePayload()
    let previouslyLoaded = try loadedServices(at: paths)
    let transaction = try beginTransaction(
      at: paths,
      stagePayload: true,
      loadedServices: previouslyLoaded
    )
    let restoredServices = try commit(
      invocation: invocation,
      role: role,
      paths: paths,
      transaction: transaction,
      previouslyLoaded: previouslyLoaded
    )

    return LifecycleResult(
      status: try makeStatus(
        role: role,
        loadedServices: restoredServices,
        at: paths
      ),
      plan: plan
    )
  }

  func uninstall(
    _ invocation: LifecycleInvocation,
    at paths: LifecyclePaths
  ) throws -> LifecycleResult {
    var plan = [
      "stop Orchard services",
      "remove app-owned payload",
      "remove launchd plists",
      "remove installed commands and links",
      "remove app install markers",
      "retain operator state",
    ]
    if invocation.dryRun {
      if itemExists(paths.transactionRoot) {
        plan.insert("recover interrupted app transaction", at: 0)
      }
      return LifecycleResult(
        status: try status(at: paths).status,
        plan: plan
      )
    }
    if (failurePoint != nil || abruptFailurePoint != nil) && paths.isSystemRoot {
      throw LifecycleServiceError.failureInjectionRequiresNonSystemRoot
    }
    try validateManagedPaths(at: paths)
    let lock = try acquireLifecycleLock(at: paths)
    defer { lock.release() }
    try recoverTransactionIfNeeded(at: paths)
    try validateManagedPaths(at: paths)
    try preflightTarget(at: paths)

    let previouslyLoaded = try loadedServices(at: paths)
    let transaction = try beginTransaction(
      at: paths,
      stagePayload: false,
      loadedServices: previouslyLoaded
    )
    do {
      try writeTransactionManifest(
        transaction: transaction,
        loadedServices: previouslyLoaded,
        phase: .applying,
        at: paths
      )
      try setLoadedServices([], at: paths)
      try injectFailure(at: .afterServicesStopped)
      try removeAppOwnedDirectories(at: paths)
      try injectFailure(at: .afterPayload)
      try removeLaunchdPlists(at: paths)
      try injectFailure(at: .afterPlists)
      try removeCommandLinks(at: paths)
      try injectFailure(at: .afterCommandLinks)
      try removeAppOwnedSupportEntries(at: paths)
      try injectFailure(at: .afterRoleMarker)
      try fileManager.removeItem(at: transaction.root)
    } catch {
      if isSimulatedAbruptTermination(error) {
        throw error
      }
      do {
        try rollback(
          transaction,
          paths: paths,
          loadedServices: previouslyLoaded
        )
      } catch let rollbackError {
        throw LifecycleServiceError.rollbackFailed(String(describing: rollbackError))
      }
      throw error
    }

    return LifecycleResult(
      status: try makeStatus(role: nil, loadedServices: [], at: paths),
      plan: plan
    )
  }

  func commit(
    invocation: LifecycleInvocation,
    role: InstallRole,
    paths: LifecyclePaths,
    transaction: LifecycleTransaction,
    previouslyLoaded: Set<String>
  ) throws -> Set<String> {
    do {
      try writeTransactionManifest(
        transaction: transaction,
        loadedServices: previouslyLoaded,
        phase: .applying,
        at: paths
      )
      try setLoadedServices([], at: paths)
      try injectFailure(at: .afterServicesStopped)
      try installPayload(at: paths, sourceRoot: transaction.stagedPayload)
      try injectFailure(at: .afterPayload)
      try installPlists(
        for: role,
        at: paths,
        sourceRoot: transaction.stagedPayload
      )
      try injectFailure(at: .afterPlists)
      try installCommandLinks(at: paths)
      try injectFailure(at: .afterCommandLinks)
      try writeRole(role, at: paths)
      try writeInstallMarker(at: paths)
      try removeIfPresent(paths.roleRequest)

      let selectedServices = Set(contract.roles[role.rawValue] ?? [])
      let restoredServices: Set<String>
      if invocation.operation == .update {
        restoredServices = previouslyLoaded.intersection(selectedServices)
      } else {
        restoredServices = []
      }
      try normalizeInstallation(at: paths, transaction: transaction)
      try injectFailure(at: .afterRoleMarker)
      try setLoadedServices(restoredServices, at: paths)
      try fileManager.removeItem(at: transaction.root)
      return restoredServices
    } catch {
      if isSimulatedAbruptTermination(error) {
        throw error
      }
      do {
        try rollback(
          transaction,
          paths: paths,
          loadedServices: previouslyLoaded
        )
      } catch let rollbackError {
        throw LifecycleServiceError.rollbackFailed(String(describing: rollbackError))
      }
      throw error
    }
  }

  func injectFailure(at point: LifecycleFailurePoint) throws {
    if abruptFailurePoint == point {
      throw LifecycleServiceError.simulatedAbruptTermination(point)
    }
    if failurePoint == point {
      throw LifecycleServiceError.injectedFailure(point)
    }
  }

  func isSimulatedAbruptTermination(_ error: Error) -> Bool {
    guard let lifecycleError = error as? LifecycleServiceError else {
      return false
    }
    if case .simulatedAbruptTermination = lifecycleError {
      return true
    }
    return false
  }
  func installPlan(role: InstallRole, paths: LifecyclePaths) -> [String] {
    [
      "copy payload to \(paths.supportRoot.path)",
      "install role \(role.rawValue) launchd plists",
      "install command links",
      "write role marker",
    ]
  }
}
