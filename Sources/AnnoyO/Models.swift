import Foundation

struct VideoSearchResult: Identifiable, Hashable, Codable, Sendable {
    let bvid: String
    let title: String
    let creator: String
    let description: String
    let coverURL: URL?
    let durationText: String
    let playCountText: String
    let publishedAt: Date?

    var id: String { bvid }
    var webURL: URL? { URL(string: "https://www.bilibili.com/video/\(bvid)") }
}

enum RoamingPlaylist {
    static let id = UUID(uuidString: "A6609F76-4E8E-4EE4-9DA8-2D278EE6AE7D")!
    static let name = "漫游"

    struct Window: Equatable, Sendable {
        let items: [VideoSearchResult]
        let currentID: String?
    }

    static func normalized(
        items: [VideoSearchResult],
        currentID requestedCurrentID: String?
    ) -> Window {
        var seenIDs = Set<String>()
        let uniqueItems = items.filter { seenIDs.insert($0.id).inserted }
        guard !uniqueItems.isEmpty else {
            return Window(items: [], currentID: nil)
        }

        guard let currentID = requestedCurrentID,
            let currentIndex = uniqueItems.firstIndex(where: { $0.id == currentID })
        else {
            return Window(items: Array(uniqueItems.prefix(3)), currentID: nil)
        }

        let lowerBound = max(uniqueItems.startIndex, currentIndex - 1)
        let upperBound = min(uniqueItems.endIndex, currentIndex + 2)
        return Window(
            items: Array(uniqueItems[lowerBound..<upperBound]),
            currentID: currentID
        )
    }

    static func selecting(
        _ video: VideoSearchResult,
        in items: [VideoSearchResult],
        currentID: String?
    ) -> Window {
        if currentID == video.id {
            return normalized(items: items, currentID: currentID)
        }
        let previous = currentID.flatMap { id in
            items.first(where: { $0.id == id })
        }
        return Window(
            items: [previous, video].compactMap { $0 },
            currentID: video.id
        )
    }

    static func insertingNext(
        _ video: VideoSearchResult,
        in items: [VideoSearchResult],
        currentID: String?
    ) -> Window {
        guard let currentID,
            let currentIndex = items.firstIndex(where: { $0.id == currentID })
        else {
            let candidates = items.filter { $0.id != video.id } + [video]
            return normalized(items: candidates, currentID: nil)
        }

        let previous =
            currentIndex > items.startIndex
            ? items[currentIndex - 1]
            : nil
        let current = items[currentIndex]
        let retainedPrevious = previous?.id == video.id ? nil : previous
        let windowItems = [retainedPrevious, current, video]
            .compactMap { $0 }
            .reduce(into: [VideoSearchResult]()) { result, candidate in
                guard !result.contains(where: { $0.id == candidate.id }) else { return }
                result.append(candidate)
            }
        return Window(items: windowItems, currentID: currentID)
    }

    static func next(
        in items: [VideoSearchResult],
        currentID: String?
    ) -> VideoSearchResult? {
        guard let currentID,
            let currentIndex = items.firstIndex(where: { $0.id == currentID }),
            items.indices.contains(currentIndex + 1)
        else { return nil }
        return items[currentIndex + 1]
    }
}

struct AudioStream: Sendable {
    let url: URL
    let duration: TimeInterval
    let pageTitle: String?
    let representationID: Int
    let bandwidth: Int
}

struct VideoPart: Identifiable, Hashable, Sendable {
    let cid: Int64
    let number: Int
    let title: String
    let duration: TimeInterval

    var id: Int64 { cid }
}

struct BilibiliAccount: Equatable, Sendable {
    let name: String
    let avatarURL: URL?
}

struct QRCodeLoginSession: Sendable {
    let key: String
    let url: URL
}

enum QRCodeLoginStatus: Sendable {
    case waitingForScan
    case waitingForConfirmation
    case confirmed
    case expired
}

enum PlaybackState: Equatable, Sendable {
    case idle
    case resolving
    case buffering
    case playing
    case paused
    case failed(String)

    var isPlaying: Bool {
        self == .playing
    }

    var showsPauseControl: Bool {
        self == .playing || self == .buffering
    }
}

enum PlaybackOrderMode: CaseIterable, Equatable, Sendable {
    case repeatAll
    case repeatOne
    case shuffle
}

enum BilibiliError: LocalizedError, Sendable {
    case invalidResponse
    case api(code: Int, message: String)
    case noAudio
    case noPages

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Bilibili 返回了无法识别的数据"
        case .api(_, let message):
            message.isEmpty ? "Bilibili 请求失败" : message
        case .noAudio:
            "这个视频没有可用的音轨"
        case .noPages:
            "这个视频没有可播放的分P"
        }
    }
}
