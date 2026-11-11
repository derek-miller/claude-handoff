import AppKit

// menubar-checks <wording|state> <directory>: runs one check program against the spliced App.swift.
@main
struct Checks {
    @MainActor static func main() throws {
        switch CommandLine.arguments[1] {
        case "wording": try WordingChecks.run()
        case "state": StateChecks.run()
        default: fatalError("unknown check \(CommandLine.arguments[1])")
        }
    }
}

// A data file the test wrote into the check directory.
func fixtureData(_ name: String) -> Data {
    try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(name))
}
