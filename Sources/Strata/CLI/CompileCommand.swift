import Foundation
import StrataCore

/// `strata compile <file.kbd>` — validate a config and print diagnostics (exit 1 on errors).
enum CompileCommand {
    static func run(args: [String]) -> Int32 {
        guard let path = args.first, let data = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write("usage: strata compile <file.kbd>\n".data(using: .utf8)!)
            return 2
        }
        let result = ConfigCompiler.compile(text: String(decoding: data, as: UTF8.self))
        let name = (path as NSString).lastPathComponent
        for d in result.diagnostics { print(d.description(filename: name)) }
        if let k = result.keymap, !result.hasErrors {
            print("ok: \(k.layers.count) layers (\(k.layers.map(\.name).joined(separator: ", "))), \(k.source.count) source keys, \(result.warnings.count) warnings")
            return 0
        }
        return 1
    }
}
