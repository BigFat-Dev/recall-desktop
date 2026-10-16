// Copyright (C) 2026 BigFat-Dev
// SPDX-License-Identifier: MIT
import AppKit

// Opaque, transient clipboard data only. Never log, parse or persist the prior
// clipboard; tests use a private named pasteboard, never the user's clipboard.
@MainActor
final class ClipboardLease {
    private let pasteboard: NSPasteboard
    private let items: [[NSPasteboard.PasteboardType: Data]]
    private(set) var originalChangeCount: Int
    private var ownedChangeCount: Int?
    private var ownedString: String?
    init(_ pasteboard: NSPasteboard) throws {
        self.pasteboard = pasteboard
        originalChangeCount = pasteboard.changeCount
        var saved = [[NSPasteboard.PasteboardType: Data]](), size = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var values = [NSPasteboard.PasteboardType: Data]()
            var unavailable = [NSPasteboard.PasteboardType]()
            for type in item.types {
                guard let data = item.data(forType: type) else { unavailable.append(type); continue }
                size += data.count
                guard size <= 64 * 1024 * 1024 else { throw RecallFailure(message: "当前剪贴板超过保护容量，本次操作已停止，未覆盖剪贴板。") }
                values[type] = data
            }
            // AppKit advertises this derived UTF-16 representation even when
            // its on-demand converter returns nil. Preserve its concrete UTF-8
            // source; AppKit can advertise the derived representation again.
            for type in unavailable {
                guard type.rawValue == "public.utf16-external-plain-text", values[.string] != nil else {
                    throw RecallFailure(message: "无法完整保留当前剪贴板，本次操作已停止，未覆盖剪贴板。")
                }
            }
            saved.append(values)
        }
        guard pasteboard.changeCount == originalChangeCount else { throw RecallFailure(message: "剪贴板正在被其他操作修改，本次操作已停止。") }
        items = saved
    }
    @discardableResult func own(_ string: String, revision: Int? = nil) -> Bool {
        let observed = revision ?? pasteboard.changeCount
        guard pasteboard.changeCount == observed, pasteboard.string(forType: .string) == string,
              pasteboard.changeCount == observed else { return false }
        ownedChangeCount = observed
        ownedString = string
        return true
    }
    var hasChanged: Bool { pasteboard.changeCount != originalChangeCount }
    @discardableResult func restoreIfOwned() -> Bool {
        guard let revision = ownedChangeCount, let string = ownedString,
              pasteboard.changeCount == revision, pasteboard.string(forType: .string) == string else { return false }
        return restoreSnapshot()
    }
    // Only call without an ownership proof after an explicit user choice.
    @discardableResult func restoreSnapshot() -> Bool {
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        // No suspension between checking the clipboard revision and restoring.
        pasteboard.clearContents()
        ownedChangeCount = nil; ownedString = nil
        return restored.isEmpty || pasteboard.writeObjects(restored)
    }
}

@MainActor
final class ClipboardCoordinator {
    private(set) var recovery: ClipboardLease?
    func discardRecovery() { recovery = nil }
    func restoreRecovery() -> Bool {
        guard let recovery, recovery.restoreSnapshot() else { return false }
        self.recovery = nil; return true
    }
    func copyThreadLink(from pasteboard: NSPasteboard, issueCopy: () throws -> Void,
                        verifyForeground: () throws -> Void, attempts: Int = 15,
                        interval: UInt64 = 80_000_000) async throws -> (URL, String) {
        guard recovery == nil else { throw RecallFailure(message: "请先在 Recall 面板选择恢复操作前剪贴板，或保留当前剪贴板，再重试。") }
        try Task.checkCancellation()
        let lease = try ClipboardLease(pasteboard)
        defer {
            if !lease.restoreIfOwned(), lease.hasChanged { recovery = lease }
        }
        try issueCopy()
        // This bounded observer task deliberately finishes observing the issued copy
        // even when its caller is cancelled. It never sends another host action.
        let observer = Task { @MainActor in
            for _ in 0..<attempts {
                try await Task.sleep(nanoseconds: interval)
                guard lease.hasChanged else { continue }
                let revision = pasteboard.changeCount
                guard let copied = pasteboard.string(forType: .string) else {
                    throw RecallFailure(message: "复制结果不是可核验的对话链接；原剪贴板暂存在内存，可在 Recall 面板恢复。")
                }
                guard let link = try? canonicalThreadLink(copied) else {
                    throw RecallFailure(message: "剪贴板复制结果不是有效对话链接；操作前内容暂存在内存，可在 Recall 面板选择恢复。")
                }
                guard lease.own(copied, revision: revision) else {
                    throw RecallFailure(message: "剪贴板在读取时改变；未覆盖新内容，可在 Recall 面板选择恢复。")
                }
                return link
            }
            throw RecallFailure(message: "宿主“复制对话深链接”没有返回结果。快捷键可能被改动。没有按标题查找或猜测对话。")
        }
        let result = try await observer.value
        try Task.checkCancellation()
        try verifyForeground()
        return result
    }
}
