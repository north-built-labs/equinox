import Foundation

/// Routes to the SwiftUI app or to a diagnostics mode.
/// `--self-test [output-file]` measures the live audio path; `--snapshots <dir>` renders UI screens to PNG;
/// `--update-dry-run <zip> <sig> <version> <log>` exercises the real updater against local files.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--self-test") {
            let output = i + 1 < args.count
                ? URL(fileURLWithPath: args[i + 1])
                : FileManager.default.temporaryDirectory.appendingPathComponent("equinox-selftest.txt")
            SelfTest.launch(output: output)
        } else if let i = args.firstIndex(of: "--update-dry-run"), i + 4 < args.count {
            UpdateDryRun.run(zip: args[i + 1], sig: args[i + 2], version: args[i + 3], log: args[i + 4])
        } else if let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count {
            Snapshots.render(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
        } else {
            EquinoxApp.main()
        }
    }
}
