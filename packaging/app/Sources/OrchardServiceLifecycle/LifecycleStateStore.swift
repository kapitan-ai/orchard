import Foundation

extension LifecycleService {
  func status(at paths: LifecyclePaths) throws -> LifecycleResult {
    LifecycleResult(
      status: try makeStatus(
        role: try readRole(at: paths),
        loadedServices: try loadedServices(at: paths),
        at: paths
      ),
      plan: []
    )
  }

  func makeStatus(
    role: InstallRole?,
    loadedServices: Set<String>,
    at paths: LifecyclePaths
  ) throws -> LifecycleStatus {
    let packagePresent = try packageReceiptIsPresent(at: paths)
    let appMarker = paths.supportRoot
      .appendingPathComponent("support/.app-install-complete")
    let source: InstallationSource
    if packagePresent {
      source = .package
    } else if itemExists(appMarker) {
      source = .app
    } else {
      source = .none
    }

    var blockers: [LifecycleBlocker] = []
    if packagePresent {
      blockers.append(.packageReceipt(contract.packageReceipt))
    }
    if try tlsState(at: paths) == .partial {
      blockers.append(.partialTLSState)
    }

    return LifecycleStatus(
      role: role,
      loadedServices: loadedServices,
      installationSource: source,
      retainedPaths: contract.retainedDirectories.map {
        "\(contract.supportRoot)/\($0)"
      },
      blockers: blockers
    )
  }

  func readRole(at paths: LifecyclePaths) throws -> InstallRole? {
    guard itemExists(paths.roleMarker) else {
      return nil
    }
    try validateRoleFile(paths.roleMarker, at: paths, request: false)
    return try readRoleFile(paths.roleMarker)
  }

  func resolveRole(
    _ requestedRole: InstallRole?,
    at paths: LifecyclePaths
  ) throws -> InstallRole {
    if let requestedRole {
      return requestedRole
    }
    if itemExists(paths.roleRequest) {
      try validateRoleRequest(paths.roleRequest, at: paths)
      return try readRoleFile(paths.roleRequest)
    }
    if let persisted = try readRole(at: paths) {
      return persisted
    }
    return .all
  }

  func validateRoleRequest(
    _ url: URL,
    at paths: LifecyclePaths
  ) throws {
    try validateRoleFile(url, at: paths, request: true)
  }

  func validateRoleFile(
    _ url: URL,
    at paths: LifecyclePaths,
    request: Bool
  ) throws {
    func reject() throws -> Never {
      if request {
        throw LifecycleServiceError.insecureRoleRequest(url.path)
      }
      throw LifecycleServiceError.insecureRoleFile(url.path)
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else {
      try reject()
    }

    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
    if mode & 0o022 != 0 {
      try reject()
    }
    if paths.isSystemRoot {
      let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.intValue
      if ownerID != 0 {
        try reject()
      }
    }
  }

  func readRoleFile(_ url: URL) throws -> InstallRole {
    let value = try String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let role = InstallRole(rawValue: value) else {
      throw LifecycleServiceError.invalidRoleFile(url.path, value)
    }
    return role
  }
  func tlsState(at paths: LifecyclePaths) throws -> TLSState {
    let tlsDirectory = paths.supportRoot.appendingPathComponent("config/tls")
    let expected = ["ca.key", "ca.crt", "controller.key", "controller.crt"]
    var regularFileCount = 0
    var presentCount = 0

    for name in expected {
      let url = tlsDirectory.appendingPathComponent(name)
      if itemExists(url) {
        presentCount += 1
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile == true {
          regularFileCount += 1
        }
      }
    }

    if presentCount == 0 {
      return .empty
    }
    if presentCount == expected.count && regularFileCount == expected.count {
      return .complete
    }
    return .partial
  }

  func packageReceiptIsPresent(at paths: LifecyclePaths) throws -> Bool {
    if paths.isSystemRoot {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
      process.arguments = ["--pkg-info", contract.packageReceipt]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    }
    return itemExists(paths.sandboxReceipt)
  }
}

enum TLSState {
  case empty
  case complete
  case partial
}
