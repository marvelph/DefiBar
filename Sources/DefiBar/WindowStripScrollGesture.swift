import AppKit

enum WindowStripScrollGesture {
    case idle, waitingForHorizontalMovement, scrolling

    mutating func shouldScroll(
        phase: NSEvent.Phase, momentum: NSEvent.Phase, isOverStrip: Bool,
        hasHorizontalMovement: Bool, hasPreciseDeltas: Bool
    ) -> Bool {
        if phase.contains(.cancelled) || momentum.contains(.cancelled) {
            self = .idle
            return false
        }

        if !momentum.isEmpty {
            let shouldScroll = self == .scrolling && hasHorizontalMovement
            if momentum.contains(.ended) { self = .idle }
            return shouldScroll
        }

        if phase.isEmpty {
            let shouldScroll = isOverStrip && hasHorizontalMovement
            self = shouldScroll && hasPreciseDeltas ? .scrolling : .idle
            return shouldScroll
        }

        if phase.contains(.mayBegin) || phase.contains(.began) {
            self = isOverStrip ? .waitingForHorizontalMovement : .idle
        }
        if self != .idle && hasHorizontalMovement {
            self = .scrolling
            return true
        }
        if phase.contains(.ended), self == .waitingForHorizontalMovement { self = .idle }
        return false
    }
}
