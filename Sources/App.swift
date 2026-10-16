// Copyright (C) 2026 BigFat-Dev
// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import Carbon
import ApplicationServices
import UniformTypeIdentifiers

@MainActor
final class DesktopModel: ObservableObject {
    @Published var marks = [Mark]()
    @Published var pendingCapture: Capture?
    @Published var status = "点击备注，自动返回原消息并短暂高亮"
    @Published var error: String?
    @Published var busy = false
    @Published var writable = true
    @Published var permissionGranted = AXIsProcessTrusted()
    @Published var returnIssue: ReturnIssue?
    @Published var returning = false
    @Published var cancellingReturn = false
    @Published var lastReturnSeconds: TimeInterval?
    private var returnTask: Task<Void, Never>?
    @Published var capturing = false
    @Published var cancellingCapture = false
    @Published var editingMark: Mark?
    @Published var editingDraft: String?
    @Published var canUndoDeletion = false
    @Published var canRecoverClipboard = false
    private var captureTask: Task<Void, Never>?
    private var editAfterCapture: (Mark, String)?
    private var deleted: (mark: Mark, index: Int, token: UUID)?
    let repository: MarkRepository
    let navigator = DesktopNavigator()
    let demo = DemoModel()
    init(directory: URL? = nil) {
        do {
            let selected = try LocalDataLocation.resolve(legacyDirectory: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("data"), override: directory ?? ProcessInfo.processInfo.environment["RECALL_DESKTOP_DATA_DIR"].map { URL(fileURLWithPath: $0) })
            repository = MarkRepository(directory: selected)
            reload()
        } catch {
            repository = MarkRepository(directory: directory ?? LocalDataLocation.activeDirectory)
            writable = false; self.error = "本地数据准备失败，旧文件保留：\(error.localizedDescription)"
        }
    }
    func reload() {
        guard !busy else { return }
        do { marks = try repository.load(); writable = true }
        catch { writable = false; self.error = "数据读取失败，未覆盖原文件：\(error.localizedDescription)" }
    }
    func commit(_ next: [Mark]) -> Bool {
        guard !busy, writable else { error = "本地数据暂不可写，停止写入。"; return false }
        do { try repository.save(next); marks = next; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func saveCapture(note: String) {
        guard let pendingCapture else { return }
        do {
            let mark = try pendingCapture.makeMark(note: note)
            if let existing = existingMark(for: pendingCapture) {
                editAfterCapture = (existing, note)
                self.pendingCapture = nil
                status = "消息已标记，当前输入已保留；保存将更新原备注。"
                return
            }
            if commit([mark] + marks) { self.pendingCapture = nil; status = "已保存消息身份和位置。点击备注直接返回。" }
        } catch { self.error = error.localizedDescription }
    }
    func capturePointer() {
        guard !busy else { return }
        guard pendingCapture == nil, editingMark == nil else {
            DesktopDelegate.current?.openPanel?(); NSApp.activate(ignoringOtherApps: true); return
        }
        startCapture { progress in try await self.navigator.captureAtPointer(onProgress: progress) }
    }
    func startCapture(showPanel: Bool = true, operation: @escaping @MainActor (@escaping (CaptureProgress) -> Void) async throws -> Capture) {
        guard !busy else { return }
        busy = true; capturing = true; cancellingCapture = false
        lastReturnSeconds = nil; status = CaptureProgress.locating.rawValue
        captureTask = Task {
            defer { busy = false; capturing = false; cancellingCapture = false; captureTask = nil; canRecoverClipboard = navigator.clipboard.recovery != nil }
            do {
                let capture = try await operation { stage in
                    if !self.cancellingCapture { self.status = stage.rawValue }
                }
                try Task.checkCancellation()
                acceptCapture(capture)
            } catch {
                if Task.isCancelled || error is CancellationError { status = "已取消保存"; return }
                self.error = error.localizedDescription; status = "采集未完成，未保存标记。"
            }
            if showPanel { NSApp.activate(ignoringOtherApps: true); DesktopDelegate.current?.openPanel?() }
        }
    }
    func cancelCapture() {
        guard capturing, !cancellingCapture else { return }
        cancellingCapture = true; status = "正在取消保存…"; captureTask?.cancel()
    }
    private func existingMark(for capture: Capture) -> Mark? {
        marks.first { $0.anchor.kind == capture.anchor.kind && $0.anchor.conversationID == capture.anchor.conversationID && $0.anchor.turnID == capture.anchor.turnID && $0.anchor.itemID == capture.anchor.itemID }
    }
    func acceptCapture(_ capture: Capture) {
        if let existing = existingMark(for: capture) {
            beginEditing(existing)
            status = "这条消息已标记，可直接修改原备注。"
        } else {
            pendingCapture = capture; status = "整条消息已确认，填写备注后保存。"
        }
    }
    func beginEditing(_ mark: Mark, draft: String? = nil) {
        editingDraft = draft; editingMark = mark
    }
    func captureSheetDismissed() {
        guard let pending = editAfterCapture else { return }
        editAfterCapture = nil; beginEditing(pending.0, draft: pending.1)
    }
    func jump(_ mark: Mark) {
        guard !busy else { return }
        if mark.anchor.isDemo { demo.returnTo(mark); DesktopDelegate.current?.openDemo?(); status = "已直接返回桌面测试窗口的消息并高亮；这不代表 Codex 集成已通过验收。"; return }
        startReturn { progress in try await self.navigator.returnTo(mark, onProgress: progress) }
    }
    private func startReturn(isPreview: Bool = false, operation: @escaping @MainActor (@escaping (ReturnProgress) -> Void) async throws -> TimeInterval) {
        guard !busy else { return }
        busy = true; returning = true; cancellingReturn = false
        lastReturnSeconds = nil; returnIssue = nil
        status = (isPreview ? "虚构演示 · " : "") + ReturnProgress.preparing.rawValue
        returnTask = Task {
            defer { busy = false; returning = false; cancellingReturn = false; returnTask = nil; canRecoverClipboard = navigator.clipboard.recovery != nil }
            do {
                let seconds = try await operation { progress in
                    if !self.cancellingReturn { self.status = (isPreview ? "虚构演示 · " : "") + progress.rawValue }
                }
                status = isPreview ? "演示完成（虚构，未操作 Codex）" : "已定位原消息"; lastReturnSeconds = seconds
            }
            catch {
                if Task.isCancelled || error is CancellationError {
                    status = isPreview ? "已取消演示（未操作 Codex）" : "已取消返回"
                    return
                }
                self.returnIssue = ReturnIssue(error.localizedDescription); status = "未能返回原消息"
                // A navigation failure must be visible after the host activated.
                // Raising our own error panel does not change the source chat.
                DesktopDelegate.current?.openPanel?()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    func previewReturnFeedback() {
        startReturn(isPreview: true) { progress in
            let started = ProcessInfo.processInfo.systemUptime
            for stage in ReturnProgress.allCases {
                try Task.checkCancellation()
                progress(stage)
                try await Task.sleep(nanoseconds: 4_000_000_000)
            }
            return ProcessInfo.processInfo.systemUptime - started
        }
    }
    func cancelReturn() {
        guard returning, !cancellingReturn else { return }
        cancellingReturn = true; status = "正在取消返回…"
        returnTask?.cancel()
    }
    func edit(_ mark: Mark, note: String) -> String? {
        guard !busy else { return "当前操作尚未完成，备注草稿已保留。" }
        guard note.count <= 4000 else { return "备注最多 4000 字，当前输入已保留。" }
        guard writable else { return "本地数据尚不可写，当前输入已保留。请先检查数据读取错误。" }
        guard marks.first(where: { $0.id == mark.id }) == mark else { return "这条标记已发生变化，当前输入已保留。请重新读取后再编辑。" }
        var updated = mark; updated.note = note; updated.updatedAt = Date()
        let next = marks.map { $0.id == mark.id ? updated : $0 }
        do { try repository.save(next); marks = next; status = "备注已保存"; return nil }
        catch { return "保存失败，当前输入已保留：\(error.localizedDescription)" }
    }
    func delete(_ mark: Mark) {
        guard let index = marks.firstIndex(where: { $0.id == mark.id }), commit(marks.filter { $0.id != mark.id }) else { return }
        let token = UUID(); deleted = (mark, index, token); canUndoDeletion = true; status = "已删除标记，可在 10 秒内撤销。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard self?.deleted?.token == token else { return }
            self?.deleted = nil; self?.canUndoDeletion = false
        }
    }
    func undoDeletion() {
        guard let deleted, !busy else { return }
        guard !marks.contains(where: { $0.anchor.kind == deleted.mark.anchor.kind && $0.anchor.conversationID == deleted.mark.anchor.conversationID && $0.anchor.itemID == deleted.mark.anchor.itemID }) else { error = "该消息已有标记，未重复恢复；原删除记录仍可从备份恢复。"; return }
        var next = marks; next.insert(deleted.mark, at: min(deleted.index, next.count))
        if commit(next) { self.deleted = nil; canUndoDeletion = false; status = "已恢复删除的标记" }
    }
    func restore(_ data: Data, expected: Data?) async throws {
        guard !busy, pendingCapture == nil, editingMark == nil else { throw RecallFailure(message: "请先完成当前采集或备注编辑，再恢复备份。") }
        busy = true; status = "正在恢复本地备份…"
        defer { busy = false }
        // While busy, all repository entry points below/UI are locked out.
        let target = repository
        do { marks = try await Task.detached(priority: .userInitiated) { try target.restore(data, expected: expected) }.value }
        catch { status = "备份恢复未完成"; throw error }
        writable = true
        deleted = nil; canUndoDeletion = false; status = "已从本地备份恢复标记"
    }
    func resolveClipboardRecovery(restore: Bool) {
        guard !busy else { return }
        if restore && !navigator.clipboard.restoreRecovery() {
            error = "系统未能恢复剪贴板，操作前的内容仍保留在本次进程内，可重试。"; return
        }
        navigator.clipboard.discardRecovery(); canRecoverClipboard = false
        status = restore ? "已恢复操作前剪贴板" : "已保留当前剪贴板并释放旧内容"
    }
}

struct DemoConversation: Identifiable {
    let id: String
    let title: String
    let messages: [StoredMessage]
}
@MainActor
final class DemoModel: ObservableObject {
    let conversations = [
        DemoConversation(id: "fixture-a", title: "桌面测试 A · 完整消息定位", messages: [
            StoredMessage(turnID: "turn-a", itemID: "a-user", role: "user", text: "保存消息的位置后，应怎样找回？"),
            StoredMessage(turnID: "turn-a", itemID: "a-answer", role: "assistant", text: "点击留存备注后，工具应自动打开原对话，定位到保存时的那条消息，并短暂突出显示。用户无需再搜索对话标题或正文。"),
            StoredMessage(turnID: "turn-b", itemID: "a-repeat", role: "assistant", text: "这是一条重复正文，用来验证消息身份。"),
            StoredMessage(turnID: "turn-c", itemID: "a-repeat-2", role: "assistant", text: "这是一条重复正文，用来验证消息身份。")]),
        DemoConversation(id: "fixture-b", title: "桌面测试 B · 另一条对话", messages: [
            StoredMessage(turnID: "turn-d", itemID: "b-user", role: "user", text: "这条对话用于验证跨对话直接返回。"),
            StoredMessage(turnID: "turn-d", itemID: "b-answer", role: "assistant", text: "在测试 A 保存标记，切到测试 B，再点击标记备注。应直接回到测试 A 的原消息，不出现手动找回步骤。")])]
    @Published var selectedID = "fixture-a"
    @Published var targetID: String?
    @Published var highlightedID: String?
    @Published var navigationSerial = UUID()
    var current: DemoConversation { conversations.first(where: { $0.id == selectedID })! }
    func capture(_ message: StoredMessage) -> Capture {
        let anchor = NativeAnchor(version: 2, kind: "native-fixture", conversationLink: "recall-fixture://threads/\(selectedID)", conversationID: selectedID,
                                  turnID: message.turnID, itemID: message.itemID, role: message.role, searchPhrase: message.text,
                                  bodySHA256: digest(message.text), axIdentifier: message.itemID, precision: "仅受控桌面窗口：稳定消息身份与直接滚动；非 Codex 实测")
        return Capture(title: current.title, fullText: message.text, renderedText: message.text, anchor: anchor)
    }
    func returnTo(_ mark: Mark) {
        guard let conversation = conversations.first(where: { $0.id == mark.anchor.conversationID }) else { return }
        do { try verifyStoredIdentity(mark, in: StoredConversation(id: conversation.id, title: conversation.title, messages: conversation.messages)) }
        catch { return }
        selectedID = conversation.id; targetID = mark.anchor.itemID; highlightedID = mark.anchor.itemID; navigationSerial = UUID()
        let token = navigationSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if self.navigationSerial == token { self.highlightedID = nil } }
    }
}

struct CaptureNote: View {
    @ObservedObject var model: DesktopModel
    let capture: Capture
    @State private var note = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存这条消息的位置").font(.title2.bold())
            Text(capture.title).font(.headline)
            Text(capture.anchor.role == "user" ? "用户消息" : "AI 回复").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(capture.fullText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 180).padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            TextField("留存备注 · 为什么要留存？", text: $note, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            Text(capture.anchor.isDemo ? "这条记录来自虚构桌面测试窗口。" : "原对话和消息身份已自动采集，无需粘贴原文或填写标题。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { model.pendingCapture = nil }; Button("保存标记") { model.saveCapture(note: note) }.buttonStyle(.borderedProminent).tint(.orange).disabled(!model.writable) }
        }.padding(24).frame(width: 540, height: 450)
    }
}
struct EditNote: View {
    @ObservedObject var model: DesktopModel
    let mark: Mark
    @Environment(\.dismiss) var dismiss
    @State private var note: String
    @State private var saveError: String?
    init(model: DesktopModel, mark: Mark, draft: String? = nil) { self.model = model; self.mark = mark; _note = State(initialValue: draft ?? mark.note) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改留存备注").font(.title2.bold())
            Text(mark.excerpt).foregroundStyle(.secondary)
            TextField("留存备注", text: $note, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存备注") { if let failure = model.edit(mark, note: note) { saveError = failure } else { dismiss() } }.buttonStyle(.borderedProminent).tint(.orange) }
        }.padding(24).frame(width: 490).frame(minHeight: 270)
    }
}
struct BookmarkCard: View {
    let mark: Mark
    let busy: Bool
    let onReturn: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @FocusState private var returnFocused: Bool
    private var emphasized: Bool { !busy && (hovering || returnFocused) }
    var body: some View {
        // Sibling controls keep menu actions separate from the full-card button.
        ZStack(alignment: .topTrailing) {
            Button(action: onReturn) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(mark.note.isEmpty ? "未写备注 · 点击返回消息" : mark.note)
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Label("返回原消息", systemImage: "arrow.up.right")
                            .font(.caption.weight(.medium)).foregroundStyle(.orange)
                            .fixedSize()
                            .opacity(emphasized ? 1 : 0).accessibilityHidden(true)
                    }.padding(.trailing, 32)
                    Text(mark.excerpt).font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineLimit(2).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Text("\(mark.anchor.isDemo ? "虚构测试 · " : "")\(mark.conversationTitle)")
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(mark.savedAt.formatted(date: .abbreviated, time: .shortened))
                            .lineLimit(1).fixedSize()
                    }.font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.quaternary.opacity(emphasized ? 0.6 : 0.35), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(emphasized ? 0.5 : 0), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).disabled(busy).focused($returnFocused)
            .accessibilityLabel("返回原消息：\(mark.note.isEmpty ? mark.excerpt : mark.note)")
            .help("点击卡片，返回原对话中的这条消息")
            Menu {
                Button("修改备注", systemImage: "square.and.pencil", action: onEdit)
                Divider()
                Button("删除标记", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
            .disabled(busy).accessibilityLabel("标记操作").help("修改备注或删除标记")
            .padding(4)
        }
        .onHover { hovering = $0 }
    }
}
// Hide only the visible title of this window; retain its native controls and
// logical title for the Window menu and accessibility.
struct WindowTitleHider: NSViewRepresentable {
    final class TitleView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }
    }
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.window?.titleVisibility = .hidden }
}

struct DesktopSettings: View {
    @ObservedObject var model: DesktopModel
    @ObservedObject var delegate: DesktopDelegate
    @Environment(\.openWindow) var openWindow
    @State private var localError: String?
    @State private var localNotice: String?
    @State private var restoreData: Data?
    @State private var restoreRevision: Data?
    @State private var restoreCount = 0
    @State private var confirmingRestore = false
    @State private var importingBackup = false
    private func exportBackup() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Recall-backup.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try model.repository.diskData() ?? MarkRepository.encode([])
                _ = try MarkRepository.decode(data)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                localNotice = "备份已保存到你选择的位置。"
            } catch { localError = error.localizedDescription }
        }
    }
    private func chooseRestore() {
        guard !model.busy, !importingBackup else { return }
        importingBackup = true
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        if FileManager.default.fileExists(atPath: model.repository.backupsDirectory.path) { panel.directoryURL = model.repository.backupsDirectory }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { importingBackup = false; return }
            localNotice = "正在后台读取并校验备份…"
            Task { @MainActor in
                defer { importingBackup = false }
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) { try PreparedBackup.read(url) }.value
                    guard !model.busy, model.pendingCapture == nil, model.editingMark == nil else {
                        throw RecallFailure(message: "当前有其他操作，请完成后再选择恢复备份。")
                    }
                    restoreCount = prepared.count
                    restoreRevision = try model.repository.diskData()
                    restoreData = prepared.data; confirmingRestore = true; localNotice = nil
                } catch { localNotice = nil; localError = "备份无效或无法读取，现有数据未改动：\(error.localizedDescription)" }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("设置").font(.title2.weight(.semibold))
                Spacer()
                Text("Codex 桌面伴侣").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("使用方法").font(.headline)
                Text("在 Codex 中，将指针停在已完成的消息正文上，按快捷键保存。点击标记卡片即可返回原消息。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { Text("保存消息标记"); Spacer(); Text("⌘⇧M").monospaced() }
                HStack { Text("打开标记面板"); Spacer(); Text("⌃⌥B").monospaced() }
                if let issue = delegate.shortcutIssue {
                    Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("重新检查快捷键") { delegate.configureShortcuts() }
                }
            }.font(.callout)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("本地数据与备份").font(.headline)
                Text("当前 \(model.marks.count) 条标记").font(.caption).foregroundStyle(.secondary)
                Text("更改已有内容前自动备份，写入成功后尝试保留最近 20 份。恢复时也按此规则保留旧文件。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("导出备份…") { exportBackup() }.disabled(model.busy || !model.writable)
                    Button("恢复备份…") { chooseRestore() }.disabled(model.busy || importingBackup)
                    Button("打开数据文件夹") {
                        do {
                            let directory = model.repository.url.deletingLastPathComponent()
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                            NSWorkspace.shared.open(directory)
                        } catch { localError = error.localizedDescription }
                    }
                }
                if let localNotice { Text(localNotice).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("系统权限").font(.headline)
                Label(model.permissionGranted ? "当前构建已获得系统权限" : "当前构建尚未获得系统权限",
                      systemImage: model.permissionGranted ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.callout).foregroundStyle(model.permissionGranted ? Color.secondary : Color.orange)
                HStack {
                    Button("检查权限") { model.permissionGranted = AXIsProcessTrusted() }
                    Button("打开系统设置") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("维护与验证").font(.headline)
                HStack {
                    Button("重新读取标记") { model.reload() }.disabled(model.busy)
                    Button("桌面流程测试") { openWindow(id: "desktop-fixture") }
                }
                Text("桌面流程测试仅使用虚构消息，不代表真实宿主兼容性已通过。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Label("仅本地保存", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 440)
            .alert("操作未完成", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("知道了") { localError = nil }
            } message: { Text(localError ?? "") }
            .alert("恢复本地备份？", isPresented: $confirmingRestore) {
                Button("取消", role: .cancel) { restoreData = nil }
                Button("恢复并替换") {
                    guard let restoreData else { return }
                    Task { @MainActor in
                        do { try await model.restore(restoreData, expected: restoreRevision); localNotice = "已恢复 \(restoreCount) 条标记；内容变化时，写入前已备份原有文件。"; self.restoreData = nil }
                        catch { localError = error.localizedDescription }
                    }
                }
            } message: { Text("将用备份中的 \(restoreCount) 条标记替换当前列表。内容变化时，会在写入前备份原有文件。") }
            .onAppear { model.permissionGranted = AXIsProcessTrusted() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.permissionGranted = AXIsProcessTrusted() }
    }
}

struct ReturnFailureView: View {
    let issue: ReturnIssue
    let openSettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detailsExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("未能返回原消息", systemImage: "exclamationmark.circle")
                .font(.title2.weight(.semibold))
            Text(issue.summary).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(issue.recovery).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("查看详情", isExpanded: $detailsExpanded) {
                ScrollView { Text(issue.details).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 150).padding(.top, 8)
            }.font(.callout)
            HStack {
                if issue.offersSettings { Button("打开 Recall 设置") { dismiss(); openSettings() } }
                Spacer()
                Button("知道了") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 470)
    }
}

struct ReturnStatusLine: View {
    @ObservedObject var model: DesktopModel
    @State private var confirmingClipboardRestore = false
    var body: some View {
        HStack {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let seconds = model.lastReturnSeconds, !model.busy {
                Text(String(format: "%.1f 秒", seconds)).font(.caption2).foregroundStyle(.secondary)
            }
            if model.returning {
                Button("取消") { model.cancelReturn() }.controlSize(.small)
                    .disabled(model.cancellingReturn).help("取消当前返回，不改变已有标记")
            }
            if model.capturing {
                Button("取消") { model.cancelCapture() }.controlSize(.small).disabled(model.cancellingCapture)
            }
            if model.canUndoDeletion && !model.busy { Button("撤销删除") { model.undoDeletion() }.controlSize(.small) }
            if model.canRecoverClipboard && !model.busy {
                Menu("剪贴板恢复") {
                    Button("恢复操作前剪贴板…") { confirmingClipboardRestore = true }
                    Button("保留当前剪贴板") { model.resolveClipboardRecovery(restore: false) }
                }.controlSize(.small)
            }
            Spacer(minLength: 12)
            Label("仅本地保存", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary).fixedSize()
        }.alert("恢复操作前剪贴板？", isPresented: $confirmingClipboardRestore) {
            Button("取消", role: .cancel) {}
            Button("恢复") { model.resolveClipboardRecovery(restore: true) }
        } message: { Text("将以操作前暂存的内容替换当前剪贴板。若要保留刚复制的新内容，请取消并选择“保留当前剪贴板”。旧内容仅存在本次进程内，退出后释放。") }
    }
}

struct DesktopPanel: View {
    @ObservedObject var model: DesktopModel
    @ObservedObject var delegate: DesktopDelegate
    @Environment(\.openWindow) var openWindow
    @State private var deleting: Mark?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Recall", systemImage: "bookmark.fill").font(.title3.weight(.semibold)).foregroundStyle(.orange)
                Text("· 已保存的消息").font(.headline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("标记 ⌘⇧M").font(.caption).foregroundStyle(.secondary)
                    .help("在 Codex 消息正文上停住指针，按 ⌘⇧M 保存标记；⌃⌥B 打开此面板")
                Button { openWindow(id: "desktop-settings") } label: {
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("设置").help("使用方法、权限和维护")
            }
            Divider()
            if let issue = delegate.shortcutIssue {
                HStack {
                    Text(issue).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("查看设置") { openWindow(id: "desktop-settings") }
                }
            }
            if !model.permissionGranted {
                HStack {
                    Label("需要系统权限才能保存和返回消息", systemImage: "exclamationmark.shield")
                        .font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("检查权限") { openWindow(id: "desktop-settings") }
                }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.marks.isEmpty {
                        VStack(spacing: 12) {
                            Text("还没有消息标记").font(.headline)
                            Text("在 Codex 中，将指针停在一条已完成的消息正文上，\n按 ⌘⇧M 保存标记，再写一句留存备注。\n之后点击卡片，即可返回原消息。")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, minHeight: 200)
                    }
                    ForEach(model.marks) { mark in
                        BookmarkCard(mark: mark, busy: model.busy,
                                     onReturn: { model.jump(mark) }, onEdit: { model.beginEditing(mark) }, onDelete: { deleting = mark })
                    }
                }
            }
            ReturnStatusLine(model: model)
        }.padding(24).frame(minWidth: 540, minHeight: 570)
        .background(WindowTitleHider().frame(width: 0, height: 0))
        .sheet(item: $model.pendingCapture, onDismiss: { model.captureSheetDismissed() }) { capture in CaptureNote(model: model, capture: capture) }
        .sheet(item: $model.editingMark) { mark in EditNote(model: model, mark: mark, draft: model.editingDraft) }
        .sheet(item: $model.returnIssue) { issue in
            ReturnFailureView(issue: issue, openSettings: { openWindow(id: "desktop-settings") })
        }
        .alert("删除本地标记？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }; Button("删除", role: .destructive) { if let deleting { model.delete(deleting) }; deleting = nil }
        } message: { Text("只删除 Recall 的记录；删除后 10 秒内可撤销，也可从本地备份恢复。") }
        .alert("核心操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
        .onAppear {
            model.permissionGranted = AXIsProcessTrusted()
            delegate.configureShortcuts()
            delegate.openPanel = { openWindow(id: "desktop-panel") }
            delegate.openDemo = { openWindow(id: "desktop-fixture") }
            delegate.capture = { model.capturePointer() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.permissionGranted = AXIsProcessTrusted() }
    }
}
extension Capture: Identifiable { var id: String { anchor.conversationID + ":" + anchor.itemID } }
struct DesktopFixture: View {
    @ObservedObject var model: DesktopModel
    @ObservedObject var demo: DemoModel
    @Environment(\.openWindow) var openWindow
    @State private var overlayCount = 0
    @State private var overlayStatus = ""
    @State private var boundaryStatus = ""
    @State private var counterQuery = "虚构定位片段"
    @State private var counterStatus = ""
    @State private var cardStatus = ""
    @State private var previewFailure = false
    @FocusState private var counterFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("受控桌面流程验证 · 全部消息均为虚构").font(.title2.bold())
            Text("验证跨对话直接返回、稳定身份和整条消息高亮。此窗口不能证明真实 Codex 的辅助功能结构已通过验收。").font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("返回反馈预览（虚构，不操作 Codex）") {
                HStack {
                    Button("演示返回进度与取消") { model.previewReturnFeedback() }.disabled(model.busy)
                    Button("预览失败提示") { previewFailure = true }
                }
                ReturnStatusLine(model: model)
            }
            DisclosureGroup("标记卡片交互预览（虚构，不写入数据）") {
                if let mark = try? demo.capture(demo.current.messages[1]).makeMark(note: "点击卡片返回原消息") {
                    BookmarkCard(mark: mark, busy: false,
                                 onReturn: { cardStatus = "已触发卡片返回入口（虚构，无宿主操作）" },
                                 onEdit: { cardStatus = "已触发修改备注菜单（虚构，未修改数据）" },
                                 onDelete: { cardStatus = "已触发删除标记菜单（虚构，未删除数据）" })
                    Text(cardStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("当前对话", selection: $demo.selectedID) { ForEach(demo.conversations) { conversation in Text(conversation.title).tag(conversation.id) } }.pickerStyle(.segmented)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(demo.current.messages, id: \.itemID) { message in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(message.role == "user" ? "用户消息" : "AI 回复").font(.caption).foregroundStyle(.secondary)
                                Text(message.text).frame(maxWidth: .infinity, alignment: .leading)
                                Button("标记这条消息") { model.pendingCapture = demo.capture(message); openWindow(id: "desktop-panel") }
                            }.padding(18).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(demo.highlightedID == message.itemID ? Color.orange : Color.clear, lineWidth: 3)).id(message.itemID)
                        }
                    }.padding(6)
                }
                .onChange(of: demo.navigationSerial) { if let target = demo.targetID { DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) } } }
                .onAppear { if let target = demo.targetID { proxy.scrollTo(target, anchor: .center) } }
            }
            Text(demo.highlightedID == nil ? "等待点击标记备注返回。" : "已直接返回消息 \(demo.highlightedID!)，整条消息高亮 2.5 秒。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("测试重复高亮显示") {
                    do { try model.navigator.highlightSyntheticWindow(); overlayCount += 1; overlayStatus = "第\(overlayCount)次高亮窗口已显示（仅渲染测试，非宿主返回）。" }
                    catch { overlayStatus = "高亮渲染测试失败。" }
                }
                Text(overlayStatus).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("测试完整正文位置与高亮") {
                    NSApp.activate(ignoringOtherApps: true)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        do {
                            let quick = try model.navigator.verifySyntheticBody(demo.current.messages[1].text)
                            boundaryStatus = "完整正文位置已核验，并显示短暂高亮（仅虚构窗口）。" + (quick ? "快速与后备路径一致。" : "后备路径已通过。")
                        } catch { boundaryStatus = error.localizedDescription }
                    }
                }
                Text(boundaryStatus).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                HStack {
                    TextField("局部计数测试", text: $counterQuery).focused($counterFocused).frame(width: 180).accessibilityIdentifier("recall-local-counter-field")
                    Text("1 / 1").frame(width: 48).accessibilityElement(children: .ignore).accessibilityLabel("1 / 1")
                }.accessibilityElement(children: .contain)
                Button("检查局部计数") {
                    NSApp.activate(ignoringOtherApps: true)
                    counterFocused = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        do { try model.navigator.verifySyntheticCounter(); counterStatus = "查找框附近计数核验通过（虚构窗口）。" }
                        catch { counterStatus = error.localizedDescription }
                    }
                }
                Text(counterStatus).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(minWidth: 750, minHeight: 600)
            .sheet(isPresented: $previewFailure) {
                ReturnFailureView(issue: ReturnIssue("最终核验无法确认完整消息，未高亮。结构诊断（不含正文）：虚构 AXGroup：节点 12，完整否。"), openSettings: {})
            }
    }
}
@MainActor
final class DesktopDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static var current: DesktopDelegate?
    @Published var shortcutIssue: String?
    var openPanel: (() -> Void)?, openDemo: (() -> Void)?, capture: (() -> Void)?
    private var markKey: EventHotKeyRef?, panelKey: EventHotKeyRef?, handler: EventHandlerRef?
    private var legacyDockIcon: AppearanceDockIcon?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS 26+ selects the native icon rendition, including Finder and the Dock.
        if #unavailable(macOS 26.0) { legacyDockIcon = AppearanceDockIcon(bundle: .main) }
        configureShortcuts()
    }
    func configureShortcuts() {
        Self.current = self
        if handler == nil {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr, key.signature == 0x52434454 else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                if key.id == 1 { DesktopDelegate.current?.capture?() }
                else if key.id == 2 { DesktopDelegate.current?.openPanel?(); NSApp.activate(ignoringOtherApps: true) }
            }
            return noErr
        }, 1, &spec, nil, &handler)
            guard result == noErr else { handler = nil; shortcutIssue = "快捷键监听不可用，请重新启动 Recall。"; return }
        }
        let markResult = markKey == nil ? RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x52434454, id: 1), GetApplicationEventTarget(), 0, &markKey) : noErr
        let panelResult = panelKey == nil ? RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x52434454, id: 2), GetApplicationEventTarget(), 0, &panelKey) : noErr
        if markResult != noErr { markKey = nil }; if panelResult != noErr { panelKey = nil }
        shortcutIssue = ShortcutAvailability.message(mark: markResult == noErr, panel: panelResult == noErr)
    }
}
#if !RECALL_TESTING
@main
struct RecallDesktopApp: App {
    @NSApplicationDelegateAdaptor(DesktopDelegate.self) var delegate
    @StateObject private var model = DesktopModel()
    var body: some Scene {
        Window("Recall Desktop", id: "desktop-panel") { DesktopPanel(model: model, delegate: delegate) }.defaultSize(width: 650, height: 730)
            .commands {
                CommandMenu("标记") {
                    Button("打开标记面板") { delegate.openPanel?(); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("b", modifiers: [.control, .option])
                    Button("标记指针下的消息") { model.capturePointer() }.keyboardShortcut("m", modifiers: [.command, .shift])
                }
            }
        Window("桌面流程验证", id: "desktop-fixture") { DesktopFixture(model: model, demo: model.demo) }.defaultSize(width: 880, height: 750)
        Window("Recall 设置", id: "desktop-settings") { DesktopSettings(model: model, delegate: delegate) }.windowResizability(.contentSize)
        MenuBarExtra { DesktopMenu(model: model) } label: {
            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill")
                if model.busy { Text(model.capturing ? "保存中…" : "返回中…") }
            }
        }
    }
}
#endif
struct DesktopMenu: View {
    @ObservedObject var model: DesktopModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("打开标记面板  ⌃⌥B") { openWindow(id: "desktop-panel"); NSApp.activate(ignoringOtherApps: true) }
        Text("在 Codex 消息处按 ⌘⇧M 标记")
        if model.returning {
            Text(model.status)
            Button(model.cancellingReturn ? "正在取消…" : "取消返回") { model.cancelReturn() }.disabled(model.cancellingReturn)
        }
        if model.capturing {
            Text(model.status)
            Button(model.cancellingCapture ? "正在取消…" : "取消保存") { model.cancelCapture() }.disabled(model.cancellingCapture)
        }
        Divider()
        Button("设置…") { openWindow(id: "desktop-settings"); NSApp.activate(ignoringOtherApps: true) }
        Button("退出") { NSApp.terminate(nil) }
    }
}
