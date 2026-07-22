import Combine
import Foundation

@MainActor
final class PlaybackQueue: ObservableObject {
    @Published private(set) var items: [VideoSearchResult]
    @Published private(set) var currentID: String? {
        didSet {
            if !suppressesCurrentSelectionChanged,
               currentID != nil,
               currentID != oldValue {
                currentSelectionChanged.send()
            }
        }
    }
    @Published private(set) var resumePartIndex: Int
    @Published private(set) var resumePosition: TimeInterval
    @Published private(set) var savedPlaylistID: UUID?
    @Published private(set) var savedPlaylistName: String?
    @Published private(set) var playbackSourcePlaylistID: UUID?

    private let storageURL: URL
    private var suppressesCurrentSelectionChanged = false
    var onPersist: (() -> Void)?
    let currentSelectionChanged = PassthroughSubject<Void, Never>()

    convenience init() {
        self.init(storageURL: PlaybackQueue.defaultStorageURL)
    }

    init(storageURL: URL) {
        self.storageURL = storageURL
        if let snapshot = Self.load(from: storageURL) {
            items = snapshot.items
            currentID = snapshot.currentID
            resumePartIndex = max(0, snapshot.resumePartIndex)
            resumePosition = max(0, snapshot.resumePosition)
            savedPlaylistID = snapshot.savedPlaylistID
            savedPlaylistName = snapshot.savedPlaylistName
            playbackSourcePlaylistID = snapshot.playbackSourcePlaylistID
        } else {
            items = []
            currentID = nil
            resumePartIndex = 0
            resumePosition = 0
            savedPlaylistID = nil
            savedPlaylistName = nil
            playbackSourcePlaylistID = nil
        }
    }

    var displayName: String {
        savedPlaylistName ?? RoamingPlaylist.name
    }

    var isRoaming: Bool {
        savedPlaylistID == RoamingPlaylist.id
    }

    var current: VideoSearchResult? {
        guard let currentID else { return nil }
        return items.first { $0.id == currentID }
    }

    var canAdvance: Bool {
        guard let currentID, let index = items.firstIndex(where: { $0.id == currentID }) else {
            return !items.isEmpty
        }
        return items.indices.contains(index + 1)
    }

    var canRetreat: Bool {
        guard let currentID, let index = items.firstIndex(where: { $0.id == currentID }) else {
            return false
        }
        return items.indices.contains(index - 1)
    }

    func contains(_ video: VideoSearchResult) -> Bool {
        items.contains { $0.id == video.id }
    }

    func playNow(_ video: VideoSearchResult) {
        if isRoaming {
            let window = RoamingPlaylist.selecting(
                video,
                in: items,
                currentID: currentID
            )
            items = window.items
            currentID = window.currentID
            resumePartIndex = 0
            resumePosition = 0
            persist()
            return
        }

        if !contains(video) {
            let insertionIndex: Int
            if let currentID, let index = items.firstIndex(where: { $0.id == currentID }) {
                insertionIndex = index + 1
            } else {
                insertionIndex = items.endIndex
            }
            items.insert(video, at: insertionIndex)
        }
        currentID = video.id
        resumePartIndex = 0
        resumePosition = 0
        persist()
    }

    func enqueue(_ video: VideoSearchResult) {
        if isRoaming {
            if currentID != nil {
                _ = replaceRoamingNext(with: video)
            } else {
                let window = RoamingPlaylist.insertingNext(
                    video,
                    in: items,
                    currentID: nil
                )
                guard window.items != items else { return }
                items = window.items
                persist()
            }
            return
        }

        guard !contains(video) else { return }
        items.append(video)
        persist()
    }

    func select(_ video: VideoSearchResult) {
        guard contains(video) else { return }
        if isRoaming {
            let window = RoamingPlaylist.selecting(
                video,
                in: items,
                currentID: currentID
            )
            items = window.items
            currentID = window.currentID
            resumePartIndex = 0
            resumePosition = 0
            persist()
            return
        }
        currentID = video.id
        resumePartIndex = 0
        resumePosition = 0
        persist()
    }

    @discardableResult
    func advance() -> VideoSearchResult? {
        let next: VideoSearchResult?
        if let currentID, let index = items.firstIndex(where: { $0.id == currentID }) {
            next = items.indices.contains(index + 1) ? items[index + 1] : nil
        } else {
            next = items.first
        }
        guard let next else { return nil }
        select(next)
        return next
    }

    @discardableResult
    func retreat() -> VideoSearchResult? {
        guard let currentID,
              let index = items.firstIndex(where: { $0.id == currentID }),
              items.indices.contains(index - 1)
        else { return nil }
        let previous = items[index - 1]
        select(previous)
        return previous
    }

    func remove(_ video: VideoSearchResult) {
        guard contains(video) else { return }
        items.removeAll { $0.id == video.id }
        if currentID == video.id {
            currentID = nil
            resumePartIndex = 0
            resumePosition = 0
        }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        let sourceIndices = source.sorted()
        guard !sourceIndices.isEmpty,
              sourceIndices.allSatisfy(items.indices.contains)
        else { return }

        let movingItems = sourceIndices.map { items[$0] }
        var remaining = items.enumerated()
            .filter { !source.contains($0.offset) }
            .map(\.element)
        let removedBeforeDestination = sourceIndices.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(remaining.count, destination - removedBeforeDestination))
        remaining.insert(contentsOf: movingItems, at: adjustedDestination)
        items = remaining
        persist()
    }

    func moveToTop(_ video: VideoSearchResult) {
        if isRoaming {
            enqueue(video)
            return
        }
        guard video.id != currentID,
              items.contains(where: { $0.id == video.id })
        else { return }

        let remaining = items.filter { $0.id != video.id && $0.id != currentID }
        if let current = items.first(where: { $0.id == currentID }) {
            items = [current, video] + remaining
        } else {
            items = [video] + remaining
        }
        persist()
    }

    func clear() {
        items = []
        currentID = nil
        resumePartIndex = 0
        resumePosition = 0
        persist()
    }

    func replace(
        items newItems: [VideoSearchResult],
        currentID requestedCurrentID: String?,
        resumePartIndex newPartIndex: Int,
        resumePosition newPosition: TimeInterval,
        savedPlaylistID newSavedPlaylistID: UUID? = nil,
        savedPlaylistName newSavedPlaylistName: String? = nil
    ) {
        suppressesCurrentSelectionChanged = true
        defer { suppressesCurrentSelectionChanged = false }
        let window = newSavedPlaylistID == RoamingPlaylist.id
            ? RoamingPlaylist.normalized(items: newItems, currentID: requestedCurrentID)
            : RoamingPlaylist.Window(items: newItems, currentID: requestedCurrentID)
        items = window.items
        if let requestedCurrentID = window.currentID,
           window.items.contains(where: { $0.id == requestedCurrentID }) {
            currentID = requestedCurrentID
        } else {
            currentID = newSavedPlaylistID == RoamingPlaylist.id
                ? nil
                : window.items.first?.id
        }
        resumePartIndex = max(0, newPartIndex)
        resumePosition = max(0, newPosition.isFinite ? newPosition : 0)
        savedPlaylistID = newSavedPlaylistID
        savedPlaylistName = newSavedPlaylistName
        persist()
    }

    @discardableResult
    func insertRoamingNextIfMissing(
        _ video: VideoSearchResult,
        after expectedCurrentID: String
    ) -> Bool {
        guard isRoaming,
              currentID == expectedCurrentID,
              RoamingPlaylist.next(in: items, currentID: currentID) == nil,
              !contains(video)
        else { return false }

        let window = RoamingPlaylist.insertingNext(
            video,
            in: items,
            currentID: currentID
        )
        items = window.items
        persist()
        return true
    }

    @discardableResult
    func replaceRoamingNext(with video: VideoSearchResult) -> Bool {
        guard isRoaming,
              let currentID,
              video.id != currentID
        else { return false }

        let window = RoamingPlaylist.insertingNext(
            video,
            in: items,
            currentID: currentID
        )
        guard window.items != items || window.currentID != self.currentID else {
            return false
        }
        items = window.items
        self.currentID = window.currentID
        persist()
        return true
    }

    func markSaved(as playlist: SavedPlaylist) {
        savedPlaylistID = playlist.id
        savedPlaylistName = playlist.name
        persist()
    }

    func updateSavedPlaylistName(id: UUID, name: String) {
        guard savedPlaylistID == id else { return }
        savedPlaylistName = name
        persist()
    }

    func updatePlaybackSourcePlaylistID(_ playlistID: UUID?) {
        guard playbackSourcePlaylistID != playlistID else { return }
        playbackSourcePlaylistID = playlistID
        persist()
    }

    func updateResume(partIndex: Int, position: TimeInterval) {
        guard currentID != nil else { return }
        resumePartIndex = max(0, partIndex)
        resumePosition = max(0, position.isFinite ? position : 0)
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(
            items: items,
            currentID: currentID,
            resumePartIndex: resumePartIndex,
            resumePosition: resumePosition,
            savedPlaylistID: savedPlaylistID,
            savedPlaylistName: savedPlaylistName,
            playbackSourcePlaylistID: playbackSourcePlaylistID
        )
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: storageURL, options: .atomic)
        } catch {
            // A transient persistence failure must not interrupt playback.
        }
        onPersist?()
    }

    private static func load(from url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    private static var defaultStorageURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("AnnoyO", isDirectory: true)
            .appendingPathComponent("playback-queue.json")
    }

}

private struct Snapshot: Codable {
    let items: [VideoSearchResult]
    let currentID: String?
    let resumePartIndex: Int
    let resumePosition: TimeInterval
    let savedPlaylistID: UUID?
    let savedPlaylistName: String?
    let playbackSourcePlaylistID: UUID?
}
