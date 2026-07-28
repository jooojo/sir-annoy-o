import Combine
import Foundation

@MainActor
final class PlaybackQueue: ObservableObject {
    @Published private(set) var items: [PlaybackItem]
    @Published private(set) var currentID: String? {
        didSet {
            if !suppressesCurrentSelectionChanged,
                currentID != nil,
                currentID != oldValue
            {
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

    var current: PlaybackItem? {
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

    func contains(_ item: PlaybackItem) -> Bool {
        items.contains { $0.id == item.id }
    }

    func contains(_ video: VideoSearchResult) -> Bool {
        items.contains { $0.video.id == video.id }
    }

    func playNow(_ item: PlaybackItem) {
        if isRoaming {
            let window = RoamingPlaylist.selecting(
                item,
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

        if !contains(item) {
            let insertionIndex: Int
            if let currentID, let index = items.firstIndex(where: { $0.id == currentID }) {
                insertionIndex = index + 1
            } else {
                insertionIndex = items.endIndex
            }
            items.insert(item, at: insertionIndex)
        }
        currentID = item.id
        resumePartIndex = 0
        resumePosition = 0
        persist()
    }

    func playNow(_ video: VideoSearchResult) {
        playNow(PlaybackItem(video: video))
    }

    func enqueue(_ item: PlaybackItem) {
        if isRoaming {
            if currentID != nil {
                _ = replaceRoamingNext(with: item)
            } else {
                let window = RoamingPlaylist.insertingNext(
                    item,
                    in: items,
                    currentID: nil
                )
                guard window.items != items else { return }
                items = window.items
                persist()
            }
            return
        }

        guard !contains(item) else { return }
        items.append(item)
        persist()
    }

    func enqueue(_ video: VideoSearchResult) {
        enqueue(PlaybackItem(video: video))
    }

    func select(_ item: PlaybackItem) {
        guard contains(item) else { return }
        if isRoaming {
            let window = RoamingPlaylist.selecting(
                item,
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
        currentID = item.id
        resumePartIndex = 0
        resumePosition = 0
        persist()
    }

    func select(_ video: VideoSearchResult) {
        guard let item = items.first(where: { $0.video.id == video.id }) else { return }
        select(item)
    }

    @discardableResult
    func advance() -> PlaybackItem? {
        let next: PlaybackItem?
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
    func retreat() -> PlaybackItem? {
        guard let currentID,
            let index = items.firstIndex(where: { $0.id == currentID }),
            items.indices.contains(index - 1)
        else { return nil }
        let previous = items[index - 1]
        select(previous)
        return previous
    }

    func remove(_ item: PlaybackItem) {
        guard contains(item) else { return }
        items.removeAll { $0.id == item.id }
        if currentID == item.id {
            currentID = nil
            resumePartIndex = 0
            resumePosition = 0
        }
        persist()
    }

    func remove(_ video: VideoSearchResult) {
        let matchingItems = items.filter { $0.video.id == video.id }
        for item in matchingItems {
            remove(item)
        }
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

    func moveToTop(_ item: PlaybackItem) {
        if isRoaming {
            enqueue(item)
            return
        }
        guard item.id != currentID,
            items.contains(where: { $0.id == item.id })
        else { return }

        let remaining = items.filter { $0.id != item.id && $0.id != currentID }
        if let current = items.first(where: { $0.id == currentID }) {
            items = [current, item] + remaining
        } else {
            items = [item] + remaining
        }
        persist()
    }

    func moveToTop(_ video: VideoSearchResult) {
        guard let item = items.first(where: { $0.video.id == video.id }) else { return }
        moveToTop(item)
    }

    func clear() {
        items = []
        currentID = nil
        resumePartIndex = 0
        resumePosition = 0
        persist()
    }

    func replace(
        items newItems: [PlaybackItem],
        currentID requestedCurrentID: String?,
        resumePartIndex newPartIndex: Int,
        resumePosition newPosition: TimeInterval,
        savedPlaylistID newSavedPlaylistID: UUID? = nil,
        savedPlaylistName newSavedPlaylistName: String? = nil
    ) {
        suppressesCurrentSelectionChanged = true
        defer { suppressesCurrentSelectionChanged = false }
        let window =
            newSavedPlaylistID == RoamingPlaylist.id
            ? RoamingPlaylist.normalized(items: newItems, currentID: requestedCurrentID)
            : RoamingPlaylist.Window(items: newItems, currentID: requestedCurrentID)
        items = window.items
        if let requestedCurrentID = window.currentID,
            window.items.contains(where: { $0.id == requestedCurrentID })
        {
            currentID = requestedCurrentID
        } else {
            currentID =
                newSavedPlaylistID == RoamingPlaylist.id
                ? nil
                : window.items.first?.id
        }
        resumePartIndex = max(0, newPartIndex)
        resumePosition = max(0, newPosition.isFinite ? newPosition : 0)
        savedPlaylistID = newSavedPlaylistID
        savedPlaylistName = newSavedPlaylistName
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
        replace(
            items: newItems.map { PlaybackItem(video: $0) },
            currentID: requestedCurrentID,
            resumePartIndex: newPartIndex,
            resumePosition: newPosition,
            savedPlaylistID: newSavedPlaylistID,
            savedPlaylistName: newSavedPlaylistName
        )
    }

    @discardableResult
    func insertRoamingNextIfMissing(
        _ item: PlaybackItem,
        after expectedCurrentID: String
    ) -> Bool {
        guard isRoaming,
            currentID == expectedCurrentID,
            RoamingPlaylist.next(in: items, currentID: currentID) == nil,
            !contains(item)
        else { return false }

        let window = RoamingPlaylist.insertingNext(
            item,
            in: items,
            currentID: currentID
        )
        items = window.items
        persist()
        return true
    }

    @discardableResult
    func insertRoamingNextIfMissing(
        _ video: VideoSearchResult,
        after expectedCurrentID: String
    ) -> Bool {
        insertRoamingNextIfMissing(
            PlaybackItem(video: video),
            after: expectedCurrentID
        )
    }

    @discardableResult
    func replaceRoamingNext(with item: PlaybackItem) -> Bool {
        guard isRoaming,
            let currentID,
            item.id != currentID
        else { return false }

        let window = RoamingPlaylist.insertingNext(
            item,
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

    @discardableResult
    func replaceRoamingNext(with video: VideoSearchResult) -> Bool {
        replaceRoamingNext(with: PlaybackItem(video: video))
    }

    @discardableResult
    func expand(
        _ placeholder: PlaybackItem,
        into expandedItems: [PlaybackItem],
        selecting selectedID: String?
    ) -> PlaybackItem? {
        guard let placeholderIndex = items.firstIndex(where: { $0.id == placeholder.id }),
            !expandedItems.isEmpty
        else { return nil }

        let wasCurrent = currentID == placeholder.id
        let selected =
            selectedID.flatMap { id in expandedItems.first(where: { $0.id == id }) }
            ?? expandedItems.first!
        var replacement = items
        replacement.remove(at: placeholderIndex)
        replacement.insert(contentsOf: expandedItems, at: placeholderIndex)
        var seenIDs = Set<String>()
        replacement = replacement.filter { seenIDs.insert($0.id).inserted }

        if isRoaming {
            let requestedCurrentID = wasCurrent ? selected.id : currentID
            let window = RoamingPlaylist.normalized(
                items: replacement,
                currentID: requestedCurrentID
            )
            items = window.items
            currentID = window.currentID
        } else {
            items = replacement
            if wasCurrent {
                currentID = selected.id
            }
        }
        if wasCurrent {
            resumePartIndex = 0
        }
        persist()
        return items.first(where: { $0.id == selected.id })
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
        return
            root
            .appendingPathComponent("AnnoyO", isDirectory: true)
            .appendingPathComponent("playback-queue.json")
    }

}

private struct Snapshot: Codable {
    let items: [PlaybackItem]
    let currentID: String?
    let resumePartIndex: Int
    let resumePosition: TimeInterval
    let savedPlaylistID: UUID?
    let savedPlaylistName: String?
    let playbackSourcePlaylistID: UUID?
}
