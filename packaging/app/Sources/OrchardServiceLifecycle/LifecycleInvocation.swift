import Foundation

public enum LifecycleOperation: String, Equatable, Sendable {
  case install
  case update
  case uninstall
  case status

  var mutatesState: Bool {
    self != .status
  }
}

public enum InstallRole: String, CaseIterable, Equatable, Sendable {
  case all
  case controller
  case nodeAgent = "node-agent"
}

public enum LifecycleError: Error, Equatable, Sendable {
  case missingOperation
  case invalidOperation(String)
  case missingValue(String)
  case invalidRole(String)
  case unknownOption(String)
  case rootPrivilegesRequired
  case invalidRoot(String)
}

public struct LifecycleInvocation: Equatable, Sendable {
  public let operation: LifecycleOperation
  public let role: InstallRole?
  public let root: String
  public let dryRun: Bool

  public static func parse(
    arguments: [String],
    effectiveUserID: UInt32
  ) throws -> LifecycleInvocation {
    guard let operationArgument = arguments.first else {
      throw LifecycleError.missingOperation
    }
    guard let operation = LifecycleOperation(rawValue: operationArgument) else {
      throw LifecycleError.invalidOperation(operationArgument)
    }

    var role: InstallRole?
    var root = "/"
    var dryRun = false
    var index = 1

    while index < arguments.count {
      let option = arguments[index]
      switch option {
      case "--role":
        let value = try value(after: option, at: index, in: arguments)
        guard let parsedRole = InstallRole(rawValue: value) else {
          throw LifecycleError.invalidRole(value)
        }
        role = parsedRole
        index += 2
      case "--root":
        root = try canonicalRoot(
          try value(after: option, at: index, in: arguments)
        )
        index += 2
      case "--dry-run":
        dryRun = true
        index += 1
      default:
        throw LifecycleError.unknownOption(option)
      }
    }

    if operation.mutatesState && root == "/" && !dryRun && effectiveUserID != 0 {
      throw LifecycleError.rootPrivilegesRequired
    }

    return LifecycleInvocation(
      operation: operation,
      role: role,
      root: root,
      dryRun: dryRun
    )
  }

  private static func value(
    after option: String,
    at index: Int,
    in arguments: [String]
  ) throws -> String {
    let valueIndex = index + 1
    guard valueIndex < arguments.count else {
      throw LifecycleError.missingValue(option)
    }
    return arguments[valueIndex]
  }

  private static func canonicalRoot(_ value: String) throws -> String {
    guard value.hasPrefix("/") else {
      throw LifecycleError.invalidRoot(value)
    }
    let canonical = URL(fileURLWithPath: value)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    if canonical == "/System/Volumes/Data" || canonical.hasPrefix("/System/Volumes/Data/") {
      throw LifecycleError.invalidRoot(value)
    }
    return canonical
  }
}
