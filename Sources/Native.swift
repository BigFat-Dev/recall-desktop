// Copyright (C) 2026 BigFat-Dev
// SPDX-License-Identifier: MIT
import AppKit
import ApplicationServices
import Carbon

private var activeReturnPerformance: ReturnPerformance?
private func copyAttribute(_ element: AXUIElement, _ attribute: String, _ result: inout CFTypeRef?) -> AXError {
    let started = ProcessInfo.processInfo.systemUptime
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
    activeReturnPerformance?.recordAX(seconds: ProcessInfo.processInfo.systemUptime - started, cannotComplete: status == .cannotComplete)
    return status
}
private func elementAtPosition(_ point: CGPoint) -> (AXError, AXUIElement?) {
    let started = ProcessInfo.processInfo.systemUptime
    var hit: AXUIElement?
    let status = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
    activeReturnPerformance?.recordAX(seconds: ProcessInfo.processInfo.systemUptime - started, cannotComplete: status == .cannotComplete)
    return (status, hit)
}
private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard copyAttribute(element, attribute, &result) == .success else { return nil }
    return result
}
private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
private func text(_ element: AXUIElement) -> String {
    for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let string = value(element, key) as? String, !string.isEmpty { return string }
    }
    return ""
}
private func isEditableInput(_ element: AXUIElement, knownRole: String? = nil) -> Bool {
    let role = knownRole ?? (value(element, kAXRoleAttribute) as? String ?? "")
    guard role == kAXTextAreaRole || role == kAXTextFieldRole else { return false }
    if value(element, kAXSubroleAttribute) as? String == "AXSecureTextField" { return true }
    if value(element, "AXEditable") as? Bool == true { return true }
    var editable = DarwinBoolean(false)
    let started = ProcessInfo.processInfo.systemUptime
    let result = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &editable)
    activeReturnPerformance?.recordAX(seconds: ProcessInfo.processInfo.systemUptime - started, cannotComplete: result == .cannotComplete)
    // Unknown input mutability is rejected, rather than risking a composer field.
    return result != .success || editable.boolValue
}
private func isReadableBodyText(_ element: AXUIElement, knownRole: String? = nil) -> Bool {
    let role = knownRole ?? (value(element, kAXRoleAttribute) as? String ?? "")
    return role == kAXStaticTextRole || ([kAXTextAreaRole, kAXTextFieldRole].contains(role) && !isEditableInput(element, knownRole: role))
}
// Candidate discovery only. The final complete-body/history proof is unchanged.
// Generic traversal lets synthetic tests exercise scroll-content-only nodes,
// overlapping branches, cycles and blocked inputs without inspecting a host.
func pointTextNode<Node>(from root: Node, at point: CGPoint, until deadline: Date,
                         maximum: Int = 650, maximumDepth: Int = 35,
                         key: (Node) -> Int, same: (Node, Node) -> Bool,
                         blocked: (Node) -> Bool, bounds: (Node) -> CGRect?,
                         children: (Node) -> [Node], readable: (Node) -> Bool) -> Node? {
    var count = 0, seen = [Int: [Node]]()
    func descend(_ node: Node, depth: Int) -> Node? {
        guard count < maximum, depth < maximumDepth, Date() < deadline else { return nil }
        let hash = key(node)
        guard !seen[hash, default: []].contains(where: { same($0, node) }) else { return nil }
        seen[hash, default: []].append(node); count += 1
        guard !blocked(node) else { return nil }
        if let frame = bounds(node), !frame.contains(point) { return nil }
        for child in children(node).prefix(maximum) {
            if let result = descend(child, depth: depth + 1) { return result }
        }
        guard Date() < deadline, readable(node), let frame = bounds(node), frame.contains(point) else { return nil }
        return node
    }
    return descend(root, depth: 0)
}
func distinctPointChildren<Node>(_ groups: [[Node]], same: (Node, Node) -> Bool) -> [Node] {
    var result = [Node]()
    for group in groups {
        for node in group.prefix(650) where !result.contains(where: { same($0, node) }) {
            result.append(node)
            if result.count == 650 { return result }
        }
    }
    return result
}
private final class PointReadDiagnostics {
    var attempts = 0, nodes = 0, ordinary = 0, visible = 0, contents = 0, failed = 0
    var summary: String { "尝试\(attempts)，节点\(nodes)，普通子项\(ordinary)，可见子项\(visible)，内容子项\(contents)，读取失败\(failed)" }
}
private func pointChildren(_ node: AXUIElement, diagnostics: PointReadDiagnostics?) -> [AXUIElement] {
    var groups = [[AXUIElement]]()
    // These are public AX relationships. They only propose leaves under the
    // original pointer; they do not establish complete message boundaries.
    for attribute in [kAXVisibleChildrenAttribute, kAXContentsAttribute, kAXChildrenAttribute] {
        var raw: CFTypeRef?
        let status = copyAttribute(node, attribute, &raw)
        let nodes: [AXUIElement]
        if status == .success, let array = raw as? [AXUIElement] { nodes = array }
        else if status == .success, let element = axElement(raw) { nodes = [element] }
        else {
            if status != .attributeUnsupported && status != .noValue { diagnostics?.failed += 1 }
            nodes = []
        }
        if attribute == kAXChildrenAttribute { diagnostics?.ordinary += nodes.count }
        else if attribute == kAXVisibleChildrenAttribute { diagnostics?.visible += nodes.count }
        else { diagnostics?.contents += nodes.count }
        groups.append(nodes)
    }
    return distinctPointChildren(groups, same: { CFEqual($0, $1) })
}
private func bodyTextAtPoint(_ root: AXUIElement, point: CGPoint, until: Date? = nil,
                             diagnostics: PointReadDiagnostics? = nil) -> AXUIElement? {
    let deadline = min(Date().addingTimeInterval(2), until ?? .distantFuture)
    return pointTextNode(from: root, at: point, until: deadline,
        key: { Int(truncatingIfNeeded: CFHash($0)) }, same: { CFEqual($0, $1) },
        blocked: { node in
            diagnostics?.nodes += 1
            let role = value(node, kAXRoleAttribute) as? String ?? ""
            return [kAXButtonRole, kAXToolbarRole, kAXMenuRole].contains(role) || isEditableInput(node, knownRole: role)
        }, bounds: rect, children: { pointChildren($0, diagnostics: diagnostics) },
        readable: { isReadableBodyText($0) && !normalized(text($0)).isEmpty })
}
private func rect(_ element: AXUIElement) -> CGRect? {
    guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}
private struct NodeSnapshot {
    let nodes: [AXUIElement]
    let texts: [String]
    let complete: Bool
}
private enum ScanPurpose { case body, discovery, findControls }
private func snapshot(_ root: AXUIElement, maximum: Int = 2400, until: Date? = nil, purpose: ScanPurpose = .body, within region: CGRect? = nil) -> NodeSnapshot {
    var nodes = [AXUIElement](), texts = [String](), count = 0, complete = true
    var seen = [CFHashCode: [AXUIElement]]()
    let deadline = min(Date().addingTimeInterval(2), until ?? .distantFuture)
    func walk(_ element: AXUIElement, depth: Int, blocked: Bool) {
        guard Date() < deadline else { complete = false; return }
        if let region, let frame = rect(element), !frame.intersects(region) { return }
        guard count < maximum, depth <= 45, Date() < deadline else { complete = false; return }
        let hash = CFHash(element)
        if seen[hash, default: []].contains(where: { CFEqual($0, element) }) { return }
        seen[hash, default: []].append(element); count += 1
        guard let role = value(element, kAXRoleAttribute) as? String else { complete = false; return }
        let excludedRoles = purpose == .findControls ? [kAXMenuRole] : [kAXButtonRole, kAXToolbarRole, kAXMenuRole]
        let ignored = blocked || isEditableInput(element, knownRole: role) || excludedRoles.contains(role)
        // These subtrees cannot contribute message text; failure in a toolbar or
        // editable composer must not mark the message's own scan incomplete.
        guard !ignored else { return }
        let own: String
        if purpose == .findControls {
            // Counter labels may use AXUnknown/AXGroup rather than StaticText.
            // Only compact, purely numeric counter fragments qualify; arbitrary
            // control descriptions never replace or suppress their children.
            let label = text(element)
            own = isCounterFragment(label) && (rect(element)?.width ?? .infinity) < 160 ? label : ""
        } else { own = isReadableBodyText(element, knownRole: role) ? text(element) : "" }
        if !normalized(own).isEmpty {
            // An accessibility text node's value already contains its inline
            // descendants. Reading both duplicates wrappers and rich text.
            nodes.append(element); texts.append(own)
            if purpose != .discovery { return }
        }
        var children: CFTypeRef?
        let status = copyAttribute(element, kAXChildrenAttribute, &children)
        if status == .success {
            guard let children = children as? [AXUIElement] else { complete = false; return }
            for child in children {
                guard Date() < deadline else { complete = false; break }
                // Stream candidates as they are reached. Pre-filtering every
                // sibling first can exhaust the AX deadline without one result.
                walk(child, depth: depth + 1, blocked: ignored)
                if count >= maximum { complete = false; break }
            }
        } else if status != .attributeUnsupported && status != .noValue { complete = false }
        // Empty nodes are allowed. The complete expected source body must still
        // match; omitting a real paragraph therefore cannot produce success.
    }
    walk(root, depth: 0, blocked: false)
    return NodeSnapshot(nodes: nodes, texts: texts, complete: complete)
}
private func ancestry(_ element: AXUIElement) -> [AXUIElement] {
    var chain = [element], current = element
    for _ in 0..<35 {
        guard let parent = axElement(value(current, kAXParentAttribute)) else { break }
        if chain.contains(where: { CFEqual($0, parent) }) { break }
        chain.append(parent); current = parent
        if value(parent, kAXRoleAttribute) as? String == kAXWindowRole { break }
    }
    return chain
}
private func counterAtScreenPosition(near field: AXUIElement, diagnostics: inout [String], budget: TimeInterval = 2) throws -> Bool? {
    guard let fieldFrame = rect(field) else { return nil }
    var fieldPID: pid_t = 0
    guard AXUIElementGetPid(field, &fieldPID) == .success else { return nil }
    let deadline = Date().addingTimeInterval(budget)
    // Some find bars place the count beside the field; others overlay it at
    // its trailing edge. Query descendants remain explicitly excluded below.
    let xs = [20.0, -24, 36, -48, 8, -72, 52, 76, 100, 132, 164].map { fieldFrame.maxX + $0 }
    let ys = [fieldFrame.midY, fieldFrame.midY - 10, fieldFrame.midY + 10]
    var fragments = [(element: AXUIElement, label: String, frame: CGRect)]()
    var hitCount = 0
    var otherProcessCount = 0, failedHits = 0
    for y in ys {
        for x in xs {
            guard Date() < deadline else { break }
            let point = CGPoint(x: x, y: y)
            let (status, result) = elementAtPosition(point)
            guard status == .success, let hit = result else { failedHits += 1; continue }
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success, pid == fieldPID else { otherProcessCount += 1; continue }
            hitCount += 1
            let chain = ancestry(hit)
            // Never interpret the search query itself as its match count.
            guard !chain.contains(where: { CFEqual($0, field) || isEditableInput($0) }) else { continue }
            for node in chain.prefix(3) {
                guard let bounds = rect(node), bounds.contains(point), bounds.width < 160,
                      abs(bounds.midY - fieldFrame.midY) < 35 else { continue }
                let label = text(node)
                guard isCounterFragment(label) else { continue }
                if let result = parseUniqueCounter(label) {
                    diagnostics = ["屏幕位置命中\(hitCount)，独立计数控件已读取"]
                    return result
                }
                if !fragments.contains(where: { CFEqual($0.element, node) || ($0.frame == bounds && $0.label == label) }) { fragments.append((node, label, bounds)) }
            }
        }
        if Date() >= deadline { break }
    }
    let evidence = parseCounterFragments(fragments.sorted { $0.frame.minX < $1.frame.minX }.map(\.label))
    diagnostics = ["屏幕位置命中\(hitCount)，其他进程\(otherProcessCount)，调用失败\(failedHits)，计数片段\(fragments.count)，计数证据\(evidence.count)"]
    guard evidence.count <= 1 else { throw RecallFailure(message: "查找框旁的计数控件不能唯一核验。") }
    return evidence.first
}
private func findCounterEvidence(near field: AXUIElement, diagnostics: inout [String]) throws -> Bool? {
    guard let fieldFrame = rect(field) else { diagnostics = ["查找框无可读坐标"]; return nil }
    if let direct = try counterAtScreenPosition(near: field, diagnostics: &diagnostics) { return direct }
    let directDiagnostics = diagnostics
    let region = CGRect(x: fieldFrame.minX - 6, y: fieldFrame.minY - 24, width: fieldFrame.width + 252, height: fieldFrame.height + 48)
    let deadline = Date().addingTimeInterval(3)
    diagnostics = directDiagnostics
    for parent in ancestry(field).dropFirst().prefix(6) {
        guard Date() < deadline else { diagnostics.append("局部读取时间上限"); break }
        if value(parent, kAXRoleAttribute) as? String == kAXWindowRole { break }
        let counters = snapshot(parent, maximum: 180, until: deadline, purpose: .findControls, within: region)
        let nearby = zip(counters.nodes, counters.texts).compactMap { node, string -> String? in
            guard let frame = rect(node), abs(frame.midY - fieldFrame.midY) < 35, frame.width < 160,
                  frame.midX >= fieldFrame.minX, frame.midX <= fieldFrame.maxX + 240 else { return nil }
            return string
        }
        let parsed = parseCounterFragments(nearby)
        diagnostics.append("\(value(parent, kAXRoleAttribute) as? String ?? "未知角色")：局部节点\(counters.nodes.count)，完整\(counters.complete ? "是" : "否")，计数证据\(parsed.count)")
        guard counters.complete else { continue }
        guard parsed.count <= 1 else { throw RecallFailure(message: "查找栏附近存在多个计数证据，无法唯一核验。") }
        if let evidence = parsed.first { return evidence }
    }
    return nil
}
private struct VerifiedBody {
    let root: AXUIElement
    let frame: CGRect
    let rendered: String
    let wholeContainer: Bool
}
private func verifiedBody(around leaf: AXUIElement, expected: String, diagnostics: inout [String], until: Date? = nil) -> VerifiedBody? {
    let leafChain = ancestry(leaf)
    let deadline = min(Date().addingTimeInterval(4), until ?? .distantFuture)
    for parent in leafChain {
        guard Date() < deadline else { diagnostics.append("总扫描时间上限"); break }
        let role = value(parent, kAXRoleAttribute) as? String ?? ""
        if role == kAXWindowRole || isEditableInput(parent) || [kAXButtonRole, kAXToolbarRole, kAXMenuRole].contains(role) { break }
        // Nested scroll areas (for example a code block) are not message limits.
        let tree = snapshot(parent, maximum: 2400, until: deadline)
        let ranges = tree.complete ? fullBodyRanges(in: tree.texts, expected: expected) : []
        diagnostics.append("\(role)：节点\(tree.nodes.count)，文字\(normalized(tree.texts.joined(separator: " ")).count)字，完整\(tree.complete ? "是" : "否")，全文匹配\(ranges.count)")
        guard tree.complete, ranges.count == 1, let range = ranges.first,
              let hitIndex = tree.nodes.firstIndex(where: { atom in leafChain.contains(where: { CFEqual($0, atom) }) }),
              range.contains(hitIndex) else { continue }
        let frames = tree.nodes[range].compactMap(rect)
        guard frames.count == range.count, let first = frames.first else { continue }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        return VerifiedBody(root: parent, frame: union, rendered: expected, wholeContainer: range.lowerBound == 0 && range.upperBound == tree.nodes.count)
    }
    return nil
}
private func bodyRoot(around leaf: AXUIElement, expected: String) -> (AXUIElement, CGRect)? {
    var diagnostics = [String]()
    if let body = verifiedBody(around: leaf, expected: expected, diagnostics: &diagnostics) {
        return (body.root, body.frame)
    }
    return nil
}
private func bodyMatches(in tree: NodeSnapshot, expected: String, diagnostics: inout [String], budget: TimeInterval = 6, candidateBudget: TimeInterval = 4, firstCompleteCandidate: Bool = false) -> [(AXUIElement, CGRect)] {
    var bodies = [(AXUIElement, CGRect)]()
    let target = normalized(expected)
    let normalizedTexts = tree.texts.map(normalized)
    let candidates = tree.nodes.indices.filter { !normalizedTexts[$0].isEmpty && target.contains(normalizedTexts[$0]) }.sorted { normalizedTexts[$0].count > normalizedTexts[$1].count }
    let deadline = Date().addingTimeInterval(budget)
    diagnostics.append("候选节点\(tree.nodes.count)，候选扫描完成\(tree.complete ? "是" : "否")，候选\(candidates.count)")
    for index in candidates {
        guard Date() < deadline else { diagnostics.append("核验超时"); return [] }
        let chain = ancestry(tree.nodes[index])
        if bodies.contains(where: { found in chain.contains(where: { CFEqual($0, found.0) }) || ancestry(found.0).contains(where: { CFEqual($0, tree.nodes[index]) }) }) { continue }
        var details = [String]()
        if let match = verifiedBody(around: tree.nodes[index], expected: expected, diagnostics: &details, until: min(deadline, Date().addingTimeInterval(candidateBudget))),
           !bodies.contains(where: { CFEqual($0.0, match.root) && $0.1 == match.frame }) {
            bodies.append((match.root, match.frame))
            if firstCompleteCandidate { return bodies }
        }
        if bodies.isEmpty { diagnostics = Array((diagnostics + details.suffix(2)).suffix(4)) }
        if bodies.count > 1 { break }
    }
    diagnostics.append("完整消息范围\(bodies.count)")
    return bodies
}
private func bodyAtVisiblePoints(in window: AXUIElement, expected: String, ownerPID: pid_t, diagnostics: inout [String], budget: TimeInterval = 6, candidateBudget: TimeInterval = 4) -> (AXUIElement, CGRect)? {
    guard let bounds = rect(window) else { return nil }
    let target = normalized(expected), deadline = Date().addingTimeInterval(budget)
    let step = min(24.0, max(14, bounds.height / 45))
    var ys = [CGFloat](), y = bounds.minY + 64
    while y < bounds.maxY - 24 { ys.append(y); y += step }
    ys.sort { abs($0 - bounds.midY) < abs($1 - bounds.midY) }
    var hits = 0, fragments = 0
    // A paragraph may cover many sample points. Rechecking the same failed
    // paragraph and its ancestors consumes the entire budget on long messages.
    // This set is local to one pass; no text, geometry or proof survives a pass.
    var checkedLeaves = [CFHashCode: [AXUIElement]]()
    for y in ys {
        for fraction in [0.55, 0.40, 0.72, 0.86] {
            guard Date() < deadline else { diagnostics.append("可见位置命中\(hits)，候选\(fragments)，时间上限"); return nil }
            let point = CGPoint(x: bounds.minX + bounds.width * fraction, y: y)
            let (status, result) = elementAtPosition(point)
            guard status == .success, let hit = result else { continue }
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success, pid == ownerPID else { continue }
            hits += 1
            guard let leaf = bodyTextAtPoint(hit, point: point, until: min(deadline, Date().addingTimeInterval(0.25))) else { continue }
            let hash = CFHash(leaf)
            guard !checkedLeaves[hash, default: []].contains(where: { CFEqual($0, leaf) }) else { continue }
            checkedLeaves[hash, default: []].append(leaf)
            let fragment = normalized(text(leaf))
            guard fragment.count >= min(12, target.count), target.contains(fragment),
                  !ancestry(leaf).contains(where: { isEditableInput($0) || [kAXButtonRole, kAXToolbarRole, kAXMenuRole].contains(value($0, kAXRoleAttribute) as? String ?? "") }) else { continue }
            fragments += 1
            var details = [String]()
            if let body = verifiedBody(around: leaf, expected: expected, diagnostics: &details, until: min(deadline, Date().addingTimeInterval(candidateBudget))), body.frame.intersects(bounds) {
                diagnostics.append("可见位置命中\(hits)，整条正文局部完整核验通过")
                return (body.root, body.frame)
            }
        }
    }
    diagnostics.append("可见位置命中\(hits)，候选\(fragments)")
    return nil
}
private func locateVerifiedBody(in window: AXUIElement, expected: String, ownerPID: pid_t, diagnostics: inout [String]) throws -> (AXUIElement, CGRect)? {
    // Discovery may time out on unrelated chat/sidebar branches. It only
    // proposes candidates: verifiedBody still requires a complete local tree
    // and the entire exact source body. Original identity is prechecked; source
    // uniqueness is proven against complete fresh history before highlighting.
    let tree = snapshot(window, purpose: .discovery, within: rect(window))
    // Prefer a locally provable whole body before allowing common fragments
    // to ascend through large chat containers. This has the same candidate
    // semantics as the screen-point fallback: source identity and uniqueness
    // still require the complete fresh history proof, followed by a fresh
    // subtree/coordinate reread. Incomplete or timed-out scans never qualify.
    if let body = bodyMatches(in: tree, expected: expected, diagnostics: &diagnostics, budget: 0.35, candidateBudget: 0.1, firstCompleteCandidate: true).first { return body }
    let bodies = bodyMatches(in: tree, expected: expected, diagnostics: &diagnostics)
    guard bodies.count <= 1 else { throw RecallFailure(message: "已加载区域中完整消息重复，无法核验原位置。") }
    if let body = bodies.first { return body }
    return bodyAtVisiblePoints(in: window, expected: expected, ownerPID: ownerPID, diagnostics: &diagnostics)
}
private func revalidateBody(_ root: AXUIElement, in window: AXUIElement, expected: String) throws -> (AXUIElement, CGRect)? {
    // Reuse a candidate element, never its text or coordinates. Reread the
    // complete local subtree after the fresh history check; a stale AX handle,
    // rerender or incomplete tree falls back to normal discovery.
    guard ancestry(root).contains(where: { CFEqual($0, window) }) else { return nil }
    let tree = snapshot(root)
    guard tree.complete else { return nil }
    let ranges = fullBodyRanges(in: tree.texts, expected: expected)
    guard ranges.count <= 1 else { throw RecallFailure(message: "最终核验发现重复完整正文，已停止高亮。") }
    guard let range = ranges.first else { return nil }
    let frames = tree.nodes[range].compactMap(rect)
    guard frames.count == range.count, let first = frames.first else { return nil }
    return (root, frames.dropFirst().reduce(first) { $0.union($1) })
}

@MainActor
final class DesktopNavigator {
    let clipboard = ClipboardCoordinator()
    private var highlight: NSPanel?
    private var highlightExpiry: DispatchWorkItem?
    private var highlightAppearance = UUID()
    private var generation = UUID()
    private let history = HistoryReader()
    private var activationObserver: NSObjectProtocol?
    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, activated.bundleIdentifier != "com.openai.codex" else { return }
            MainActor.assumeIsolated {
                self?.clearHighlight()
                self?.generation = UUID()
            }
        }
    }
    private func host() throws -> (NSRunningApplication, AXUIElement) {
        guard AXIsProcessTrusted() else { throw RecallFailure(message: "当前构建未获得系统辅助功能权限，尚未读取消息。若 Recall Desktop 开关已经开启，请移除旧项，再添加当前文件夹中的 Recall Desktop.app 并允许。签名切换后，旧项可能仍显示开启。权限不会自动授予。") }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first else { throw RecallFailure(message: "Codex 未运行。无法返回原对话。") }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        // Chromium enables native accessibility when assistive technology asks
        // for the application's public role. Permission alone does not create
        // the renderer tree. Do this before asking for windows or hit testing.
        // https://chromium.googlesource.com/chromium/src/+/master/chrome/browser/chrome_browser_application_mac.mm
        _ = value(app, kAXRoleAttribute)
        return (running, app)
    }
    private func ensureFront(_ running: NSRunningApplication) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier else { throw RecallFailure(message: "当前应用已改变，停止采集或导航。") }
    }
    private func key(_ code: CGKeyCode, flags: CGEventFlags, running: NSRunningApplication, cancelledCleanup: Bool = false) throws {
        if !cancelledCleanup { try Task.checkCancellation() }
        try ensureFront(running)
        guard let source = CGEventSource(stateID: .combinedSessionState), let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { throw RecallFailure(message: "无法调用宿主公开快捷键。") }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    private func pause(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func currentLink(_ running: NSRunningApplication) async throws -> (URL, String) {
        try await clipboard.copyThreadLink(from: .general,
            issueCopy: { try self.key(CGKeyCode(kVK_ANSI_L), flags: [.maskCommand, .maskAlternate], running: running) },
            verifyForeground: { try self.ensureFront(running) })
    }
    func captureAtPointer(onProgress: (CaptureProgress) -> Void = { _ in }) async throws -> Capture {
        try Task.checkCancellation()
        onProgress(.locating)
        let (running, app) = try host(); try ensureFront(running)
        guard let window = axElement(value(app, kAXFocusedWindowAttribute)), let windowRect = rect(window) else { throw RecallFailure(message: "无法读取当前对话窗口。") }
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first else { throw RecallFailure(message: "无法读取屏幕坐标。") }
        let cursor = NSEvent.mouseLocation
        let point = CGPoint(x: cursor.x, y: primary.frame.maxY - cursor.y)
        guard windowRect.contains(point) else { throw RecallFailure(message: "请把指针停在原对话的一条消息正文上，再按保存快捷键。") }
        let pointDiagnostics = PointReadDiagnostics()
        let discoveryDeadline = Date().addingTimeInterval(4)
        var candidate: AXUIElement?, hitRole = "未知角色", hitSubrole = "无"
        var hitEditable = false, lastHitStatus = AXError.success
        // A newly authorized web view may expose its scroll area before its
        // text tree is ready. Retry fresh handles at the original point only.
        for attempt in 0..<24 {
            try Task.checkCancellation(); try ensureFront(running)
            guard let focusedWindow = axElement(value(app, kAXFocusedWindowAttribute)), CFEqual(focusedWindow, window) else {
                throw RecallFailure(message: "采集期间窗口已改变，未读取其他窗口的消息。")
            }
            pointDiagnostics.attempts += 1
            _ = value(focusedWindow, kAXRoleAttribute)
            let attemptDeadline = min(discoveryDeadline, Date().addingTimeInterval(0.45))
            let (status, result) = elementAtPosition(point); lastHitStatus = status
            if status == .success, let hit = result {
                var hitPID: pid_t = 0
                guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == running.processIdentifier else {
                    throw RecallFailure(message: "指针命中的对象不属于 Codex，停止采集。")
                }
                hitRole = value(hit, kAXRoleAttribute) as? String ?? "未知角色"
                hitSubrole = value(hit, kAXSubroleAttribute) as? String ?? "无"
                hitEditable = isEditableInput(hit, knownRole: hitRole)
                if let leaf = bodyTextAtPoint(hit, point: point, until: attemptDeadline, diagnostics: pointDiagnostics)
                    ?? bodyTextAtPoint(focusedWindow, point: point, until: attemptDeadline, diagnostics: pointDiagnostics) {
                    let chain = ancestry(leaf)
                    if let ownerWindow = chain.first(where: { value($0, kAXRoleAttribute) as? String == kAXWindowRole }), !CFEqual(ownerWindow, focusedWindow) {
                        throw RecallFailure(message: "正文节点属于其他窗口，已停止采集。")
                    }
                    guard !chain.contains(where: { isEditableInput($0) || [kAXButtonRole, kAXToolbarRole, kAXMenuRole].contains(value($0, kAXRoleAttribute) as? String ?? "") }) else {
                        throw RecallFailure(message: "指针下对象不是可核验的只读消息正文，未保存。")
                    }
                    candidate = leaf; break
                }
            }
            if Date() >= discoveryDeadline || attempt == 23 { break }
            try await pause(0.16)
        }
        guard let leaf = candidate else {
            throw RecallFailure(message: "当前正文节点仍无法核验（角色：\(hitRole)，子角色：\(hitSubrole)，可编辑：\(hitEditable ? "是或未知" : "否")）。结构诊断（不含正文）：\(pointDiagnostics.summary)，命中状态\(lastHitStatus.rawValue)。未保存局部或近似内容。")
        }
        let fragment = text(leaf)
        guard !normalized(fragment).isEmpty else { throw RecallFailure(message: "指针下的文字无法读取。") }
        let (link, threadID) = try await currentLink(running)
        onProgress(.reading)
        let conversation = try await history.read(threadID)
        try Task.checkCancellation()
        onProgress(.verifying)
        try ensureFront(running)
        let normalizedFragment = normalized(fragment)
        let matches = conversation.messages.filter { $0.normalizedRendered.contains(normalizedFragment) || $0.normalizedText.contains(normalizedFragment) }
        guard matches.count == 1, let selected = matches.first else { throw RecallFailure(message: "无法把指针下的正文唯一对应到原消息。没有按相似度或出现顺序猜测消息。") }
        var diagnostics = [String]()
        let renderedBody = verifiedBody(around: leaf, expected: selected.rendered, diagnostics: &diagnostics)
        var rawDiagnostics = [String]()
        guard let body = renderedBody ?? verifiedBody(around: leaf, expected: selected.text, diagnostics: &rawDiagnostics) else {
            throw RecallFailure(message: "完整消息尚未核验，未保存段落或近似位置。结构诊断（不含正文）：历史正文\(normalized(selected.rendered).count)字；\(diagnostics.suffix(6).joined(separator: "；"))。")
        }
        guard try await currentLink(running).1 == threadID else { throw RecallFailure(message: "采集期间原对话已切换，已停止。") }
        var checkDiagnostics = [String]()
        guard let checked = verifiedBody(around: leaf, expected: body.rendered, diagnostics: &checkDiagnostics) else { throw RecallFailure(message: "保存前完整消息已改变或无法完整读取，停止采集。") }
        let bodyText = checked.rendered
        let queries = phraseCandidates(bodyText)
        guard let query = queries.first(where: { phrase in
            occurrenceCount(phrase, in: bodyText) == 1 &&
            conversation.messages.filter { occurrenceCount(phrase, in: $0.rendered) > 0 || occurrenceCount(phrase, in: $0.text) > 0 }.count == 1
        }) else { throw RecallFailure(message: "原消息没有唯一可查找的片段，无法承诺直接返回。暂不允许保存不可靠的标记。") }
        let anchor = NativeAnchor(version: 2, kind: "native-deep-link+verified-find+full-body", conversationLink: link.absoluteString, conversationID: threadID,
                                  turnID: selected.turnID, itemID: selected.itemID, role: selected.role, searchPhrase: query,
                                  bodySHA256: digest(bodyText), axIdentifier: checked.wholeContainer ? value(checked.root, kAXIdentifierAttribute) as? String : nil,
                                  precision: "官方对话和历史消息 ID；唯一定位片段与完整正文精确核验；无原生消息级深链接")
        try Task.checkCancellation()
        onProgress(.preparing)
        return Capture(title: conversation.title, fullText: selected.text, renderedText: bodyText, anchor: anchor)
    }
    func returnTo(_ mark: Mark, onProgress: (ReturnProgress) -> Void = { _ in }) async throws -> TimeInterval {
        try Task.checkCancellation()
        onProgress(.preparing)
        let started = ProcessInfo.processInfo.systemUptime
        let performance = ReturnPerformance()
        activeReturnPerformance = performance
        var completed = false
        defer {
            let report = performance.finish(completed: completed)
            if activeReturnPerformance === performance { activeReturnPerformance = nil }
            let directory = LocalDataLocation.activeDirectory
            try? ReturnPerformance.save(report, directory: directory)
        }
        try mark.validate()
        let token = UUID(); generation = token; clearHighlight()
        let (running, app) = try host()
        performance.transition(.historyFirst)
        let conversation = try await history.readIdentity(mark.anchor.conversationID, turnID: mark.anchor.turnID, itemID: mark.anchor.itemID)
        try Task.checkCancellation()
        performance.transition(.identityFirst)
        try verifyStoredIdentity(mark, in: conversation)
        guard generation == token else { throw RecallFailure(message: "已取消过时的导航。") }
        performance.transition(.openConversation)
        onProgress(.opening)
        let (link, _) = try canonicalThreadLink(mark.anchor.conversationLink)
        guard NSWorkspace.shared.open(link) else { throw RecallFailure(message: "系统没有打开原对话深链接。") }
        running.activate(options: [])
        var ready = false
        for _ in 0..<10 {
            try await pause(0.3)
            if generation != token { throw RecallFailure(message: "已取消过时导航。") }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier,
               let copied = try? await currentLink(running), copied.1 == mark.anchor.conversationID { ready = true; break }
        }
        guard ready else { throw RecallFailure(message: "宿主没有确认已经打开原对话。未继续查找其他对话。") }
        performance.transition(.nativeFind)
        onProgress(.locating)
        try key(CGKeyCode(kVK_ANSI_F), flags: .maskCommand, running: running)
        try await pause(0.25); try ensureFront(running)
        guard let field = axElement(value(app, kAXFocusedUIElementAttribute)), value(field, kAXRoleAttribute) as? String == kAXTextFieldRole else { throw RecallFailure(message: "宿主未暴露聚焦的对话查找框。未向消息输入框写入内容。") }
        let labels = [kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"].compactMap { value(field, $0) as? String }.joined(separator: " ").lowercased()
        guard labels.contains("search") || labels.contains("find") || labels.contains("查找") || labels.contains("搜索") || labels.contains("寻找") else { throw RecallFailure(message: "无法核验这是对话查找框。未写入任何文字。") }
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, mark.anchor.searchPhrase as CFString) == .success else { throw RecallFailure(message: "无法向宿主对话查找框设置定位片段。") }
        var ownsFind = true
        func closeOwnedFind() throws {
            try ensureFront(running)
            guard generation == token, value(field, kAXValueAttribute) as? String == mark.anchor.searchPhrase else { throw RecallFailure(message: "查找栏已改变，未安全关闭原查找栏。") }
            guard let currentWindow = axElement(value(app, kAXFocusedWindowAttribute)), ancestry(field).contains(where: { CFEqual($0, currentWindow) }) else { throw RecallFailure(message: "查找栏所在窗口已改变，已停止。") }
            if let focused = axElement(value(app, kAXFocusedUIElementAttribute)), !CFEqual(focused, field), !ancestry(focused).contains(where: { CFEqual($0, field) }) {
                guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { throw RecallFailure(message: "未能安全聚焦原查找栏，未发送关闭按键。") }
            }
            try key(CGKeyCode(kVK_Escape), flags: [], running: running, cancelledCleanup: true)
            ownsFind = false
        }
        defer { if ownsFind { try? closeOwnedFind() } }
        try await pause(0.65)
        try key(CGKeyCode(kVK_ANSI_G), flags: .maskCommand, running: running)
        try await pause(0.25)
        performance.transition(.optionalCounter)
        var counterDiagnostics = [String]()
        guard generation == token else { throw RecallFailure(message: "导航已被另一条标记替代。") }
        try ensureFront(running)
        // A missing optional native count is not evidence of failure or success.
        // Stable history identity, a globally unique locator, and a complete
        // visible body must all independently pass below.
        if try counterAtScreenPosition(near: field, diagnostics: &counterDiagnostics, budget: 0.15) == false {
            throw RecallFailure(message: "宿主查找返回多个位置或没有匹配，已停止。不会选择第一个相似结果。")
        }
        performance.transition(.closeFind)
        guard try await currentLink(running).1 == mark.anchor.conversationID, generation == token else { throw RecallFailure(message: "关闭查找栏前原对话发生切换，已停止。") }
        // Native find highlighting changes the accessibility structure. Close our
        // own find UI on both success and failure, then locate the full
        // message using the same structural proof as capture.
        try closeOwnedFind()
        try await pause(0.2)
        performance.transition(.bodyFirst)
        onProgress(.verifying)
        var verifiedCandidate: (AXUIElement, CGRect)?
        var bodyDiagnostics = [String]()
        for _ in 0..<2 {
            guard generation == token else { throw RecallFailure(message: "导航已被替代。") }
            try ensureFront(running)
            guard let currentWindow = axElement(value(app, kAXFocusedWindowAttribute)) else { break }
            bodyDiagnostics = []
            if let (body, frame) = try locateVerifiedBody(in: currentWindow, expected: mark.renderedText, ownerPID: running.processIdentifier, diagnostics: &bodyDiagnostics), let windowRect = rect(currentWindow), windowRect.intersects(frame) {
                // AX identifiers can change on rerender. The authoritative
                // identity is the official thread/turn/item tuple plus raw text.
                verifiedCandidate = (body, frame.intersection(windowRect)); break
            }
            try await pause(0.2)
        }
        guard let candidate = verifiedCandidate, candidate.1.width > 1, candidate.1.height > 1 else { throw RecallFailure(message: "原消息身份已预检、查找栏已关闭，但完整消息位置未核验。结构诊断（不含正文）：\(bodyDiagnostics.suffix(5).joined(separator: "；"))。未显示成功高亮。") }
        guard try await currentLink(running).1 == mark.anchor.conversationID, generation == token else { throw RecallFailure(message: "高亮前原对话发生切换，已停止。") }
        performance.transition(.historySecond)
        let proofWork = try await history.verifyForReturn(mark)
        try Task.checkCancellation()
        performance.recordProof(proofWork)
        performance.transition(.identitySecond)
        try ensureFront(running)
        guard generation == token, try await currentLink(running).1 == mark.anchor.conversationID,
              let currentWindow = axElement(value(app, kAXFocusedWindowAttribute)) else { throw RecallFailure(message: "最终核验期间原对话或导航目标已改变。") }
        performance.transition(.bodyFinal)
        var finalDiagnostics = [String]()
        guard let (body, bodyFrame) = try revalidateBody(candidate.0, in: currentWindow, expected: mark.renderedText) ?? locateVerifiedBody(in: currentWindow, expected: mark.renderedText, ownerPID: running.processIdentifier, diagnostics: &finalDiagnostics), let windowFrame = rect(currentWindow) else { throw RecallFailure(message: "最终核验无法确认完整消息，未高亮。结构诊断（不含正文）：\(finalDiagnostics.suffix(5).joined(separator: "；"))。") }
        var visible = bodyFrame.intersection(windowFrame)
        for ancestor in ancestry(body) where value(ancestor, kAXRoleAttribute) as? String == kAXScrollAreaRole {
            guard let viewport = rect(ancestor) else { throw RecallFailure(message: "无法核验滚动区域的可见位置。") }
            visible = visible.intersection(viewport)
        }
        guard !visible.isNull, visible.width > 1, visible.height > 1 else { throw RecallFailure(message: "目标消息不在可见区域，未高亮。") }
        try ensureFront(running)
        guard generation == token else { throw RecallFailure(message: "高亮显示前导航已取消。") }
        performance.transition(.highlight)
        try Task.checkCancellation()
        onProgress(.highlighting)
        try showHighlight(visible, token: token)
        completed = true
        return ProcessInfo.processInfo.systemUptime - started
    }
    private func clearHighlight() {
        highlightExpiry?.cancel(); highlightExpiry = nil; highlightAppearance = UUID()
        highlight?.orderOut(nil); highlight = nil
    }
    private func showHighlight(_ axFrame: CGRect, token: UUID) throws {
        clearHighlight()
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first else { throw RecallFailure(message: "已定位原消息，但无法取得高亮显示坐标。") }
        let frame = CGRect(x: axFrame.minX - 4, y: primary.frame.maxY - axFrame.maxY - 4, width: axFrame.width + 8, height: axFrame.height + 8)
        let panel = MessageHighlightPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false; panel.canHide = false
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size)); view.wantsLayer = true
        view.layer?.borderWidth = 3; view.layer?.borderColor = NSColor.systemOrange.cgColor; view.layer?.cornerRadius = 8
        view.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.08).cgColor
        panel.contentView = view; highlight = panel; panel.orderFrontRegardless()
        guard panel.isVisible else { clearHighlight(); throw RecallFailure(message: "已定位原消息，但高亮窗口未能显示。返回流程尚未完整完成。") }
        let appearance = UUID(); highlightAppearance = appearance
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.highlightAppearance == appearance else { return }
            self.clearHighlight()
        }
        highlightExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: expiry)
    }
    // Render-only regression check on our synthetic window. No host inspection,
    // navigation, saved message, source data or permissions are involved.
    func highlightSyntheticWindow() throws {
        guard let window = NSApp.windows.first(where: { $0.title == "桌面流程验证" && $0.isVisible }),
              let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first else { throw RecallFailure(message: "受控测试窗口尚未显示。") }
        let screen = window.convertToScreen(window.contentLayoutRect.insetBy(dx: 18, dy: 18))
        let ax = CGRect(x: screen.minX, y: primary.frame.maxY - screen.maxY, width: screen.width, height: screen.height)
        let token = UUID(); generation = token
        try showHighlight(ax, token: token)
    }
    @discardableResult func verifySyntheticBody(_ expected: String) throws -> Bool {
        let ownApp = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        guard let window = axElement(value(ownApp, kAXFocusedWindowAttribute)), value(window, kAXTitleAttribute) as? String == "桌面流程验证" else { throw RecallFailure(message: "未聚焦虚构测试窗口。") }
        var diagnostics = [String]()
        let tree = snapshot(window, purpose: .discovery, within: rect(window))
        let quick = bodyMatches(in: tree, expected: expected, diagnostics: &diagnostics, budget: 0.35, candidateBudget: 0.1, firstCompleteCandidate: true).first
        let fallback = bodyMatches(in: tree, expected: expected, diagnostics: &diagnostics)
        guard let located = try locateVerifiedBody(in: window, expected: expected, ownerPID: ProcessInfo.processInfo.processIdentifier, diagnostics: &diagnostics),
              let repeated = try revalidateBody(located.0, in: window, expected: expected),
              fallback.count == 1, fallback[0].1 == located.1,
              quick == nil || quick!.1 == located.1,
              try revalidateBody(located.0, in: window, expected: expected + "\n不存在的测试段落") == nil,
              located.1 == repeated.1, let bounds = rect(window), bounds.intersects(located.1) else { throw RecallFailure(message: "受控完整正文核验失败：\(diagnostics.joined(separator: "；"))") }
        // Exercise the same point-to-leaf path used by real user capture,
        // against this app's synthetic window only. A found leaf must still
        // prove the entire expected message through the original body verifier.
        guard let sampleFrame = tree.nodes.compactMap(rect).first(where: {
            located.1.contains(CGPoint(x: $0.midX, y: $0.midY))
        }) else { throw RecallFailure(message: "受控正文没有可测的文字坐标。") }
        let target = CGPoint(x: sampleFrame.midX, y: sampleFrame.midY)
        var pointDiagnostics = [String]()
        guard let leaf = bodyTextAtPoint(window, point: target),
              let captured = verifiedBody(around: leaf, expected: expected, diagnostics: &pointDiagnostics),
              captured.frame == located.1 else {
            throw RecallFailure(message: "受控指针正文采集核验失败；未将容器当作正文。")
        }
        let token = UUID(); generation = token
        try showHighlight(located.1.intersection(bounds), token: token)
        return quick != nil
    }
    func verifySyntheticCounter() throws {
        let ownApp = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        guard let window = axElement(value(ownApp, kAXFocusedWindowAttribute)), value(window, kAXTitleAttribute) as? String == "桌面流程验证",
              let field = axElement(value(ownApp, kAXFocusedUIElementAttribute)), value(field, kAXIdentifierAttribute) as? String == "recall-local-counter-field" else { throw RecallFailure(message: "未聚焦受控查找测试输入框。") }
        var diagnostics = [String]()
        guard try counterAtScreenPosition(near: field, diagnostics: &diagnostics) == true else { throw RecallFailure(message: "受控局部计数核验失败（屏幕命中）：\(diagnostics.joined(separator: "；"))") }
    }
}
private final class MessageHighlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func verifyStoredIdentity(_ mark: Mark, in conversation: StoredConversation) throws {
    guard conversation.id == mark.anchor.conversationID else { throw RecallFailure(message: "原对话身份不一致。") }
    let matches = conversation.messages.filter { $0.turnID == mark.anchor.turnID && $0.itemID == mark.anchor.itemID }
    guard matches.count == 1, let original = matches.first else { throw RecallFailure(message: "原消息已不存在，或消息身份不能唯一核验。不会跳到内容相同的其他消息。") }
    guard original.role == mark.anchor.role, original.text == mark.fullText else { throw RecallFailure(message: "原消息作者或内容已改变，停止定位。") }
}
func verifyUniqueLocator(_ mark: Mark, in conversation: StoredConversation) throws {
    guard conversation.coverage == .wholeConversation else { throw RecallFailure(message: "仅完成目标消息预检，尚未读取全部历史，不能确认定位唯一性。") }
    let phrase = normalized(mark.anchor.searchPhrase)
    let matches = conversation.messages.filter { locatorPresent(phrase, in: $0.normalizedRendered) || locatorPresent(phrase, in: $0.normalizedText) }
    guard matches.count == 1, matches[0].turnID == mark.anchor.turnID, matches[0].itemID == mark.anchor.itemID else { throw RecallFailure(message: "定位片段已出现在其他消息中，无法唯一确认原位置。未选择重复或相似结果。") }
    let bodies = [normalized(mark.fullText), normalized(mark.renderedText)].filter { !$0.isEmpty }
    guard !conversation.otherSearchTexts.contains(where: { candidate in
        bodies.contains { candidate.contains($0) }
    }) else { throw RecallFailure(message: "工具结果或附件中也出现了完整原文，无法排除同文位置。已停止返回。") }
}
