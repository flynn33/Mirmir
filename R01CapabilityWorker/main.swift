import Darwin
import Foundation

do {
    try R01CapabilityWorkerCommand().run(
        arguments: Array(CommandLine.arguments.dropFirst())
    )
} catch {
    FileHandle.standardError.write(Data("R01 capability worker failed.\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}
