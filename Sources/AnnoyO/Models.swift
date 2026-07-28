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

struct PlaybackItem: Identifiable, Hashable, Codable, Sendable {
    let video: VideoSearchResult
    let part: VideoPart?
    let partCount: Int

    init(video: VideoSearchResult, part: VideoPart? = nil, partCount: Int = 1) {
        self.video = video
        self.part = part
        self.partCount = max(1, partCount)
    }

    var id: String {
        guard let part, partCount > 1 else { return video.id }
        return "\(video.id)#\(part.cid)"
    }

    var bvid: String { video.bvid }
    var title: String {
        guard let part, partCount > 1 else { return video.title }
        return "P\(part.number) · \(part.title)"
    }
    var creator: String { video.creator }
    var description: String { video.description }
    var coverURL: URL? { video.coverURL }
    var durationText: String {
        guard let part else { return video.durationText }
        let totalSeconds = max(0, Int(part.duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
    var playCountText: String { video.playCountText }
    var publishedAt: Date? { video.publishedAt }
    var webURL: URL? {
        guard
            var components = video.webURL.flatMap({
                URLComponents(url: $0, resolvingAgainstBaseURL: false)
            })
        else { return video.webURL }
        if let part, partCount > 1 {
            components.queryItems = [URLQueryItem(name: "p", value: String(part.number))]
        }
        return components.url
    }

    static func flatten(video: VideoSearchResult, parts: [VideoPart]) -> [PlaybackItem] {
        parts.map { PlaybackItem(video: video, part: $0, partCount: parts.count) }
    }

    private enum CodingKeys: String, CodingKey {
        case video
        case part
        case partCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.video) {
            video = try container.decode(VideoSearchResult.self, forKey: .video)
            part = try container.decodeIfPresent(VideoPart.self, forKey: .part)
            partCount = max(1, try container.decodeIfPresent(Int.self, forKey: .partCount) ?? 1)
        } else {
            video = try VideoSearchResult(from: decoder)
            part = nil
            partCount = 1
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(video, forKey: .video)
        try container.encodeIfPresent(part, forKey: .part)
        try container.encode(partCount, forKey: .partCount)
    }
}

enum RoamingPlaylist {
    static let id = UUID(uuidString: "A6609F76-4E8E-4EE4-9DA8-2D278EE6AE7D")!
    static let name = "漫游"

    struct Window: Equatable, Sendable {
        let items: [PlaybackItem]
        let currentID: String?
    }

    static func normalized(
        items: [PlaybackItem],
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
        _ item: PlaybackItem,
        in items: [PlaybackItem],
        currentID: String?
    ) -> Window {
        if currentID == item.id {
            return normalized(items: items, currentID: currentID)
        }
        let previous = currentID.flatMap { id in
            items.first(where: { $0.id == id })
        }
        return Window(
            items: [previous, item].compactMap { $0 },
            currentID: item.id
        )
    }

    static func insertingNext(
        _ item: PlaybackItem,
        in items: [PlaybackItem],
        currentID: String?
    ) -> Window {
        guard let currentID,
            let currentIndex = items.firstIndex(where: { $0.id == currentID })
        else {
            let candidates = items.filter { $0.id != item.id } + [item]
            return normalized(items: candidates, currentID: nil)
        }

        let previous =
            currentIndex > items.startIndex
            ? items[currentIndex - 1]
            : nil
        let current = items[currentIndex]
        let retainedPrevious = previous?.id == item.id ? nil : previous
        let windowItems = [retainedPrevious, current, item]
            .compactMap { $0 }
            .reduce(into: [PlaybackItem]()) { result, candidate in
                guard !result.contains(where: { $0.id == candidate.id }) else { return }
                result.append(candidate)
            }
        return Window(items: windowItems, currentID: currentID)
    }

    static func next(
        in items: [PlaybackItem],
        currentID: String?
    ) -> PlaybackItem? {
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

struct VideoPart: Identifiable, Hashable, Codable, Sendable {
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
