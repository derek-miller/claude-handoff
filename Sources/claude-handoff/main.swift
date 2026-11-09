import Foundation
import HandoffCore

let a = CommandLine.arguments
if a.count > 2 && a[1] == "__roundtrip" {
    let data = try fs.readFile(a[2])
    if a.count > 3 && a[3] == "lines" {
        var out = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            if let v = try? JSON.parse(String(line)) { out += JSON.text(v) + " " + sha(stable(v)) + "\n" }
        }
        process.stdout(out)
    } else {
        process.stdout(jsonText(try JSON.parse(data)))
    }
    exit(0)
}

exit(runCLI(Array(CommandLine.arguments.dropFirst())))
