import Foundation
import Testing

/// Every text the app shows goes through L() with English as the key (see Localization.swift);
/// these check that the Italian table has each of them, with the same placeholders, and nothing else.
private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func italian() throws -> [String: String] {
    let url = root.appendingPathComponent("Resources/it.lproj/Localizable.strings")
    return try #require(NSDictionary(contentsOf: url) as? [String: String])
}

/// The keys of the L("…") and L("…", context: "…") calls in the app's sources.
private func keysInSources() throws -> Set<String> {
    let folder = root.appendingPathComponent("Sources/LimitBar")
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    let call = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)"(?:\s*,\s*context:\s*"((?:[^"\\]|\\.)*)")?"#)
    var keys: Set<String> = []
    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for match in call.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: source).map { String(source[$0]) }
            }
            guard var key = group(1) else { continue }
            key = key.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: "\\")
            if let context = group(2) { key += " [\(context)]" }
            keys.insert(key)
        }
    }
    return keys
}

/// The kinds of the placeholders, in order once positions ("%2$d") are taken into account.
private func placeholders(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?([@dsf])"#)
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    var sequential = 0
    var byPosition: [Int: String] = [:]
    for match in matches {
        let kind = String(text[Range(match.range(at: 2), in: text)!])
        if let position = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }) {
            byPosition[position] = kind
        } else {
            sequential += 1
            byPosition[sequential] = kind
        }
    }
    return byPosition.keys.sorted().map { byPosition[$0]! }
}

@Test func everyTextHasAnItalianTranslation() throws {
    let table = try italian()
    let missing = try keysInSources().filter { table[$0] == nil }.sorted()
    #expect(missing.isEmpty, "Missing in it.lproj: \(missing)")
}

@Test func translationsKeepTheirPlaceholders() throws {
    for (english, italian) in try italian() {
        let key = english.replacingOccurrences(of: #" \[[^\]]*\]$"#, with: "", options: .regularExpression)
        #expect(placeholders(key) == placeholders(italian), "\(english) → \(italian)")
    }
}

@Test func noTranslationIsLeftOver() throws {
    let used = try keysInSources()
    let unused = try italian().keys.filter { !used.contains($0) }.sorted()
    #expect(unused.isEmpty, "Not used anywhere: \(unused)")
}
