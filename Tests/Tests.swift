// Copyright (C) 2026 BigFat-Dev
// SPDX-License-Identifier: MIT
import Foundation
import AppKit

@main
struct TestMain {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ truth: Bool, _ description: String) {
            guard truth else { fatalError("FAIL: \(description)") }
            count += 1; print("PASS: \(description)")
        }
        func expectFailure(_ description: String, _ operation: () throws -> Void) {
            do { try operation(); fatalError("FAIL: \(description)") } catch { count += 1; print("PASS: \(description)") }
        }
        func pointProbe(_ node: PointFixtureNode, deadline: Date = Date().addingTimeInterval(1), limit: Int = 650) -> PointFixtureNode? {
            pointTextNode(from: node, at: CGPoint(x: 25, y: 25), until: deadline, maximum: limit,
                key: { _ in 0 }, same: { $0 === $1 }, blocked: { $0.blocked }, bounds: { $0.frame },
                children: { distinctPointChildren([$0.visible, $0.contents, $0.ordinary], same: { $0 === $1 }) },
                readable: { $0.readable })
        }
        let visibleText = PointFixtureNode(readable: true)
        let visibleArea = PointFixtureNode(); visibleArea.visible = [visibleText]
        check(pointProbe(visibleArea) === visibleText, "普通子项为空时仍从可见子项找到指针下的只读文字")
        let contentText = PointFixtureNode(readable: true)
        let contentArea = PointFixtureNode(); contentArea.contents = [contentText]
        check(pointProbe(contentArea) === contentText, "滚动区仅暴露内容子项时仍可发现候选正文")
        let firstText = PointFixtureNode(readable: true), otherText = PointFixtureNode(readable: true)
        check(distinctPointChildren([[firstText], [firstText, otherText], [otherText]], same: { $0 === $1 }).count == 2,
              "多个辅助功能关系的重复节点只保留一次且不合并不同身份")
        let cycle = PointFixtureNode(); cycle.ordinary = [cycle, visibleText]
        check(pointProbe(cycle) === visibleText, "循环关系不耗尽扫描预算，哈希碰撞不丢失真正文字节点")
        let blockedArea = PointFixtureNode(); blockedArea.blocked = true; blockedArea.contents = [visibleText]
        check(pointProbe(blockedArea) == nil, "可编辑输入或按钮的后代不能作为消息正文候选")
        let outside = PointFixtureNode(readable: true); outside.frame = CGRect(x: 100, y: 100, width: 20, height: 20)
        let geometryArea = PointFixtureNode(); geometryArea.visible = [outside]; geometryArea.ordinary = [contentText]
        check(pointProbe(geometryArea) === contentText, "屏幕其他位置的文字不替代原指针下文字")
        let missingFrame = PointFixtureNode(readable: true); missingFrame.frame = nil
        check(pointProbe(PointFixtureNode()) == nil && pointProbe(missingFrame) == nil, "容器或缺少文字坐标时不猜测候选")
        check(pointProbe(visibleArea, deadline: Date().addingTimeInterval(-1)) == nil,
              "候选扫描超时只返回未找到，不冒充核验通过")
        check(pointProbe(visibleArea, limit: 1) == nil, "候选节点预算耗尽时不越界读取后代")
        let threadID = "11111111-1111-4111-8111-111111111111"
        check(ShortcutAvailability.message(mark: true, panel: true) == nil, "正常快捷键不显示冲突警告")
        check(ShortcutAvailability.message(mark: false, panel: true)?.contains("保存快捷键") == true && ShortcutAvailability.message(mark: true, panel: false)?.contains("面板快捷键") == true, "快捷键冲突准确指出不可用的入口")
        let bodyIssue = ReturnIssue("最终核验无法确认完整消息，未高亮。结构诊断（不含正文）：AXGroup 节点 12。")
        check(!bodyIssue.summary.contains("AXGroup") && bodyIssue.details.contains("AXGroup") && !bodyIssue.recovery.isEmpty, "返回失败把诊断留在详情，并给出下一步")
        check(ReturnIssue("当前构建未获得系统辅助功能权限").offersSettings, "权限失败提供设置入口")
        check(ReturnIssue("当前剪贴板超过保护容量").recovery.contains("妥善保存"), "剪贴板保护失败提供对应处理方法")
        check(ReturnIssue("原消息作者或内容已改变，停止定位。").summary.contains("已被修改"), "原文变化不误报可安全重试")
        check(ReturnIssue("定位片段已出现在其他消息中").summary.contains("无法安全返回"), "重复位置不建议跳到相似结果")
        var framing = NewlineFramer()
        check(try framing.append(Data("first".utf8)).isEmpty, "分块响应不提前解析未结束的记录")
        let framed = try framing.append(Data("\nsecond\npar".utf8))
        let lastFrame = try framing.append(Data("tial\n".utf8))
        check(framed == [Data("first".utf8), Data("second".utf8)] && lastFrame == [Data("partial".utf8)], "多记录与跨块残余的响应边界完整保留")
        var unicodeFraming = NewlineFramer()
        let rawFrame = Data((String(repeating: "测试😀", count: 800) + "\n").utf8)
        var collected = [Data]()
        for byte in rawFrame { collected.append(contentsOf: try unicodeFraming.append(Data([byte]))) }
        check(collected == [Data(rawFrame.dropLast())] && unicodeFraming.inspectedBytes == rawFrame.count, "UTF8 任意字节分块仍原样恢复，每字节仅扫描一次")
        expectFailure("响应缓冲超过上限明确停止") { var bounded = NewlineFramer(limit: 3); _ = try bounded.append(Data("1234".utf8)) }
        let link = "codex://threads/\(threadID)"
        check(try canonicalThreadLink(link).1 == threadID, "官方本地对话链接解析")
        for bad in ["codex://threads/new", "https://example.com", "codex://threads/\(threadID)?prompt=hello", "codex://threads/\(threadID)/other", "codex://threads/not-an-id"] {
            expectFailure("拒绝非规范链接：\(bad)") { _ = try canonicalThreadLink(bad) }
        }
        check(parseUniqueCounter("1 / 1") == true, "唯一查找结果")
        check(parseUniqueCounter("1 of 2") == false, "多结果拒绝")
        check(parseUniqueCounter("0 / 0") == false, "零结果拒绝")
        check(parseUniqueCounter("这是 1/1 的其他正文") == nil, "正文数字不冒充查找计数")
        check(parseUniqueCounter("共很多条") == nil, "未知计数格式停止")
        check(parseCounterFragments(["上一项", "1", "/", "1", "下一项"]) == [true], "分成多个控件的唯一查找计数")
        check(parseCounterFragments(["1", "of", "2"]) == [false], "拆分的多结果计数仍拒绝")
        check(parseCounterFragments(["1 / 1", "1 / 2"]).count == 2, "多个计数证据不冒充唯一计数")
        check(parseCounterFragments(["查找", "上一项", "下一项"]).isEmpty, "没有计数时不猜测成功")
        check(isCounterFragment("1 / 1") && isCounterFragment("1 of") && isCounterFragment("of"), "非标准文字控件仅接受计数片段")
        check(!isCounterFragment("正文里有1/1") && !isCounterFragment("查找工具栏"), "正文和通用控件描述不压制计数子节点")
        let unicodeSamples = ["中文定位", "é", "e\u{301}", "İ", "i", "ß", "ss", "Σ", "σ", "ς", "한", "😀", "👩‍💻", "👩", "Aa", "a", "A", "\u{301}"]
        check(unicodeSamples.allSatisfy { source in unicodeSamples.allSatisfy { needle in locatorPresent(needle, in: source) == (source.range(of: needle, options: .caseInsensitive) != nil) } }, "快速匹配保留原有 Unicode、组合字符和大小写语义")
        check(normalized(plainMarkdown("# 标题\n\n正文 **重点** 内容\n\n- 第一项\n- 第二项")) == "标题 正文 重点 内容 第一项 第二项", "标题段落和列表保留渲染文字边界")
        check(normalized(plainMarkdown("普通\n\n另一段")) == "普通 另一段", "多段正文不被连成错误单词")
        check(normalized(plainMarkdown("```swift\nlet a = 1\nlet b = 2\n```")) == "let a = 1 let b = 2", "代码块保持完整内容")
        check(occurrenceCount("片段", in: "片段在同一消息中再次出现片段") == 2, "同一消息内重复定位片段不冒充唯一结果")
        check(occurrenceCount("aaa", in: "aaaa") == 2, "重叠定位片段视为不唯一")
        check(fullBodyRanges(in: ["AI 回复", "标题", "第一段", "第二段", "23:50"], expected: "标题\n第一段\n第二段") == [1..<4], "混合容器仅圈定完整消息文字范围")
        check(fullBodyRanges(in: ["Hel", "lo", "world"], expected: "Hello world") == [0..<3], "行内拆分和段落边界同时核验")
        check(fullBodyRanges(in: ["前一条消息 整条正文 后一条消息"], expected: "整条正文").isEmpty, "不把大节点中的子串冒充消息范围")
        check(fullBodyRanges(in: ["第一段"], expected: "第一段 第二段").isEmpty, "正文缺少后半段停止")
        check(fullBodyRanges(in: ["第二段"], expected: "第一段 第二段").isEmpty, "正文缺少前半段停止")
        check(fullBodyRanges(in: ["第一段", "未知文字", "第二段"], expected: "第一段 第二段").isEmpty, "不跳过正文中未核验的文字")
        check(fullBodyRanges(in: ["整条正文", "另一条", "整条正文"], expected: "整条正文").count == 2, "相同完整正文范围重复时不唯一")
        check(fullBodyRanges(in: ["原文中的 空格"], expected: "原文中的空格").isEmpty, "不消除正文节点内部有意义的空格")
        let text = "点击备注后，直接返回原对话的准确消息位置。"
        let original = StoredMessage(turnID: "turn-original", itemID: "message-original", role: "assistant", text: text)
        let sameTextOtherMessage = StoredMessage(turnID: "turn-other", itemID: "message-other", role: "assistant", text: text)
        let anchor = NativeAnchor(version: 2, kind: "native-deep-link+verified-find+full-body", conversationLink: link, conversationID: threadID, turnID: original.turnID, itemID: original.itemID, role: original.role, searchPhrase: text, bodySHA256: digest(text), axIdentifier: nil, precision: "test")
        let capture = Capture(title: "虚构对话", fullText: text, renderedText: text, anchor: anchor)
        let mark = try capture.makeMark(note: "定位测试")
        try verifyUniqueLocator(mark, in: StoredConversation(id: threadID, title: "虚构对话", messages: [original]))
        check(true, "当前原消息的定位片段仍唯一")
        expectFailure("工具输出中完整引用原文时停止返回") { try verifyUniqueLocator(mark, in: StoredConversation(id: threadID, title: "虚构对话", messages: [original], otherItemTexts: ["工具输出前缀\n" + text + "\n后缀"])) }
        try verifyUniqueLocator(mark, in: StoredConversation(id: threadID, title: "虚构对话", messages: [original], otherItemTexts: ["与此标记无关的工具结果"]))
        check(true, "无关工具结果不阻止原消息定位")
        let parts: [String: Any] = ["type": "toolOutput", "content": [["text": "点击备注后，直接返回"], ["text": "原对话的准确消息位置。"]]]
        expectFailure("多段工具输出拼接后重复完整原文仍拒绝") { try verifyUniqueLocator(mark, in: StoredConversation(id: threadID, title: "虚构对话", messages: [original], otherItemTexts: HistoryReader.publicItemStrings(parts))) }
        let richOriginal = StoredMessage(turnID: "turn-rich", itemID: "rich", role: "assistant", text: "原文中的 **关键结论** 必须核验")
        let richAnchor = NativeAnchor(version: 2, kind: anchor.kind, conversationLink: link, conversationID: threadID, turnID: richOriginal.turnID, itemID: richOriginal.itemID, role: "assistant", searchPhrase: "关键结论", bodySHA256: digest(richOriginal.rendered), axIdentifier: nil, precision: "test")
        let richMark = try Capture(title: "虚构对话", fullText: richOriginal.text, renderedText: richOriginal.rendered, anchor: richAnchor).makeMark(note: "虚构")
        expectFailure("工具输出的不同 Markdown 渲染出相同全文仍拒绝") { try verifyUniqueLocator(richMark, in: StoredConversation(id: threadID, title: "虚构对话", messages: [richOriginal], otherItemTexts: ["原文中的 __关键结论__ 必须核验"])) }
        expectFailure("新增相同正文后不因界面只加载一个副本而误跳") { try verifyUniqueLocator(mark, in: StoredConversation(id: threadID, title: "虚构对话", messages: [original, sameTextOtherMessage])) }
        try verifyStoredIdentity(mark, in: StoredConversation(id: threadID, title: "同标题", messages: [original, sameTextOtherMessage]))
        check(true, "重复正文时仍按消息身份核验")
        expectFailure("原消息删除后不跳到相同正文的另一条消息") { try verifyStoredIdentity(mark, in: StoredConversation(id: threadID, title: "同标题", messages: [sameTextOtherMessage])) }
        expectFailure("同标题其他对话拒绝") { try verifyStoredIdentity(mark, in: StoredConversation(id: "22222222-2222-4222-8222-222222222222", title: "同标题", messages: [original])) }
        let changed = StoredMessage(turnID: original.turnID, itemID: original.itemID, role: original.role, text: text + "已修改")
        expectFailure("原消息修改停止") { try verifyStoredIdentity(mark, in: StoredConversation(id: threadID, title: "同标题", messages: [changed])) }
        let changedRole = StoredMessage(turnID: original.turnID, itemID: original.itemID, role: "user", text: text)
        expectFailure("作者变化停止") { try verifyStoredIdentity(mark, in: StoredConversation(id: threadID, title: "同标题", messages: [changedRole])) }
        expectFailure("相同消息身份重复停止") { try verifyStoredIdentity(mark, in: StoredConversation(id: threadID, title: "同标题", messages: [original, original])) }
        expectFailure("过长备注停止") { _ = try capture.makeMark(note: String(repeating: "a", count: 4001)) }
        check(!phraseCandidates(text).isEmpty, "自动构造定位片段")
        let rendering = TextRenderingCache(byteLimit: 1024, entryLimit: 2)
        _ = rendering.rendered("第一份 **原文**"); _ = rendering.rendered("第一份 **原文**")
        check(rendering.renderCount == 1, "相同原始字节复用渲染转换")
        _ = rendering.rendered("第一份 **原文** 已改")
        check(rendering.renderCount == 2, "原文改变必须重新转换")
        _ = rendering.rendered("第三份"); _ = rendering.rendered("第一份 **原文**")
        check(rendering.renderCount == 4, "有界转换缓存淘汰后可重新计算")
        let zeroCache = TextRenderingCache(byteLimit: 1)
        _ = zeroCache.rendered("大于上限"); _ = zeroCache.rendered("大于上限")
        check(zeroCache.renderCount == 2, "超过内存预算不保留转换结果")
        let unicodeCache = TextRenderingCache()
        _ = unicodeCache.rendered("é"); _ = unicodeCache.rendered("e\u{301}")
        check(unicodeCache.renderCount == 2, "转换键使用原始 UTF8 字节而非规范等价文字")
        let ring = BoundedMatchCache<String>(capacity: 3)
        ring.insert(false, for: "a"); ring.insert(true, for: "b"); ring.insert(false, for: "c")
        ring.insert(true, for: "d"); ring.insert(false, for: "e")
        check(ring.value(for: "a") == nil && ring.value(for: "b") == nil && ring.value(for: "c") == false && ring.value(for: "d") == true && ring.value(for: "e") == false, "环形查询缓存跨越容量后保留正确的阳性和阴性事实")
        ring.insert(true, for: "c"); ring.insert(true, for: "f")
        check(ring.value(for: "c") == nil && ring.value(for: "d") == true && ring.value(for: "f") == true, "更新已有查询不破坏环形淘汰顺序")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let renamedHost = URL(fileURLWithPath: "/Users/fixture/Applications/Codex Renamed.app")
        let oldHost = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let hostCLI = renamedHost.appendingPathComponent(HostExecutable.component)
        let resolverIdentity: (URL) -> String? = { $0 == renamedHost || $0 == oldHost ? HostExecutable.bundleID : "other.application" }
        check(try HostExecutable.resolve(override: nil, runningBundles: [renamedHost], installedBundle: oldHost, identity: resolverIdentity, executable: { $0 == hostCLI.path }) == hostCLI, "改名或位于用户目录的运行宿主按实际位置发现组件")
        check(try HostExecutable.resolve(override: nil, runningBundles: [], installedBundle: renamedHost, identity: resolverIdentity, executable: { $0 == hostCLI.path }) == hostCLI, "无运行副本时通过系统登记位置发现宿主")
        expectFailure("多个不同位置的运行宿主不猜测组件") { _ = try HostExecutable.resolve(override: nil, runningBundles: [renamedHost, oldHost], installedBundle: oldHost, identity: resolverIdentity, executable: { _ in true }) }
        expectFailure("运行宿主组件缺失时不混用另一副本") { _ = try HostExecutable.resolve(override: nil, runningBundles: [renamedHost], installedBundle: oldHost, identity: resolverIdentity, executable: { $0.hasPrefix(oldHost.path) }) }
        expectFailure("宿主bundle身份不符时不执行组件") { _ = try HostExecutable.resolve(override: nil, runningBundles: [URL(fileURLWithPath: "/Other.app")], installedBundle: nil, identity: resolverIdentity, executable: { _ in true }) }
        expectFailure("显式但无效的开发路径不静默回退") { _ = try HostExecutable.resolve(override: "/missing", runningBundles: [renamedHost], installedBundle: oldHost, identity: resolverIdentity, executable: { _ in false }) }
        check(try HostExecutable.resolve(override: "/fixture/official-codex", runningBundles: [], installedBundle: nil, executable: { _ in true }).path == "/fixture/official-codex", "显式开发覆盖继续支持虚构服务和自选组件")
        var fakeTime = 10.0
        let performance = ReturnPerformance(clock: { fakeTime })
        fakeTime = 12; performance.transition(.historyFirst)
        performance.recordAX(seconds: 0.2, cannotComplete: true)
        fakeTime = 17; performance.transition(.bodyFirst)
        fakeTime = 20
        let report = performance.finish(completed: false)
        check(report.elapsedSeconds == 10 && report.stages["prepare"]?.seconds == 2 && report.stages["historyFirst"]?.seconds == 5 && report.stages["bodyFirst"]?.seconds == 3, "阶段计时覆盖总耗时与未完成阶段")
        check(report.stages["historyFirst"]?.axCalls == 1 && report.stages["historyFirst"]?.axCannotComplete == 1 && report.stages["historyFirst"]?.axSeconds == 0.2, "辅助功能计数与耗时归入当前阶段")
        let metricsRoot = root.appendingPathComponent("numeric-performance")
        try ReturnPerformance.save(report, directory: metricsRoot)
        let encoded = try Data(contentsOf: metricsRoot.appendingPathComponent("last-return-performance.json"))
        let metricObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        check(Set(metricObject.keys) == ["formatVersion", "completed", "elapsedSeconds", "stages"], "本地诊断仅保存固定结构与数字，不接受正文标识或备注")
        let repo = MarkRepository(directory: root)
        check(try repo.load().isEmpty, "初次本地记录为空")
        try repo.save([mark])
        let reboot = MarkRepository(directory: root)
        check(try reboot.load() == [mark], "重启恢复消息身份、原文、备注与定位信息")
        var edited = mark; edited.note = "修改后备注"; edited.updatedAt = Date()
        try reboot.save([edited]); let afterEdit = MarkRepository(directory: root)
        check(try afterEdit.load().first?.note == "修改后备注", "备注修改持久化")
        expectFailure("旧实例不覆盖新记录") { try repo.save([]) }
        try afterEdit.save([]); let afterDelete = MarkRepository(directory: root)
        check(try afterDelete.load().isEmpty, "删除持久化")
        let corrupted = root.appendingPathComponent("corrupt"); try FileManager.default.createDirectory(at: corrupted, withIntermediateDirectories: true)
        let badFile = corrupted.appendingPathComponent("bookmarks.json"), badData = Data("broken".utf8); try badData.write(to: badFile)
        expectFailure("损坏文件读取报错") { _ = try MarkRepository(directory: corrupted).load() }
        check(try Data(contentsOf: badFile) == badData, "损坏原文件不覆盖")
        let safe = MarkRepository(directory: root.appendingPathComponent("backup-check"))
        _ = try safe.load(); try safe.save([mark]); try safe.save([edited])
        let snapshots = try FileManager.default.contentsOfDirectory(at: safe.backupsDirectory, includingPropertiesForKeys: nil)
        check(try snapshots.contains { try MarkRepository.decode(Data(contentsOf: $0)) == [mark] }, "修改前自动备份原记录")
        let revision = try safe.diskData()
        expectFailure("损坏备份不能覆盖现有数据") { _ = try safe.restore(Data("bad".utf8), expected: revision) }
        check(try safe.diskData() == revision, "恢复失败保留当前文件原样")
        _ = try safe.restore(MarkRepository.encode([mark]), expected: revision)
        check(try safe.load() == [mark], "恢复有效备份保留完整消息身份")
        expectFailure("恢复确认后发生外部修改时拒绝覆盖") { _ = try safe.restore(MarkRepository.encode([]), expected: revision) }
        for index in 0..<23 { var item = mark; item.note = "虚构备份\(index)"; try safe.save([item]) }
        check(try FileManager.default.contentsOfDirectory(at: safe.backupsDirectory, includingPropertiesForKeys: nil).count == 20, "自动备份保留最近二十份，不无限增长")
        let legacyDirectory = root.appendingPathComponent("legacy"), destination = root.appendingPathComponent("fixed-data")
        let legacy = MarkRepository(directory: legacyDirectory); _ = try legacy.load(); try legacy.save([mark])
        let originalBytes = try legacy.diskData()
        _ = try LocalDataLocation.resolve(legacyDirectory: legacyDirectory, destination: destination)
        let migrated = MarkRepository(directory: destination)
        check(try migrated.load() == [mark] && legacy.diskData() == originalBytes, "首次迁移保留身份并原样保留旧文件")
        try migrated.save([edited])
        _ = try LocalDataLocation.resolve(legacyDirectory: legacyDirectory, destination: destination)
        check(try MarkRepository(directory: destination).load() == [edited], "再次启动不会用旧文件覆盖新数据")
        let emptyTarget = root.appendingPathComponent("bad-migration")
        expectFailure("旧文件损坏时迁移停止") { _ = try LocalDataLocation.resolve(legacyDirectory: corrupted, destination: emptyTarget) }
        check(!FileManager.default.fileExists(atPath: emptyTarget.appendingPathComponent("bookmarks.json").path), "损坏迁移不会创建空档案冒充成功")
        let damagedStore = MarkRepository(directory: root.appendingPathComponent("recovery"))
        try FileManager.default.createDirectory(at: damagedStore.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try badData.write(to: damagedStore.url)
        _ = try damagedStore.restore(MarkRepository.encode([mark]), expected: badData)
        check(try damagedStore.load() == [mark], "当前档案损坏时仍可明确恢复有效备份")
        let damagedBackups = try FileManager.default.contentsOfDirectory(at: damagedStore.backupsDirectory, includingPropertiesForKeys: nil)
        check(try damagedBackups.contains { try Data(contentsOf: $0) == badData }, "修复损坏档案前仍保留原始损坏文件")
        let largeBackup = root.appendingPathComponent("large-valid-backup.json")
        var largeData = try MarkRepository.encode([mark])
        largeData.append(Data(repeating: 0x20, count: 65 * 1024 * 1024))
        try largeData.write(to: largeBackup); largeData = Data()
        let prepared = try await Task.detached { try PreparedBackup.read(largeBackup) }.value
        check(prepared.data.count > 64 * 1024 * 1024 && prepared.count == 1, "超过64MiB的有效备份后台读取及完整校验不再拒绝")
        let largeStore = MarkRepository(directory: root.appendingPathComponent("large-restored"))
        _ = try largeStore.restore(prepared.data, expected: nil)
        check(try largeStore.load() == [mark], "超过64MiB的有效备份恢复后身份正文备注均保留")
        expectFailure("后台读取损坏备份明确失败") { _ = try PreparedBackup.read(badFile) }
        let privatePasteboard = NSPasteboard.withUniqueName()
        defer { privatePasteboard.releaseGlobally() }
        let richItem = NSPasteboardItem(); richItem.setString("虚构原始文字", forType: .string); richItem.setData(Data("fake-rich-data".utf8), forType: .rtf)
        privatePasteboard.clearContents(); privatePasteboard.writeObjects([richItem])
        let lease = try ClipboardLease(privatePasteboard)
        privatePasteboard.clearContents(); privatePasteboard.setString(link, forType: .string); lease.own(link)
        check(lease.restoreIfOwned() && privatePasteboard.string(forType: .string) == "虚构原始文字" && privatePasteboard.data(forType: .rtf) == Data("fake-rich-data".utf8), "取得链接后恢复原剪贴板的文字与富格式")
        let changedLease = try ClipboardLease(privatePasteboard)
        privatePasteboard.clearContents(); privatePasteboard.setString(link, forType: .string); changedLease.own(link)
        privatePasteboard.clearContents(); privatePasteboard.setString("用户随后新复制的虚构内容", forType: .string)
        check(!changedLease.restoreIfOwned() && privatePasteboard.string(forType: .string) == "用户随后新复制的虚构内容", "剪贴板版本变化时不恢复旧内容")
        privatePasteboard.clearContents()
        let emptyLease = try ClipboardLease(privatePasteboard)
        privatePasteboard.setString(link, forType: .string); emptyLease.own(link)
        check(emptyLease.restoreIfOwned() && (privatePasteboard.pasteboardItems ?? []).isEmpty, "原剪贴板为空时恢复为空")
        privatePasteboard.clearContents(); privatePasteboard.setString("取消前虚构内容", forType: .string)
        let coordinator = ClipboardCoordinator()
        let cancelledCopy = Task { @MainActor in
            try await coordinator.copyThreadLink(from: privatePasteboard, issueCopy: {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    privatePasteboard.clearContents(); privatePasteboard.setString(link, forType: .string)
                }
            }, verifyForeground: {}, interval: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 10_000_000); cancelledCopy.cancel()
        do { _ = try await cancelledCopy.value; fatalError("FAIL: cancelled copy") } catch {}
        check(privatePasteboard.string(forType: .string) == "取消前虚构内容" && coordinator.recovery == nil, "取消早于宿主复制完成仍等待结果并恢复原剪贴板")
        do {
            _ = try await coordinator.copyThreadLink(from: privatePasteboard, issueCopy: {
                privatePasteboard.clearContents(); privatePasteboard.setString(link, forType: .string)
            }, verifyForeground: { throw RecallFailure(message: "虚构焦点切换") }, interval: 1_000_000)
            fatalError("FAIL: focus change")
        } catch {}
        check(privatePasteboard.string(forType: .string) == "取消前虚构内容", "复制完成后焦点变化仍先接管并恢复原剪贴板")
        do {
            _ = try await coordinator.copyThreadLink(from: privatePasteboard, issueCopy: {
                privatePasteboard.clearContents(); privatePasteboard.setString("非链接新内容", forType: .string)
            }, verifyForeground: {}, interval: 1_000_000)
            fatalError("FAIL: invalid link")
        } catch {}
        check(coordinator.recovery != nil && privatePasteboard.string(forType: .string) == "非链接新内容", "未知结果不冒充宿主内容，原剪贴板暂存等待用户选择")
        do {
            _ = try await coordinator.copyThreadLink(from: privatePasteboard, issueCopy: { fatalError("Must not issue copy") }, verifyForeground: {})
            fatalError("FAIL: unresolved recovery")
        } catch {}
        check(coordinator.restoreRecovery() && privatePasteboard.string(forType: .string) == "取消前虚构内容", "明确恢复选择可找回复制前内容且不会被下一操作替换")
        privatePasteboard.clearContents(); privatePasteboard.setString("版本快照", forType: .string)
        let revisionLease = try ClipboardLease(privatePasteboard)
        privatePasteboard.clearContents(); privatePasteboard.setString(link, forType: .string)
        let oldRevision = privatePasteboard.changeCount
        privatePasteboard.clearContents(); privatePasteboard.setString("更新后的虚构内容", forType: .string)
        check(!revisionLease.own(link, revision: oldRevision) && !revisionLease.restoreIfOwned(), "读取后版本改变不能误接管或覆盖用户新复制内容")
        let successfulCopy = try await coordinator.copyThreadLink(from: privatePasteboard, issueCopy: {
            privatePasteboard.clearContents(); privatePasteboard.setString(link, forType: .string)
        }, verifyForeground: {}, interval: 1_000_000)
        check(successfulCopy.1 == threadID && privatePasteboard.string(forType: .string) == "更新后的虚构内容" && coordinator.recovery == nil, "正常复制仍返回准确对话身份并自动恢复原内容")
        do {
            _ = try await coordinator.copyThreadLink(from: privatePasteboard, issueCopy: {}, verifyForeground: {}, attempts: 1, interval: 1_000_000)
            fatalError("FAIL: missing copy")
        } catch {}
        check(coordinator.recovery == nil && privatePasteboard.string(forType: .string) == "更新后的虚构内容", "宿主没有复制时不制造恢复记录或改变剪贴板")
        do {
            _ = try await coordinator.copyThreadLink(from: privatePasteboard, issueCopy: {
                privatePasteboard.clearContents(); privatePasteboard.setData(Data([1, 2, 3]), forType: .rtf)
            }, verifyForeground: {}, interval: 1_000_000)
            fatalError("FAIL: nontext copy")
        } catch {}
        check(coordinator.recovery != nil, "非文字复制结果也保留原内容供用户恢复")
        coordinator.discardRecovery()
        check(coordinator.recovery == nil && privatePasteboard.data(forType: .rtf) == Data([1, 2, 3]), "用户选择保留当前内容后释放旧快照而不覆盖新格式")
        check(HistoryReader.message(["type": "userMessage", "id": "m", "content": [["type": "image", "url": "never-read"]]], turnID: "t") == nil, "包含附件的消息不假装文字完整消息")
        let trace = root.appendingPathComponent("fixture-methods.txt")
        setenv("RECALL_FIXTURE_TRACE", trace.path, 1); setenv("RECALL_FIXTURE_LIFECYCLE", "1", 1)
        let reader = HistoryReader()
        let fixture = try await reader.read(threadID)
        check(fixture.id == threadID && fixture.messages.count == 2 && fixture.messages.first?.itemID == "message-original", "真实客户端代码通过受控本地 stdio 接口分页读取")
        let fresh = try await reader.read(threadID)
        check(fresh.messages.first?.text != fixture.messages.first?.text, "复用连接仍重新读取全部分页，不返回旧快照")
        expectFailure("转换缓存命中也不能掩盖原消息已改变") { try verifyStoredIdentity(mark, in: fresh) }
        do { _ = try await reader.read(threadID); fatalError("FAIL: 连接中断必须失败") }
        catch { check(true, "连接中断停止核验，不回退旧历史") }
        let recovered = try await reader.read(threadID)
        check(recovered.messages == fixture.messages, "连接中断后下次主动操作可重新连接")
        let calls = try String(contentsOf: trace).split(separator: "\n")
        check(calls.filter { $0 == "initialize" }.count == 2, "正常重复读取复用初始化，断线仅重建一次连接")
        check(calls.filter { $0 == "thread/items/list" }.count == 6, "每次成功读取仍完整请求全部历史页")
        unsetenv("RECALL_FIXTURE_TRACE"); unsetenv("RECALL_FIXTURE_LIFECYCLE")
        setenv("RECALL_FIXTURE_VERIFY_MODE", "clean", 1)
        let scopedReader = HistoryReader()
        let scoped = try await scopedReader.readIdentity(threadID, turnID: original.turnID, itemID: original.itemID)
        check(scoped.coverage == .singleTurn(original.turnID) && scoped.messages.count == 1, "身份预检只读取目标轮次与原消息")
        try verifyStoredIdentity(mark, in: scoped)
        check(true, "小范围预检仍核验原消息身份和原文")
        expectFailure("小范围预检不能冒充完整历史唯一性证明") { try verifyUniqueLocator(mark, in: scoped) }
        let proof = try await scopedReader.verifyForReturn(mark)
        check(proof.pages == 2 && proof.records == 2, "流式最终核验读取全部分页")
        let warmProof = try await scopedReader.verifyForReturn(mark)
        check(warmProof.pages == 2 && warmProof.cacheHits > 0 && warmProof.computedProjections == 0, "复用精确源指纹的查询结果仍重新读取所有分页")
        let tinyIndex = HistoryReader(projectionLimit: 1)
        _ = try await tinyIndex.verifyForReturn(mark)
        let evictedProof = try await tinyIndex.verifyForReturn(mark)
        check(evictedProof.pages == 2 && evictedProof.computedProjections > 0, "查询索引淘汰只导致重算，不影响完整核验")
        for mode in ["changed", "deleted", "duplicate", "markup_duplicate", "tool_duplicate", "split_tool_duplicate"] {
            setenv("RECALL_FIXTURE_VERIFY_MODE", mode, 1)
            do { _ = try await HistoryReader().verifyForReturn(mark); fatalError("FAIL: \(mode)") }
            catch { check(true, "流式完整证明拒绝 \(mode)") }
        }
        for mode in ["change_after_third", "append_after_third", "nested_tool_after_third", "reorder_after_third"] {
            setenv("RECALL_FIXTURE_VERIFY_MODE", mode, 1)
            let cachedReader = HistoryReader()
            _ = try await cachedReader.verifyForReturn(mark)
            _ = try await cachedReader.verifyForReturn(mark)
            do { _ = try await cachedReader.verifyForReturn(mark); fatalError("FAIL: \(mode)") }
            catch { check(true, "查询缓存不能掩盖后续变化 \(mode)") }
        }
        setenv("RECALL_FIXTURE_VERIFY_MODE", "field_heavy", 1)
        let recordCache = HistoryReader(projectionLimit: 4)
        let fieldCold = try await recordCache.verifyForReturn(mark)
        let fieldWarm = try await recordCache.verifyForReturn(mark)
        check(fieldCold.computedProjections == 2 && fieldWarm.computedProjections == 0 && fieldWarm.cacheHits == 2 && fieldWarm.pages == 2, "数千元数据字段按整条来源缓存，容量有限仍可完整复用")
        do {
            _ = try await ReadOnlyRPC().call("thread/searchOccurrences", params: [:])
            fatalError("FAIL: 未使用的旧接口不得留在请求白名单")
        } catch {
            check(error.localizedDescription.contains("拒绝非只读接口"), "未使用旧接口在发出请求前被白名单拒绝")
        }
        setenv("RECALL_FIXTURE_VERIFY_MODE", "slow", 1)
        let cancellableRPC = ReadOnlyRPC()
        try await cancellableRPC.start()
        let waiting = Task { try await cancellableRPC.call("thread/items/list", params: ["threadId": threadID]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelStarted = ProcessInfo.processInfo.systemUptime
        waiting.cancel()
        do { _ = try await waiting.value; fatalError("FAIL: cancelled read succeeded") }
        catch is CancellationError { check(ProcessInfo.processInfo.systemUptime - cancelStarted < 0.5, "取消立即解除等待，不必等慢响应或超时") }
        let afterLateReply = try await cancellableRPC.call("thread/read", params: ["threadId": threadID])
        check(afterLateReply["thread"] != nil && afterLateReply["data"] == nil, "取消请求的迟到响应不会交给后续请求")
        let cancelledProof = Task { try await HistoryReader().verifyForReturn(mark) }
        cancelledProof.cancel()
        do { _ = try await cancelledProof.value; fatalError("FAIL: cancelled proof succeeded") }
        catch is CancellationError { check(true, "已取消的完整证明不能返回成功") }
        unsetenv("RECALL_FIXTURE_VERIFY_MODE")
        print("\(count) checks passed")
    }
}

private final class PointFixtureNode {
    var readable: Bool
    var blocked = false
    var frame: CGRect? = CGRect(x: 0, y: 0, width: 50, height: 50)
    var visible = [PointFixtureNode](), contents = [PointFixtureNode](), ordinary = [PointFixtureNode]()
    init(readable: Bool = false) { self.readable = readable }
}
