import Darwin
import Foundation
import XCTest

@testable import OrchardServiceLifecycle

final class LifecycleServiceTests: XCTestCase {
  private var temporaryDirectories: [URL] = []

  override func tearDownWithError() throws {
    let fileManager = FileManager.default
    for directory in temporaryDirectories {
      try? fileManager.removeItem(at: directory)
    }
    temporaryDirectories.removeAll()
  }

  func testInstallAllCreatesRoleSelectedServiceLayoutWithoutStartingServices() throws {
    let fixture = try makeFixture()
    let invocation = try LifecycleInvocation.parse(
      arguments: ["install", "--role", "all", "--root", fixture.root.path],
      effectiveUserID: 501
    )

    let result = try LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    ).execute(invocation)

    XCTAssertEqual(result.status.role, .all)
    XCTAssertEqual(result.status.loadedServices, [])
    XCTAssertTrue(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/releases/controller.txt"
      ))
    XCTAssertTrue(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/LaunchDaemons/com.orchard.controller.plist"
      ))
    XCTAssertTrue(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/LaunchDaemons/com.orchard.node-agent.plist"
      ))
    XCTAssertEqual(
      try text(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/support/.install-role"
      ),
      "all\n"
    )

    let orchardctl = relocated(
      root: fixture.root,
      absolutePath: "/usr/local/bin/orchardctl"
    )
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: orchardctl.path),
      relocated(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/bin/orchardctl"
      ).path
    )
  }

  func testInstallWithoutRoleDefaultsToAll() throws {
    let fixture = try makeFixture()
    let invocation = try LifecycleInvocation.parse(
      arguments: ["install", "--root", fixture.root.path],
      effectiveUserID: 501
    )

    let result = try LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    ).execute(invocation)

    XCTAssertEqual(result.status.role, .all)
  }

  func testWritableRoleRequestIsRejectedBeforeInstall() throws {
    let fixture = try makeFixture()
    let request = relocated(
      root: fixture.root,
      absolutePath: "/Library/Application Support/Orchard/support/.install-role.request"
    )
    try write("controller\n", to: request)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o666],
      ofItemAtPath: request.path
    )
    let invocation = try LifecycleInvocation.parse(
      arguments: ["install", "--root", fixture.root.path],
      effectiveUserID: 501
    )

    XCTAssertThrowsError(
      try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload
      ).execute(invocation)
    ) { error in
      XCTAssertEqual(
        error as? LifecycleServiceError,
        .insecureRoleRequest(request.path)
      )
    }
    XCTAssertFalse(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/releases/controller.txt"
      ))
  }

  func testTrustedRoleRequestIsConsumedAndPersistedForUpdate() throws {
    let fixture = try makeFixture()
    let request = relocated(
      root: fixture.root,
      absolutePath: "/Library/Application Support/Orchard/support/.install-role.request"
    )
    try write("controller\n", to: request)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: request.path
    )
    let service = LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    )

    let installed = try service.execute(
      LifecycleInvocation.parse(
        arguments: ["install", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )
    XCTAssertEqual(installed.status.role, .controller)
    XCTAssertFalse(FileManager.default.fileExists(atPath: request.path))

    let updated = try service.execute(
      LifecycleInvocation.parse(
        arguments: ["update", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )
    XCTAssertEqual(updated.status.role, .controller)
  }

  func testWritablePersistedRoleIsRejectedBeforeUpdate() throws {
    let fixture = try makeFixture()
    let service = LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    )
    _ = try service.execute(
      LifecycleInvocation.parse(
        arguments: ["install", "--role", "controller", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )
    let marker = relocated(
      root: fixture.root,
      absolutePath: "/Library/Application Support/Orchard/support/.install-role"
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o666],
      ofItemAtPath: marker.path
    )

    XCTAssertThrowsError(
      try service.execute(
        LifecycleInvocation.parse(
          arguments: ["update", "--root", fixture.root.path],
          effectiveUserID: 501
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? LifecycleServiceError,
        .insecureRoleFile(marker.path)
      )
    }
  }

  func testInstallRefusesToReplaceForeignCommandAtManagedLinkPath() throws {
    let fixture = try makeFixture()
    let command = relocated(root: fixture.root, absolutePath: "/usr/local/bin/orchardctl")
    try write("foreign-command", to: command)

    XCTAssertThrowsError(
      try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload
      ).execute(
        LifecycleInvocation.parse(
          arguments: ["install", "--role", "all", "--root", fixture.root.path],
          effectiveUserID: 501
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? LifecycleServiceError,
        .commandLinkConflict(command.path)
      )
    }
    XCTAssertEqual(try String(contentsOf: command, encoding: .utf8), "foreign-command")
  }

  func testUninstallRetainsForeignReplacementAtManagedLinkPath() throws {
    let fixture = try makeFixture()
    let service = LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    )
    _ = try service.execute(
      LifecycleInvocation.parse(
        arguments: ["install", "--role", "all", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )
    let command = relocated(root: fixture.root, absolutePath: "/usr/local/bin/orchardctl")
    try FileManager.default.removeItem(at: command)
    try write("foreign-command", to: command)

    _ = try service.execute(
      LifecycleInvocation.parse(
        arguments: ["uninstall", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )

    XCTAssertEqual(try String(contentsOf: command, encoding: .utf8), "foreign-command")
  }

  func testInstallRejectsSymlinkedManagedAncestor() throws {
    let fixture = try makeFixture()
    let escaped = fixture.root.deletingLastPathComponent().appendingPathComponent("escaped")
    try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)
    let library = fixture.root.appendingPathComponent("Library")
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: library.path,
      withDestinationPath: escaped.path
    )

    XCTAssertThrowsError(
      try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload
      ).execute(
        LifecycleInvocation.parse(
          arguments: ["install", "--role", "all", "--root", fixture.root.path],
          effectiveUserID: 501
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? LifecycleServiceError,
        .unsafeManagedPath(library.path)
      )
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: escaped.appendingPathComponent("Application Support/Orchard").path
      ))
  }

  func testInstallRejectsSymlinkedRetainedChild() throws {
    let fixture = try makeFixture()
    let escaped = fixture.root.deletingLastPathComponent().appendingPathComponent("escaped-config")
    try FileManager.default.createDirectory(at: escaped, withIntermediateDirectories: true)
    let config = relocated(
      root: fixture.root,
      absolutePath: "/Library/Application Support/Orchard/config"
    )
    try FileManager.default.createDirectory(
      at: config.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      atPath: config.path,
      withDestinationPath: escaped.path
    )

    XCTAssertThrowsError(
      try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload
      ).execute(
        LifecycleInvocation.parse(
          arguments: ["install", "--role", "all", "--root", fixture.root.path],
          effectiveUserID: 501
        )
      )
    ) { error in
      XCTAssertEqual(error as? LifecycleServiceError, .unsafeManagedPath(config.path))
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: escaped.path), [])
  }

  func testInstallRejectsPayloadSymlink() throws {
    let fixture = try makeFixture()
    let link = fixture.payload.appendingPathComponent("native/escaped")
    try FileManager.default.createSymbolicLink(
      atPath: link.path,
      withDestinationPath: "/usr/bin/true"
    )

    XCTAssertThrowsError(
      try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload
      ).execute(
        LifecycleInvocation.parse(
          arguments: ["install", "--role", "all", "--root", fixture.root.path],
          effectiveUserID: 501
        )
      )
    ) { error in
      guard case .unsafePayloadPath(let path) = error as? LifecycleServiceError else {
        return XCTFail("expected unsafe payload path, got \(error)")
      }
      XCTAssertTrue(path.hasSuffix("/payload/native/escaped"), path)
    }
  }

  func testInstallPreservesManifestRecordedRelativePayloadSymlink() throws {
    let fixture = try makeFixture()
    let link = fixture.payload.appendingPathComponent("native/worker-link")
    try FileManager.default.createSymbolicLink(
      atPath: link.path,
      withDestinationPath: "worker.txt"
    )
    try write(
      #"{"symlinks":[{"path":"native/worker-link","target":"worker.txt"}]}"#,
      to: fixture.payload.appendingPathComponent("manifest.json")
    )

    _ = try LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    ).execute(
      LifecycleInvocation.parse(
        arguments: ["install", "--role", "all", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )

    let installedLink = relocated(
      root: fixture.root,
      absolutePath: "/Library/Application Support/Orchard/native/worker-link"
    )
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: installedLink.path),
      "worker.txt"
    )
  }

  func testDryRunReportsPendingRecoveryWithoutMutatingIt() throws {
    let fixture = try makeFixture()
    let service = LifecycleService(contract: fixture.contract, payloadRoot: fixture.payload)
    _ = try service.execute(
      LifecycleInvocation.parse(
        arguments: ["install", "--role", "all", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )
    try write(
      "controller-v2", to: fixture.payload.appendingPathComponent("releases/controller.txt"))
    let update = try LifecycleInvocation.parse(
      arguments: ["update", "--role", "controller", "--root", fixture.root.path],
      effectiveUserID: 501
    )
    XCTAssertThrowsError(
      try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload,
        abruptFailurePoint: .afterPayload
      ).execute(update)
    )
    let transaction = relocated(
      root: fixture.root,
      absolutePath: "/Library/Application Support/Orchard/support/.app-transaction"
    )
    let before = try directoryDigest(transaction)

    let result = try service.execute(
      LifecycleInvocation.parse(
        arguments: [
          "update", "--role", "controller", "--root", fixture.root.path, "--dry-run",
        ],
        effectiveUserID: 501
      )
    )

    XCTAssertTrue(result.plan.contains("recover interrupted app transaction"))
    XCTAssertEqual(try directoryDigest(transaction), before)
    XCTAssertEqual(
      try text(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/releases/controller.txt"
      ),
      "controller-v2"
    )
  }

  func testConcurrentMutationIsRejectedByExclusiveLifecycleLock() throws {
    let fixture = try makeFixture()
    let lock = relocated(
      root: fixture.root,
      absolutePath: "/Library/Application Support/Orchard/support/.app-lifecycle.lock"
    )
    try FileManager.default.createDirectory(
      at: lock.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    defer {
      _ = flock(descriptor, LOCK_UN)
      close(descriptor)
    }

    XCTAssertThrowsError(
      try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload
      ).execute(
        LifecycleInvocation.parse(
          arguments: ["install", "--role", "all", "--root", fixture.root.path],
          effectiveUserID: 501
        )
      )
    ) { error in
      XCTAssertEqual(error as? LifecycleServiceError, .lifecycleLocked(lock.path))
    }
  }

  func testLifecycleLockDescriptorIsCloseOnExec() throws {
    let fixture = try makeFixture()
    let service = LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    )
    let lock = try service.acquireLifecycleLock(
      at: LifecyclePaths(root: fixture.root, contract: fixture.contract)
    )
    defer { lock.release() }

    XCTAssertNotEqual(fcntl(lock.descriptor, F_GETFD) & FD_CLOEXEC, 0)
  }

  func testInstallNormalizesModesAndRecordsSystemOwnershipIntent() throws {
    let fixture = try makeFixture()
    _ = try LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    ).execute(
      LifecycleInvocation.parse(
        arguments: ["install", "--role", "all", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )

    let expectedModes: [String: Int] = [
      "/Library/Application Support/Orchard": 0o755,
      "/Library/Application Support/Orchard/config": 0o750,
      "/Library/Application Support/Orchard/config/tls": 0o750,
      "/Library/Application Support/Orchard/logs": 0o755,
      "/Library/Application Support/Orchard/bin/orchardctl": 0o755,
      "/Library/LaunchDaemons/com.orchard.controller.plist": 0o644,
      "/Library/Application Support/Orchard/support/.install-role": 0o644,
      "/Library/Application Support/Orchard/support/.app-install-complete": 0o600,
      "/Library/Application Support/Orchard/support/.app-launchd-state.json": 0o600,
    ]
    for (path, mode) in expectedModes {
      XCTAssertEqual(
        try permissions(
          relocated(root: fixture.root, absolutePath: path)
        ),
        mode,
        path
      )
    }

    let ownershipIntent = try text(
      root: fixture.root,
      absolutePath: "/Library/Application Support/Orchard/support/.app-ownership-intent.json"
    )
    XCTAssertTrue(ownershipIntent.contains("\"owner_id\":0"))
    XCTAssertTrue(ownershipIntent.contains("\"admin_group_id\":80"))
  }

  func testUpdatePreservesOperatorStateAndRestoresOnlyLoadedInRoleServices() throws {
    let fixture = try makeFixture()
    let service = LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    )
    let install = try LifecycleInvocation.parse(
      arguments: ["install", "--role", "all", "--root", fixture.root.path],
      effectiveUserID: 501
    )
    _ = try service.execute(install)

    try write(
      "operator-config",
      to: relocated(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/config/controller.env"
      )
    )
    try write(
      "operator-model",
      to: relocated(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/models/model.bin"
      )
    )
    try write(
      "{\"loaded_services\":[\"com.orchard.controller\",\"com.orchard.node-agent\"]}",
      to: relocated(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/support/.app-launchd-state.json"
      )
    )
    try write(
      "controller-v2", to: fixture.payload.appendingPathComponent("releases/controller.txt"))

    let update = try LifecycleInvocation.parse(
      arguments: ["update", "--role", "controller", "--root", fixture.root.path],
      effectiveUserID: 501
    )
    let result = try service.execute(update)

    XCTAssertEqual(result.status.role, .controller)
    XCTAssertEqual(result.status.loadedServices, ["com.orchard.controller"])
    XCTAssertEqual(
      try text(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/releases/controller.txt"
      ),
      "controller-v2"
    )
    XCTAssertEqual(
      try text(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/config/controller.env"
      ),
      "operator-config"
    )
    XCTAssertEqual(
      try text(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/models/model.bin"
      ),
      "operator-model"
    )
    XCTAssertFalse(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/LaunchDaemons/com.orchard.node-agent.plist"
      ))
  }

  func testReinstallRestoresPreviouslyLoadedInRoleServices() throws {
    let fixture = try makeFixture()
    let service = LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    )
    let install = try LifecycleInvocation.parse(
      arguments: ["install", "--role", "all", "--root", fixture.root.path],
      effectiveUserID: 501
    )
    _ = try service.execute(install)

    try write(
      "{\"loaded_services\":[\"com.orchard.controller\",\"com.orchard.node-agent\"]}",
      to: relocated(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/support/.app-launchd-state.json"
      )
    )

    let reinstall = try LifecycleInvocation.parse(
      arguments: ["install", "--role", "controller", "--root", fixture.root.path],
      effectiveUserID: 501
    )
    let result = try service.execute(reinstall)

    XCTAssertEqual(result.status.role, .controller)
    XCTAssertEqual(result.status.loadedServices, ["com.orchard.controller"])
  }

  func testFailedUpdateRollsBackPayloadRolePlistsAndLoadedServices() throws {
    let fixture = try makeFixture()
    let installService = LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    )
    let install = try LifecycleInvocation.parse(
      arguments: ["install", "--role", "all", "--root", fixture.root.path],
      effectiveUserID: 501
    )
    _ = try installService.execute(install)

    try write(
      "{\"loaded_services\":[\"com.orchard.controller\",\"com.orchard.node-agent\"]}",
      to: relocated(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/support/.app-launchd-state.json"
      )
    )
    try write(
      "controller-v2", to: fixture.payload.appendingPathComponent("releases/controller.txt"))

    let update = try LifecycleInvocation.parse(
      arguments: ["update", "--role", "controller", "--root", fixture.root.path],
      effectiveUserID: 501
    )
    let failingService = LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload,
      failurePoint: .afterPlists
    )

    XCTAssertThrowsError(try failingService.execute(update)) { error in
      XCTAssertEqual(
        error as? LifecycleServiceError,
        .injectedFailure(.afterPlists)
      )
    }

    XCTAssertEqual(
      try text(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/releases/controller.txt"
      ),
      "controller"
    )
    XCTAssertEqual(
      try text(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/support/.install-role"
      ),
      "all\n"
    )
    XCTAssertTrue(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/LaunchDaemons/com.orchard.node-agent.plist"
      ))

    let status = try LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    ).execute(
      LifecycleInvocation.parse(
        arguments: ["status", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )
    XCTAssertEqual(status.status.role, .all)
    XCTAssertEqual(
      status.status.loadedServices,
      ["com.orchard.controller", "com.orchard.node-agent"]
    )
  }

  func testEveryInjectedCommitFailureRollsBack() throws {
    for point in LifecycleFailurePoint.allCases {
      let fixture = try makeFixture()
      _ = try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload
      ).execute(
        LifecycleInvocation.parse(
          arguments: ["install", "--role", "all", "--root", fixture.root.path],
          effectiveUserID: 501
        )
      )
      try write(
        "{\"loaded_services\":[\"com.orchard.controller\",\"com.orchard.node-agent\"]}",
        to: relocated(
          root: fixture.root,
          absolutePath: "/Library/Application Support/Orchard/support/.app-launchd-state.json"
        )
      )
      try write(
        "controller-v2",
        to: fixture.payload.appendingPathComponent("releases/controller.txt")
      )

      let update = try LifecycleInvocation.parse(
        arguments: ["update", "--role", "controller", "--root", fixture.root.path],
        effectiveUserID: 501
      )
      XCTAssertThrowsError(
        try LifecycleService(
          contract: fixture.contract,
          payloadRoot: fixture.payload,
          failurePoint: point
        ).execute(update),
        point.rawValue
      )

      XCTAssertEqual(
        try text(
          root: fixture.root,
          absolutePath: "/Library/Application Support/Orchard/releases/controller.txt"
        ),
        "controller",
        point.rawValue
      )
      let status = try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload
      ).execute(
        LifecycleInvocation.parse(
          arguments: ["status", "--root", fixture.root.path],
          effectiveUserID: 501
        )
      ).status
      XCTAssertEqual(status.role, .all, point.rawValue)
      XCTAssertEqual(
        status.loadedServices,
        ["com.orchard.controller", "com.orchard.node-agent"],
        point.rawValue
      )
    }
  }

  func testNextMutationRecoversTransactionLeftByAbruptTermination() throws {
    let fixture = try makeFixture()
    _ = try LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    ).execute(
      LifecycleInvocation.parse(
        arguments: ["install", "--role", "all", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )
    try write(
      "{\"loaded_services\":[\"com.orchard.controller\",\"com.orchard.node-agent\"]}",
      to: relocated(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/support/.app-launchd-state.json"
      )
    )
    try write(
      "controller-v2", to: fixture.payload.appendingPathComponent("releases/controller.txt"))
    let update = try LifecycleInvocation.parse(
      arguments: ["update", "--role", "controller", "--root", fixture.root.path],
      effectiveUserID: 501
    )

    XCTAssertThrowsError(
      try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload,
        abruptFailurePoint: .afterPayload
      ).execute(update)
    ) { error in
      XCTAssertEqual(
        error as? LifecycleServiceError,
        .simulatedAbruptTermination(.afterPayload)
      )
    }

    let invalidPayload = fixture.payload
      .deletingLastPathComponent()
      .appendingPathComponent("missing-payload")
    XCTAssertThrowsError(
      try LifecycleService(
        contract: fixture.contract,
        payloadRoot: invalidPayload
      ).execute(update)
    ) { error in
      XCTAssertEqual(
        error as? LifecycleServiceError,
        .missingPayloadPath("releases")
      )
    }

    XCTAssertEqual(
      try text(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/releases/controller.txt"
      ),
      "controller"
    )
    XCTAssertFalse(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/support/.app-transaction"
      ))
    let status = try LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    ).execute(
      LifecycleInvocation.parse(
        arguments: ["status", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    ).status
    XCTAssertEqual(status.role, .all)
    XCTAssertEqual(
      status.loadedServices,
      ["com.orchard.controller", "com.orchard.node-agent"]
    )
  }

  func testNextMutationRemovesEmptyPreparingJournalWithoutManifest() throws {
    let fixture = try makeFixture()
    let preparing = relocated(
      root: fixture.root,
      absolutePath:
        "/Library/Application Support/Orchard/support/.app-transaction.preparing"
    )
    try FileManager.default.createDirectory(at: preparing, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: preparing.path
    )

    _ = try LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    ).execute(
      LifecycleInvocation.parse(
        arguments: ["install", "--role", "all", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: preparing.path))
  }

  func testUninstallRemovesServiceArtifactsAndRetainsOperatorState() throws {
    let fixture = try makeFixture()
    let service = LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    )
    _ = try service.execute(
      LifecycleInvocation.parse(
        arguments: ["install", "--role", "all", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )

    let retainedFiles = [
      "/Library/Application Support/Orchard/config/controller.env",
      "/Library/Application Support/Orchard/data/state.db",
      "/Library/Application Support/Orchard/models/model.bin",
      "/Library/Application Support/Orchard/bundles/support.tar",
      "/Library/Application Support/Orchard/logs/controller.log",
      "/Library/Application Support/Orchard/support/operator-note.txt",
    ]
    for path in retainedFiles {
      try write("retain", to: relocated(root: fixture.root, absolutePath: path))
    }

    let result = try service.execute(
      LifecycleInvocation.parse(
        arguments: ["uninstall", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    )

    XCTAssertNil(result.status.role)
    XCTAssertEqual(result.status.loadedServices, [])
    XCTAssertFalse(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/releases/controller.txt"
      ))
    XCTAssertFalse(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/LaunchDaemons/com.orchard.controller.plist"
      ))
    XCTAssertFalse(
      fileExists(
        root: fixture.root,
        absolutePath: "/usr/local/bin/orchardctl"
      ))
    XCTAssertFalse(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/support/.install-role"
      ))
    for path in retainedFiles {
      XCTAssertEqual(
        try text(root: fixture.root, absolutePath: path),
        "retain",
        path
      )
    }
  }

  func testPartialTLSStateFailsBeforeInstallMutation() throws {
    let fixture = try makeFixture()
    try write(
      "partial-ca",
      to: relocated(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/config/tls/ca.crt"
      )
    )
    let install = try LifecycleInvocation.parse(
      arguments: ["install", "--role", "controller", "--root", fixture.root.path],
      effectiveUserID: 501
    )

    XCTAssertThrowsError(
      try LifecycleService(
        contract: fixture.contract,
        payloadRoot: fixture.payload
      ).execute(install)
    ) { error in
      XCTAssertEqual(error as? LifecycleServiceError, .partialTLSState)
    }

    XCTAssertFalse(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/releases/controller.txt"
      ))
    XCTAssertEqual(
      try text(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/config/tls/ca.crt"
      ),
      "partial-ca"
    )
  }

  func testPackageReceiptBlocksMutationAndStatusReportsPackageOwnership() throws {
    let fixture = try makeFixture()
    let receiptPath =
      "\(fixture.contract.sandboxReceiptDirectory)/\(fixture.contract.packageReceipt)"
    try write(
      "installed",
      to: relocated(root: fixture.root, absolutePath: receiptPath)
    )
    let service = LifecycleService(
      contract: fixture.contract,
      payloadRoot: fixture.payload
    )

    let status = try service.execute(
      LifecycleInvocation.parse(
        arguments: ["status", "--root", fixture.root.path],
        effectiveUserID: 501
      )
    ).status

    XCTAssertEqual(status.installationSource, .package)
    XCTAssertEqual(status.blockers, [.packageReceipt("com.orchard.pkg")])
    XCTAssertTrue(
      status.retainedPaths.contains(
        "/Library/Application Support/Orchard/config"
      ))

    for arguments in [
      ["install", "--role", "all", "--root", fixture.root.path],
      ["update", "--role", "controller", "--root", fixture.root.path],
      ["uninstall", "--root", fixture.root.path],
    ] {
      let invocation = try LifecycleInvocation.parse(
        arguments: arguments,
        effectiveUserID: 501
      )
      XCTAssertThrowsError(try service.execute(invocation), arguments[0]) { error in
        XCTAssertEqual(
          error as? LifecycleServiceError,
          .packageReceiptPresent("com.orchard.pkg")
        )
      }
    }
    XCTAssertFalse(
      fileExists(
        root: fixture.root,
        absolutePath: "/Library/Application Support/Orchard/releases/controller.txt"
      ))
  }

  private func makeFixture() throws -> (
    root: URL,
    payload: URL,
    contract: InstallContract
  ) {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("orchard-service-tests-\(UUID().uuidString)")
    let root = base.appendingPathComponent("root")
    let payload = base.appendingPathComponent("payload")
    temporaryDirectories.append(base)

    try FileManager.default.createDirectory(
      at: payload,
      withIntermediateDirectories: true
    )
    try write("controller", to: payload.appendingPathComponent("releases/controller.txt"))
    try write("native", to: payload.appendingPathComponent("native/worker.txt"))
    try write(
      "openssl",
      to: payload.appendingPathComponent("support/openssl/lib/libcrypto.3.dylib")
    )

    for command in [
      "orchard-controller",
      "orchard-managed-postgres",
      "orchard-node-agent",
      "orchardctl",
    ] {
      try write(command, to: payload.appendingPathComponent("share/bin/\(command)"))
    }

    for label in ["com.orchard.controller", "com.orchard.node-agent"] {
      try write(label, to: payload.appendingPathComponent("share/launchd/\(label).plist"))
    }
    try write("{}", to: payload.appendingPathComponent("manifest.json"))

    let contractURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("service-lifecycle.json")
    return (root, payload, try InstallContract.load(from: contractURL))
  }

  private func write(_ value: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(value.utf8).write(to: url)
  }

  private func relocated(root: URL, absolutePath: String) -> URL {
    root.appendingPathComponent(String(absolutePath.dropFirst()))
  }

  private func fileExists(root: URL, absolutePath: String) -> Bool {
    FileManager.default.fileExists(atPath: relocated(root: root, absolutePath: absolutePath).path)
  }

  private func text(root: URL, absolutePath: String) throws -> String {
    try String(contentsOf: relocated(root: root, absolutePath: absolutePath), encoding: .utf8)
  }

  private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(
      (attributes[.posixPermissions] as? NSNumber)?.intValue
    )
  }

  private func directoryDigest(_ root: URL) throws -> [String] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
    else {
      return []
    }
    var entries: [String] = []
    for case let url as URL in enumerator {
      let relative = String(url.path.dropFirst(root.path.count + 1))
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values.isDirectory == true {
        entries.append("directory:\(relative)")
      } else if values.isSymbolicLink == true {
        entries.append(
          "symlink:\(relative):\(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))"
        )
      } else {
        entries.append("file:\(relative):\(try Data(contentsOf: url).base64EncodedString())")
      }
    }
    return entries.sorted()
  }
}
