import Combine
import Foundation

struct SavedPlaylist: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var items: [VideoSearchResult]
    var currentID: String?
    var resumePartIndex: Int
    var resumePosition: TimeInterval

    var isRoaming: Bool { id == RoamingPlaylist.id }
}

@MainActor
final class SavedPlaylistStore: ObservableObject {
    @Published private(set) var playlists: [SavedPlaylist]

    private let storageURL: URL

    convenience init() {
        self.init(storageURL: Self.defaultStorageURL)
    }

    init(storageURL: URL) {
        self.storageURL = storageURL
        let archive = Self.load(from: storageURL)
        let prepared = Self.preparingPlaylists(archive.playlists)
        playlists = prepared.playlists
        if prepared.didChange {
            persist()
        }
    }

    var roamingPlaylist: SavedPlaylist {
        playlists.first(where: \.isRoaming)!
    }

    @discardableResult
    func createEmptyPlaylist() -> SavedPlaylist {
        createPlaylist(items: [], currentID: nil, resumePartIndex: 0, resumePosition: 0)
    }

    func update(_ playlistID: UUID, from queue: PlaybackQueue) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let window = playlists[index].isRoaming
            ? RoamingPlaylist.normalized(items: queue.items, currentID: queue.currentID)
            : RoamingPlaylist.Window(items: queue.items, currentID: queue.currentID)
        playlists[index].items = window.items
        playlists[index].currentID = window.currentID
        playlists[index].resumePartIndex = queue.resumePartIndex
        playlists[index].resumePosition = queue.resumePosition
        playlists[index].updatedAt = Date()
        persist()
    }

    func updatePlaybackState(
        _ playlistID: UUID,
        currentID: String?,
        resumePartIndex: Int,
        resumePosition: TimeInterval
    ) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              currentID == nil || playlists[index].items.contains(where: { $0.id == currentID })
        else { return }
        if playlists[index].isRoaming {
            let window: RoamingPlaylist.Window
            if let currentID,
               let video = playlists[index].items.first(where: { $0.id == currentID }) {
                window = RoamingPlaylist.selecting(
                    video,
                    in: playlists[index].items,
                    currentID: playlists[index].currentID
                )
            } else {
                window = RoamingPlaylist.normalized(
                    items: playlists[index].items,
                    currentID: nil
                )
            }
            playlists[index].items = window.items
            playlists[index].currentID = window.currentID
        } else {
            playlists[index].currentID = currentID
        }
        playlists[index].resumePartIndex = max(0, resumePartIndex)
        playlists[index].resumePosition = max(0, resumePosition.isFinite ? resumePosition : 0)
        playlists[index].updatedAt = Date()
        persist()
    }

    private func createPlaylist(
        items: [VideoSearchResult],
        currentID: String?,
        resumePartIndex: Int,
        resumePosition: TimeInterval
    ) -> SavedPlaylist {
        let now = Date()
        let playlist = SavedPlaylist(
            id: UUID(),
            name: nextAvailableName(),
            createdAt: now,
            updatedAt: now,
            items: items,
            currentID: currentID,
            resumePartIndex: max(0, resumePartIndex),
            resumePosition: max(0, resumePosition.isFinite ? resumePosition : 0)
        )
        playlists.append(playlist)
        persist()
        return playlist
    }

    func rename(_ playlist: SavedPlaylist, to proposedName: String) {
        guard !playlist.isRoaming else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !playlists.contains(where: { $0.id != playlist.id && $0.name == name }),
              let index = playlists.firstIndex(where: { $0.id == playlist.id })
        else { return }
        playlists[index].name = name
        playlists[index].updatedAt = Date()
        persist()
    }

    func delete(_ playlist: SavedPlaylist) {
        guard !playlist.isRoaming else { return }
        playlists.removeAll { $0.id == playlist.id }
        persist()
    }

    @discardableResult
    func insertRoamingNextIfMissing(
        _ video: VideoSearchResult,
        after currentID: String
    ) -> Bool {
        guard let index = playlists.firstIndex(where: \.isRoaming),
              playlists[index].currentID == currentID,
              RoamingPlaylist.next(
                in: playlists[index].items,
                currentID: currentID
              ) == nil,
              !playlists[index].items.contains(where: { $0.id == video.id })
        else { return false }

        let window = RoamingPlaylist.insertingNext(
            video,
            in: playlists[index].items,
            currentID: currentID
        )
        playlists[index].items = window.items
        playlists[index].updatedAt = Date()
        persist()
        return true
    }

    func replaceRoamingContents(from queue: PlaybackQueue) {
        guard let index = playlists.firstIndex(where: \.isRoaming) else { return }
        let window = RoamingPlaylist.normalized(
            items: queue.items,
            currentID: queue.currentID
        )
        playlists[index].items = window.items
        playlists[index].currentID = window.currentID
        playlists[index].resumePartIndex = max(0, queue.resumePartIndex)
        playlists[index].resumePosition = max(
            0,
            queue.resumePosition.isFinite ? queue.resumePosition : 0
        )
        playlists[index].updatedAt = Date()
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let archive = SavedPlaylistArchive(playlists: playlists)
            try encoder.encode(archive).write(to: storageURL, options: .atomic)
        } catch {
            // Saving a named playlist must never interrupt current playback.
        }
    }

    private static func load(from url: URL) -> SavedPlaylistArchive {
        guard let data = try? Data(contentsOf: url) else {
            return SavedPlaylistArchive(playlists: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let archive = try? decoder.decode(SavedPlaylistArchive.self, from: data) {
            return archive
        }
        if let legacyPlaylists = try? decoder.decode([SavedPlaylist].self, from: data) {
            return SavedPlaylistArchive(
                playlists: legacyPlaylists
            )
        }
        return SavedPlaylistArchive(playlists: [])
    }

    private static func preparingPlaylists(
        _ loadedPlaylists: [SavedPlaylist]
    ) -> (playlists: [SavedPlaylist], didChange: Bool) {
        let now = Date()
        var didChange = false
        var roaming = loadedPlaylists.first(where: \.isRoaming)
        let userPlaylists = loadedPlaylists
            .filter { !$0.isRoaming }
            .sorted { $0.createdAt < $1.createdAt }

        if var existing = roaming {
            let window = RoamingPlaylist.normalized(
                items: existing.items,
                currentID: existing.currentID
            )
            if existing.name != RoamingPlaylist.name
                || existing.items != window.items
                || existing.currentID != window.currentID {
                existing.name = RoamingPlaylist.name
                existing.items = window.items
                existing.currentID = window.currentID
                existing.updatedAt = now
                roaming = existing
                didChange = true
            }
        } else {
            roaming = SavedPlaylist(
                id: RoamingPlaylist.id,
                name: RoamingPlaylist.name,
                createdAt: now,
                updatedAt: now,
                items: [],
                currentID: nil,
                resumePartIndex: 0,
                resumePosition: 0
            )
            didChange = true
        }

        return ([roaming!] + userPlaylists, didChange)
    }

    private static var defaultStorageURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("AnnoyO", isDirectory: true)
            .appendingPathComponent("saved-playlists.json")
    }

    private func nextAvailableName() -> String {
        let usedIndices = Set(playlists.compactMap { playlistIndex(from: $0.name) })
        var index = 1
        while usedIndices.contains(index) {
            index += 1
        }
        return "播放列表\(index)"
    }

    private func playlistIndex(from name: String) -> Int? {
        let prefix = "播放列表"
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard !suffix.isEmpty,
              suffix.allSatisfy(\.isNumber),
              let index = Int(suffix),
              index > 0
        else { return nil }
        return index
    }
}

private struct SavedPlaylistArchive: Codable {
    let playlists: [SavedPlaylist]
}
