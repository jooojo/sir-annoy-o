import Foundation

enum RollerLoopLayout {
    static let compactItemLimit = 6

    static func usesCompactLoop(forItemCount itemCount: Int) -> Bool {
        itemCount > 1 && itemCount <= compactItemLimit
    }

    static func cycles(forItemCount itemCount: Int) -> [Int] {
        usesCompactLoop(forItemCount: itemCount) || itemCount <= 1
            ? [1]
            : Array(0 ... 2)
    }

    static func boundaryWrapTarget(
        currentOffset: CGFloat,
        minimumOffset: CGFloat,
        maximumOffset: CGFloat,
        scrollingDeltaY: CGFloat,
        tolerance: CGFloat = 1
    ) -> CGFloat? {
        guard maximumOffset > minimumOffset else { return nil }
        if scrollingDeltaY > 0,
           currentOffset <= minimumOffset + tolerance {
            return maximumOffset
        }
        if scrollingDeltaY < 0,
           currentOffset >= maximumOffset - tolerance {
            return minimumOffset
        }
        return nil
    }
}
