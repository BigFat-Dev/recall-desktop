// Copyright (C) 2026 BigFat-Dev
// SPDX-License-Identifier: MIT
import Foundation

@main
struct ModelTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1; print("PASS: \(name)") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("model")
        let model = DesktopModel(directory: root)
        let anchor = NativeAnchor(version: 2, kind: "native-fixture", conversationLink: "recall-fixture://threads/fixture-a", conversationID: "fixture-a", turnID: "turn", itemID: "message", role: "assistant", searchPhrase: "虚构完整消息", bodySHA256: digest("虚构完整消息"), axIdentifier: nil, precision: "fixture")
        let capture = Capture(title: "虚构对话", fullText: "虚构完整消息", renderedText: "虚构完整消息", anchor: anchor)
        model.acceptCapture(capture); model.saveCapture(note: "原备注")
        let mark = model.marks[0]
        check(model.edit(mark, note: String(repeating: "字", count: 4001)) != nil && model.marks[0] == mark, "备注超长时失败且原备注保持原样")
        let other = MarkRepository(directory: root); _ = try other.load(); try other.save([])
        check(model.edit(mark, note: "未保存草稿") != nil && model.marks[0] == mark, "外部写入冲突时编辑返回错误而非假成功")
        model.reload(); model.acceptCapture(capture); model.saveCapture(note: "恢复原备注")
        let fresh = model.marks[0]
        model.acceptCapture(capture)
        check(model.pendingCapture == nil && model.editingMark?.id == fresh.id && model.editingDraft == nil, "重复采集直接进入原备注编辑，不创建第二条记录")
        model.editingMark = nil; model.pendingCapture = capture; model.saveCapture(note: "竞态中的新草稿")
        check(model.pendingCapture == nil && model.editingMark == nil, "重复保存先关闭采集框，避免同时弹出两个编辑框")
        model.captureSheetDismissed()
        check(model.editingMark?.id == fresh.id && model.editingDraft == "竞态中的新草稿" && model.marks.count == 1, "保存时发现重复仍保留用户新输入")
        model.editingMark = nil; model.delete(fresh)
        check(model.marks.isEmpty && model.canUndoDeletion, "删除成功后提供撤销")
        model.undoDeletion()
        check(model.marks == [fresh] && !model.canUndoDeletion, "撤销删除恢复原身份和原备注")
        model.startCapture(showPanel: false) { progress in
            progress(.reading); try await Task.sleep(nanoseconds: 5_000_000_000); return capture
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        check(model.capturing && model.status == CaptureProgress.reading.rawValue, "采集期间显示实际阶段")
        model.cancelCapture()
        for _ in 0..<100 where model.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        check(!model.busy && !model.capturing && model.pendingCapture == nil && model.status == "已取消保存", "取消采集不弹备注框并恢复可操作状态")
        let restoreBytes = try MarkRepository.encode([fresh])
        let expected = try model.repository.diskData()
        try await model.restore(restoreBytes, expected: expected)
        check(model.marks == [fresh] && !model.busy && model.writable, "后台恢复完成后模型与磁盘一致并恢复可操作状态")
        check(model.edit(fresh, note: "后台恢复后的编辑") == nil, "后台恢复更新同一存储修订，后续编辑不会误报冲突")
        do { try await model.restore(restoreBytes, expected: expected); preconditionFailure("stale restore accepted") }
        catch {}
        check(!model.busy && model.marks.first?.note == "后台恢复后的编辑", "恢复修订过期明确失败且解除忙碌状态，不覆盖新备注")
        print("\(count) model checks passed")
    }
}
