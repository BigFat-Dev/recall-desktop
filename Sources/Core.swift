// Copyright (C) 2026 BigFat-Dev
// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit

struct RecallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
enum ReturnProgress: String, CaseIterable {
    case preparing = "正在确认原消息…"
    case opening = "正在打开原对话…"
    case locating = "正在定位消息…"
    case verifying = "正在核验消息…"
    case highlighting = "正在显示原消息…"
}
struct ReturnIssue: Identifiable {
    let id = UUID()
    let summary: String
    let recovery: String
    let details: String
    var offersSettings = false
    init(_ details: String) {
        self.details = details
        if details.contains("未获得系统辅助功能权限") {
            summary = "需要系统权限才能返回消息。"
            recovery = "打开 Recall 设置检查权限，并在系统设置中允许当前应用。"
            offersSettings = true
        } else if details.contains("剪贴板") {
            summary = "暂时无法安全保留剪贴板内容。"
            recovery = "为避免覆盖，本次操作已停止。若面板出现“剪贴板恢复”，请选择恢复或保留当前内容；否则请先妥善保存已复制的内容再重试。"
        } else if details.contains("Codex 未运行") || details.contains("官方 Codex") || details.contains("Codex CLI") {
            summary = "暂时无法连接 Codex。"
            recovery = "请确认官方 Codex 已安装并打开，只运行一个安装副本。组件缺失时更新或重新安装宿主；具体原因见详情。"
        } else if details.contains("作者或内容已改变") {
            summary = "原消息已被修改，无法确认保存时的位置。"
            recovery = "请查看原对话。如需保留修改后的消息，请重新标记。"
        } else if details.contains("原消息已不存在") || details.contains("原消息不存在") {
            summary = "无法确认原消息仍然存在。"
            recovery = "请检查原对话是否仍可访问，以及消息是否已删除。标记仍保留。"
        } else if ["多个位置", "重复", "其他消息", "同文位置"].contains(where: details.contains) {
            summary = "存在重复或无法区分的位置，无法安全返回。"
            recovery = "已停止定位。请查看原对话，确认消息内容；不会自动选择相似结果。"
        } else if ["发生切换", "已改变", "已取消", "已被替代", "导航目标"].contains(where: details.contains) {
            summary = "对话或操作焦点发生变化，返回已停止。"
            recovery = "重新点击标记后，请等待定位完成，期间保持 Codex 在前台。"
        } else if ["超时", "超过时限", "历史过长", "历史连接", "历史接口"].contains(where: details.contains) {
            summary = "未能完成原消息的历史核验。"
            recovery = "请等待 Codex 加载完成后重试。若持续失败，可展开详情查看原因。"
        } else {
            summary = "未能确认原消息的完整位置。"
            recovery = "请等待 Codex 加载完成后重试，并保持其在前台。若仍失败，可展开详情查看原因。"
        }
    }
}
struct NewlineFramer {
    private var buffer = Data()
    private var scanned = 0
    private let limit: Int
    private(set) var inspectedBytes = 0
    init(limit: Int = 16_000_000) { self.limit = limit }
    mutating func append(_ bytes: Data) throws -> [Data] {
        guard buffer.count + bytes.count <= limit else {
            buffer.removeAll(keepingCapacity: false); scanned = 0
            throw RecallFailure(message: "历史响应超过读取上限，停止核验。")
        }
        buffer.append(bytes)
        var lines = [Data](), consumed = 0
        var search = buffer.index(buffer.startIndex, offsetBy: scanned)
        while search < buffer.endIndex {
            guard let newline = buffer[search...].firstIndex(of: 10) else {
                inspectedBytes += buffer.distance(from: search, to: buffer.endIndex)
                break
            }
            inspectedBytes += buffer.distance(from: search, to: newline) + 1
            let start = buffer.index(buffer.startIndex, offsetBy: consumed)
            lines.append(Data(buffer[start..<newline]))
            search = buffer.index(after: newline)
            consumed = buffer.distance(from: buffer.startIndex, to: search)
        }
        scanned = buffer.count - consumed
        if consumed > 0 { buffer.removeFirst(consumed) }
        return lines
    }
}
enum ReturnStage: String, Codable {
    case prepare, historyFirst, identityFirst, openConversation, nativeFind, optionalCounter
    case closeFind, bodyFirst, historySecond, identitySecond, bodyFinal, highlight
}
struct ReturnStageTiming: Codable {
    var seconds: Double = 0
    var axCalls = 0
    var axSeconds: Double = 0
    var axCannotComplete = 0
    var longestAXSeconds: Double = 0
}
struct ReturnPerformanceReport: Codable {
    let formatVersion: Int
    let completed: Bool
    let elapsedSeconds: Double
    let stages: [String: ReturnStageTiming]
    var proof: ReturnProofWork?
}
struct ReturnProofWork: Codable {
    var projectionUnitVersion = 2
    var pages = 0
    var records = 0
    var cacheHits = 0
    var computedProjections = 0
    var pageWaitSeconds = 0.0
    var preparationSeconds = 0.0
    var matchSeconds = 0.0
    var cacheWriteSeconds = 0.0
}
// Numeric-only, latest-operation diagnostics. No body, query, title, note,
// message id, path, digest or error string is accepted by this type.
final class ReturnPerformance {
    private let clock: () -> Double
    private let started: Double
    private var checkpoint: Double
    private var stage: ReturnStage = .prepare
    private var stages = [String: ReturnStageTiming]()
    private var proof: ReturnProofWork?
    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock; started = clock(); checkpoint = started
    }
    func transition(_ next: ReturnStage) {
        let now = clock()
        stages[stage.rawValue, default: ReturnStageTiming()].seconds += max(0, now - checkpoint)
        checkpoint = now; stage = next
    }
    func recordAX(seconds: Double, cannotComplete: Bool) {
        stages[stage.rawValue, default: ReturnStageTiming()].axCalls += 1
        stages[stage.rawValue, default: ReturnStageTiming()].axSeconds += seconds
        stages[stage.rawValue, default: ReturnStageTiming()].longestAXSeconds = max(stages[stage.rawValue]?.longestAXSeconds ?? 0, seconds)
        if cannotComplete { stages[stage.rawValue, default: ReturnStageTiming()].axCannotComplete += 1 }
    }
    func recordProof(_ work: ReturnProofWork) { proof = work }
    func finish(completed: Bool) -> ReturnPerformanceReport {
        transition(stage)
        return ReturnPerformanceReport(formatVersion: 1, completed: completed, elapsedSeconds: max(0, clock() - started), stages: stages, proof: proof)
    }
    static func save(_ report: ReturnPerformanceReport, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("last-return-performance.json")
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
func normalized(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
func locatorPresent(_ phrase: String, in text: String) -> Bool {
    // Fast Foundation rejection avoids constructing Swift grapheme indices for
    // every nonmatch. Positives retain the original Swift/Foundation check.
    guard (text as NSString).range(of: phrase, options: .caseInsensitive).location != NSNotFound else { return false }
    return text.range(of: phrase, options: .caseInsensitive) != nil
}
func digest(_ text: String) -> String { SHA256.hash(data: Data(normalized(text).utf8)).map { String(format: "%02x", $0) }.joined() }
func plainMarkdown(_ text: String) -> String {
    if let rich = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) {
        // Foundation omits separators between block runs. Restore boundaries so
        // headings, paragraphs and list items match the rendered message.
        var result = "", lastBlock: Int?
        for run in rich.runs {
            let block = run.presentationIntent?.components.first?.identity
            if !result.isEmpty, let block, let lastBlock, block != lastBlock { result += "\n" }
            result += String(rich[run.range].characters)
            if let block { lastBlock = block }
        }
        return result
    }
    return text
}
func occurrenceCount(_ phrase: String, in text: String) -> Int {
    let body = normalized(text), needle = normalized(phrase)
    guard !needle.isEmpty else { return 0 }
    var count = 0, start = body.startIndex
    while start < body.endIndex, let range = body.range(of: needle, options: .caseInsensitive, range: start..<body.endIndex) {
        count += 1
        // Count overlaps as ambiguous too; no host-search behavior is assumed.
        start = body.index(after: range.lowerBound)
    }
    return count
}
// A message must consume whole consecutive accessibility text nodes. Allow
// layout whitespace only at node boundaries; never accept a substring of a
// larger node, missing paragraphs, or text skipped inside the body.
func fullBodyRanges(in texts: [String], expected: String) -> [Range<Int>] {
    let target = normalized(expected)
    let atoms = texts.map(normalized)
    guard !target.isEmpty else { return [] }
    var matches = [Range<Int>]()
    for start in atoms.indices {
        var cursor = target.startIndex
        for end in start..<atoms.count {
            let atom = atoms[end]
            guard !atom.isEmpty else { break }
            if end > start, cursor < target.endIndex, target[cursor] == " " { cursor = target.index(after: cursor) }
            guard target[cursor...].hasPrefix(atom), let next = target.index(cursor, offsetBy: atom.count, limitedBy: target.endIndex) else { break }
            cursor = next
            if cursor == target.endIndex { matches.append(start..<(end + 1)); break }
        }
    }
    return matches
}
func canonicalThreadLink(_ raw: String) throws -> (URL, String) {
    guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          parts.scheme == "codex", parts.host == "threads", parts.query == nil, parts.fragment == nil,
          !parts.path.contains("%"), let id = parts.path.split(separator: "/").first,
          parts.path.split(separator: "/").count == 1, UUID(uuidString: String(id)) != nil,
          let url = URL(string: "codex://threads/\(id)") else {
        throw RecallFailure(message: "宿主没有返回受支持的本地对话深链接。已停止，不按标题猜对话。")
    }
    return (url, String(id))
}
struct NativeAnchor: Codable, Equatable {
    let version: Int
    let kind: String
    let conversationLink: String
    let conversationID: String
    let turnID: String
    let itemID: String
    let role: String
    let searchPhrase: String
    let bodySHA256: String
    let axIdentifier: String?
    let precision: String
    var isDemo: Bool { kind == "native-fixture" }
}
struct Mark: Codable, Identifiable, Equatable {
    let id: UUID
    let sourceApp: String
    let conversationTitle: String
    let fullText: String
    let renderedText: String
    let excerpt: String
    var note: String
    let savedAt: Date
    var updatedAt: Date
    let anchor: NativeAnchor
    func validate() throws {
        guard !normalized(fullText).isEmpty, fullText.utf8.count <= 1_000_000,
              anchor.version == 2, !anchor.turnID.isEmpty, !anchor.itemID.isEmpty,
              ["user", "assistant"].contains(anchor.role), !conversationTitle.isEmpty, note.count <= 4000,
              !normalized(anchor.searchPhrase).isEmpty, digest(renderedText) == anchor.bodySHA256,
              excerpt == String(normalized(renderedText).prefix(160)) else {
            throw RecallFailure(message: "标记数据或定位校验异常。未覆盖原文件。")
        }
        if !anchor.isDemo {
            let (_, id) = try canonicalThreadLink(anchor.conversationLink)
            guard id == anchor.conversationID, anchor.kind == "native-deep-link+verified-find+full-body" else { throw RecallFailure(message: "对话身份校验失败。") }
        }
    }
}
struct Capture {
    let title: String
    let fullText: String
    let renderedText: String
    let anchor: NativeAnchor
    func makeMark(note: String) throws -> Mark {
        let now = Date()
        let mark = Mark(id: UUID(), sourceApp: anchor.isDemo ? "桌面测试窗口（虚构）" : "Codex 桌面应用", conversationTitle: title, fullText: fullText, renderedText: renderedText, excerpt: String(normalized(renderedText).prefix(160)), note: note, savedAt: now, updatedAt: now, anchor: anchor)
        try mark.validate()
        return mark
    }
}
func phraseCandidates(_ text: String) -> [String] {
    let lines = text.split(whereSeparator: { $0.isNewline }).map { normalized(String($0)) }.filter { !$0.isEmpty }
    var result = [String]()
    for line in lines.sorted(by: { $0.count > $1.count }) {
        let chars = Array(line)
        for length in [100, 70, 40] {
            guard chars.count >= min(length, 12) else { continue }
            let actual = min(length, chars.count)
            for start in [0, max(0, (chars.count - actual) / 2), max(0, chars.count - actual)] {
                let phrase = String(chars[start..<(start + actual)])
                if !result.contains(phrase) { result.append(phrase) }
            }
        }
    }
    if result.isEmpty && !normalized(text).isEmpty { result = [normalized(text)] }
    return Array(result.prefix(9))
}
func parseUniqueCounter(_ text: String) -> Bool? {
    let patterns = [#"^\s*([0-9]+)\s*/\s*([0-9]+)\s*$"#, #"^\s*([0-9]+)\s+of\s+([0-9]+)\s*$"#, #"^\s*第?\s*([0-9]+)\s*(?:个|项)?\s*[,，/]?\s*共\s*([0-9]+)\s*(?:个|项)?\s*$"#]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let first = Range(match.range(at: 1), in: text), let second = Range(match.range(at: 2), in: text),
              let current = Int(text[first]), let total = Int(text[second]) else { continue }
        return current == 1 && total == 1
    }
    return nil
}
func parseCounterFragments(_ fragments: [String]) -> [Bool] {
    var evidence = [Bool]()
    for start in fragments.indices {
        for end in start..<min(fragments.count, start + 5) {
            if let parsed = parseUniqueCounter(fragments[start...end].joined(separator: " ")) {
                evidence.append(parsed); break
            }
        }
    }
    return evidence
}
func isCounterFragment(_ text: String) -> Bool {
    let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty, candidate.count <= 48 else { return false }
    return candidate.range(of: #"^(?:[0-9\s/第共个项,，]|of)+$"#, options: [.regularExpression, .caseInsensitive]) != nil
}
struct DiskArchive: Codable { let version: Int; let marks: [Mark] }
struct PreparedBackup: Sendable {
    let data: Data
    let count: Int
    static func read(_ url: URL) throws -> PreparedBackup {
        let data = try Data(contentsOf: url, options: .uncached)
        return PreparedBackup(data: data, count: try MarkRepository.decode(data).count)
    }
}
final class MarkRepository {
    let url: URL
    private var signature: Data?
    init(directory: URL) { url = directory.appendingPathComponent("bookmarks.json") }
    static func decode(_ data: Data) throws -> [Mark] {
        let archive = try JSONDecoder().decode(DiskArchive.self, from: data)
        guard archive.version == 2, Set(archive.marks.map(\.id)).count == archive.marks.count else { throw RecallFailure(message: "本地存储版本或记录 ID 异常；原文件保留。") }
        for mark in archive.marks { try mark.validate() }
        return archive.marks
    }
    static func encode(_ marks: [Mark]) throws -> Data {
        for mark in marks { try mark.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(DiskArchive(version: 2, marks: marks))
    }
    func diskData() throws -> Data? {
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    func load() throws -> [Mark] {
        guard FileManager.default.fileExists(atPath: url.path) else { signature = nil; return [] }
        let data = try Data(contentsOf: url)
        let marks = try Self.decode(data)
        signature = data
        return marks
    }
    func save(_ marks: [Mark]) throws {
        try write(marks, expected: signature)
    }
    var backupsDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("backups") }
    @discardableResult func restore(_ data: Data, expected: Data?) throws -> [Mark] {
        let marks = try Self.decode(data)
        try write(marks, expected: expected)
        return marks
    }
    private func write(_ marks: [Mark], expected: Data?) throws {
        let data = try Self.encode(marks)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = dir.appendingPathComponent(".write-lock")
        do { try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false) }
        catch { throw RecallFailure(message: "另一个实例正在写入，或遗留了写入锁。未覆盖文件。") }
        defer { try? FileManager.default.removeItem(at: lock) }
        let current = try diskData()
        guard current == expected else { throw RecallFailure(message: "数据已被其他实例修改。请重新读取。") }
        if let current, current != data {
            try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let timestamp = DateFormatter(); timestamp.locale = Locale(identifier: "en_US_POSIX"); timestamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let backup = backupsDirectory.appendingPathComponent("before-change-\(timestamp.string(from: Date()))-\(UUID().uuidString).json")
            try current.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        signature = data
        // Keep the newest twenty automatic snapshots, only after a successful write.
        if let backups = try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let ordered = backups.filter { $0.lastPathComponent.hasPrefix("before-change-") && $0.pathExtension == "json" }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for old in ordered.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
        }
    }
}

enum LocalDataLocation {
    static var standardDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Recall Desktop", isDirectory: true)
    }
    static var activeDirectory: URL {
        ProcessInfo.processInfo.environment["RECALL_DESKTOP_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? standardDirectory
    }
    static func resolve(legacyDirectory: URL, destination: URL = standardDirectory, override: URL? = nil) throws -> URL {
        if let override { return override }
        let target = MarkRepository(directory: destination)
        if FileManager.default.fileExists(atPath: target.url.path) { return destination }
        let legacy = MarkRepository(directory: legacyDirectory)
        guard FileManager.default.fileExists(atPath: legacy.url.path) else { return destination }
        let marks = try legacy.load()
        // Repository's existing lock and expected revision protect concurrent migration.
        _ = try target.load()
        guard !FileManager.default.fileExists(atPath: target.url.path) else { return destination }
        try target.save(marks)
        guard try target.load() == marks else { throw RecallFailure(message: "数据迁移核验失败，旧数据仍保留。") }
        return destination
    }
}

enum CaptureProgress: String, CaseIterable {
    case locating = "正在读取指针下的消息…"
    case reading = "正在读取对话历史…"
    case verifying = "正在核验整条消息…"
    case preparing = "正在准备备注框…"
}

enum ShortcutAvailability {
    static func message(mark: Bool, panel: Bool) -> String? {
        let unavailable = [(mark, "保存快捷键 ⌘⇧M"), (panel, "面板快捷键 ⌃⌥B")].filter { !$0.0 }.map { $0.1 }
        return unavailable.isEmpty ? nil : unavailable.joined(separator: "、") + " 当前不可用，可能被其他程序占用。处理冲突后可重新检查。"
    }
}
