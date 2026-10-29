import Foundation
import SyncCore

let args = Array(CommandLine.arguments.dropFirst())
let configURL = ConfigLoader.defaultURL()

func printUsage() {
    print("""
    usage: nas-sync <command>

      validate [path]        check the config file
    """)
}

switch args.first {
case "validate":
    let url = args.count > 1 ? URL(filePath: args[1]) : configURL
    let result = ConfigLoader.load(from: url)
    for issue in result.issues {
        print("\(issue.severity.rawValue): \(issue)")
    }
    if result.isValid {
        print("Config OK.")
    }
    exit(result.isValid ? 0 : 1)
default:
    printUsage()
    exit(args.isEmpty ? 0 : 1)
}
