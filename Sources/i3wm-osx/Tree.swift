import Foundation
import CoreGraphics

enum Layout: String {
    case splitH = "splith"
    case splitV = "splitv"
    case tabbed
    case stacking

    var isSplit: Bool { self == .splitH || self == .splitV }
}

enum Orientation { case horizontal, vertical, none

    static func from(_ layout: Layout) -> Orientation {
        switch layout {
        case .splitH, .tabbed: return .horizontal
        case .splitV, .stacking: return .vertical
        }
    }
}

enum Direction {
    case left, right, up, down

    var orientation: Orientation {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }
    var positive: Bool {
        switch self {
        case .right, .down: return true
        case .left, .up: return false
        }
    }
}

final class Container {
    enum Kind {
        case root
        case workspace
        case split
        case window(ManagedWindow)
    }

    static var nextID: Int = 1

    var id: Int
    var kind: Kind
    var layout: Layout = .splitH
    var children: [Container] = []
    weak var parent: Container?
    var rect: CGRect = .zero
    var fraction: CGFloat = 0
    var focusOrder: [Int] = []

    init(kind: Kind) {
        self.id = Container.nextID
        Container.nextID += 1
        self.kind = kind
    }

    var isWindow: Bool {
        if case .window = kind { return true } else { return false }
    }

    var window: ManagedWindow? {
        if case .window(let w) = kind { return w } else { return nil }
    }

    var isLeaf: Bool { children.isEmpty }

    func add(_ child: Container, at index: Int? = nil) {
        if let p = child.parent { p.remove(child) }
        child.parent = self
        if let i = index, i >= 0, i <= children.count {
            children.insert(child, at: i)
        } else {
            children.append(child)
        }
        focusOrder.append(child.id)
        fixFractions()
    }

    func remove(_ child: Container) {
        children.removeAll { $0 === child }
        focusOrder.removeAll { $0 == child.id }
        child.parent = nil
        fixFractions()
    }

    /// Mirrors i3's `con_fix_percent`: ensures siblings' fractions sum to 1.
    /// New children entering with fraction=0 get the average of existing
    /// siblings; if everyone is unset, all share equally. After this runs
    /// every child has a positive fraction summing to 1.0, so `placeSplit`
    /// never has to renormalize on render — eliminates drift across mutations.
    func fixFractions() {
        guard !children.isEmpty else { return }
        let n = CGFloat(children.count)
        let setChildren = children.filter { $0.fraction > 0.0001 }
        if setChildren.isEmpty {
            let eq = 1.0 / n
            for c in children { c.fraction = eq }
            return
        }
        let avg = setChildren.reduce(0.0) { $0 + $1.fraction } / CGFloat(setChildren.count)
        for c in children where c.fraction <= 0.0001 { c.fraction = avg }
        let total = children.reduce(0.0) { $0 + $1.fraction }
        guard total > 0.0001 else { return }
        for c in children { c.fraction /= total }
    }

    func indexOf(_ child: Container) -> Int? {
        children.firstIndex { $0 === child }
    }

    var lastFocusedChild: Container? {
        for id in focusOrder.reversed() {
            if let c = children.first(where: { $0.id == id }) { return c }
        }
        return children.last
    }

    func bumpFocus(_ child: Container) {
        focusOrder.removeAll { $0 == child.id }
        focusOrder.append(child.id)
        parent?.bumpFocus(self)
    }

    func collectWindows() -> [ManagedWindow] {
        var out: [ManagedWindow] = []
        if let w = window { out.append(w) }
        for c in children { out.append(contentsOf: c.collectWindows()) }
        return out
    }

    func deepestFocusedLeaf() -> Container {
        var c = self
        while let next = c.lastFocusedChild { c = next }
        return c
    }
}

struct LayoutContext {
    var innerGap: CGFloat
    var outerGap: CGFloat
    var smartGaps: Bool
    var barInset: CGFloat
    var barAtBottom: Bool
}

enum LayoutEngine {
    static func compute(workspace: Container, in available: CGRect, ctx: LayoutContext) {
        var area = available
        if ctx.barAtBottom {
            area.size.height -= ctx.barInset
        } else {
            area.origin.y += ctx.barInset
            area.size.height -= ctx.barInset
        }
        let leafCount = workspace.collectWindows().count
        let outer = ctx.smartGaps && leafCount <= 1 ? 0 : ctx.outerGap
        area = area.insetBy(dx: outer, dy: outer)
        workspace.rect = area
        applyLayout(container: workspace, rect: area, ctx: ctx, leafCount: leafCount)
    }

    private static func applyLayout(container: Container, rect: CGRect, ctx: LayoutContext, leafCount: Int) {
        container.rect = rect
        if container.children.isEmpty { return }
        let gap = ctx.smartGaps && leafCount <= 1 ? 0 : ctx.innerGap

        switch container.layout {
        case .splitH:
            placeSplit(container: container, rect: rect, axis: .horizontal, gap: gap, ctx: ctx, leafCount: leafCount)
        case .splitV:
            placeSplit(container: container, rect: rect, axis: .vertical, gap: gap, ctx: ctx, leafCount: leafCount)
        case .tabbed:
            placeTabbed(container: container, rect: rect, ctx: ctx, leafCount: leafCount)
        case .stacking:
            placeStacked(container: container, rect: rect, ctx: ctx, leafCount: leafCount)
        }
    }

    private static func placeSplit(container: Container, rect: CGRect, axis: Orientation, gap: CGFloat, ctx: LayoutContext, leafCount: Int) {
        // Floating leaves don't participate in tile flow — their containers
        // stay in the tree (for workspace-association) but they don't take up
        // tile space.
        let tileable = container.children.filter { !($0.window?.isFloating ?? false) }
        let n = tileable.count
        if n == 0 { return }
        let totalGap = gap * CGFloat(max(n - 1, 0))
        let totalFraction = tileable.reduce(0.0) { $0 + max($1.fraction, 0) }
        let fractions: [CGFloat]
        if totalFraction <= 0.0001 {
            let equal = 1.0 / CGFloat(n)
            fractions = Array(repeating: equal, count: n)
        } else {
            fractions = tileable.map { max($0.fraction, 0) / totalFraction }
        }
        // Always write the *normalized* fraction back so stored state matches
        // what was rendered. Skipping this is what causes drift across
        // sequences of add/remove/resize.
        for (c, f) in zip(tileable, fractions) { c.fraction = f }

        let start: CGFloat = axis == .horizontal ? rect.minX : rect.minY
        let span: CGFloat = axis == .horizontal ? rect.width : rect.height
        let end = start + span
        let usable = max(span - totalGap, 0)
        var cursor = start
        for (i, child) in tileable.enumerated() {
            let isLast = i == n - 1
            // Clamp the last child's trailing edge to `end` so floating-point
            // accumulation can't push it past the parent rect.
            let nominalSize = usable * fractions[i]
            let size = isLast ? max(end - cursor, 0) : nominalSize
            let r: CGRect
            if axis == .horizontal {
                r = CGRect(x: cursor, y: rect.minY, width: size, height: rect.height)
            } else {
                r = CGRect(x: rect.minX, y: cursor, width: rect.width, height: size)
            }
            applyLayout(container: child, rect: r, ctx: ctx, leafCount: leafCount)
            // No gap added after the last child.
            cursor += size + (isLast ? 0 : gap)
        }
    }

    private static func placeTabbed(container: Container, rect: CGRect, ctx: LayoutContext, leafCount: Int) {
        let tabHeight: CGFloat = 22
        let inner = CGRect(x: rect.minX, y: rect.minY + tabHeight, width: rect.width, height: rect.height - tabHeight)
        let active = container.lastFocusedChild
        for child in container.children {
            if child === active {
                applyLayout(container: child, rect: inner, ctx: ctx, leafCount: leafCount)
            } else {
                applyLayout(container: child, rect: CGRect(x: -10000, y: -10000, width: inner.width, height: inner.height), ctx: ctx, leafCount: leafCount)
            }
        }
    }

    private static func placeStacked(container: Container, rect: CGRect, ctx: LayoutContext, leafCount: Int) {
        let titleH: CGFloat = 18
        let stackH = titleH * CGFloat(container.children.count)
        let inner = CGRect(x: rect.minX, y: rect.minY + stackH, width: rect.width, height: max(rect.height - stackH, 0))
        let active = container.lastFocusedChild
        for child in container.children {
            if child === active {
                applyLayout(container: child, rect: inner, ctx: ctx, leafCount: leafCount)
            } else {
                applyLayout(container: child, rect: CGRect(x: -10000, y: -10000, width: inner.width, height: inner.height), ctx: ctx, leafCount: leafCount)
            }
        }
    }
}
