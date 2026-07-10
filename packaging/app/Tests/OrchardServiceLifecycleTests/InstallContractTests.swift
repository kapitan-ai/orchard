import Foundation
import XCTest

@testable import OrchardServiceLifecycle

final class InstallContractTests: XCTestCase {
  func testRepositoryContractDefinesRolesServicesAndRetainedState() throws {
    let packageDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contractURL =
      packageDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("service-lifecycle.json")

    let contract = try InstallContract.load(from: contractURL)

    XCTAssertEqual(
      contract.roles["all"],
      [
        "com.orchard.controller",
        "com.orchard.node-agent",
      ])
    XCTAssertEqual(contract.roles["controller"], ["com.orchard.controller"])
    XCTAssertEqual(contract.roles["node-agent"], ["com.orchard.node-agent"])
    XCTAssertEqual(contract.packageReceipt, "com.orchard.pkg")
    XCTAssertEqual(
      Set(contract.retainedDirectories),
      Set(["config", "data", "models", "bundles", "logs", "support"])
    )
  }
}
