// Copyright (C) 2026 BigFat-Dev
// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import AppKit

enum HostExecutable {
    static let bundleID = "com.openai.codex"
    static let component = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    // An explicit developer override is never silently replaced by another CLI.
    static func resolve(override: String?, runningBundles: [URL], installedBundle: URL?,
                        identity: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
                        executable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) throws -> URL {
        if let override {
            guard override.hasPrefix("/"), executable(override) else {
                throw RecallFailure(message: "指定的官方 Codex CLI 路径不可执行，请修正 RECALL_CODEX_PATH 后重启 Recall。")
            }
            return URL(fileURLWithPath: override)
        }
        // The running host wins. Never read history through a different installed
        // copy when its component is missing or incompatible.
        let candidates = runningBundles.isEmpty ? installedBundle.map { [$0] } ?? [] : runningBundles
        let unique = Set(candidates.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        guard unique.count == 1, let host = unique.first, identity(host) == bundleID else {
            throw RecallFailure(message: "找不到唯一的官方 Codex 桌面应用，请退出多余副本并启动要使用的 Codex，再重试。")
        }
        let cli = host.appendingPathComponent(component)
        guard executable(cli.path) else {
            throw RecallFailure(message: "已找到 Codex，但找不到官方 Codex CLI 组件。请更新或重新安装官方桌面应用，再重启 Recall；未使用其他应用的组件。")
        }
        return cli
    }
    @MainActor static func current() throws -> URL {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard running.allSatisfy({ $0.bundleURL != nil }) else {
            throw RecallFailure(message: "无法读取运行中 Codex 的安装位置，请重启官方桌面应用。")
        }
        return try resolve(override: ProcessInfo.processInfo.environment["RECALL_CODEX_PATH"],
                    runningBundles: running.compactMap(\.bundleURL),
                    installedBundle: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))
    }
}

struct RawStoredMessage: Sendable {
    let turnID: String
    let itemID: String
    let role: String
    let text: String
}
private struct ProjectionInput: Sendable {
    let texts: [String]
    let isMessage: Bool
    func fingerprint() -> Data {
        if isMessage, texts.count == 1 { return Data(SHA256.hash(data: Data(texts[0].utf8))) }
        // The proof is OR over all these strings. Sort fixed-length digests so
        // dictionary traversal order cannot invalidate the record-level cache.
        // publicItemStrings also includes ordered multipart joins; changing an
        // array order therefore still changes this fingerprint when relevant.
        let parts = texts.map { Data(SHA256.hash(data: Data($0.utf8))) }.sorted { $0.lexicographicallyPrecedes($1) }
        var hash = SHA256()
        hash.update(data: Data("record-text-or-v2".utf8))
        var count = UInt64(parts.count).bigEndian
        withUnsafeBytes(of: &count) { hash.update(data: Data($0)) }
        for part in parts { hash.update(data: part) }
        return Data(hash.finalize())
    }
}
final class BoundedMatchCache<Key: Hashable> {
    private var values = [Key: Bool]()
    private var slots = [Key]()
    private var nextVictim = 0
    private let capacity: Int
    init(capacity: Int) { self.capacity = max(1, capacity) }
    func value(for key: Key) -> Bool? { values[key] }
    func insert(_ value: Bool, for key: Key) {
        if values[key] == nil {
            if slots.count < capacity { slots.append(key) }
            else {
                values.removeValue(forKey: slots[nextVictim])
                slots[nextVictim] = key
                nextVictim = (nextVictim + 1) % capacity
            }
        }
        values[key] = value
    }
}
private struct ProjectionKey: Hashable, Sendable {
    let query: Data
    let source: Data
    let isMessage: Bool
}
private struct LocatorQuery: Sendable {
    let phrase: String
    let bodies: [String]
    let key: Data
    init(_ mark: Mark) throws {
        phrase = normalized(mark.anchor.searchPhrase)
        bodies = [normalized(mark.fullText), normalized(mark.renderedText)].filter { !$0.isEmpty }
        key = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: ["projection-record-v2", phrase, mark.fullText, mark.renderedText])))
    }
    func matches(_ input: ProjectionInput) throws -> Bool {
        for text in input.texts {
            try Task.checkCancellation()
            let raw = normalized(text)
            if input.isMessage {
                if locatorPresent(phrase, in: raw) { return true }
                if locatorPresent(phrase, in: normalized(plainMarkdown(text))) { return true }
            } else {
                if bodies.contains(where: { raw.contains($0) }) { return true }
                let rendered = normalized(plainMarkdown(text))
                if bodies.contains(where: { rendered.contains($0) }) { return true }
            }
        }
        return false
    }
}

struct PreparedText {
    let rendered: String
    let normalizedSource: String
    let normalizedRendered: String
    init(_ source: String) {
        rendered = plainMarkdown(source)
        normalizedSource = normalized(source); normalizedRendered = normalized(rendered)
    }
}
struct StoredMessage: Equatable {
    let turnID: String
    let itemID: String
    let role: String
    let text: String
    let rendered: String
    let normalizedText: String
    let normalizedRendered: String
    init(turnID: String, itemID: String, role: String, text: String, prepared: PreparedText? = nil) {
        self.turnID = turnID; self.itemID = itemID; self.role = role; self.text = text
        let prepared = prepared ?? PreparedText(text)
        rendered = prepared.rendered
        normalizedText = prepared.normalizedSource; normalizedRendered = prepared.normalizedRendered
    }
}
enum HistoryCoverage: Equatable { case wholeConversation, singleTurn(String) }
struct StoredConversation {
    let id: String
    let title: String
    let messages: [StoredMessage]
    let otherItemTexts: [String]
    let otherSearchTexts: [String]
    let coverage: HistoryCoverage
    init(id: String, title: String, messages: [StoredMessage], otherItemTexts: [String] = [], otherSearchTexts: [String]? = nil, coverage: HistoryCoverage = .wholeConversation) {
        self.id = id; self.title = title; self.messages = messages; self.otherItemTexts = otherItemTexts
        self.otherSearchTexts = otherSearchTexts ?? otherItemTexts.flatMap { [normalized($0), normalized(plainMarkdown($0))] }
        self.coverage = coverage
    }
}

// Cache transformations only, keyed by the exact fresh source bytes. Never use
// a cached history snapshot to establish identity, existence or uniqueness.
final class TextRenderingCache {
    private var values = [Data: (prepared: PreparedText, cost: Int)]()
    private var order = [Data](), cost = 0
    private let byteLimit: Int, entryLimit: Int
    private(set) var renderCount = 0
    init(byteLimit: Int = 8 * 1024 * 1024, entryLimit: Int = 2048) { self.byteLimit = byteLimit; self.entryLimit = entryLimit }
    func rendered(_ source: String) -> String { prepared(source).rendered }
    func prepared(_ source: String) -> PreparedText {
        let key = Data(source.utf8)
        if let value = values[key] { return value.prepared }
        let result = PreparedText(source); renderCount += 1
        let size = key.count + result.rendered.utf8.count + result.normalizedSource.utf8.count + result.normalizedRendered.utf8.count
        guard size <= byteLimit, entryLimit > 0 else { return result }
        while cost + size > byteLimit || values.count >= entryLimit {
            guard !order.isEmpty else { break }
            if let removed = values.removeValue(forKey: order.removeFirst()) { cost -= removed.cost }
        }
        values[key] = (result, size); order.append(key); cost += size
        return result
    }
}

// Only documented read methods, over the official local stdio transport.
// No account methods, model calls, direct database access, transcript reads or HTTP.
// Response buffers and continuation ownership are protected by `lock`.
final class ReadOnlyRPC: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var framing = NewlineFramer()
    private var pending = [Int: CheckedContinuation<[String: Any], Error>]()
    private var sequence = 0
    private var started = false
    var isAvailable: Bool { lock.lock(); defer { lock.unlock() }; return started }
    private let allowed: Set<String> = ["initialize", "thread/read", "thread/items/list"]

    func start() async throws {
        process.executableURL = try await HostExecutable.current()
        process.arguments = ["-c", "analytics.enabled=false", "app-server", "--stdio"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { self?.failAll("公开本地历史接口已关闭或无法启动。没有修改对话；消息身份尚未核验。") }
            else { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in self?.failAll("公开本地历史接口启动失败或退出。未读取认证凭证，也没有改用私有数据库。") }
        try process.run(); lock.withLock { started = true }
        let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        _ = try await call("initialize", params: ["clientInfo": ["name": "recall_desktop_readonly", "title": "Recall Desktop", "version": clientVersion], "capabilities": ["experimentalApi": true]])
        try notify("initialized")
    }
    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
    func call(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard allowed.contains(method) else { throw RecallFailure(message: "客户端拒绝非只读接口。") }
        let id = lock.withLock { sequence += 1; return sequence }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !Task.isCancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            guard started else { lock.unlock(); continuation.resume(throwing: RecallFailure(message: "公开本地历史连接已关闭，请重试。未使用旧历史替代核验。")); return }
            pending[id] = continuation
            do {
                let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
                try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
                lock.unlock()
            } catch {
                pending.removeValue(forKey: id); lock.unlock(); continuation.resume(throwing: error); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let waiter = self.pending.removeValue(forKey: id); self.lock.unlock()
                waiter?.resume(throwing: RecallFailure(message: "公开本地历史接口超时。没有确认原消息，操作已停止。"))
            }
            }
            try Task.checkCancellation()
            return result
        }, onCancel: {
            self.lock.lock(); let waiter = self.pending.removeValue(forKey: id); self.lock.unlock()
            waiter?.resume(throwing: CancellationError())
        })
    }
    private func notify(_ method: String) throws {
        guard method == "initialized" else { throw RecallFailure(message: "拒绝未知通知。") }
        let data = try JSONSerialization.data(withJSONObject: ["method": method])
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
    }
    private func receive(_ data: Data) {
        lock.lock()
        let lines: [Data]
        do { lines = try framing.append(data) }
        catch { lock.unlock(); failAll("历史响应超过读取上限，停止核验。"); return }
        lock.unlock()
        for line in lines {
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = value["id"] as? Int else { continue }
            lock.lock(); let waiter = pending.removeValue(forKey: id); lock.unlock()
            if let error = value["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "未知错误"
                waiter?.resume(throwing: RecallFailure(message: "公开历史接口拒绝读取：\(message.prefix(500))"))
            } else { waiter?.resume(returning: value["result"] as? [String: Any] ?? [:]) }
        }
    }
    private func failAll(_ reason: String) {
        lock.lock(); started = false; let waiters = Array(pending.values); pending.removeAll(); lock.unlock()
        for waiter in waiters { waiter.resume(throwing: RecallFailure(message: reason)) }
    }
}

actor HistoryReader {
    private var client: ReadOnlyRPC?
    private let rendering = TextRenderingCache()
    // Only cryptographic source/query keys and boolean query results; no old
    // history rows. Every proof still fetches every fresh public history page.
    private let projections: BoundedMatchCache<ProjectionKey>
    init(projectionLimit: Int = 16_384) { projections = BoundedMatchCache(capacity: projectionLimit) }
    private func connection() async throws -> ReadOnlyRPC {
        if let existing = client, existing.isAvailable { return existing }
        let fresh = ReadOnlyRPC(); try await fresh.start(); client = fresh; return fresh
    }
    func read(_ threadID: String) async throws -> StoredConversation {
        try await load(threadID, turnID: nil, itemID: nil)
    }
    func readIdentity(_ threadID: String, turnID: String, itemID: String) async throws -> StoredConversation {
        guard !turnID.isEmpty, !itemID.isEmpty else { throw RecallFailure(message: "原消息标识缺失，停止身份预检。") }
        return try await load(threadID, turnID: turnID, itemID: itemID)
    }
    private func load(_ threadID: String, turnID: String?, itemID: String?) async throws -> StoredConversation {
        try Task.checkCancellation()
        let rpc = try await connection()
        do { return try await read(threadID, turnID: turnID, itemID: itemID, using: rpc) }
        catch { if client === rpc { client = nil }; throw error }
    }
    func verifyForReturn(_ mark: Mark) async throws -> ReturnProofWork {
        try Task.checkCancellation()
        try mark.validate()
        let rpc = try await connection()
        do { return try await verifyForReturn(mark, using: rpc) }
        catch { if client === rpc { client = nil }; throw error }
    }
    private func verifyForReturn(_ mark: Mark, using rpc: ReadOnlyRPC) async throws -> ReturnProofWork {
        let firstWait = ProcessInfo.processInfo.systemUptime
        let response = try await rpc.call("thread/read", params: ["threadId": mark.anchor.conversationID])
        let metadataWait = ProcessInfo.processInfo.systemUptime - firstWait
        guard let thread = response["thread"] as? [String: Any], thread["id"] as? String == mark.anchor.conversationID,
              let title = thread["name"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecallFailure(message: "公开接口没有确认原对话身份和标题。") }
        let query = try LocatorQuery(mark)
        var seenCursors = Set<String>(), seenMessages = Set<String>()
        var originalCount = 0, locatorCount = 0, work = ReturnProofWork()
        let deadline = Date().addingTimeInterval(60)
        var params: [String: Any] = ["threadId": mark.anchor.conversationID, "limit": 100, "sortDirection": "asc"]
        let pageWaitStarted = ProcessInfo.processInfo.systemUptime
        var page = try await rpc.call("thread/items/list", params: params)
        work.pageWaitSeconds += metadataWait + ProcessInfo.processInfo.systemUptime - pageWaitStarted
        for _ in 0..<100 {
            let preparationStarted = ProcessInfo.processInfo.systemUptime
            try Task.checkCancellation()
            guard Date() < deadline else { throw RecallFailure(message: "完整历史核验超过时限，已停止。") }
            guard let rows = page["data"] as? [[String: Any]] else { throw RecallFailure(message: "历史分页响应格式不受支持。") }
            work.pages += 1; work.records += rows.count
            var inputs = [ProjectionInput](), owners = [RawStoredMessage?]()
            for row in rows {
                try Task.checkCancellation()
                guard let turn = row["turnId"] as? String, let item = row["item"] as? [String: Any] else { throw RecallFailure(message: "历史记录缺少原始标识，停止核验。") }
                if let message = Self.rawMessage(item, turnID: turn) {
                    guard seenMessages.insert(message.turnID + ":" + message.itemID).inserted else { throw RecallFailure(message: "历史消息身份重复，已停止。") }
                    if message.turnID == mark.anchor.turnID && message.itemID == mark.anchor.itemID {
                        originalCount += 1
                        guard message.role == mark.anchor.role, message.text == mark.fullText else { throw RecallFailure(message: "原消息作者或内容已改变，停止定位。") }
                    }
                    inputs.append(ProjectionInput(texts: [message.text], isMessage: true)); owners.append(message)
                } else {
                    let texts = Self.publicItemStrings(item)
                    if !texts.isEmpty { inputs.append(ProjectionInput(texts: texts, isMessage: false)); owners.append(nil) }
                }
            }
            let cursor = page["nextCursor"] as? String
            if let cursor {
                guard seenCursors.insert(cursor).inserted else { throw RecallFailure(message: "历史分页游标重复，停止核验。") }
                params["cursor"] = cursor
            }
            let nextParams: [String: Any]? = cursor == nil ? nil : params
            work.preparationSeconds += ProcessInfo.processInfo.systemUptime - preparationStarted
            // One-page lookahead overlaps read-only I/O with bounded local CPU
            // work. Structured concurrency bounds lifetime on errors as well.
            async let following = Self.nextPage(nextParams, rpc: rpc)
            let flags = try await project(inputs, query: query, work: &work)
            for (index, found) in flags.enumerated() where found {
                guard let owner = owners[index] else { throw RecallFailure(message: "工具结果或附件中也出现了完整原文，无法排除同文位置。已停止返回。") }
                locatorCount += 1
                guard locatorCount == 1, owner.turnID == mark.anchor.turnID, owner.itemID == mark.anchor.itemID else { throw RecallFailure(message: "定位片段已出现在其他消息中，无法唯一确认原位置。未选择重复或相似结果。") }
            }
            let waitStarted = ProcessInfo.processInfo.systemUptime
            let next = try await following
            work.pageWaitSeconds += ProcessInfo.processInfo.systemUptime - waitStarted
            guard let next else {
                guard originalCount == 1, locatorCount == 1 else { throw RecallFailure(message: "原消息不存在，或完整历史不能唯一核验原位置。") }
                return work
            }
            page = next
        }
        throw RecallFailure(message: "历史分页超过上限；没有截断历史并猜测消息。")
    }
    nonisolated private static func nextPage(_ params: [String: Any]?, rpc: ReadOnlyRPC) async throws -> [String: Any]? {
        guard let params else { return nil }
        return try await rpc.call("thread/items/list", params: params)
    }
    private func project(_ inputs: [ProjectionInput], query: LocatorQuery, work: inout ReturnProofWork) async throws -> [Bool] {
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        var keys = [ProjectionKey](), facts = [ProjectionKey: Bool](), jobs = [(ProjectionKey, ProjectionInput)]()
        var queued = Set<ProjectionKey>()
        for input in inputs {
            let key = ProjectionKey(query: query.key, source: input.fingerprint(), isMessage: input.isMessage)
            keys.append(key)
            if let found = projections.value(for: key) { facts[key] = found; work.cacheHits += 1 }
            else if queued.insert(key).inserted { jobs.append((key, input)) }
        }
        work.computedProjections += jobs.count
        work.preparationSeconds += ProcessInfo.processInfo.systemUptime - preparationStarted
        let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount), jobs.count)
        let batch = jobs
        let computeStarted = ProcessInfo.processInfo.systemUptime
        let computed = try await withThrowingTaskGroup(of: (ProjectionKey, Bool).self) { group in
            for index in 0..<workers {
                let job = batch[index]
                group.addTask {
                    try Task.checkCancellation()
                    return (job.0, try query.matches(job.1))
                }
            }
            var next = workers
            var results = [(ProjectionKey, Bool)]()
            while let part = try await group.next() {
                results.append(part)
                if next < batch.count {
                    let job = batch[next]; next += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return (job.0, try query.matches(job.1))
                    }
                }
            }
            return results
        }
        work.matchSeconds += ProcessInfo.processInfo.systemUptime - computeStarted
        let cacheStarted = ProcessInfo.processInfo.systemUptime
        for (key, found) in computed {
            facts[key] = found
            projections.insert(found, for: key)
        }
        work.cacheWriteSeconds += ProcessInfo.processInfo.systemUptime - cacheStarted
        return keys.map { facts[$0]! }
    }
    private func read(_ threadID: String, turnID: String?, itemID: String?, using rpc: ReadOnlyRPC) async throws -> StoredConversation {
        let response = try await rpc.call("thread/read", params: ["threadId": threadID])
        guard let thread = response["thread"] as? [String: Any], thread["id"] as? String == threadID else { throw RecallFailure(message: "公开接口没有确认此原对话。") }
        guard let title = thread["name"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecallFailure(message: "公开接口未返回对话标题。不会用摘要或首条消息冒充标题。") }
        var messages = [StoredMessage](), otherItemTexts = [String](), cursor: String?, seen = Set<String>()
        let deadline = Date().addingTimeInterval(60)
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard Date() < deadline else { throw RecallFailure(message: "对话历史过长，未完成完整读取，操作停止。") }
            var params: [String: Any] = ["threadId": threadID, "limit": 100, "sortDirection": "asc"]
            if let turnID { params["turnId"] = turnID }
            if let cursor { params["cursor"] = cursor }
            let page = try await rpc.call("thread/items/list", params: params)
            guard let rows = page["data"] as? [[String: Any]] else { throw RecallFailure(message: "历史分页响应格式不受支持。") }
            for row in rows {
                guard let turn = row["turnId"] as? String, let item = row["item"] as? [String: Any] else { throw RecallFailure(message: "历史记录缺少原始标识，停止读取。") }
                if let turnID {
                    guard turn == turnID else { throw RecallFailure(message: "历史接口未返回指定轮次，停止身份预检。") }
                    if item["id"] as? String != itemID { continue }
                }
                if let message = Self.message(item, turnID: turn, rendering: rendering) { messages.append(message) }
                else if turnID == nil { otherItemTexts.append(contentsOf: Self.publicItemStrings(item)) }
            }
            cursor = page["nextCursor"] as? String
            if cursor == nil {
                guard Set(messages.map { $0.turnID + ":" + $0.itemID }).count == messages.count else { throw RecallFailure(message: "历史消息标识重复，无法确认身份。") }
                let searchable = otherItemTexts.flatMap { source -> [String] in
                    let prepared = rendering.prepared(source)
                    return [prepared.normalizedSource, prepared.normalizedRendered]
                }
                return StoredConversation(id: threadID, title: title, messages: messages, otherItemTexts: otherItemTexts, otherSearchTexts: searchable, coverage: turnID.map(HistoryCoverage.singleTurn) ?? .wholeConversation)
            }
            guard seen.insert(cursor!).inserted else { throw RecallFailure(message: "历史分页游标重复，停止读取。") }
        }
        throw RecallFailure(message: "历史分页超过上限；没有静默截断并猜测消息。")
    }
    nonisolated static func message(_ item: [String: Any], turnID: String, rendering: TextRenderingCache? = nil) -> StoredMessage? {
        guard let raw = rawMessage(item, turnID: turnID) else { return nil }
        return StoredMessage(turnID: raw.turnID, itemID: raw.itemID, role: raw.role, text: raw.text, prepared: rendering?.prepared(raw.text))
    }
    nonisolated static func rawMessage(_ item: [String: Any], turnID: String) -> RawStoredMessage? {
        guard let type = item["type"] as? String, let id = item["id"] as? String, !id.isEmpty else { return nil }
        if type == "agentMessage", let text = item["text"] as? String, text.contains(where: { !$0.isWhitespace }) {
            return RawStoredMessage(turnID: turnID, itemID: id, role: "assistant", text: text)
        }
        if type == "userMessage", let parts = item["content"] as? [[String: Any]] {
            // Attachments are not silently converted into a text-only bookmark.
            guard parts.allSatisfy({ $0["type"] as? String == "text" }) else { return nil }
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if text.contains(where: { !$0.isWhitespace }) { return RawStoredMessage(turnID: turnID, itemID: id, role: "user", text: text) }
        }
        return nil
    }
    // Only fields already returned by the public history API. Keep these in
    // memory to reject a full-body duplicate in tool output or attachments;
    // never persist or log them, and never read private host files.
    nonisolated static func publicItemStrings(_ value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let object = value as? [String: Any] { return object.values.flatMap(publicItemStrings) }
        if let array = value as? [Any] {
            var strings = array.flatMap(publicItemStrings)
            let parts = array.compactMap { ($0 as? [String: Any])?["text"] as? String }
            if parts.count > 1 { strings.append(parts.joined(separator: "\n")); strings.append(parts.joined()) }
            return strings
        }
        return []
    }
}
