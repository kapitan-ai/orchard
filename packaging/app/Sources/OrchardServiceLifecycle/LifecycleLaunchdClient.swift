import Foundation

extension LifecycleService {
  func loadedServices(at paths: LifecyclePaths) throws -> Set<String> {
    if paths.isSystemRoot {
      var loaded: Set<String> = []
      for label in allServiceLabels() where try systemServiceIsLoaded(label) {
        loaded.insert(label)
      }
      return loaded
    }

    let stateURL = paths.launchdStateFile
    guard fileManager.fileExists(atPath: stateURL.path) else {
      return []
    }
    let state = try JSONDecoder().decode(
      SandboxLaunchdState.self,
      from: Data(contentsOf: stateURL)
    )
    return Set(state.loadedServices)
  }

  func setLoadedServices(
    _ services: Set<String>,
    at paths: LifecyclePaths
  ) throws {
    if paths.isSystemRoot {
      var currentlyLoaded: Set<String> = []
      for label in allServiceLabels() where try systemServiceIsLoaded(label) {
        currentlyLoaded.insert(label)
      }
      for label in currentlyLoaded.subtracting(services).sorted() {
        let status = try launchctlStatus(["bootout", "system/\(label)"])
        guard status == 0 else {
          throw LifecycleServiceError.launchdFailure(label, "bootout", status)
        }
        if try systemServiceIsLoaded(label) {
          throw LifecycleServiceError.launchdFailure(label, "verify-stopped", -1)
        }
      }
      for label in services.subtracting(currentlyLoaded).sorted() {
        let plist = paths.launchDaemonDirectory.appendingPathComponent("\(label).plist")
        let status = try launchctlStatus(["bootstrap", "system", plist.path])
        guard status == 0 else {
          throw LifecycleServiceError.launchdFailure(label, "bootstrap", status)
        }
        guard try systemServiceIsLoaded(label) else {
          throw LifecycleServiceError.launchdFailure(label, "verify-started", -1)
        }
      }
      return
    }

    let state = SandboxLaunchdState(loadedServices: services.sorted())
    try fileManager.createDirectory(
      at: paths.launchdStateFile.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(state).write(to: paths.launchdStateFile, options: .atomic)
  }

  func allServiceLabels() -> [String] {
    Array(Set(contract.roles.values.flatMap { $0 })).sorted()
  }

  func systemServiceIsLoaded(_ label: String) throws -> Bool {
    let status = try launchctlStatus(["print", "system/\(label)"])
    switch status {
    case 0:
      return true
    case 113:
      return false
    default:
      throw LifecycleServiceError.launchdFailure(label, "query", status)
    }
  }

  func launchctlStatus(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
}

struct SandboxLaunchdState: Codable {
  let loadedServices: [String]

  enum CodingKeys: String, CodingKey {
    case loadedServices = "loaded_services"
  }
}
