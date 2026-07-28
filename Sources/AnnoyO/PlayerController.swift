import AVFoundation
import AppKit
import Combine
import MediaPlayer

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var searchResults: [VideoSearchResult] = []
    @Published private(set) var hasMoreSearchResults = false
    @Published private(set) var searchPaginationError: String?
    @Published private(set) var currentItem: PlaybackItem?
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

    var currentVideo: VideoSearchResult? { currentItem?.video }

    private let service: BilibiliService
    private let audioCache: AudioCache
    private let player = AVPlayer()
    private var currentResourceLoader: AudioResourceLoader?
    private var currentParts: [VideoPart] = []
    private var currentPartIndex = 0
    private var currentItemStatusObservation: NSKeyValueObservation?
    private var currentItemGeneration = UUID()
    private var activeLoadID = UUID()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var nextPrefetchTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var relatedVideoTask: Task<Void, Never>?
    private var searchQuery = ""
    private var searchPage = 0
    private var searchGeneration = UUID()
    private var cancellables = Set<AnyCancellable>()
    private var playbackIntent = false
    private var playbackBaseline: TimeInterval = 0
    private var lastPersistedPosition: TimeInterval = 0
    private var lastPlayedVideoID: String?
    private var shufflePlaylistID: UUID?
    private var shuffleHistory: [String] = []
    private var shuffleCursor = 0
    private var roamingRecommendationSourceID: String?
    private var roamingRecommendations: [VideoSearchResult] = []
    private var roamingRecommendationCursor = -1
    private var pendingRoamingRecommendationReplacementSourceID: String?
    private var remoteCommandRegistrations: [(command: MPRemoteCommand, target: Any)] = []

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
        player.automaticallyWaitsToMinimizeStalling = true

        let initialPlaylist: SavedPlaylist
        if let activeID = playbackQueue.savedPlaylistID,
            let active = self.savedPlaylists.playlists.first(where: { $0.id == activeID })
        {
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
        playbackQueue.$items
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleNextPrefetchIfReady()
                }
            }
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
                let current = source.items.first(where: { $0.id == currentID })
            {
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

    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        for registration in remoteCommandRegistrations {
            registration.command.removeTarget(registration.target)
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
        let item =
            playbackQueue.items.first(where: { $0.video.id == video.id })
            ?? PlaybackItem(video: video)
        playbackQueue.playNow(item)
        setPlayingPlaylistID(playbackQueue.savedPlaylistID)
        resetShuffleOrder(startingAt: item)
        load(item, partIndex: 0, knownParts: nil, autoplay: true)
    }

    func enqueue(_ video: VideoSearchResult) {
        guard !playbackQueue.contains(video) else {
            notice = "已在当前列表"
            return
        }
        let item = PlaybackItem(video: video)
        playbackQueue.enqueue(item)
        resolveQueuedItemIfNeeded(item)
        notice = playbackQueue.isRoaming ? "已设为漫游下一首" : "已加入播放队列"
    }

    func replaceRoamingNext(with video: VideoSearchResult) {
        replaceRoamingNext(with: PlaybackItem(video: video))
    }

    func replaceRoamingNext(with item: PlaybackItem) {
        guard playbackQueue.replaceRoamingNext(with: item) else { return }
        resolveQueuedItemIfNeeded(item)
        roamingRecommendationCursor =
            roamingRecommendations.firstIndex(where: {
                $0.id == item.video.id
            }) ?? -1
        notice = "已替换漫游下一首"
    }

    func replaceRoamingNextRecommendation() {
        guard playbackQueue.isRoaming,
            let currentItem = playbackQueue.current,
            currentItem.video.id == roamingRecommendationSourceID
        else {
            pendingRoamingRecommendationReplacementSourceID = playbackQueue.current?.video.id
            requestRoamingRecommendationIfNeeded(for: playbackQueue.current?.video)
            return
        }

        let excludedIDs = Set(playbackQueue.items.map(\.video.id))
        guard let candidate = nextRoamingRecommendation(excluding: excludedIDs),
            playbackQueue.replaceRoamingNext(with: PlaybackItem(video: candidate.video))
        else { return }
        resolveQueuedItemIfNeeded(PlaybackItem(video: candidate.video))

        roamingRecommendationCursor = candidate.index
        notice = "已换一首推荐"
    }

    func playQueued(_ item: PlaybackItem) {
        playbackQueue.select(item)
        setPlayingPlaylistID(playbackQueue.savedPlaylistID)
        resetShuffleOrder(startingAt: item)
        load(item, partIndex: 0, knownParts: nil, autoplay: true)
    }

    func playQueued(_ video: VideoSearchResult) {
        if let item = playbackQueue.items.first(where: { $0.video.id == video.id }) {
            playQueued(item)
        } else {
            play(video)
        }
    }

    func removeFromQueue(_ item: PlaybackItem) {
        guard isDisplayingPlayingPlaylist, currentItem?.id == item.id else {
            playbackQueue.remove(item)
            requestRoamingRecommendationIfNeeded()
            return
        }

        let items = playbackQueue.items
        let currentIndex = items.firstIndex(where: { $0.id == item.id })
        let replacement: PlaybackItem?
        if let currentIndex, items.indices.contains(currentIndex + 1) {
            replacement = items[currentIndex + 1]
        } else if let currentIndex, items.indices.contains(currentIndex - 1) {
            replacement = items[currentIndex - 1]
        } else {
            replacement = nil
        }
        let shouldAutoplay = playbackIntent || playbackState.isPlaying

        playbackQueue.remove(item)
        if let replacement {
            playbackQueue.select(replacement)
            resetShuffleOrder(startingAt: replacement)
            load(replacement, partIndex: 0, knownParts: nil, autoplay: shouldAutoplay)
        } else {
            stopPlaybackAndClearCurrent()
        }
    }

    func removeFromQueue(_ video: VideoSearchResult) {
        guard let item = playbackQueue.items.first(where: { $0.video.id == video.id }) else {
            return
        }
        removeFromQueue(item)
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
        let currentIndex =
            playbackQueue.savedPlaylistID
            .flatMap { id in playlists.firstIndex(where: { $0.id == id }) }
            ?? 0
        let targetIndex = (currentIndex + offset % playlists.count + playlists.count) % playlists.count
        loadSavedPlaylist(playlists[targetIndex], direction: offset >= 0 ? 1 : -1)
    }

    var canSwitchPlaylist: Bool {
        savedPlaylists.playlists.count > 1
    }

    var isDisplayingPlayingPlaylist: Bool {
        currentItem != nil
            && playingPlaylistID != nil
            && playbackQueue.savedPlaylistID == playingPlaylistID
    }

    var canReturnToPlayingPlaylist: Bool {
        guard currentItem != nil, let playingPlaylistID else { return false }
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
        if playbackOrderMode == .shuffle, let currentItem {
            resetShuffleOrder(startingAt: currentItem)
        } else {
            clearShuffleOrder()
        }
        scheduleNextPrefetchIfReady()
    }

    func togglePlayback() {
        switch playbackState {
        case .playing, .buffering:
            pausePlayback()
        case .paused:
            resumePlayback()
        case .idle, .failed:
            retryCurrentPlayback()
        case .resolving:
            break
        }
    }

    func playNext() {
        guard let currentItem else { return }
        if currentParts.indices.contains(currentPartIndex + 1) {
            updatePlayingResume(partIndex: currentPartIndex + 1, position: 0)
            load(
                currentItem,
                partIndex: currentPartIndex + 1,
                knownParts: currentParts,
                autoplay: true
            )
            return
        }
        let next =
            playbackOrderMode == .shuffle
            ? nextShuffledVideo(after: currentItem)
            : adjacentPlayingVideo(
                to: currentItem,
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
        guard let currentItem else { return }
        if currentParts.indices.contains(currentPartIndex - 1) {
            updatePlayingResume(partIndex: currentPartIndex - 1, position: 0)
            load(
                currentItem,
                partIndex: currentPartIndex - 1,
                knownParts: currentParts,
                autoplay: true
            )
            return
        }
        let previous =
            playbackOrderMode == .shuffle
            ? previousShuffledVideo(before: currentItem)
            : adjacentPlayingVideo(
                to: currentItem,
                offset: -1,
                wrapping: playingPlaylistID != RoamingPlaylist.id
            )
        guard let previous else { return }
        selectPlayingVideo(previous)
        load(previous, partIndex: 0, knownParts: nil, autoplay: true)
    }

    private func replayCurrentVideo() {
        guard let currentItem else { return }
        updatePlayingResume(partIndex: 0, position: 0)
        load(
            currentItem,
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
        guard let currentItem else { return }
        openVideo(currentItem)
    }

    func openVideo(_ item: PlaybackItem) {
        guard let url = item.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openVideo(_ video: VideoSearchResult) {
        guard let url = video.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    func resumePlayback() {
        guard currentItem != nil else { return }
        if case .failed = playbackState {
            retryCurrentPlayback()
            return
        }
        cancelNextPrefetch()
        playbackIntent = true
        playbackBaseline = player.currentTime().seconds.isFinite ? player.currentTime().seconds : elapsed
        player.play()
        playbackState = .buffering
        updateNowPlaying()
    }

    func pausePlayback() {
        cancelNextPrefetch()
        playbackIntent = false
        player.pause()
        if currentItem != nil, playbackState != .resolving {
            playbackState = .paused
            lastPersistedPosition = elapsed
            updatePlayingResume(partIndex: currentPartIndex, position: elapsed)
            updateNowPlaying()
        }
    }

    private func stopPlaybackAndClearCurrent() {
        loadTask?.cancel()
        cancelNextPrefetch()
        relatedVideoTask?.cancel()
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = nil
        currentItemGeneration = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentResourceLoader = nil
        audioLevel.reset()
        playbackIntent = false
        setPlayingPlaylistID(nil)
        currentItem = nil
        currentParts = []
        currentPart = nil
        currentPartIndex = 0
        totalParts = 0
        elapsed = 0
        duration = 0
        lastPersistedPosition = 0
        lastPlayedVideoID = nil
        playbackState = .idle
        updateNowPlaying()
    }

    private func retryCurrentPlayback() {
        guard let currentItem else { return }
        load(
            currentItem,
            partIndex: currentPartIndex,
            knownParts: currentParts.isEmpty ? nil : currentParts,
            autoplay: true,
            resumeAt: elapsed
        )
    }

    private func setPlayingPlaylistID(_ playlistID: UUID?) {
        if playingPlaylistID != playlistID {
            clearShuffleOrder()
            relatedVideoTask?.cancel()
            clearRoamingRecommendations()
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

    private var playingPlaylistItems: [PlaybackItem] {
        guard let playingPlaylistID else { return [] }
        if playbackQueue.savedPlaylistID == playingPlaylistID {
            return playbackQueue.items
        }
        return savedPlaylists.playlists.first(where: { $0.id == playingPlaylistID })?.items ?? []
    }

    private func adjacentPlayingVideo(
        to item: PlaybackItem,
        offset: Int,
        wrapping: Bool = false
    ) -> PlaybackItem? {
        let items = playingPlaylistItems
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        let targetIndex = index + offset
        if items.indices.contains(targetIndex) {
            return items[targetIndex]
        }
        guard wrapping, !items.isEmpty else { return nil }
        return offset >= 0 ? items.first : items.last
    }

    private func resetShuffleOrder(startingAt item: PlaybackItem) {
        guard playbackOrderMode == .shuffle,
            let playingPlaylistID,
            playingPlaylistItems.contains(where: { $0.id == item.id })
        else {
            clearShuffleOrder()
            return
        }
        shufflePlaylistID = playingPlaylistID
        shuffleHistory = [item.id]
        shuffleCursor = 0
    }

    private func clearShuffleOrder() {
        shufflePlaylistID = nil
        shuffleHistory = []
        shuffleCursor = 0
    }

    private func reconcileShuffleOrder(currentVideo: PlaybackItem) {
        let itemIDs = Set(playingPlaylistItems.map(\.id))
        guard shufflePlaylistID == playingPlaylistID,
            shuffleHistory.allSatisfy(itemIDs.contains),
            shuffleHistory.indices.contains(shuffleCursor),
            shuffleHistory[shuffleCursor] == currentVideo.id
        else {
            resetShuffleOrder(startingAt: currentVideo)
            return
        }
    }

    private func nextShuffledVideo(after currentVideo: PlaybackItem) -> PlaybackItem? {
        reconcileShuffleOrder(currentVideo: currentVideo)
        let candidates = playingPlaylistItems.filter {
            $0.id != currentVideo.id && $0.id != lastPlayedVideoID
        }
        guard let next = candidates.randomElement() else { return nil }
        shuffleHistory = Array(shuffleHistory.prefix(shuffleCursor + 1))
        shuffleHistory.append(next.id)
        shuffleCursor += 1
        return next
    }

    private func previousShuffledVideo(before currentVideo: PlaybackItem) -> PlaybackItem? {
        reconcileShuffleOrder(currentVideo: currentVideo)
        guard shuffleCursor > 0 else { return nil }
        shuffleCursor -= 1
        let previousID = shuffleHistory[shuffleCursor]
        return playingPlaylistItems.first(where: { $0.id == previousID })
    }

    private func selectPlayingVideo(_ video: PlaybackItem) {
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
        guard let playingPlaylistID, let currentItem else { return }
        if playbackQueue.savedPlaylistID == playingPlaylistID {
            playbackQueue.updateResume(partIndex: partIndex, position: position)
        } else {
            savedPlaylists.updatePlaybackState(
                playingPlaylistID,
                currentID: currentItem.id,
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
                ? playingPlaylistItems.contains(where: {
                    $0.id != currentItem?.id && $0.id != lastPlayedVideoID
                })
                : currentItem.flatMap {
                    adjacentPlayingVideo(
                        to: $0,
                        offset: 1,
                        wrapping: playingPlaylistID != RoamingPlaylist.id
                    )
                } != nil)
    }

    var canGoPrevious: Bool {
        guard let currentItem else { return false }
        return elapsed > 0
            || currentParts.indices.contains(currentPartIndex - 1)
            || (playbackOrderMode == .shuffle
                ? shuffleCursor > 0
                : adjacentPlayingVideo(
                    to: currentItem,
                    offset: -1,
                    wrapping: playingPlaylistID != RoamingPlaylist.id
                ) != nil)
    }

    var currentSubtitle: String {
        if let currentPart, totalParts > 1 {
            return "P\(currentPart.number)/\(totalParts) · \(currentPart.title)"
        }
        return currentItem?.creator ?? ""
    }

    private func load(
        _ requestedItem: PlaybackItem,
        partIndex: Int,
        knownParts: [VideoPart]?,
        autoplay: Bool,
        resumeAt: TimeInterval = 0
    ) {
        let startsNewVideo = currentItem?.id != requestedItem.id
        let loadID = UUID()
        activeLoadID = loadID
        loadTask?.cancel()
        cancelNextPrefetch()
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = nil
        currentItemGeneration = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentResourceLoader = nil
        audioLevel.reset()
        playbackIntent = autoplay
        if startsNewVideo, let currentItem {
            lastPlayedVideoID = currentItem.id
        }
        currentItem = requestedItem
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
        if startsNewVideo || roamingRecommendationSourceID != requestedItem.video.id {
            requestRoamingRecommendationIfNeeded(for: requestedItem.video)
        }

        loadTask = Task { [weak self, service] in
            do {
                let selectedItem: PlaybackItem
                if requestedItem.part != nil {
                    selectedItem = requestedItem
                } else {
                    let parts: [VideoPart]
                    if let knownParts {
                        parts = knownParts
                    } else {
                        parts = try await service.videoParts(for: requestedItem.video)
                    }
                    guard parts.indices.contains(partIndex), !Task.isCancelled else { return }
                    let expandedItems = PlaybackItem.flatten(
                        video: requestedItem.video,
                        parts: parts
                    )
                    let requestedSelection = expandedItems[partIndex]
                    guard let self, self.activeLoadID == loadID else { return }
                    selectedItem =
                        self.expandPlayingItem(
                            requestedItem,
                            into: expandedItems,
                            selecting: requestedSelection.id
                        ) ?? requestedSelection
                    self.currentItem = selectedItem
                }
                guard let part = selectedItem.part,
                    !Task.isCancelled,
                    self?.activeLoadID == loadID
                else { return }
                self?.currentParts = [part]
                self?.currentPartIndex = 0
                self?.currentPart = part
                self?.totalParts = selectedItem.partCount
                self?.duration = part.duration
                self?.elapsed = min(max(0, resumeAt), part.duration)

                let stream = try await service.resolveAudio(for: selectedItem.video, part: part)
                let headers = await service.playbackHeaders(for: selectedItem.video)
                guard !Task.isCancelled else { return }

                let cacheKey = AudioCacheKey(
                    bvid: selectedItem.bvid,
                    cid: part.cid,
                    representationID: stream.representationID
                )
                guard
                    let cachedAsset = self?.audioCache.makeAsset(
                        for: AudioCacheSource(
                            key: cacheKey,
                            url: stream.url,
                            headers: headers
                        )
                    )
                else { return }
                self?.currentResourceLoader = cachedAsset.resourceLoader
                let asset = cachedAsset.asset
                guard try await asset.load(.isPlayable) else {
                    throw BilibiliError.noAudio
                }
                let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
                let item = AVPlayerItem(asset: asset)
                guard self?.activeLoadID == loadID,
                    self?.currentItem?.id == selectedItem.id
                else { return }
                if let audioTrack = audioTracks?.first {
                    item.audioMix = self?.audioLevel.makeAudioMix(for: audioTrack)
                }
                self?.duration = stream.duration
                self?.observeStatus(of: item)
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
                guard !Task.isCancelled, self?.activeLoadID == loadID else { return }
                self?.handlePlaybackFailure(error.localizedDescription)
            }
        }
    }

    private func expandPlayingItem(
        _ placeholder: PlaybackItem,
        into expandedItems: [PlaybackItem],
        selecting selectedID: String
    ) -> PlaybackItem? {
        guard let playingPlaylistID else { return nil }
        if playbackQueue.savedPlaylistID == playingPlaylistID {
            return playbackQueue.expand(
                placeholder,
                into: expandedItems,
                selecting: selectedID
            )
        }
        return savedPlaylists.expand(
            placeholder,
            into: expandedItems,
            selecting: selectedID,
            in: playingPlaylistID
        )
    }

    private func resolveQueuedItemIfNeeded(
        _ placeholder: PlaybackItem,
        in requestedPlaylistID: UUID? = nil
    ) {
        guard placeholder.part == nil else { return }
        let playlistID = requestedPlaylistID ?? playbackQueue.savedPlaylistID
        Task { [weak self, service] in
            do {
                let parts = try await service.videoParts(for: placeholder.video)
                try Task.checkCancellation()
                let expandedItems = PlaybackItem.flatten(
                    video: placeholder.video,
                    parts: parts
                )
                guard let self else { return }
                if self.playbackQueue.savedPlaylistID == playlistID,
                    self.playbackQueue.items.contains(where: { $0.id == placeholder.id })
                {
                    _ = self.playbackQueue.expand(
                        placeholder,
                        into: expandedItems,
                        selecting: nil
                    )
                } else if let playlistID {
                    _ = self.savedPlaylists.expand(
                        placeholder,
                        into: expandedItems,
                        selecting: nil,
                        in: playlistID
                    )
                }
            } catch {
                return
            }
        }
    }

    private func observeStatus(of item: AVPlayerItem) {
        currentItemStatusObservation?.invalidate()
        let generation = UUID()
        currentItemGeneration = generation
        currentItemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self] observedItem, _ in
            guard observedItem.status == .failed else { return }
            let message = observedItem.error?.localizedDescription ?? "音频播放失败，请重试"
            Task { @MainActor [weak self] in
                guard self?.currentItemGeneration == generation else { return }
                self?.handlePlaybackFailure(message)
            }
        }
    }

    func handlePlaybackFailure(_ message: String) {
        guard currentItem != nil else { return }
        cancelNextPrefetch()
        playbackIntent = false
        player.pause()
        audioLevel.reset()
        playbackState = .failed(message)
        notice = message
        updateNowPlaying()
    }

    private func scheduleNextPrefetchIfReady() {
        cancelNextPrefetch()
        guard playbackState == .playing,
            player.currentItem != nil,
            let target = nextAudioPrefetchTarget()
        else { return }

        nextPrefetchTask = Task { [service, audioCache] in
            do {
                let part: VideoPart
                if let knownPart = target.item.part {
                    part = knownPart
                } else {
                    guard
                        let firstPart = try await service.videoParts(
                            for: target.item.video
                        ).first
                    else {
                        return
                    }
                    part = firstPart
                }
                try Task.checkCancellation()
                let stream = try await service.resolveAudio(for: target.item.video, part: part)
                let headers = await service.playbackHeaders(for: target.item.video)
                try Task.checkCancellation()
                try await audioCache.prefetch(
                    AudioCacheSource(
                        key: AudioCacheKey(
                            bvid: target.item.bvid,
                            cid: part.cid,
                            representationID: stream.representationID
                        ),
                        url: stream.url,
                        headers: headers
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func cancelNextPrefetch() {
        nextPrefetchTask?.cancel()
        nextPrefetchTask = nil
    }

    private func nextAudioPrefetchTarget() -> AudioPrefetchTarget? {
        guard let currentItem else { return nil }
        guard playbackOrderMode == .repeatAll,
            let nextVideo = adjacentPlayingVideo(
                to: currentItem,
                offset: 1,
                wrapping: playingPlaylistID != RoamingPlaylist.id
            ),
            nextVideo.id != currentItem.id
        else { return nil }
        return AudioPrefetchTarget(item: nextVideo)
    }

    private func requestRoamingRecommendationIfNeeded(
        for video: VideoSearchResult? = nil
    ) {
        let requestedVideo = video ?? currentItem?.video
        guard let requestedVideo else { return }
        let requestedVideoID = requestedVideo.id
        let isPlayingRoamingVideo =
            playingPlaylistID == RoamingPlaylist.id
            && currentItem?.video.id == requestedVideoID
        let isBrowsingRoamingVideo =
            playbackQueue.isRoaming
            && playbackQueue.current?.video.id == requestedVideoID
        guard isPlayingRoamingVideo || isBrowsingRoamingVideo else { return }
        if pendingRoamingRecommendationReplacementSourceID != nil,
            pendingRoamingRecommendationReplacementSourceID != requestedVideoID
        {
            pendingRoamingRecommendationReplacementSourceID = nil
        }

        relatedVideoTask?.cancel()
        relatedVideoTask = Task { [weak self, service] in
            do {
                let recommendations = try await service.relatedVideos(for: requestedVideo)
                guard !Task.isCancelled,
                    let self
                else { return }
                let stillPlayingRoamingVideo =
                    self.playingPlaylistID == RoamingPlaylist.id
                    && self.currentItem?.video.id == requestedVideoID
                let stillBrowsingRoamingVideo =
                    self.playbackQueue.isRoaming
                    && self.playbackQueue.current?.video.id == requestedVideoID
                guard stillPlayingRoamingVideo || stillBrowsingRoamingVideo else { return }

                self.roamingRecommendationSourceID = requestedVideoID
                self.roamingRecommendations = recommendations
                self.roamingRecommendationCursor =
                    self.roamingNextVideo(after: requestedVideoID)
                    .flatMap { next in
                        recommendations.firstIndex(where: {
                            $0.id == next.video.id
                        })
                    }
                    ?? -1
                self.fillRoamingNextIfMissing(after: requestedVideoID)
                if self.pendingRoamingRecommendationReplacementSourceID == requestedVideoID {
                    self.pendingRoamingRecommendationReplacementSourceID = nil
                    self.replaceRoamingNextRecommendation()
                }
            } catch is CancellationError {
                return
            } catch {
                // Related videos are opportunistic; playback remains usable without one.
            }
        }
    }

    private func fillRoamingNextIfMissing(after currentID: String) {
        guard roamingNextVideo(after: currentID) == nil else { return }

        let items =
            playbackQueue.savedPlaylistID == RoamingPlaylist.id
            ? playbackQueue.items
            : savedPlaylists.roamingPlaylist.items
        let excludedIDs = Set(items.map(\.video.id))
        guard let candidate = nextRoamingRecommendation(excluding: excludedIDs) else { return }
        guard let currentItemID = roamingCurrentItemID(for: currentID) else { return }
        let candidateItem = PlaybackItem(video: candidate.video)

        let inserted: Bool
        if playbackQueue.savedPlaylistID == RoamingPlaylist.id {
            inserted = playbackQueue.insertRoamingNextIfMissing(
                candidateItem,
                after: currentItemID
            )
        } else {
            inserted = savedPlaylists.insertRoamingNextIfMissing(
                candidateItem,
                after: currentItemID
            )
        }
        if inserted {
            roamingRecommendationCursor = candidate.index
            resolveQueuedItemIfNeeded(candidateItem, in: RoamingPlaylist.id)
        }
    }

    private func nextRoamingRecommendation(
        excluding excludedIDs: Set<String>
    ) -> (index: Int, video: VideoSearchResult)? {
        guard !roamingRecommendations.isEmpty else { return nil }
        for offset in 1...roamingRecommendations.count {
            let index = (roamingRecommendationCursor + offset) % roamingRecommendations.count
            let candidate = roamingRecommendations[index]
            if !excludedIDs.contains(candidate.id) {
                return (index, candidate)
            }
        }
        return nil
    }

    private func clearRoamingRecommendations() {
        roamingRecommendationSourceID = nil
        roamingRecommendations = []
        roamingRecommendationCursor = -1
        pendingRoamingRecommendationReplacementSourceID = nil
    }

    private func roamingNextVideo(after currentID: String) -> PlaybackItem? {
        let items: [PlaybackItem]
        let storedCurrentItem: PlaybackItem?
        if playbackQueue.savedPlaylistID == RoamingPlaylist.id {
            items = playbackQueue.items
            storedCurrentItem = playbackQueue.current
        } else {
            let roaming = savedPlaylists.roamingPlaylist
            items = roaming.items
            storedCurrentItem = roaming.currentID.flatMap { id in
                roaming.items.first(where: { $0.id == id })
            }
        }
        guard storedCurrentItem?.video.id == currentID,
            let storedCurrentItem
        else { return nil }
        return RoamingPlaylist.next(in: items, currentID: storedCurrentItem.id)
    }

    private func roamingCurrentItemID(for videoID: String) -> String? {
        if playbackQueue.savedPlaylistID == RoamingPlaylist.id {
            return playbackQueue.current?.video.id == videoID
                ? playbackQueue.currentID
                : nil
        }
        let roaming = savedPlaylists.roamingPlaylist
        guard let currentID = roaming.currentID,
            roaming.items.first(where: { $0.id == currentID })?.video.id == videoID
        else { return nil }
        return currentID
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
                        self.elapsed > self.playbackBaseline + 0.01
                    {
                        self.playbackState = .playing
                        self.updateNowPlaying()
                        self.scheduleNextPrefetchIfReady()
                    }
                }
                if let itemDuration = self.player.currentItem?.duration.seconds,
                    itemDuration.isFinite, itemDuration > 0
                {
                    self.duration = itemDuration
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let endedItemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            Task { @MainActor in
                guard let self else { return }
                if let endedItemID,
                    self.player.currentItem.map(ObjectIdentifier.init) != endedItemID
                {
                    return
                }
                if self.playbackOrderMode == .repeatOne, self.currentItem != nil {
                    if self.currentParts.indices.contains(self.currentPartIndex + 1) {
                        self.playNext()
                    } else {
                        self.replayCurrentVideo()
                    }
                } else if self.canGoNext {
                    self.playNext()
                } else {
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

        registerRemoteCommand(commands.playCommand) { [weak self] _ in
            Task { @MainActor in self?.resumePlayback() }
            return .success
        }
        registerRemoteCommand(commands.pauseCommand) { [weak self] _ in
            Task { @MainActor in self?.pausePlayback() }
            return .success
        }
        registerRemoteCommand(commands.togglePlayPauseCommand) { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        registerRemoteCommand(commands.nextTrackCommand) { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
        registerRemoteCommand(commands.previousTrackCommand) { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }
        registerRemoteCommand(commands.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func registerRemoteCommand(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget(handler: handler)
        remoteCommandRegistrations.append((command, target))
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        guard currentItem != nil else { return }
        switch status {
        case .waitingToPlayAtSpecifiedRate where playbackIntent:
            cancelNextPrefetch()
            if playbackState != .resolving {
                playbackBaseline = player.currentTime().seconds.isFinite ? player.currentTime().seconds : elapsed
                playbackState = .buffering
                updateNowPlaying()
            }
        case .paused where !playbackIntent:
            if playbackState != .resolving {
                if case .failed = playbackState { return }
                playbackState = .paused
                updateNowPlaying()
            }
        default:
            break
        }
    }

    private func updateNowPlaying() {
        guard let currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: currentItem.title,
            MPMediaItemPropertyArtist: currentItem.creator,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playbackState.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: currentItem.bvid,
        ]
        MPNowPlayingInfoCenter.default().playbackState = playbackState.isPlaying ? .playing : .paused
    }
}

private struct AudioPrefetchTarget: Sendable {
    let item: PlaybackItem
}
