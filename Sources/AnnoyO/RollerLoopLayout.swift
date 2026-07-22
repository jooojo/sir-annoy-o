import Foundation

enum RollerLoopLayout {
    private static let sparseItemLimit = 6

    static func cycles(forItemCount itemCount: Int) -> [Int] {
        guard itemCount > 0 else { return [] }
        return itemCount <= sparseItemLimit
            ? Array(0 ... 6)
            : Array(0 ... 2)
    }

    static func middleCycle(forItemCount itemCount: Int) -> Int {
        let renderedCycles = cycles(forItemCount: itemCount)
        guard !renderedCycles.isEmpty else { return 0 }
        return renderedCycles[renderedCycles.count / 2]
    }

    static func recenteredOffset(
        currentOffset: CGFloat,
        viewportHeight: CGFloat,
        documentMinimumY: CGFloat,
        documentHeight: CGFloat,
        cycleContentInset: CGFloat,
        cycleCount: Int
    ) -> CGFloat? {
        guard cycleCount > 1 else { return nil }
        let repeatedContentHeight = documentHeight - cycleContentInset * 2
        let cycleHeight = repeatedContentHeight / CGFloat(cycleCount)
        guard cycleHeight > 0 else { return nil }

        let relativeCenter = currentOffset
            + viewportHeight / 2
            - documentMinimumY
            - cycleContentInset
        let visibleCycle = min(
            cycleCount - 1,
            max(0, Int(floor(relativeCenter / cycleHeight)))
        )
        let middleCycle = cycleCount / 2
        guard visibleCycle != middleCycle else { return nil }
        return currentOffset + CGFloat(middleCycle - visibleCycle) * cycleHeight
    }
}
