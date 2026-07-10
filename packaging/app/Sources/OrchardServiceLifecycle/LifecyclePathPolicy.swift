import Foundation

extension LifecycleService {
  func validateManagedPaths(at paths: LifecyclePaths) throws {
    var managed = [
      paths.supportRoot,
      paths.launchDaemonDirectory,
      paths.supportRoot.appendingPathComponent("support"),
      paths.transactionRoot,
      paths.preparingTransactionRoot,
      paths.lifecycleLock,
    ]
    managed += contract.retainedDirectories.map {
      paths.supportRoot.appendingPathComponent($0)
    }
    managed += contract.appOwnedDirectories.map {
      paths.supportRoot.appendingPathComponent($0)
    }
    managed += contract.appOwnedSupportEntries.map {
      paths.supportRoot.appendingPathComponent("support/\($0)")
    }
    managed += allServiceLabels().map {
      paths.launchDaemonDirectory.appendingPathComponent("\($0).plist")
    }
    for destination in managed {
      try rejectSymlinkedComponents(from: paths.root, through: destination)
    }
    for absolutePath in contract.commandLinks.values {
      let parent = paths.relocate(absolutePath).deletingLastPathComponent()
      try rejectSymlinkedComponents(from: paths.root, through: parent)
    }
  }
  func rejectSymlinkedComponents(from root: URL, through destination: URL) throws {
    let rootComponents = root.standardizedFileURL.pathComponents
    let destinationComponents = destination.standardizedFileURL.pathComponents
    guard destinationComponents.starts(with: rootComponents) else {
      throw LifecycleServiceError.unsafeManagedPath(destination.path)
    }
    var current = root.standardizedFileURL
    if root.path == "/", itemExists(current) {
      try validateTrustedSystemComponent(current)
    }
    for component in destinationComponents.dropFirst(rootComponents.count) {
      current.appendPathComponent(component)
      if itemExists(current), isSymbolicLink(current) {
        throw LifecycleServiceError.unsafeManagedPath(current.path)
      }
      if root.path == "/", itemExists(current) {
        try validateTrustedSystemComponent(current)
      }
    }
  }

  private func validateTrustedSystemComponent(_ url: URL) throws {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
    guard owner == 0, mode & 0o022 == 0 else {
      throw LifecycleServiceError.unsafeManagedPath(url.path)
    }
  }
}

struct LifecyclePaths {
  let root: URL
  let contract: InstallContract

  var supportRoot: URL {
    relocate(contract.supportRoot)
  }

  var launchDaemonDirectory: URL {
    relocate(contract.launchDaemonDirectory)
  }

  var launchdStateFile: URL {
    supportRoot.appendingPathComponent("support/.app-launchd-state.json")
  }

  var transactionRoot: URL {
    supportRoot.appendingPathComponent("support/.app-transaction")
  }

  var preparingTransactionRoot: URL {
    supportRoot.appendingPathComponent("support/.app-transaction.preparing")
  }

  var lifecycleLock: URL {
    supportRoot.appendingPathComponent("support/.app-lifecycle.lock")
  }

  var roleMarker: URL {
    supportRoot.appendingPathComponent("support/.install-role")
  }

  var roleRequest: URL {
    supportRoot.appendingPathComponent("support/.install-role.request")
  }

  var sandboxReceipt: URL {
    relocate("\(contract.sandboxReceiptDirectory)/\(contract.packageReceipt)")
  }

  var isSystemRoot: Bool {
    root.path == "/"
  }

  func relocate(_ absolutePath: String) -> URL {
    if root.path == "/" {
      return URL(fileURLWithPath: absolutePath)
    }
    return root.appendingPathComponent(String(absolutePath.dropFirst()))
  }
}
