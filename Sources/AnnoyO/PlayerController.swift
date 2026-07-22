import AppKit
import AVFoundation
import Combine
import MediaPlayer

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var searchResults: [VideoSearchResult] = []
    @Published private(set) var hasMoreSearchResults = false
    @Published private(set) var searchPaginationError: String?
    @Published private(set) var currentVideo: VideoSearchResult?
    @Published private(set) var playbackState: PlaybackState = .idle
    @Published private(set) var isSearching = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentPart: VideoPart?
    @Published private(set) var totalParts = 0
    @Published var volume: Double = 0.8 {
        didSet { player.volume = Float(volume) }
    }
    @Published var notice: String?
    @Published private(set) var account: BilibiliAccount?
    @Published private(set) var playingPlaylistID: UUID?
    @Published private(set) var playbackOrderMode: PlaybackOrderMode = .repeatAll
    @Published private(set) var playlistTransitionDirection = 1

    let playbackQueue: PlaybackQueue
    let audioLevel = AudioReactiveLevel()
    let savedPlaylists: SavedPlaylistStore

    private let service: BilibiliService
    private let audioCache: AudioCache
    private let player = AVPlayer()
    private var currentResourceLoader: AudioResourceLoader?
    private var currentParts: [VideoPart] = []
    private var currentPartIndex = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var relatedVideoTask: Task<Void, Never>?
    private var searchQuery = ""
    private var searchPage = 0
    private var searchGeneration = UUID()
    private var cancellables = Set<AnyCancellable>()
    private var playbackIntent = false
    private var playbackBaseline: TimeInterval = 0
    private var lastPersistedPosition: TimeInterval = 0
    private var shufflePlaylistID: UUID?
    private var shuffleOrder: [String] = []
    private var shuffleCursor = 0

    convenience init(service: BilibiliService = .shared) {
        self.init(
            service: service,
            playbackQueue: PlaybackQueue(),
            audioCache: .shared,
            restoresQueue: true
        )
    }

    init(
        service: BilibiliService,
        playbackQueue: PlaybackQueue,
        audioCache: AudioCache,
        restoresQueue: Bool,
        savedPlaylists: SavedPlaylistStore? = nil
    ) {
        self.service = service
        self.playbackQueue = playbackQueue
        self.audioCache = audioCache
        self.savedPlaylists = savedPlaylists ?? SavedPlaylistStore()
        player.volume = Float(volume)
        player.automaticallyWaitsToMinimizeStalling = false

        let initialPlaylist: SavedPlaylist
        if let activeID = playbackQueue.savedPlaylistID,
           let active = self.savedPlaylists.playlists.first(where: { $0.id == activeID }) {
            self.savedPlaylists.update(active.id, from: playbackQueue)
            initialPlaylist = self.savedPlaylists.playlists.first(where: { $0.id == active.id }) ?? active
        } else if !playbackQueue.items.isEmpty {
            self.savedPlaylists.replaceRoamingContents(from: playbackQueue)
            initialPlaylist = self.savedPlaylists.roamingPlaylist
        } else {
            initialPlaylist = self.savedPlaylists.roamingPlaylist
        }
        playbackQueue.replace(
            items: initialPlaylist.items,
            currentID: initialPlaylist.currentID,
            resumePartIndex: initialPlaylist.resumePartIndex,
            resumePosition: initialPlaylist.resumePosition,
            savedPlaylistID: initialPlaylist.id,
            savedPlaylistName: initialPlaylist.name
        )
        playbackQueue.onPersist = { [weak self] in
            self?.persistActivePlaylist()
        }

        playbackQueue.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.savedPlaylists.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        installObservers()
        configureRemoteCommands()
        updateNowPlaying()
        if restoresQueue {
            if let sourceID = playbackQueue.playbackSourcePlaylistID,
               let source = self.savedPlaylists.playlists.first(where: { $0.id == sourceID }),
               let currentID = source.currentID,
               let current = source.items.first(where: { $0.id == currentID }) {
                setPlayingPlaylistID(sourceID)
                load(
                    current,
                    partIndex: source.resumePartIndex,
                    knownParts: nil,
                    autoplay: false,
                    resumeAt: source.resumePosition
                )
            } else if let current = playbackQueue.current {
                setPlayingPlaylistID(initialPlaylist.id)
                load(
                    current,
                    partIndex: playbackQueue.resumePartIndex,
                    knownParts: nil,
                    autoplay: false,
                    resumeAt: playbackQueue.resumePosition
                )
            } else {
                setPlayingPlaylistID(nil)
            }
        }
    }

    func search(_ keyword: String) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        searchGeneration = UUID()
        searchQuery = query
        searchPage = 0
        searchResults = []
        hasMoreSearchResults = false
        searchPaginationError = nil
        notice = nil
        loadSearchPage(1, replacing: true, generation: searchGeneration)
    }

    func loadMoreSearchResults() {
        guard !isSearching,
              hasMoreSearchResults,
              searchPaginationError == nil,
              !searchQuery.isEmpty
        else { return }
        loadSearchPage(searchPage + 1, replacing: false, generation: searchGeneration)
    }

    func retryLoadingSearchResults() {
        guard searchPaginationError != nil else { return }
        searchPaginationError = nil
        loadMoreSearchResults()
    }

    private func loadSearchPage(_ page: Int, replacing: Bool, generation: UUID) {
        let query = searchQuery
        isSearching = true
        searchTask = Task { [weak self, service] in
            do {
                let pageResults = try await service.search(keyword: query, page: page)
                guard !Task.isCancelled,
                      let self,
                      self.searchGeneration == generation
                else { return }

                let existingIDs = replacing ? Set<String>() : Set(self.searchResults.map(\.id))
                var seenIDs = existingIDs
                let uniqueResults = pageResults.filter { seenIDs.insert($0.id).inserted }
                if replacing {
                    self.searchResults = uniqueResults
                } else {
                    self.searchResults.append(contentsOf: uniqueResults)
                }
                self.searchPage = page
                self.hasMoreSearchResults = !pageResults.isEmpty && !uniqueResults.isEmpty
                self.searchPaginationError = nil
                self.isSearching = false
                if replacing, uniqueResults.isEmpty {
                    self.notice = "没有找到相关视频"
                }
            } catch is CancellationError {
                guard let self, self.searchGeneration == generation else { return }
                self.isSearching = false
            } catch {
                guard let self, self.searchGeneration == generation else { return }
                self.isSearching = false
                if replacing {
                    self.notice = error.localizedDescription
                } else {
                    self.searchPaginationError = error.localizedDescription
                }
            }
        }
    }

    func play(_ video: VideoSearchResult) {
        playbackQueue.playNow(video)
        setPlayingPlaylistID(playbackQueue.savedPlaylistID)
        resetShuffleOrder(startingAt: video)
        load(video, partIndex: 0, knownParts: nil, autoplay: true)
    }

    func enqueue(_ video: VideoSearchResult) {
        playbackQueue.enqueue(video)
        notice = playbackQueue.isRoaming ? "已设为漫游下一首" : "已加入播放队列"
    }

    func playQueued(_ video: VideoSearchResult) {
        playbackQueue.select(video)
        setPlayingPlaylistID(playbackQueue.savedPlaylistID)
        resetShuffleOrder(startingAt: video)
        load(video, partIndex: 0, knownParts: nil, autoplay: true)
    }

    func removeFromQueue(_ video: VideoSearchResult) {
        guard isDisplayingPlayingPlaylist, currentVideo?.id == video.id else {
            playbackQueue.remove(video)
            requestRoamingRecommendationIfNeeded()
            return
        }

        let items = playbackQueue.items
        let currentIndex = items.firstIndex(where: { $0.id == video.id })
        let replacement: VideoSearchResult?
        if let currentIndex, items.indices.contains(currentIndex + 1) {
            replacement = items[currentIndex + 1]
        } else if let currentIndex, items.indices.contains(currentIndex - 1) {
            replacement = items[currentIndex - 1]
        } else {
            replacement = nil
        }
        let shouldAutoplay = playbackIntent || playbackState.isPlaying

        playbackQueue.remove(video)
        if let replacement {
            playbackQueue.select(replacement)
            resetShuffleOrder(startingAt: replacement)
            load(replacement, partIndex: 0, knownParts: nil, autoplay: shouldAutoplay)
        } else {
            stopPlaybackAndClearCurrent()
        }
    }

    func cacheSummary() -> AudioCacheSummary {
        audioCache.summary()
    }

    func clearAudioCache() {
        audioCache.clear()
    }

    func renameSavedPlaylist(_ playlist: SavedPlaylist, to name: String) {
        guard !playlist.isRoaming else { return }
        savedPlaylists.rename(playlist, to: name)
        if let renamed = savedPlaylists.playlists.first(where: { $0.id == playlist.id }) {
            playbackQueue.updateSavedPlaylistName(id: renamed.id, name: renamed.name)
        }
    }

    func deleteSavedPlaylist(_ playlist: SavedPlaylist) {
        guard !playlist.isRoaming else { return }
        let wasActive = playbackQueue.savedPlaylistID == playlist.id
        if playingPlaylistID == playlist.id {
            setPlayingPlaylistID(nil)
        }
        savedPlaylists.delete(playlist)
        guard wasActive else { return }
        let replacement = savedPlaylists.roamingPlaylist
        loadSavedPlaylist(replacement)
    }

    func loadSavedPlaylist(_ playlist: SavedPlaylist, direction: Int? = nil) {
        if playbackQueue.savedPlaylistID != playlist.id {
            playlistTransitionDirection = direction ?? navigationDirection(to: playlist.id)
        }
        persistActivePlaylist()
        playbackQueue.replace(
            items: playlist.items,
            currentID: playlist.currentID,
            resumePartIndex: playlist.resumePartIndex,
            resumePosition: playlist.resumePosition,
            savedPlaylistID: playlist.id,
            savedPlaylistName: playlist.name
        )
        notice = "已切换至“\(playlist.name)”"
    }

    func createPlaylist() {
        persistActivePlaylist()
        let playlist = savedPlaylists.createEmptyPlaylist()
        loadSavedPlaylist(playlist, direction: 1)
    }

    func switchPlaylist(by offset: Int) {
        let playlists = savedPlaylists.playlists
        guard playlists.count > 1 else { return }
        let currentIndex = playbackQueue.savedPlaylistID
            .flatMap { id in playlists.firstIndex(where: { $0.id == id }) }
            ?? 0
        let targetIndex = (currentIndex + offset % playlists.count + playlists.count) % playlists.count
        loadSavedPlaylist(playlists[targetIndex], direction: offset >= 0 ? 1 : -1)
    }

    var canSwitchPlaylist: Bool {
        savedPlaylists.playlists.count > 1
    }

    var isDisplayingPlayingPlaylist: Bool {
        currentVideo != nil
            && playingPlaylistID != nil
            && playbackQueue.savedPlaylistID == playingPlaylistID
    }

    var canReturnToPlayingPlaylist: Bool {
        guard currentVideo != nil, let playingPlaylistID else { return false }
        return savedPlaylists.playlists.contains(where: { $0.id == playingPlaylistID })
    }

    @discardableResult
    func returnToPlayingPlaylist() -> Bool {
        guard canReturnToPlayingPlaylist,
              let playingPlaylistID,
              let playlist = savedPlaylists.playlists.first(where: { $0.id == playingPlaylistID })
        else { return false }
        if playbackQueue.savedPlaylistID != playingPlaylistID {
            loadSavedPlaylist(playlist)
        }
        return true
    }

    func cyclePlaybackOrderMode() {
        switch playbackOrderMode {
        case .repeatAll:
            playbackOrderMode = .repeatOne
        case .repeatOne:
            playbackOrderMode = .shuffle
        case .shuffle:
            playbackOrderMode = .repeatAll
        }
        if playbackOrderMode == .shuffle, let currentVideo {
            resetShuffleOrder(startingAt: currentVideo)
        } else {
            clearShuffleOrder()
        }
    }

    func togglePlayback() {
        switch playbackState {
        case .playing, .buffering:
            pausePlayback()
        case .paused:
            resumePlayback()
        case .idle, .failed:
            if let currentVideo {
                load(
                    currentVideo,
                    partIndex: currentPartIndex,
                    knownParts: currentParts.isEmpty ? nil : currentParts,
                    autoplay: true
                )
            }
        case .resolving:
            break
        }
    }

    func playNext() {
        guard let currentVideo else { return }
        if currentParts.indices.contains(currentPartIndex + 1) {
            updatePlayingResume(partIndex: currentPartIndex + 1, position: 0)
            load(
                currentVideo,
                partIndex: currentPartIndex + 1,
                knownParts: currentParts,
                autoplay: true
            )
            return
        }
        let next = playbackOrderMode == .shuffle
            ? nextShuffledVideo(after: currentVideo)
            : adjacentPlayingVideo(
                to: currentVideo,
                offset: 1,
                wrapping: playingPlaylistID != RoamingPlaylist.id
            )
        guard let next else { return }
        selectPlayingVideo(next)
        load(next, partIndex: 0, knownParts: nil, autoplay: true)
    }

    func playPrevious() {
        if elapsed > 4 {
            seek(to: 0)
            return
        }
        guard let currentVideo else { return }
        if currentParts.indices.contains(currentPartIndex - 1) {
            updatePlayingResume(partIndex: currentPartIndex - 1, position: 0)
            load(
                currentVideo,
                partIndex: currentPartIndex - 1,
                knownParts: currentParts,
                autoplay: true
            )
            return
        }
        let previous = playbackOrderMode == .shuffle
            ? previousShuffledVideo(before: currentVideo)
            : adjacentPlayingVideo(
                to: currentVideo,
                offset: -1,
                wrapping: playingPlaylistID != RoamingPlaylist.id
            )
        guard let previous else { return }
        selectPlayingVideo(previous)
        load(previous, partIndex: 0, knownParts: nil, autoplay: true)
    }

    private func replayCurrentVideo() {
        guard let currentVideo else { return }
        updatePlayingResume(partIndex: 0, position: 0)
        load(
            currentVideo,
            partIndex: 0,
            knownParts: currentParts.isEmpty ? nil : currentParts,
            autoplay: true
        )
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let target = CMTime(seconds: max(0, min(seconds, duration)), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = target.seconds
        lastPersistedPosition = elapsed
        updatePlayingResume(partIndex: currentPartIndex, position: elapsed)
        updateNowPlaying()
    }

    func openCurrentVideo() {
        guard let currentVideo else { return }
        openVideo(currentVideo)
    }

    func openVideo(_ video: VideoSearchResult) {
        guard let url = video.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    func resumePlayback() {
        guard currentVideo != nil else { return }
        playbackIntent = true
        playbackBaseline = player.currentTime().seconds.isFinite ? player.currentTime().seconds : elapsed
        player.play()
        playbackState = .buffering
        updateNowPlaying()
    }

    func pausePlayback() {
        playbackIntent = false
        player.pause()
        if currentVideo != nil, playbackState != .resolving {
            playbackState = .paused
            lastPersistedPosition = elapsed
            updatePlayingResume(partIndex: currentPartIndex, position: elapsed)
            updateNowPlaying()
        }
    }

    private func stopPlaybackAndClearCurrent() {
        loadTask?.cancel()
        relatedVideoTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentResourceLoader = nil
        audioLevel.reset()
        playbackIntent = false
        setPlayingPlaylistID(nil)
        currentVideo = nil
        currentParts = []
        currentPart = nil
        currentPartIndex = 0
        totalParts = 0
        elapsed = 0
        duration = 0
        lastPersistedPosition = 0
        playbackState = .idle
        updateNowPlaying()
    }

    private func setPlayingPlaylistID(_ playlistID: UUID?) {
        if playingPlaylistID != playlistID {
            clearShuffleOrder()
            relatedVideoTask?.cancel()
        }
        playingPlaylistID = playlistID
        playbackQueue.updatePlaybackSourcePlaylistID(playlistID)
    }

    private func navigationDirection(to targetID: UUID) -> Int {
        let playlists = savedPlaylists.playlists
        guard let currentID = playbackQueue.savedPlaylistID,
              let currentIndex = playlists.firstIndex(where: { $0.id == currentID }),
              let targetIndex = playlists.firstIndex(where: { $0.id == targetID })
        else { return 1 }
        return targetIndex >= currentIndex ? 1 : -1
    }

    private func persistActivePlaylist() {
        guard let playlistID = playbackQueue.savedPlaylistID else { return }
        savedPlaylists.update(playlistID, from: playbackQueue)
    }

    private var playingPlaylistItems: [VideoSearchResult] {
        guard let playingPlaylistID else { return [] }
        if playbackQueue.savedPlaylistID == playingPlaylistID {
            return playbackQueue.items
        }
        return savedPlaylists.playlists.first(where: { $0.id == playingPlaylistID })?.items ?? []
    }

    private func adjacentPlayingVideo(
        to video: VideoSearchResult,
        offset: Int,
        wrapping: Bool = false
    ) -> VideoSearchResult? {
        let items = playingPlaylistItems
        guard let index = items.firstIndex(where: { $0.id == video.id }) else { return nil }
        let targetIndex = index + offset
        if items.indices.contains(targetIndex) {
            return items[targetIndex]
        }
        guard wrapping, !items.isEmpty else { return nil }
        return offset >= 0 ? items.first : items.last
    }

    private func resetShuffleOrder(startingAt video: VideoSearchResult) {
        guard playbackOrderMode == .shuffle,
              let playingPlaylistID,
              playingPlaylistItems.contains(where: { $0.id == video.id })
        else {
            clearShuffleOrder()
            return
        }
        shufflePlaylistID = playingPlaylistID
        shuffleOrder = [video.id] + playingPlaylistItems
            .filter { $0.id != video.id }
            .map(\.id)
            .shuffled()
        shuffleCursor = 0
    }

    private func clearShuffleOrder() {
        shufflePlaylistID = nil
        shuffleOrder = []
        shuffleCursor = 0
    }

    private func reconcileShuffleOrder(currentVideo: VideoSearchResult) {
        let itemIDs = Set(playingPlaylistItems.map(\.id))
        let orderIDs = Set(shuffleOrder)
        guard shufflePlaylistID == playingPlaylistID,
              itemIDs == orderIDs,
              shuffleOrder.indices.contains(shuffleCursor),
              shuffleOrder[shuffleCursor] == currentVideo.id
        else {
            resetShuffleOrder(startingAt: currentVideo)
            return
        }
    }

    private func nextShuffledVideo(after currentVideo: VideoSearchResult) -> VideoSearchResult? {
        reconcileShuffleOrder(currentVideo: currentVideo)
        if !shuffleOrder.indices.contains(shuffleCursor + 1) {
            resetShuffleOrder(startingAt: currentVideo)
        }
        guard shuffleOrder.indices.contains(shuffleCursor + 1) else { return nil }
        shuffleCursor += 1
        let nextID = shuffleOrder[shuffleCursor]
        return playingPlaylistItems.first(where: { $0.id == nextID })
    }

    private func previousShuffledVideo(before currentVideo: VideoSearchResult) -> VideoSearchResult? {
        reconcileShuffleOrder(currentVideo: currentVideo)
        guard shuffleCursor > 0 else { return nil }
        shuffleCursor -= 1
        let previousID = shuffleOrder[shuffleCursor]
        return playingPlaylistItems.first(where: { $0.id == previousID })
    }

    private func selectPlayingVideo(_ video: VideoSearchResult) {
        guard let playingPlaylistID else { return }
        if playbackQueue.savedPlaylistID == playingPlaylistID {
            playbackQueue.select(video)
        } else {
            savedPlaylists.updatePlaybackState(
                playingPlaylistID,
                currentID: video.id,
                resumePartIndex: 0,
                resumePosition: 0
            )
        }
    }

    private func updatePlayingResume(partIndex: Int, position: TimeInterval) {
        guard let playingPlaylistID, let currentVideo else { return }
        if playbackQueue.savedPlaylistID == playingPlaylistID {
            playbackQueue.updateResume(partIndex: partIndex, position: position)
        } else {
            savedPlaylists.updatePlaybackState(
                playingPlaylistID,
                currentID: currentVideo.id,
                resumePartIndex: partIndex,
                resumePosition: position
            )
        }
    }

    func refreshAccount() {
        Task { [weak self, service] in
            let account = try? await service.account()
            self?.account = account
        }
    }

    func logOut() {
        Task { [weak self, service] in
            await service.logOutLocally()
            self?.account = nil
            self?.notice = "已退出本机 Bilibili 账号"
        }
    }

    var canGoNext: Bool {
        currentParts.indices.contains(currentPartIndex + 1)
            || (playbackOrderMode == .shuffle
                ? playingPlaylistItems.contains(where: { $0.id != currentVideo?.id })
                : currentVideo.flatMap {
                    adjacentPlayingVideo(
                        to: $0,
                        offset: 1,
                        wrapping: playingPlaylistID != RoamingPlaylist.id
                    )
                } != nil)
    }

    var canGoPrevious: Bool {
        guard let currentVideo else { return false }
        return elapsed > 0
            || currentParts.indices.contains(currentPartIndex - 1)
            || (playbackOrderMode == .shuffle
                ? shuffleCursor > 0
                : adjacentPlayingVideo(
                    to: currentVideo,
                    offset: -1,
                    wrapping: playingPlaylistID != RoamingPlaylist.id
                ) != nil)
    }

    var currentSubtitle: String {
        if let currentPart, totalParts > 1 {
            return "P\(currentPart.number)/\(totalParts) · \(currentPart.title)"
        }
        return currentVideo?.creator ?? ""
    }

    private func load(
        _ video: VideoSearchResult,
        partIndex: Int,
        knownParts: [VideoPart]?,
        autoplay: Bool,
        resumeAt: TimeInterval = 0
    ) {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentResourceLoader = nil
        audioLevel.reset()
        playbackIntent = autoplay
        currentVideo = video
        playbackState = .resolving
        elapsed = max(0, resumeAt)
        lastPersistedPosition = elapsed
        duration = 0
        if knownParts == nil {
            currentParts = []
            currentPart = nil
            currentPartIndex = 0
            totalParts = 0
        }
        notice = nil
        updateNowPlaying()
        requestRoamingRecommendationIfNeeded(for: video)

        loadTask = Task { [weak self, service] in
            do {
                let parts: [VideoPart]
                if let knownParts {
                    parts = knownParts
                } else {
                    parts = try await service.videoParts(for: video)
                }
                guard parts.indices.contains(partIndex), !Task.isCancelled else { return }
                let part = parts[partIndex]
                guard self?.currentVideo == video else { return }
                self?.currentParts = parts
                self?.currentPartIndex = partIndex
                self?.currentPart = part
                self?.totalParts = parts.count
                self?.duration = part.duration
                self?.elapsed = min(max(0, resumeAt), part.duration)

                let stream = try await service.resolveAudio(for: video, part: part)
                let headers = await service.playbackHeaders(for: video)
                guard !Task.isCancelled else { return }

                let cacheKey = AudioCacheKey(
                    bvid: video.bvid,
                    cid: part.cid,
                    representationID: stream.representationID
                )
                guard let cachedAsset = self?.audioCache.makeAsset(
                    key: cacheKey,
                    originURL: stream.url,
                    headers: headers
                ) else { return }
                self?.currentResourceLoader = cachedAsset.resourceLoader
                let asset = cachedAsset.asset
                guard try await asset.load(.isPlayable) else {
                    throw BilibiliError.noAudio
                }
                let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
                let item = AVPlayerItem(asset: asset)
                guard self?.currentVideo == video else { return }
                if let audioTrack = audioTracks?.first {
                    item.audioMix = self?.audioLevel.makeAudioMix(for: audioTrack)
                }
                self?.duration = stream.duration
                self?.player.replaceCurrentItem(with: item)
                if resumeAt > 0 {
                    let resumeTime = CMTime(
                        seconds: min(resumeAt, stream.duration),
                        preferredTimescale: 600
                    )
                    await self?.player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if self?.playbackIntent == true {
                    self?.playbackBaseline = 0
                    self?.playbackState = .buffering
                    self?.player.play()
                } else {
                    self?.playbackState = .paused
                }
                self?.updateNowPlaying()
            } catch is CancellationError {
                return
            } catch {
                self?.playbackIntent = false
                self?.audioLevel.reset()
                self?.playbackState = .failed(error.localizedDescription)
                self?.notice = error.localizedDescription
                self?.updateNowPlaying()
            }
        }
    }

    private func requestRoamingRecommendationIfNeeded(
        for video: VideoSearchResult? = nil
    ) {
        let requestedVideo = video ?? currentVideo
        guard let requestedVideo,
              playingPlaylistID == RoamingPlaylist.id,
              roamingNextVideo(after: requestedVideo.id) == nil
        else { return }

        relatedVideoTask?.cancel()
        let requestedVideoID = requestedVideo.id
        relatedVideoTask = Task { [weak self, service] in
            do {
                guard let recommendation = try await service.topRelatedVideo(for: requestedVideo),
                      !Task.isCancelled,
                      let self,
                      self.playingPlaylistID == RoamingPlaylist.id,
                      self.currentVideo?.id == requestedVideoID
                else { return }

                if self.playbackQueue.savedPlaylistID == RoamingPlaylist.id {
                    _ = self.playbackQueue.insertRoamingNextIfMissing(
                        recommendation,
                        after: requestedVideoID
                    )
                } else {
                    _ = self.savedPlaylists.insertRoamingNextIfMissing(
                        recommendation,
                        after: requestedVideoID
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                // Related videos are opportunistic; playback remains usable without one.
            }
        }
    }

    private func roamingNextVideo(after currentID: String) -> VideoSearchResult? {
        let items: [VideoSearchResult]
        let storedCurrentID: String?
        if playbackQueue.savedPlaylistID == RoamingPlaylist.id {
            items = playbackQueue.items
            storedCurrentID = playbackQueue.currentID
        } else {
            let roaming = savedPlaylists.roamingPlaylist
            items = roaming.items
            storedCurrentID = roaming.currentID
        }
        guard storedCurrentID == currentID else { return nil }
        return RoamingPlaylist.next(in: items, currentID: currentID)
    }

    private func installObservers() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                Task { @MainActor in
                    self?.handleTimeControlStatus(status)
                }
            }
            .store(in: &cancellables)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if time.seconds.isFinite {
                    self.elapsed = max(0, time.seconds)
                    if abs(self.elapsed - self.lastPersistedPosition) >= 5 {
                        self.lastPersistedPosition = self.elapsed
                        self.updatePlayingResume(
                            partIndex: self.currentPartIndex,
                            position: self.elapsed
                        )
                    }
                    if self.playbackIntent,
                       self.playbackState == .buffering,
                       self.elapsed > self.playbackBaseline + 0.01 {
                        self.playbackState = .playing
                        self.updateNowPlaying()
                    }
                }
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.playbackOrderMode == .repeatOne, self.currentVideo != nil {
                    if self.currentParts.indices.contains(self.currentPartIndex + 1) {
                        self.playNext()
                    } else {
                        self.replayCurrentVideo()
                    }
                } else if self.canGoNext { self.playNext() }
                else {
                    self.playbackIntent = false
                    self.playbackState = .paused
                    self.seek(to: 0)
                }
            }
        }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = true

        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resumePlayback() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pausePlayback() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        guard currentVideo != nil else { return }
        switch status {
        case .waitingToPlayAtSpecifiedRate where playbackIntent:
            if playbackState != .resolving {
                playbackBaseline = player.currentTime().seconds.isFinite ? player.currentTime().seconds : elapsed
                playbackState = .buffering
                updateNowPlaying()
            }
        case .paused where !playbackIntent:
            if playbackState != .resolving {
                playbackState = .paused
                updateNowPlaying()
            }
        default:
            break
        }
    }

    private func updateNowPlaying() {
        guard let currentVideo else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentVideo.title,
            MPMediaItemPropertyArtist: currentVideo.creator,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playbackState.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: currentVideo.bvid
        ]
        MPNowPlayingInfoCenter.default().playbackState = playbackState.isPlaying ? .playing : .paused
    }
}
