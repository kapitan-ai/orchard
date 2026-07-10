import Darwin
import Foundation

private func emitUsage() {
  let usage = [
    "app": "Orchard",
    "usage": "Orchard service <install|update|uninstall|status> [options]",
  ]
  if let data = try? JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys]) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "service" else {
  emitUsage()
  exit(arguments.isEmpty ? 0 : 64)
}

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let helper =
  executable
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appendingPathComponent("Helpers/orchard-service")

let process = Process()
process.executableURL = helper
process.arguments = Array(arguments.dropFirst())
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

do {
  try process.run()
  process.waitUntilExit()
  exit(process.terminationStatus)
} catch {
  let message = "Orchard could not start its embedded lifecycle helper.\n"
  FileHandle.standardError.write(Data(message.utf8))
  exit(70)
}
