import Foundation
import XCTest

@testable import OrchardServiceLifecycle

final class LifecycleInvocationTests: XCTestCase {
  func testInstallRejectsUnknownRole() {
    XCTAssertThrowsError(
      try LifecycleInvocation.parse(
        arguments: ["install", "--role", "worker", "--root", "/tmp/orchard-test"],
        effectiveUserID: 501
      )
    ) { error in
      XCTAssertEqual(error as? LifecycleError, .invalidRole("worker"))
    }
  }

  func testInstallWithoutRoleDefersRoleResolutionToLifecycleService() throws {
    let invocation = try LifecycleInvocation.parse(
      arguments: ["install", "--root", "/tmp/orchard-test"],
      effectiveUserID: 501
    )

    XCTAssertNil(invocation.role)
  }

  func testSystemMutationRequiresRootButDryRunDoesNot() throws {
    XCTAssertThrowsError(
      try LifecycleInvocation.parse(
        arguments: ["update", "--role", "controller"],
        effectiveUserID: 501
      )
    ) { error in
      XCTAssertEqual(error as? LifecycleError, .rootPrivilegesRequired)
    }

    let dryRun = try LifecycleInvocation.parse(
      arguments: ["update", "--role", "controller", "--dry-run"],
      effectiveUserID: 501
    )

    XCTAssertTrue(dryRun.dryRun)
    XCTAssertEqual(dryRun.root, "/")
  }

  func testCanonicalRootCannotBypassRootPrivilegeGuard() throws {
    XCTAssertThrowsError(
      try LifecycleInvocation.parse(
        arguments: ["install", "--root", "/private/.."],
        effectiveUserID: 501
      )
    ) { error in
      XCTAssertEqual(error as? LifecycleError, .rootPrivilegesRequired)
    }

    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("orchard-root-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(
      at: temporary,
      withDestinationURL: URL(fileURLWithPath: "/")
    )
    defer { try? FileManager.default.removeItem(at: temporary) }

    XCTAssertThrowsError(
      try LifecycleInvocation.parse(
        arguments: ["uninstall", "--root", temporary.path],
        effectiveUserID: 501
      )
    ) { error in
      XCTAssertEqual(error as? LifecycleError, .rootPrivilegesRequired)
    }
  }

  func testRelativeRootIsRejected() {
    XCTAssertThrowsError(
      try LifecycleInvocation.parse(
        arguments: ["status", "--root", "tmp/orchard"],
        effectiveUserID: 501
      )
    ) { error in
      XCTAssertEqual(error as? LifecycleError, .invalidRoot("tmp/orchard"))
    }
  }

  func testDataVolumeFirmlinkRootIsRejected() {
    XCTAssertThrowsError(
      try LifecycleInvocation.parse(
        arguments: ["install", "--root", "/System/Volumes/Data"],
        effectiveUserID: 0
      )
    ) { error in
      XCTAssertEqual(error as? LifecycleError, .invalidRoot("/System/Volumes/Data"))
    }
  }
}
