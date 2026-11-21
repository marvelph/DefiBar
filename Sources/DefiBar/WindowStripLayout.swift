import Foundation

struct WindowStripLayout {
    enum Marker: CaseIterable {
        case fullscreen, stackStart, stackEnd, floating, continuationLeft, continuationRight
    }

    enum Item {
        case window(WorkspaceState.Window)
        case marker(Marker)
    }

    struct VisibleStrip {
        let items: [Item]
        let width: CGFloat
        let firstWindowID: UInt64?
    }

    private struct Entry {
        let window: WorkspaceState.Window
        let stack: Int?
    }

    private struct IndexedWindow {
        let window: WorkspaceState.Window
        let firstItem: Int
    }

    private struct FittedRange {
        let items: Range<Int>
        let windows: Range<Int>
        let width: CGFloat
    }

    private let items: [Item]
    private let windows: [IndexedWindow]
    private let itemOffsets: [CGFloat]
    private let slotWidth: CGFloat
    private let leftMarkerWidth: CGFloat
    private let rightMarkerWidth: CGFloat

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
        (items, windows) = Self.makeItems(from: entries)
        self.slotWidth = slotWidth
        leftMarkerWidth = markerWidths[.continuationLeft, default: 0]
        rightMarkerWidth = markerWidths[.continuationRight, default: 0]
        // Each offset is the width before that item. The final offset is the full strip width.
        var offsets: [CGFloat] = [0]
        var offset: CGFloat = 0
        for item in items {
            switch item {
            case .window: offset += slotWidth
            case .marker(let marker): offset += markerWidths[marker, default: 0]
            }
            offsets.append(offset)
        }
        itemOffsets = offsets
    }

    func visibleStrip(maximumWidth: CGFloat, firstWindowID: UInt64?) -> VisibleStrip {
        let fullWidth = itemOffsets[items.count]
        if fullWidth <= maximumWidth {
            return VisibleStrip(items: items, width: fullWidth, firstWindowID: nil)
        }

        let focusedIndex = windows.firstIndex(where: \.window.selected)
        let previousStart = firstWindowID.flatMap { id in windows.firstIndex { $0.window.id == id } }
        let previousRange = previousStart.map { fittingRange(startingAt: $0, maximumWidth: maximumWidth) }
        let range: FittedRange
        if let focusedIndex, previousRange?.windows.contains(focusedIndex) != true {
            range = centeredRange(on: focusedIndex, maximumWidth: maximumWidth)
        } else {
            range = previousRange ?? fittingRange(startingAt: 0, maximumWidth: maximumWidth)
        }

        var visible = Array(items[range.items])
        if range.items.lowerBound > 0 { visible.insert(.marker(.continuationLeft), at: 0) }
        if range.items.upperBound < items.count { visible.append(.marker(.continuationRight)) }
        return VisibleStrip(items: visible, width: range.width, firstWindowID: windows[range.windows.lowerBound].window.id)
    }

    private func fittingRange(startingAt start: Int, maximumWidth: CGFloat) -> FittedRange {
        let firstItem = windows[start].firstItem
        let firstOffset = itemOffsets[firstItem]
        let leftWidth = firstItem > 0 ? leftMarkerWidth : 0
        let remainingWidth = itemOffsets[items.count] - firstOffset
        let rightWidth = leftWidth + remainingWidth > maximumWidth ? rightMarkerWidth : 0
        let contentWidth = maximumWidth - leftWidth - rightWidth

        var endItem = firstItem
        var endWindow = start
        while endItem < items.count, itemOffsets[endItem + 1] - firstOffset <= contentWidth {
            if case .window = items[endItem] { endWindow += 1 }
            endItem += 1
        }
        let usedWidth = itemOffsets[endItem] - firstOffset + leftWidth + rightWidth
        return FittedRange(items: firstItem..<endItem, windows: start..<endWindow, width: usedWidth)
    }

    private func centeredRange(on index: Int, maximumWidth: CGFloat) -> FittedRange {
        var best = fittingRange(startingAt: index, maximumWidth: maximumWidth)
        let earliest = max(0, index + 1 - Int(maximumWidth / slotWidth))
        for start in (earliest..<index).reversed() {
            let candidate = fittingRange(startingAt: start, maximumWidth: maximumWidth)
            guard candidate.windows.contains(index) else { continue }
            let candidateOffset = abs(candidate.windows.lowerBound + candidate.windows.upperBound - 1 - 2 * index)
            let bestOffset = abs(best.windows.lowerBound + best.windows.upperBound - 1 - 2 * index)
            if candidate.windows.count > best.windows.count
                || (candidate.windows.count == best.windows.count && candidateOffset < bestOffset) {
                best = candidate
            }
        }
        return best
    }

    private static func makeItems(from entries: [Entry]) -> ([Item], [IndexedWindow]) {
        var items: [Item] = []
        var windows: [IndexedWindow] = []
        var firstItem = 0
        for index in entries.indices {
            let entry = entries[index]
            let previous = index > 0 ? entries[index - 1] : nil
            let next = index + 1 < entries.count ? entries[index + 1] : nil
            windows.append(IndexedWindow(window: entry.window, firstItem: firstItem))
            if entry.window.nativeFullscreen == true, previous?.window.nativeFullscreen != true {
                items.append(.marker(.fullscreen))
            }
            if entry.window.floating, previous?.window.floating != true { items.append(.marker(.floating)) }
            if let stack = entry.stack, previous?.stack != stack { items.append(.marker(.stackStart)) }
            items.append(.window(entry.window))
            // Scrolling past an icon can leave the markers after it visible.
            firstItem = items.count
            if let stack = entry.stack, next?.stack != stack { items.append(.marker(.stackEnd)) }
        }
        return (items, windows)
    }
}
