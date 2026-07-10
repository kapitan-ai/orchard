import Foundation

public struct InstallContract: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let supportRoot: String
  public let launchDaemonDirectory: String
  public let packageReceipt: String
  public let sandboxReceiptDirectory: String
  public let roles: [String: [String]]
  public let commandLinks: [String: String]
  public let appOwnedDirectories: [String]
  public let retainedDirectories: [String]
  public let appOwnedSupportEntries: [String]

  public static func load(from url: URL) throws -> InstallContract {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(InstallContract.self, from: Data(contentsOf: url))
  }
}
