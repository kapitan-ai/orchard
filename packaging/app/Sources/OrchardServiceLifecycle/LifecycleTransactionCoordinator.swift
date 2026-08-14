import Darwin
import Foundation

extension LifecycleService {
  func beginTransaction(
    at paths: LifecyclePaths,
    stagePayload: Bool,
    loadedServices: Set<String>
  ) throws -> LifecycleTransaction {
    let preexistingRetainedPaths = Set(
      retainedModePaths(at: paths).filter(itemExists).map(\.path)
    )
    let transactionRoot = paths.transactionRoot
    let preparingRoot = paths.preparingTransactionRoot
    if itemExists(transactionRoot) || itemExists(preparingRoot) {
      throw LifecycleServiceError.transactionAlreadyExists(transactionRoot.path)
    }

    try fileManager.createDirectory(
      at: transactionRoot.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(at: preparingRoot, withIntermediateDirectories: false)
    try setMode(0o700, at: preparingRoot)

    try writeTransactionManifest(
      transaction: LifecycleTransaction(
        root: preparingRoot,
        stagedPayload: preparingRoot.appendingPathComponent("staged-payload"),
        snapshots: [],
        preexistingRetainedPaths: preexistingRetainedPaths
      ),
      loadedServices: loadedServices,
      phase: .preparing,
      at: paths
    )
    try fileManager.moveItem(at: preparingRoot, to: transactionRoot)

    let stagedPayload = transactionRoot.appendingPathComponent("staged-payload")
    if stagePayload {
      try fileManager.copyItem(at: payloadRoot, to: stagedPayload)
      try validatePayload(at: stagedPayload)
    }

    let backupRoot = transactionRoot.appendingPathComponent("backup")
    try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: false)
    try setMode(0o700, at: backupRoot)

    var snapshots: [LifecycleSnapshot] = []
    for (index, original) in managedPaths(at: paths).enumerated() {
      let backup = backupRoot.appendingPathComponent(String(index))
      let existed = itemExists(original)
      if existed {
        try fileManager.copyItem(at: original, to: backup)
      }
      snapshots.append(
        LifecycleSnapshot(original: original, backup: backup, existed: existed)
      )
      try writeTransactionManifest(
        transaction: LifecycleTransaction(
          root: transactionRoot,
          stagedPayload: stagedPayload,
          snapshots: snapshots,
          preexistingRetainedPaths: preexistingRetainedPaths
        ),
        loadedServices: loadedServices,
        phase: .preparing,
        at: paths
      )
    }
    let transaction = LifecycleTransaction(
      root: transactionRoot,
      stagedPayload: stagedPayload,
      snapshots: snapshots,
      preexistingRetainedPaths: preexistingRetainedPaths
    )
    try writeTransactionManifest(
      transaction: transaction,
      loadedServices: loadedServices,
      phase: .ready,
      at: paths
    )
    return transaction
  }

  func writeTransactionManifest(
    transaction: LifecycleTransaction,
    loadedServices: Set<String>,
    phase: TransactionPhase,
    at paths: LifecyclePaths
  ) throws {
    guard loadedServices.isSubset(of: Set(allServiceLabels())) else {
      throw LifecycleServiceError.invalidTransactionManifest(transaction.root.path)
    }
    let manifest = TransactionManifest(
      schemaVersion: 1,
      phase: phase,
      snapshots: transaction.snapshots.enumerated().map { index, snapshot in
        TransactionSnapshotRecord(
          originalPath: snapshot.original.path,
          backupName: String(index),
          existed: snapshot.existed
        )
      },
      loadedServices: loadedServices.sorted()
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    let manifestURL = transaction.root.appendingPathComponent("manifest.json")
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    try setMode(0o600, at: manifestURL)
    if paths.isSystemRoot {
      try fileManager.setAttributes(
        [
          .ownerAccountID: NSNumber(value: 0),
          .groupOwnerAccountID: NSNumber(value: 0),
        ],
        ofItemAtPath: manifestURL.path
      )
    }
  }

  func rollback(
    _ transaction: LifecycleTransaction,
    paths: LifecyclePaths,
    loadedServices: Set<String>
  ) throws {
    try setLoadedServices([], at: paths)
    for snapshot in transaction.snapshots.reversed() {
      if itemExists(snapshot.original) {
        try fileManager.removeItem(at: snapshot.original)
      }
      if snapshot.existed {
        try fileManager.createDirectory(
          at: snapshot.original.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: snapshot.backup, to: snapshot.original)
      }
    }
    try setLoadedServices(loadedServices, at: paths)
    try fileManager.removeItem(at: transaction.root)
  }

  func recoverTransactionIfNeeded(at paths: LifecyclePaths) throws {
    if itemExists(paths.preparingTransactionRoot) {
      try validatePreparingTransaction(at: paths)
      try fileManager.removeItem(at: paths.preparingTransactionRoot)
    }
    guard itemExists(paths.transactionRoot) else {
      return
    }
    try validateTransactionMetadata(at: paths)
    let manifestURL = paths.transactionRoot.appendingPathComponent("manifest.json")
    guard itemExists(manifestURL) else {
      throw LifecycleServiceError.invalidTransactionManifest(manifestURL.path)
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let manifest: TransactionManifest
    do {
      manifest = try decoder.decode(
        TransactionManifest.self,
        from: Data(contentsOf: manifestURL)
      )
    } catch {
      throw LifecycleServiceError.invalidTransactionManifest(manifestURL.path)
    }

    guard manifest.schemaVersion == 1,
      Set(manifest.loadedServices).isSubset(of: Set(allServiceLabels()))
    else {
      throw LifecycleServiceError.invalidTransactionManifest(manifestURL.path)
    }
    if manifest.phase == .preparing {
      try fileManager.removeItem(at: paths.transactionRoot)
      return
    }

    let allowedPaths = Set(managedPaths(at: paths).map(\.path))
    let recordedPaths = Set(manifest.snapshots.map(\.originalPath))
    let backupNames = Set(manifest.snapshots.map(\.backupName))
    guard recordedPaths == allowedPaths,
      recordedPaths.count == manifest.snapshots.count,
      backupNames.count == manifest.snapshots.count
    else {
      throw LifecycleServiceError.invalidTransactionManifest(manifestURL.path)
    }

    let backupRoot = paths.transactionRoot.appendingPathComponent("backup")
    let snapshots = try manifest.snapshots.map { record in
      guard !record.backupName.isEmpty,
        record.backupName.allSatisfy(\.isNumber),
        let backupIndex = Int(record.backupName),
        backupIndex >= 0,
        backupIndex < manifest.snapshots.count
      else {
        throw LifecycleServiceError.invalidTransactionManifest(manifestURL.path)
      }
      let backup = backupRoot.appendingPathComponent(record.backupName)
      if record.existed && !itemExists(backup) {
        throw LifecycleServiceError.invalidTransactionManifest(manifestURL.path)
      }
      return LifecycleSnapshot(
        original: URL(fileURLWithPath: record.originalPath),
        backup: backup,
        existed: record.existed
      )
    }

    try rollback(
      LifecycleTransaction(
        root: paths.transactionRoot,
        stagedPayload: paths.transactionRoot.appendingPathComponent("staged-payload"),
        snapshots: snapshots,
        preexistingRetainedPaths: []
      ),
      paths: paths,
      loadedServices: Set(manifest.loadedServices)
    )
  }

  private func validatePreparingTransaction(at paths: LifecyclePaths) throws {
    let root = paths.preparingTransactionRoot
    let manifestURL = root.appendingPathComponent("manifest.json")
    try validateTransactionRoot(root, isSystemRoot: paths.isSystemRoot)
    if !itemExists(manifestURL) {
      guard try fileManager.contentsOfDirectory(atPath: root.path).isEmpty else {
        throw LifecycleServiceError.invalidTransactionManifest(manifestURL.path)
      }
      return
    }
    try validateTransactionMetadata(root: root, isSystemRoot: paths.isSystemRoot)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard
      let manifest = try? decoder.decode(
        TransactionManifest.self,
        from: Data(contentsOf: manifestURL)
      ),
      manifest.schemaVersion == 1,
      manifest.phase == .preparing,
      manifest.snapshots.isEmpty,
      Set(manifest.loadedServices).isSubset(of: Set(allServiceLabels()))
    else {
      throw LifecycleServiceError.invalidTransactionManifest(manifestURL.path)
    }
  }

  func validateTransactionMetadata(at paths: LifecyclePaths) throws {
    try validateTransactionMetadata(root: paths.transactionRoot, isSystemRoot: paths.isSystemRoot)
  }

  private func validateTransactionMetadata(root: URL, isSystemRoot: Bool) throws {
    let manifest = root.appendingPathComponent("manifest.json")
    try validateTransactionRoot(root, isSystemRoot: isSystemRoot)
    let manifestValues = try manifest.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard manifestValues.isRegularFile == true,
      manifestValues.isSymbolicLink != true
    else {
      throw LifecycleServiceError.invalidTransactionManifest(manifest.path)
    }
    guard isSystemRoot else {
      return
    }
    let attributes = try fileManager.attributesOfItem(atPath: manifest.path)
    let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
    guard owner == 0, mode & ~0o600 == 0 else {
      throw LifecycleServiceError.invalidTransactionManifest(manifest.path)
    }
  }

  private func validateTransactionRoot(_ root: URL, isSystemRoot: Bool) throws {
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw LifecycleServiceError.invalidTransactionManifest(root.path)
    }
    guard isSystemRoot else {
      return
    }
    let attributes = try fileManager.attributesOfItem(atPath: root.path)
    let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
    guard owner == 0, mode & ~0o700 == 0 else {
      throw LifecycleServiceError.invalidTransactionManifest(root.path)
    }
  }

  func managedPaths(at paths: LifecyclePaths) -> [URL] {
    var result = contract.appOwnedDirectories.map {
      paths.supportRoot.appendingPathComponent($0)
    }
    result += allServiceLabels().map {
      paths.launchDaemonDirectory.appendingPathComponent("\($0).plist")
    }
    result += contract.commandLinks.values.sorted().map(paths.relocate)
    result += contract.appOwnedSupportEntries
      .filter { $0 != ".app-transaction" }
      .map { paths.supportRoot.appendingPathComponent("support/\($0)") }
    return result
  }
  func acquireLifecycleLock(at paths: LifecyclePaths) throws -> LifecycleLock {
    try fileManager.createDirectory(
      at: paths.lifecycleLock.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let descriptor = open(
      paths.lifecycleLock.path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard descriptor >= 0 else {
      throw LifecycleServiceError.invalidLifecycleLock(paths.lifecycleLock.path)
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw LifecycleServiceError.lifecycleLocked(paths.lifecycleLock.path)
    }
    guard fchmod(descriptor, 0o600) == 0 else {
      _ = flock(descriptor, LOCK_UN)
      close(descriptor)
      throw LifecycleServiceError.invalidLifecycleLock(paths.lifecycleLock.path)
    }
    if paths.isSystemRoot, fchown(descriptor, 0, 0) != 0 {
      _ = flock(descriptor, LOCK_UN)
      close(descriptor)
      throw LifecycleServiceError.invalidLifecycleLock(paths.lifecycleLock.path)
    }
    return LifecycleLock(descriptor: descriptor)
  }
}

struct LifecycleSnapshot {
  let original: URL
  let backup: URL
  let existed: Bool
}

struct LifecycleTransaction {
  let root: URL
  let stagedPayload: URL
  let snapshots: [LifecycleSnapshot]
  let preexistingRetainedPaths: Set<String>
}

struct TransactionSnapshotRecord: Codable {
  let originalPath: String
  let backupName: String
  let existed: Bool
}

struct TransactionManifest: Codable {
  let schemaVersion: Int
  let phase: TransactionPhase
  let snapshots: [TransactionSnapshotRecord]
  let loadedServices: [String]
}

enum TransactionPhase: String, Codable {
  case preparing
  case ready
  case applying
}

final class LifecycleLock {
  let descriptor: Int32

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  func release() {
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
