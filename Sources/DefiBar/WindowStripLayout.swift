import Foundation

struct WindowStripViewport {
    var firstWindowID: UInt64
    let focusedWindowID: UInt64?
}

struct WindowStripLayout {
    enum Marker: CaseIterable {
        case fullscreen, stackStart, stackEnd, floating
    }

    enum Item {
        case window(WorkspaceState.Window)
        case marker(Marker)
    }

    struct VisibleStrip {
        let items: [Item]
        let width: CGFloat
        let viewport: WindowStripViewport?
        let previousWindowID: UInt64?
        let nextWindowID: UInt64?
    }

    private struct Entry {
        let window: WorkspaceState.Window
        let stack: Int?
    }

    private struct FittedRange {
        let items: Range<Int>
        let windows: Range<Int>
        let width: CGFloat
    }

    private let items: [Item]
    private let windows: [WorkspaceState.Window]
    private let windowPositions: [Int]
    private let slotWidth: CGFloat
    private let markerWidths: [Marker: CGFloat]

    init(workspace: WorkspaceState.Workspace, slotWidth: CGFloat, markerWidths: [Marker: CGFloat]) {
        var entries: [Entry] = []
        for (columnIndex, column) in workspace.tiledColumns.enumerated() {
            let stack = column.count > 1 ? columnIndex : nil
            for window in column {
                entries.append(Entry(window: window, stack: stack))
            }
        }
        for window in workspace.windows where window.floating {
            entries.append(Entry(window: window, stack: nil))
        }
        let items = Self.makeItems(from: entries)
        self.items = items
        windows = entries.map(\.window)
        windowPositions = items.indices.filter {
            if case .window = items[$0] { return true }
            return false
        }
        self.slotWidth = slotWidth
        self.markerWidths = markerWidths
    }

    func visibleStrip(maximumWidth: CGFloat, arrowWidth: CGFloat, viewport: WindowStripViewport?) -> VisibleStrip {
        if CGFloat(windows.count) * slotWidth <= maximumWidth {
            let allWidth = items.reduce(CGFloat.zero) { $0 + width(of: $1) }
            if allWidth <= maximumWidth {
                return VisibleStrip(items: items, width: allWidth, viewport: nil,
                                    previousWindowID: nil, nextWindowID: nil)
            }
        }

        let availableWidth = maximumWidth - 2 * arrowWidth
        let focusedIndex = windows.firstIndex(where: \.selected)
        let focusedWindowID = focusedIndex.map { windows[$0].id }
        let range: FittedRange
        if let viewport, let start = windows.firstIndex(where: { $0.id == viewport.firstWindowID }) {
            let current = fittingRange(startingAt: start, maximumWidth: availableWidth)
            if viewport.focusedWindowID != focusedWindowID, let focusedIndex, !current.windows.contains(focusedIndex) {
                range = centeredRange(on: focusedIndex, maximumWidth: availableWidth)
            } else {
                range = current
            }
        } else if let focusedIndex {
            range = centeredRange(on: focusedIndex, maximumWidth: availableWidth)
        } else {
            range = fittingRange(startingAt: 0, maximumWidth: availableWidth)
        }

        let start = range.windows.lowerBound
        return VisibleStrip(
            items: Array(items[range.items]),
            width: range.width,
            viewport: WindowStripViewport(firstWindowID: windows[start].id, focusedWindowID: focusedWindowID),
            previousWindowID: start > 0 ? windows[start - 1].id : nil,
            nextWindowID: range.items.upperBound < items.count && start + 1 < windows.count
                ? windows[start + 1].id : nil
        )
    }

    private func fittingRange(startingAt start: Int, maximumWidth: CGFloat) -> FittedRange {
        // A scroll step drops one window and the items before it. Markers after it can stay visible.
        let firstItem = start == 0 ? 0 : windowPositions[start - 1] + 1
        var endItem = firstItem
        var endWindow = start
        var usedWidth: CGFloat = 0
        while endItem < items.count {
            let item = items[endItem]
            let itemWidth = width(of: item)
            guard usedWidth + itemWidth <= maximumWidth else { break }
            usedWidth += itemWidth
            if case .window = item { endWindow += 1 }
            endItem += 1
        }
        return FittedRange(items: firstItem..<endItem, windows: start..<endWindow, width: usedWidth)
    }

    private func centeredRange(on index: Int, maximumWidth: CGFloat) -> FittedRange {
        var best = fittingRange(startingAt: index, maximumWidth: maximumWidth)
        for start in (0..<index).reversed() {
            let candidate = fittingRange(startingAt: start, maximumWidth: maximumWidth)
            guard candidate.windows.contains(index) else { break }
            let candidateOffset = abs(candidate.windows.lowerBound + candidate.windows.upperBound - 1 - 2 * index)
            let bestOffset = abs(best.windows.lowerBound + best.windows.upperBound - 1 - 2 * index)
            if candidate.windows.count > best.windows.count
                || (candidate.windows.count == best.windows.count && candidateOffset < bestOffset) {
                best = candidate
            }
        }
        return best
    }

    private static func makeItems(from entries: [Entry]) -> [Item] {
        var items: [Item] = []
        for index in entries.indices {
            let entry = entries[index]
            let previous = index > 0 ? entries[index - 1] : nil
            let next = index + 1 < entries.count ? entries[index + 1] : nil
            if entry.window.nativeFullscreen == true, previous?.window.nativeFullscreen != true {
                items.append(.marker(.fullscreen))
            }
            if entry.window.floating, previous?.window.floating != true { items.append(.marker(.floating)) }
            if let stack = entry.stack, previous?.stack != stack { items.append(.marker(.stackStart)) }
            items.append(.window(entry.window))
            if let stack = entry.stack, next?.stack != stack { items.append(.marker(.stackEnd)) }
        }
        return items
    }

    private func width(of item: Item) -> CGFloat {
        switch item {
        case .window: return slotWidth
        case .marker(let marker): return markerWidths[marker, default: 0]
        }
    }
}
