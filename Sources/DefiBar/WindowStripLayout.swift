import Foundation

struct WindowStripPosition {
    let offset: CGFloat
    let focusedWindowID: UInt64?
    var focusAnimation: WindowStripFocusAnimation? = nil
}

struct WindowStripFocusAnimation {
    private static let duration: TimeInterval = 0.18

    let startOffset: CGFloat
    let targetOffset: CGFloat
    let startedAt: TimeInterval

    var endsAt: TimeInterval { startedAt + Self.duration }

    func offset(at time: TimeInterval) -> CGFloat {
        if time >= endsAt { return targetOffset }
        let progress = CGFloat(max(0, time - startedAt) / Self.duration)
        let remaining = 1 - progress
        let eased = 1 - remaining * remaining * remaining
        return startOffset + (targetOffset - startOffset) * eased
    }
}

struct WindowStripLayout {
    enum Marker: CaseIterable {
        case fullscreen, stackStart, stackEnd, floating, continuationLeft, continuationRight
    }

    enum Item {
        case window(WorkspaceState.Window)
        case marker(Marker)
    }

    struct Element {
        let item: Item
        let x: CGFloat
        let width: CGFloat
    }

    struct Edges {
        let left: CGFloat
        let right: CGFloat
    }

    private struct Entry {
        let window: WorkspaceState.Window
        let stack: Int?
    }

    let elements: [Element]
    let contentWidth: CGFloat
    let focusedWindowID: UInt64?
    private let focusedWindowRange: ClosedRange<CGFloat>?
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

        var width: CGFloat = 0
        var focusedID: UInt64?
        var focusedRange: ClosedRange<CGFloat>?
        elements = Self.makeItems(from: entries).map { item in
            let itemWidth: CGFloat
            switch item {
            case .window(let window):
                itemWidth = slotWidth
                if window.selected, focusedID == nil {
                    focusedID = window.id
                    focusedRange = width...(width + slotWidth)
                }
            case .marker(let marker):
                itemWidth = markerWidths[marker, default: 0]
            }
            let x = width
            width += itemWidth
            return Element(item: item, x: x, width: itemWidth)
        }
        contentWidth = width
        focusedWindowID = focusedID
        focusedWindowRange = focusedRange
        leftMarkerWidth = markerWidths[.continuationLeft, default: 0]
        rightMarkerWidth = markerWidths[.continuationRight, default: 0]
    }

    func edges(at offset: CGFloat, viewportWidth: CGFloat) -> Edges {
        let remaining = maximumOffset(for: viewportWidth) - offset
        return Edges(left: min(leftMarkerWidth, offset), right: min(rightMarkerWidth, remaining))
    }

    func maximumOffset(for viewportWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    func clampedOffset(_ offset: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        min(max(0, offset), maximumOffset(for: viewportWidth))
    }

    func restoredPosition(
        for viewportWidth: CGFloat, previous: WindowStripPosition?, animatesFocus: Bool, at time: TimeInterval
    ) -> WindowStripPosition {
        let offset = clampedOffset(previous?.offset ?? 0, viewportWidth: viewportWidth)
        let target = focusTarget(from: offset, viewportWidth: viewportWidth, previous: previous)
        guard animatesFocus, let previous, target != offset else {
            return WindowStripPosition(offset: target, focusedWindowID: focusedWindowID)
        }

        if previous.focusedWindowID == focusedWindowID, let animation = previous.focusAnimation,
           animation.targetOffset == target, animation.startOffset == clampedOffset(animation.startOffset, viewportWidth: viewportWidth) {
            if time >= animation.endsAt {
                return WindowStripPosition(offset: target, focusedWindowID: focusedWindowID)
            }
            return WindowStripPosition(offset: offset, focusedWindowID: focusedWindowID, focusAnimation: animation)
        }

        let animation = WindowStripFocusAnimation(startOffset: offset, targetOffset: target, startedAt: time)
        return WindowStripPosition(offset: offset, focusedWindowID: focusedWindowID, focusAnimation: animation)
    }

    private func focusTarget(from offset: CGFloat, viewportWidth: CGFloat, previous: WindowStripPosition?) -> CGFloat {
        guard let focusedWindowRange else { return offset }
        guard let previous else {
            let center = (focusedWindowRange.lowerBound + focusedWindowRange.upperBound) / 2
            return clampedOffset(center - viewportWidth / 2, viewportWidth: viewportWidth)
        }

        let referenceOffset: CGFloat
        if previous.focusedWindowID == focusedWindowID {
            guard let animation = previous.focusAnimation else { return offset }
            // Recompute from the start so refreshes during the animation keep its destination.
            referenceOffset = clampedOffset(animation.startOffset, viewportWidth: viewportWidth)
        } else {
            referenceOffset = offset
        }

        let leadingSpace = focusedWindowRange.lowerBound
        let trailingSpace = contentWidth - focusedWindowRange.upperBound
        // Each edge clips the scroll distance plus the visible part of its marker.
        // Near an endpoint, the visible marker is as wide as the remaining distance.
        let lastVisibleOffset = max(leadingSpace - leftMarkerWidth, leadingSpace / 2)
        let firstVisibleOffset = maximumOffset(for: viewportWidth)
            - max(trailingSpace - rightMarkerWidth, trailingSpace / 2)
        let target = min(max(referenceOffset, firstVisibleOffset), lastVisibleOffset)
        return clampedOffset(target, viewportWidth: viewportWidth)
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
}
