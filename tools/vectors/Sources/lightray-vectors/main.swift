import Foundation
import LightrayVectors

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let defaultDocs = packageRoot.appendingPathComponent("../../docs").standardizedFileURL
let defaultJSON = packageRoot.appendingPathComponent("vectors.json")

let usage = """
    usage: lightray-vectors <command>

      generate [file]     write vectors.json (default: tools/vectors/vectors.json)
      check [docs]        verify every marked block, every link and vectors.json (default: docs/)
      update [docs]       rewrite marked blocks from their vectors and write vectors.json
      print <name>        print one vector as the documents show it
      list                list the vector names
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let example = Example()
let blocks = Catalog.blocks(example)
let blockMap = Dictionary(uniqueKeysWithValues: blocks.map { ($0.name, $0.text) })
let json = Catalog.json(example).rendered() + "\n"

switch arguments.first {
case "generate":
    let target = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) : defaultJSON
    try json.write(to: target, atomically: true, encoding: .utf8)
    print("wrote \(target.path)")

case "check", "update":
    let update = arguments[0] == "update"
    let docs = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) : defaultDocs
    let report = try Docs.process(directory: docs, blocks: blockMap, update: update)
    var issues = report.issues.map(\.description)
    if update {
        try json.write(to: defaultJSON, atomically: true, encoding: .utf8)
        for file in report.filesUpdated { print("updated \(file)") }
    } else if (try? String(contentsOf: defaultJSON, encoding: .utf8)) != json {
        issues.append("vectors.json is out of date: run `lightray-vectors update`")
    }
    for name in blocks.map(\.name) where !report.namesUsed.contains(name) {
        print("note: vector \(name) is not shown in the documents")
    }
    for issue in issues { print(issue) }
    print("\(report.blocksChecked) blocks checked, \(issues.count) problems")
    if !issues.isEmpty { exit(1) }

case "print":
    guard arguments.count > 1, let text = blockMap[arguments[1]] else { fail(usage) }
    print(text)

case "list":
    for block in blocks { print(block.name) }

default:
    fail(usage)
}
