// Seed the synthetic sessions through the same Lookback reader and indexer as the app.
import Foundation
import Lookback
import RecorderCore

let reader = ClaudeCodeReader(projectsDirectory: URL(fileURLWithPath: CommandLine.arguments[1]))
let archive = try CodingArchive(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
try archive.addProject("/fixture")
try archive.setEnabled(true)
try archive.synchronize(reader: reader)
