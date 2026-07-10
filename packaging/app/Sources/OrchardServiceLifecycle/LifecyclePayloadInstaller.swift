import Foundation

extension LifecycleService {
  func removeAppOwnedDirectories(at paths: LifecyclePaths) throws {
    for directory in contract.appOwnedDirectories {
      try removeIfPresent(paths.supportRoot.appendingPathComponent(directory))
    }
  }

  func removeLaunchdPlists(at paths: LifecyclePaths) throws {
    for label in allServiceLabels() {
      try removeIfPresent(
        paths.launchDaemonDirectory.appendingPathComponent("\(label).plist")
      )
    }
  }

  func removeCommandLinks(at paths: LifecyclePaths) throws {
    for (command, absolutePath) in contract.commandLinks {
      let link = paths.relocate(absolutePath)
      let expectedTarget = paths.supportRoot.appendingPathComponent("bin/\(command)")
      if try commandLink(at: link, pointsTo: expectedTarget) {
        try fileManager.removeItem(at: link)
      }
    }
  }

  func removeAppOwnedSupportEntries(at paths: LifecyclePaths) throws {
    for entry in contract.appOwnedSupportEntries where entry != ".app-transaction" {
      try removeIfPresent(paths.supportRoot.appendingPathComponent("support/\(entry)"))
    }
  }

  func removeIfPresent(_ url: URL) throws {
    if itemExists(url) {
      try fileManager.removeItem(at: url)
    }
  }

  func normalizeInstallation(
    at paths: LifecyclePaths,
    transaction: LifecycleTransaction
  ) throws {
    let config = paths.supportRoot.appendingPathComponent("config")
    let tls = config.appendingPathComponent("tls")
    let logs = paths.supportRoot.appendingPathComponent("logs")
    let support = paths.supportRoot.appendingPathComponent("support")
    try fileManager.createDirectory(at: tls, withIntermediateDirectories: true)

    if !transaction.preexistingRetainedPaths.contains(config.path) {
      try setMode(0o750, at: config)
    }
    if !transaction.preexistingRetainedPaths.contains(tls.path) {
      try setMode(0o750, at: tls)
    }
    if !transaction.preexistingRetainedPaths.contains(logs.path) {
      try setMode(0o755, at: logs)
    }

    for directory in contract.appOwnedDirectories {
      try normalizeAppOwnedTree(
        paths.supportRoot.appendingPathComponent(directory)
      )
    }
    for command in contract.commandLinks.keys {
      try setMode(
        0o755,
        at: paths.supportRoot.appendingPathComponent("bin/\(command)")
      )
    }
    for label in allServiceLabels() {
      let plist = paths.launchDaemonDirectory.appendingPathComponent("\(label).plist")
      if itemExists(plist) {
        try setMode(0o644, at: plist)
      }
    }
    if itemExists(paths.roleMarker) {
      try setMode(0o644, at: paths.roleMarker)
    }
    for name in [".app-install-complete", ".app-launchd-state.json"] {
      let file = support.appendingPathComponent(name)
      if itemExists(file) {
        try setMode(0o600, at: file)
      }
    }

    if paths.isSystemRoot {
      try applySystemOwnership(at: paths, transaction: transaction)
    } else {
      try writeOwnershipIntent(at: paths)
    }
  }

  func normalizeAppOwnedTree(_ root: URL) throws {
    guard itemExists(root) else {
      return
    }
    try setMode(0o755, at: root)
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsPackageDescendants]
      )
    else {
      return
    }
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if isSymbolicLink(url) {
        continue
      } else if values.isDirectory == true {
        try setMode(0o755, at: url)
      } else if values.isRegularFile == true {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let current = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try setMode(current & 0o111 == 0 ? 0o644 : 0o755, at: url)
      } else {
        throw LifecycleServiceError.unsafeManagedPath(url.path)
      }
    }
  }

  func setMode(_ mode: Int, at url: URL) throws {
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: mode)],
      ofItemAtPath: url.path
    )
  }

  func writeOwnershipIntent(at paths: LifecyclePaths) throws {
    let intent = OwnershipIntent(ownerID: 0, wheelGroupID: 0, adminGroupID: 80)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    let url = paths.supportRoot
      .appendingPathComponent("support/.app-ownership-intent.json")
    try encoder.encode(intent).write(to: url, options: .atomic)
    try setMode(0o600, at: url)
  }

  func applySystemOwnership(
    at paths: LifecyclePaths,
    transaction: LifecycleTransaction
  ) throws {
    let rootWheel: [FileAttributeKey: Any] = [
      .ownerAccountID: NSNumber(value: 0),
      .groupOwnerAccountID: NSNumber(value: 0),
    ]
    let rootAdmin: [FileAttributeKey: Any] = [
      .ownerAccountID: NSNumber(value: 0),
      .groupOwnerAccountID: NSNumber(value: 80),
    ]

    for directory in contract.appOwnedDirectories {
      let url = paths.supportRoot.appendingPathComponent(directory)
      if itemExists(url) {
        try applyOwnershipRecursively(rootWheel, at: url)
      }
    }
    for url in [
      paths.supportRoot.appendingPathComponent("config"),
      paths.supportRoot.appendingPathComponent("config/tls"),
    ] where itemExists(url) && !transaction.preexistingRetainedPaths.contains(url.path) {
      try fileManager.setAttributes(rootAdmin, ofItemAtPath: url.path)
    }
    for label in allServiceLabels() {
      let plist = paths.launchDaemonDirectory.appendingPathComponent("\(label).plist")
      if itemExists(plist) {
        try fileManager.setAttributes(rootWheel, ofItemAtPath: plist.path)
      }
    }
    for name in [".install-role", ".app-install-complete", ".app-launchd-state.json"] {
      let marker = paths.supportRoot.appendingPathComponent("support/\(name)")
      if itemExists(marker) {
        try fileManager.setAttributes(rootWheel, ofItemAtPath: marker.path)
      }
    }
  }

  func applyOwnershipRecursively(
    _ attributes: [FileAttributeKey: Any],
    at root: URL
  ) throws {
    try fileManager.setAttributes(attributes, ofItemAtPath: root.path)
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: [.skipsPackageDescendants]
      )
    else {
      throw LifecycleServiceError.unsafeManagedPath(root.path)
    }
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if isSymbolicLink(url) {
        continue
      }
      guard values.isDirectory == true || values.isRegularFile == true else {
        throw LifecycleServiceError.unsafeManagedPath(url.path)
      }
      try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }
  }

  func retainedModePaths(at paths: LifecyclePaths) -> [URL] {
    [
      paths.supportRoot.appendingPathComponent("config"),
      paths.supportRoot.appendingPathComponent("config/tls"),
      paths.supportRoot.appendingPathComponent("logs"),
    ]
  }
  func validatePayload() throws {
    try validatePayload(at: payloadRoot)
  }

  func validatePayload(at root: URL) throws {
    for path in ["releases", "native", "share/bin", "share/launchd", "support/openssl"] {
      let url = root.appendingPathComponent(path)
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values?.isDirectory == true, values?.isSymbolicLink != true else {
        throw LifecycleServiceError.missingPayloadPath(path)
      }
    }
    let manifest = root.appendingPathComponent("manifest.json")
    let manifestValues = try? manifest.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard manifestValues?.isRegularFile == true, manifestValues?.isSymbolicLink != true else {
      throw LifecycleServiceError.missingPayloadPath("manifest.json")
    }
    let manifestObject = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
    guard let manifestDictionary = manifestObject as? [String: Any] else {
      throw LifecycleServiceError.unsafePayloadPath(manifest.path)
    }
    var recordedSymlinks: [String: String] = [:]
    for case let record as [String: String] in manifestDictionary["symlinks"] as? [Any] ?? [] {
      guard let path = record["path"], let target = record["target"],
        recordedSymlinks.updateValue(target, forKey: path) == nil
      else {
        throw LifecycleServiceError.unsafePayloadPath(manifest.path)
      }
    }
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    var actualSymlinks: [String: String] = [:]
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: [.skipsPackageDescendants]
      )
    else {
      throw LifecycleServiceError.missingPayloadPath(root.path)
    }
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        let canonicalParent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let canonicalLink = canonicalParent.appendingPathComponent(url.lastPathComponent)
        guard canonicalLink.path.hasPrefix(canonicalRoot.path + "/") else {
          throw LifecycleServiceError.unsafePayloadPath(url.path)
        }
        let relative = String(canonicalLink.path.dropFirst(canonicalRoot.path.count + 1))
        let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
        guard !destination.hasPrefix("/") else {
          throw LifecycleServiceError.unsafePayloadPath(url.path)
        }
        let resolved =
          canonicalParent
          .appendingPathComponent(destination)
          .resolvingSymlinksInPath()
          .standardizedFileURL
        guard resolved.path.hasPrefix(canonicalRoot.path + "/"), itemExists(resolved) else {
          throw LifecycleServiceError.unsafePayloadPath(url.path)
        }
        guard actualSymlinks.updateValue(destination, forKey: relative) == nil else {
          throw LifecycleServiceError.unsafePayloadPath(url.path)
        }
      }
    }
    guard actualSymlinks == recordedSymlinks else {
      throw LifecycleServiceError.unsafePayloadPath(manifest.path)
    }
  }

  func preflightTarget(at paths: LifecyclePaths) throws {
    if try packageReceiptIsPresent(at: paths) {
      throw LifecycleServiceError.packageReceiptPresent(contract.packageReceipt)
    }
    if try tlsState(at: paths) == .partial {
      throw LifecycleServiceError.partialTLSState
    }
  }
  func validateCommandLinkOwnership(at paths: LifecyclePaths) throws {
    for (command, absolutePath) in contract.commandLinks {
      let link = paths.relocate(absolutePath)
      guard itemExists(link) else {
        continue
      }
      let expectedTarget = paths.supportRoot.appendingPathComponent("bin/\(command)")
      guard try commandLink(at: link, pointsTo: expectedTarget) else {
        throw LifecycleServiceError.commandLinkConflict(link.path)
      }
    }
  }

  func commandLink(at link: URL, pointsTo expectedTarget: URL) throws -> Bool {
    guard isSymbolicLink(link) else {
      return false
    }
    let destination = try fileManager.destinationOfSymbolicLink(atPath: link.path)
    let resolved: URL
    if destination.hasPrefix("/") {
      resolved = URL(fileURLWithPath: destination)
    } else {
      resolved = link.deletingLastPathComponent().appendingPathComponent(destination)
    }
    return resolved.standardizedFileURL.path == expectedTarget.standardizedFileURL.path
  }
  func installPayload(at paths: LifecyclePaths, sourceRoot: URL) throws {
    try fileManager.createDirectory(
      at: paths.supportRoot,
      withIntermediateDirectories: true
    )
    for retained in contract.retainedDirectories {
      try fileManager.createDirectory(
        at: paths.supportRoot.appendingPathComponent(retained),
        withIntermediateDirectories: true
      )
    }

    for directory in ["releases", "native", "share"] {
      let source = sourceRoot.appendingPathComponent(directory)
      let destination = paths.supportRoot.appendingPathComponent(directory)
      try replaceItem(at: destination, with: source)
    }

    try replaceItem(
      at: paths.supportRoot.appendingPathComponent("support/openssl"),
      with: sourceRoot.appendingPathComponent("support/openssl")
    )

    try replaceItem(
      at: paths.supportRoot.appendingPathComponent("bin"),
      with: sourceRoot.appendingPathComponent("share/bin")
    )
  }

  func installPlists(
    for role: InstallRole,
    at paths: LifecyclePaths,
    sourceRoot: URL
  ) throws {
    try fileManager.createDirectory(
      at: paths.launchDaemonDirectory,
      withIntermediateDirectories: true
    )
    let selectedLabels = Set(contract.roles[role.rawValue] ?? [])
    let allLabels = Set(contract.roles.values.flatMap { $0 })

    for label in allLabels {
      let destination = paths.launchDaemonDirectory
        .appendingPathComponent("\(label).plist")
      if selectedLabels.contains(label) {
        let source =
          sourceRoot
          .appendingPathComponent("share/launchd/\(label).plist")
        try replaceItem(at: destination, with: source)
      } else if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
    }
  }

  func installCommandLinks(at paths: LifecyclePaths) throws {
    for (command, absolutePath) in contract.commandLinks {
      let link = paths.relocate(absolutePath)
      try fileManager.createDirectory(
        at: link.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if itemExists(link) {
        try fileManager.removeItem(at: link)
      }
      let target = paths.supportRoot.appendingPathComponent("bin/\(command)")
      try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    }
  }

  func writeRole(_ role: InstallRole, at paths: LifecyclePaths) throws {
    let support = paths.supportRoot.appendingPathComponent("support")
    try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
    try Data("\(role.rawValue)\n".utf8).write(to: paths.roleMarker, options: .atomic)
  }

  func writeInstallMarker(at paths: LifecyclePaths) throws {
    let marker = paths.supportRoot
      .appendingPathComponent("support/.app-install-complete")
    try Data("version=1\n".utf8).write(to: marker, options: .atomic)
  }

  func replaceItem(at destination: URL, with source: URL) throws {
    if itemExists(destination) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: source, to: destination)
  }

  func isSymbolicLink(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
      return false
    }
    return values.isSymbolicLink == true
  }

  func itemExists(_ url: URL) -> Bool {
    fileManager.fileExists(atPath: url.path) || isSymbolicLink(url)
  }
}

struct OwnershipIntent: Codable {
  let ownerID: Int
  let wheelGroupID: Int
  let adminGroupID: Int
}
