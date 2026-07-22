import AVFoundation
import Foundation
import MediaPlayer

@main
@MainActor
enum AnnoyOChecks {
    static func main() async throws {
        let query = WBISigner.signedQuery(
            parameters: [
                "foo": "114",
                "bar": "514",
                "baz": "1919810"
            ],
            imageKey: "7cd084941338484aae1ad9425b84077c",
            subKey: "4932caff0ff746eab6f01bf08b70ac45",
            timestamp: 1_702_204_169
        )
        check(
            query == "bar=514&baz=1919810&foo=114&wts=1702204169&w_rid=6149fdadf571698ca7e6a567265cd0ee",
            "WBI known signature"
        )
        check(
            query.hasPrefix("bar=514&baz=1919810&foo=114&wts="),
            "WBI parameter ordering"
        )

        let encoded = WBISigner.signedQuery(
            parameters: ["keyword": "音乐! (live)"],
            imageKey: "7cd084941338484aae1ad9425b84077c",
            subKey: "4932caff0ff746eab6f01bf08b70ac45",
            timestamp: 1
        )
        check(
            encoded.hasPrefix("keyword=%E9%9F%B3%E4%B9%90%20live&wts=1&w_rid="),
            "WBI encoding and sanitization"
        )
        check(
            "<em class=\"keyword\">音乐</em> &amp; Live".removingHTML == "音乐 & Live",
            "search title HTML cleanup"
        )
        verifyPlaybackQueuePersistence()
        verifyRoamingWindow()
        verifyCompactRollerLayout()
        verifySavedPlaylists()
        verifyPlaylistBrowsingDoesNotInterruptPlayback()
        verifyAudioFeatureExtractor()
        verifyControllerQueueRemoval()
        verifyAudioCacheStore()
        try await verifySearchPagination()
        try await verifyRoamingRecommendationIntegration()
        do {
            let mediaController = PlayerController(
                service: .shared,
                playbackQueue: PlaybackQueue(storageURL: temporaryQueueURL()),
                audioCache: temporaryAudioCache(),
                restoresQueue: false,
                savedPlaylists: temporarySavedPlaylistStore()
            )
            check(
                MPRemoteCommandCenter.shared().togglePlayPauseCommand.isEnabled,
                "media play/pause toggle command enabled"
            )
            check(
                MPNowPlayingInfoCenter.default().playbackState == .stopped,
                "idle Now Playing state is stopped"
            )
            check(mediaController.playbackOrderMode == .repeatAll, "playback defaults to full-list repeat")
            mediaController.cyclePlaybackOrderMode()
            check(mediaController.playbackOrderMode == .repeatOne, "playback mode advances to single repeat")
            mediaController.cyclePlaybackOrderMode()
            check(mediaController.playbackOrderMode == .shuffle, "playback mode advances to shuffle")
            mediaController.cyclePlaybackOrderMode()
            check(mediaController.playbackOrderMode == .repeatAll, "playback modes cycle mutually exclusively")
            let onlyItem = fixtureVideo(id: "BV1SHUFFLEONLY", title: "唯一一首")
            mediaController.playbackQueue.enqueue(onlyItem)
            mediaController.playQueued(onlyItem)
            mediaController.cyclePlaybackOrderMode()
            mediaController.cyclePlaybackOrderMode()
            check(
                mediaController.playbackOrderMode == .shuffle && !mediaController.canGoNext,
                "list shuffle excludes the currently playing item from candidates"
            )
            withExtendedLifetime(mediaController) {}
        }
        try await verifyConfirmedLoginFlow()

        guard ProcessInfo.processInfo.environment["ANNOYO_LIVE_TESTS"] == "1" else {
            print("All offline checks passed. Set ANNOYO_LIVE_TESTS=1 to run Bilibili checks.")
            return
        }

        let service = BilibiliService()
        let results = try await service.search(keyword: "周杰伦")
        check(!results.isEmpty, "live Bilibili search")
        let related = try await service.topRelatedVideo(for: results[0])
        check(
            related != nil && related?.id != results[0].id,
            "live Bilibili top related recommendation"
        )
        let secondPageResults = try await service.search(keyword: "周杰伦", page: 2)
        check(!secondPageResults.isEmpty, "live Bilibili search pagination")
        let parts = try await service.videoParts(for: results[0])
        check(!parts.isEmpty, "live video parts resolution")
        let stream = try await service.resolveAudio(for: results[0], part: parts[0])
        check(stream.url.scheme == "https", "live DASH audio resolution")
        let headers = await service.playbackHeaders(for: results[0])
        var rangeRequest = URLRequest(url: stream.url)
        headers.forEach { rangeRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        rangeRequest.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await URLSession.shared.data(for: rangeRequest)
        let rangeHTTP = rangeResponse as? HTTPURLResponse
        print(
            "CDN range status=\(rangeHTTP?.statusCode ?? -1) bytes=\(rangeData.count) "
                + "type=\(rangeHTTP?.value(forHTTPHeaderField: "Content-Type") ?? "none") "
                + "range=\(rangeHTTP?.value(forHTTPHeaderField: "Content-Range") ?? "none")"
        )
        check((200 ... 299).contains(rangeHTTP?.statusCode ?? -1) && !rangeData.isEmpty, "live CDN range request")

        let asset = AVURLAsset(
            url: stream.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
        let isPlayable = try await asset.load(.isPlayable)
        check(isPlayable, "live DASH asset is playable")

        let controller = PlayerController(
            service: service,
            playbackQueue: PlaybackQueue(storageURL: temporaryQueueURL()),
            audioCache: temporaryAudioCache(),
            restoresQueue: false,
            savedPlaylists: temporarySavedPlaylistStore()
        )
        controller.volume = 0
        controller.play(results[0])
        let playbackDeadline = Date().addingTimeInterval(35)
        while !controller.playbackState.isPlaying, Date() < playbackDeadline {
            if case let .failed(message) = controller.playbackState {
                check(false, "controller playback failed: \(message)")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        check(controller.playbackState.isPlaying, "controller reaches playing state")
        check(controller.totalParts == parts.count, "controller keeps the complete multipart manifest")
        check(controller.elapsed > 0, "controller playing state means time advances")
        let audioMeterDeadline = Date().addingTimeInterval(6)
        while controller.audioLevel.snapshot.energy < 0.01, Date() < audioMeterDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        check(controller.audioLevel.snapshot.energy >= 0.01, "live PCM audio reaches the reactive visual meter")
        if parts.count > 1, let firstPart = controller.currentPart {
            controller.cyclePlaybackOrderMode()
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: nil)
            try await Task.sleep(for: .milliseconds(400))
            check(
                controller.currentVideo == results[0] && controller.playbackOrderMode == .repeatOne,
                "single-item repeat stays within the current video"
            )
            controller.cyclePlaybackOrderMode()
            controller.cyclePlaybackOrderMode()
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: nil)
            let nextPartDeadline = Date().addingTimeInterval(5)
            while controller.currentPart == firstPart, Date() < nextPartDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            check(controller.currentPart != firstPart, "controller advances to the next video part")
        }
        controller.pausePlayback()

        let login = try await service.beginQRCodeLogin()
        check(login.url.scheme == "https" && !login.key.isEmpty, "live QR login generation")
        let loginStatus = try await service.pollQRCodeLogin(key: login.key)
        if case .waitingForScan = loginStatus {
            check(true, "live QR login polling")
        } else {
            check(false, "live QR login polling")
        }
        print("Resolved: \(results[0].title) — \(stream.url.host ?? "unknown host")")
        print("All live checks passed.")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAILED: \(name)\n".utf8))
            exit(1)
        }
        print("PASS: \(name)")
    }

    private static func verifyConfirmedLoginFlow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBilibiliURLProtocol.self]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = HTTPCookieStorage.sharedCookieStorage(
            forGroupContainerIdentifier: "io.annoyo.tests.\(UUID().uuidString)"
        )
        let service = BilibiliService(session: URLSession(configuration: configuration))

        let login = try await service.beginQRCodeLogin()
        check(login.key == "mock-key", "QR login session decoding")
        let status = try await service.pollQRCodeLogin(key: login.key)
        if case .confirmed = status {
            check(true, "QR login confirmation decoding")
        } else {
            check(false, "QR login confirmation decoding")
        }
        let account = try await service.account()
        check(account?.name == "测试用户", "confirmed login cookie reaches account state")
    }

    private static func verifyPlaybackQueuePersistence() {
        let storageURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/queue-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let first = fixtureVideo(id: "BV1QUEUEFIRST", title: "第一首")
        let second = fixtureVideo(id: "BV1QUEUESECOND", title: "第二首")
        let third = fixtureVideo(id: "BV1QUEUETHIRD", title: "第三首")
        let queue = PlaybackQueue(storageURL: storageURL)

        queue.playNow(first)
        queue.enqueue(second)
        queue.enqueue(second)
        queue.enqueue(third)
        check(queue.items.map(\.id) == [first.id, second.id, third.id], "queue append and deduplication")

        queue.move(from: IndexSet(integer: 2), to: 1)
        check(queue.items.map(\.id) == [first.id, third.id, second.id], "queue reordering")
        check(queue.advance() == third, "queue advances in persisted order")

        queue.moveToTop(second)
        check(queue.items.map(\.id) == [third.id, second.id, first.id], "queue item moves after current")
        queue.updateResume(partIndex: 2, position: 42.5)

        let restored = PlaybackQueue(storageURL: storageURL)
        check(restored.items.map(\.id) == queue.items.map(\.id), "queue persistence")
        check(restored.current == third, "queue current item restoration")
        check(restored.resumePartIndex == 2 && restored.resumePosition == 42.5, "queue resume restoration")
    }

    private static func verifySavedPlaylists() {
        let storageURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/playlists-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let first = fixtureVideo(id: "BV1PLAYLISTFIRST", title: "深夜电台")
        let second = fixtureVideo(id: "BV1PLAYLISTSECOND", title: "城市漫步")
        let queue = PlaybackQueue(storageURL: temporaryQueueURL())
        let store = SavedPlaylistStore(storageURL: storageURL)
        let controller = PlayerController(
            service: .shared,
            playbackQueue: queue,
            audioCache: temporaryAudioCache(),
            restoresQueue: false,
            savedPlaylists: store
        )

        let roaming = store.roamingPlaylist
        check(store.playlists.count == 1, "empty storage creates only the roaming playlist")
        check(roaming.name == "漫游" && roaming.isRoaming, "roaming playlist has stable system identity")
        check(queue.savedPlaylistID == roaming.id, "roaming playlist is active on first launch")

        queue.playNow(first)
        queue.enqueue(second)
        queue.updateResume(partIndex: 1, position: 38.5)
        check(store.roamingPlaylist.items == [first, second], "roaming mutations persist immediately")

        controller.renameSavedPlaylist(roaming, to: "不能改名")
        controller.deleteSavedPlaylist(roaming)
        check(
            store.roamingPlaylist.name == "漫游" && store.playlists.count == 1,
            "roaming playlist cannot be renamed or deleted"
        )

        controller.createPlaylist()
        guard let firstPlaylist = store.playlists.first(where: { $0.name == "播放列表1" }) else {
            check(false, "explicit creation starts at 播放列表1")
            return
        }
        check(queue.savedPlaylistID == firstPlaylist.id && queue.items.isEmpty, "new user playlist becomes active")

        queue.enqueue(first)
        queue.enqueue(second)
        controller.renameSavedPlaylist(firstPlaylist, to: "夜间播放")
        check(queue.displayName == "夜间播放", "renaming updates the active playlist title")

        controller.createPlaylist()
        guard let reusedAfterRename = store.playlists.first(where: { $0.name == "播放列表1" }) else {
            check(false, "renaming frees the default playlist index")
            return
        }
        check(queue.savedPlaylistID == reusedAfterRename.id, "new playlist reuses an index freed by rename")

        controller.deleteSavedPlaylist(reusedAfterRename)
        check(
            queue.savedPlaylistID == roaming.id,
            "deleting the active user playlist falls back to roaming"
        )
        controller.createPlaylist()
        guard let reusedAfterDelete = store.playlists.first(where: {
            $0.name == "播放列表1" && $0.id != reusedAfterRename.id
        }) else {
            check(false, "deleting frees the default playlist index")
            return
        }
        check(queue.savedPlaylistID == reusedAfterDelete.id, "new playlist reuses an index freed by delete")

        let restoredStore = SavedPlaylistStore(storageURL: storageURL)
        check(restoredStore.playlists.first?.isRoaming == true, "roaming stays first after restart")
        guard let restoredPlaylist = restoredStore.playlists.first(where: { $0.id == firstPlaylist.id }) else {
            check(false, "user playlist persistence")
            return
        }
        check(restoredPlaylist.name == "夜间播放", "renamed user playlist persists")
        check(
            Set(restoredPlaylist.items.map(\.id)) == Set([first.id, second.id]),
            "user playlist contents persist"
        )

        controller.deleteSavedPlaylist(reusedAfterDelete)
        if let nightPlaylist = store.playlists.first(where: { $0.id == firstPlaylist.id }) {
            controller.deleteSavedPlaylist(nightPlaylist)
        }
        check(store.playlists == [store.roamingPlaylist], "deleting all user lists leaves only roaming")
        check(queue.savedPlaylistID == roaming.id, "no empty replacement user playlist is created")
    }

    private static func verifyRoamingWindow() {
        let queue = PlaybackQueue(storageURL: temporaryQueueURL())
        let previous = fixtureVideo(id: "BV1ROAMPREVIOUS", title: "上一首")
        let current = fixtureVideo(id: "BV1ROAMCURRENT", title: "当前")
        let recommended = fixtureVideo(id: "BV1ROAMRECOMMENDED", title: "推荐下一首")
        let searched = fixtureVideo(id: "BV1ROAMSEARCHED", title: "搜索置入下一首")
        let later = fixtureVideo(id: "BV1ROAMLATER", title: "推进后的推荐")

        queue.replace(
            items: [previous, current],
            currentID: current.id,
            resumePartIndex: 0,
            resumePosition: 0,
            savedPlaylistID: RoamingPlaylist.id,
            savedPlaylistName: RoamingPlaylist.name
        )
        check(queue.isRoaming, "queue recognizes the roaming system playlist")
        check(
            queue.insertRoamingNextIfMissing(recommended, after: current.id),
            "Bilibili top recommendation fills an empty next slot"
        )
        check(queue.items == [previous, current, recommended], "roaming keeps previous, current and next")

        queue.enqueue(searched)
        check(
            queue.items == [previous, current, searched],
            "search insertion replaces the existing roaming next item"
        )
        queue.select(searched)
        check(queue.items == [current, searched], "advancing rotates the roaming window")
        check(
            queue.insertRoamingNextIfMissing(later, after: searched.id),
            "new current receives a fresh recommendation"
        )
        check(queue.items == [current, searched, later], "roaming window never grows beyond three items")
        check(
            !queue.insertRoamingNextIfMissing(recommended, after: searched.id),
            "automatic recommendation never replaces a populated next slot"
        )

        queue.select(current)
        check(
            queue.items == [searched, current],
            "playing any different roaming item records the old current as playback history"
        )
        check(
            queue.insertRoamingNextIfMissing(recommended, after: current.id),
            "playing a different roaming item refreshes its recommendation slot"
        )
    }

    private static func verifyCompactRollerLayout() {
        let itemCount = 3
        let renderedOccurrenceCount = RollerLoopLayout
            .cycles(forItemCount: itemCount)
            .count * itemCount
        check(
            renderedOccurrenceCount == itemCount,
            "compact roller renders each queue item only once"
        )
        check(
            RollerLoopLayout.boundaryWrapTarget(
                currentOffset: 0,
                minimumOffset: 0,
                maximumOffset: 120,
                scrollingDeltaY: 4
            ) == 120,
            "compact roller wraps upward from the first item to the last"
        )
        check(
            RollerLoopLayout.boundaryWrapTarget(
                currentOffset: 120,
                minimumOffset: 0,
                maximumOffset: 120,
                scrollingDeltaY: -4
            ) == 0,
            "compact roller wraps downward from the last item to the first"
        )
        check(
            RollerLoopLayout.cycles(forItemCount: 7) == [0, 1, 2],
            "long queues keep the seamless three-cycle roller"
        )
    }

    private static func verifyPlaylistBrowsingDoesNotInterruptPlayback() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBilibiliURLProtocol.self]
        let queueURL = temporaryQueueURL()
        let storeURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/browsing-playlists-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: queueURL)
            try? FileManager.default.removeItem(at: storeURL)
        }
        let queue = PlaybackQueue(storageURL: queueURL)
        let store = SavedPlaylistStore(storageURL: storeURL)
        let controller = PlayerController(
            service: BilibiliService(session: URLSession(configuration: configuration)),
            playbackQueue: queue,
            audioCache: temporaryAudioCache(),
            restoresQueue: false,
            savedPlaylists: store
        )
        let first = fixtureVideo(id: "BV1BROWSEFIRST", title: "播放来源第一首")
        let next = fixtureVideo(id: "BV1BROWSENEXT", title: "播放来源下一首")
        let other = fixtureVideo(id: "BV1BROWSEOTHER", title: "其他列表音频")

        controller.createPlaylist()
        queue.enqueue(first)
        queue.enqueue(next)
        let sourcePlaylistID = queue.savedPlaylistID
        controller.playQueued(first)
        check(controller.currentVideo == first, "playing a row starts that audio")
        check(controller.playingPlaylistID == sourcePlaylistID, "playback remembers its source playlist")
        controller.playQueued(next)
        controller.playNext()
        check(controller.currentVideo == first, "full-list repeat wraps from the final item to the first")

        controller.createPlaylist()
        let newPlaylistID = queue.savedPlaylistID
        check(newPlaylistID != sourcePlaylistID, "new playlist changes only the displayed playlist")
        check(controller.playlistTransitionDirection == 1, "new playlist enters from the forward direction")
        check(controller.currentVideo == first, "new playlist does not interrupt current playback")
        check(controller.playingPlaylistID == sourcePlaylistID, "new playlist preserves the playback source")

        queue.enqueue(other)
        let sourceOrderBeforeShuffle = store.playlists
            .first(where: { $0.id == sourcePlaylistID })?
            .items
            .map(\.id)
        controller.cyclePlaybackOrderMode()
        controller.cyclePlaybackOrderMode()
        check(controller.playbackOrderMode == .shuffle, "playback mode advances to random order")
        check(
            store.playlists.first(where: { $0.id == sourcePlaylistID })?.items.map(\.id)
                == sourceOrderBeforeShuffle,
            "shuffle playback mode does not reorder the playlist"
        )
        controller.playNext()
        check(controller.currentVideo == next, "automatic next follows the playback source playlist")
        check(queue.savedPlaylistID == newPlaylistID, "automatic next does not change the displayed playlist")

        check(controller.returnToPlayingPlaylist(), "return-to-current finds the playback source playlist")
        check(queue.savedPlaylistID == sourcePlaylistID, "return-to-current switches back to the playback list")
        check(controller.playlistTransitionDirection == -1, "return-to-current preserves list slide direction")
        check(queue.current == next, "return-to-current restores the currently playing row")

        controller.switchPlaylist(by: 1)
        check(queue.savedPlaylistID == newPlaylistID, "playlist navigation changes the displayed playlist")
        check(controller.playlistTransitionDirection == 1, "next playlist uses a forward slide direction")
        check(controller.currentVideo == next, "playlist navigation leaves playback untouched")

        let restoredQueue = PlaybackQueue(storageURL: queueURL)
        let restoredController = PlayerController(
            service: BilibiliService(session: URLSession(configuration: configuration)),
            playbackQueue: restoredQueue,
            audioCache: temporaryAudioCache(),
            restoresQueue: true,
            savedPlaylists: SavedPlaylistStore(storageURL: storeURL)
        )
        check(restoredQueue.savedPlaylistID == newPlaylistID, "restart preserves the displayed playlist")
        check(restoredController.currentVideo == next, "restart restores audio from the playback source")
        check(restoredController.playingPlaylistID == sourcePlaylistID, "restart preserves the playback source")

        restoredController.playQueued(other)
        check(restoredController.currentVideo == other, "playing a row in another playlist changes playback")
        check(
            restoredController.playingPlaylistID == newPlaylistID,
            "explicit playback adopts the new source playlist"
        )
    }

    private static func verifyAudioFeatureExtractor() {
        let lowTone = analyzedTone(frequency: 100)
        let midTone = analyzedTone(frequency: 1_000)
        let highTone = analyzedTone(frequency: 6_000)

        check(
            lowTone.snapshot.low > max(lowTone.snapshot.midHigh, lowTone.snapshot.high) + 0.35,
            "100 Hz audio primarily drives the low band"
        )
        check(
            midTone.snapshot.midHigh > max(midTone.snapshot.low, midTone.snapshot.high) + 0.35,
            "1 kHz audio primarily drives the mid-high band"
        )
        check(
            highTone.snapshot.high > max(highTone.snapshot.low, highTone.snapshot.lowMid) + 0.35,
            "6 kHz audio primarily drives the high band"
        )

        let quietTone = analyzedTone(frequency: 220, amplitude: 0.02)
        let loudTone = analyzedTone(frequency: 220, amplitude: 0.4)
        check(
            loudTone.snapshot.energy > quietTone.snapshot.energy + 0.35,
            "broadband energy retains track strength"
        )

        let sampleRate = 48_000.0
        let onsetExtractor = AudioFeatureExtractor(sampleRate: sampleRate)
        let silenceCount = Int(sampleRate * 0.35)
        onsetExtractor.ingest(
            [Float](repeating: 0, count: silenceCount),
            sourceStartTime: 0
        )
        onsetExtractor.ingest(
            sineWave(
                frequency: 120,
                amplitude: 0.45,
                duration: 0.9,
                sampleRate: sampleRate
            ),
            sourceStartTime: Double(silenceCount) / sampleRate
        )
        check(
            onsetExtractor.diagnostics.onsetCount == 1,
            "a sustained tone onset triggers once"
        )
        check(
            onsetExtractor.snapshot.pulse < 0.05,
            "onset pulse releases while sustained audio continues"
        )

        let samples = mixedTestSignal(sampleRate: sampleRate)
        let contiguous = AudioFeatureExtractor(sampleRate: sampleRate)
        contiguous.ingest(samples, sourceStartTime: 0)

        let chunked = AudioFeatureExtractor(sampleRate: sampleRate)
        let chunkSizes = [127, 509, 64, 1_024, 333]
        var sampleIndex = 0
        var chunkIndex = 0
        while sampleIndex < samples.count {
            let end = min(
                samples.count,
                sampleIndex + chunkSizes[chunkIndex % chunkSizes.count]
            )
            chunked.ingest(
                Array(samples[sampleIndex ..< end]),
                sourceStartTime: Double(sampleIndex) / sampleRate
            )
            sampleIndex = end
            chunkIndex += 1
        }
        check(
            abs(contiguous.diagnostics.spectralFlux - chunked.diagnostics.spectralFlux) < 0.000_001
                && contiguous.diagnostics.onsetCount == chunked.diagnostics.onsetCount
                && contiguous.snapshot == chunked.snapshot,
            "audio features do not depend on callback buffer sizes"
        )
    }

    private static func analyzedTone(
        frequency: Double,
        amplitude: Double = 0.35,
        duration: TimeInterval = 1.0,
        sampleRate: Double = 48_000
    ) -> (snapshot: AudioMotionSnapshot, diagnostics: AudioAnalysisDiagnostics) {
        let extractor = AudioFeatureExtractor(sampleRate: sampleRate)
        extractor.ingest(
            sineWave(
                frequency: frequency,
                amplitude: amplitude,
                duration: duration,
                sampleRate: sampleRate
            ),
            sourceStartTime: 0
        )
        return (extractor.snapshot, extractor.diagnostics)
    }

    private static func sineWave(
        frequency: Double,
        amplitude: Double,
        duration: TimeInterval,
        sampleRate: Double
    ) -> [Float] {
        (0 ..< Int(duration * sampleRate)).map { index in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private static func mixedTestSignal(sampleRate: Double) -> [Float] {
        let count = Int(sampleRate * 1.2)
        return (0 ..< count).map { index in
            let time = Double(index) / sampleRate
            let low = sin(2 * Double.pi * 110 * time) * 0.24
            let mid = sin(2 * Double.pi * 1_200 * time) * 0.12
            let high = sin(2 * Double.pi * 5_500 * time) * 0.05
            let pulse = time.truncatingRemainder(dividingBy: 0.4) < 0.025 ? 1.0 : 0.0
            return Float((low + mid + high) * (0.45 + pulse * 0.55))
        }
    }

    private static func verifySearchPagination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBilibiliURLProtocol.self]
        configuration.httpCookieStorage = HTTPCookieStorage.sharedCookieStorage(
            forGroupContainerIdentifier: "io.annoyo.pagination.\(UUID().uuidString)"
        )
        let service = BilibiliService(session: URLSession(configuration: configuration))
        let controller = PlayerController(
            service: service,
            playbackQueue: PlaybackQueue(storageURL: temporaryQueueURL()),
            audioCache: temporaryAudioCache(),
            restoresQueue: false,
            savedPlaylists: temporarySavedPlaylistStore()
        )

        controller.search("分页测试")
        try await waitUntil { !controller.isSearching }
        check(controller.searchResults.map(\.id) == ["BV1PAGE1A", "BV1PAGE1B"], "search first page")
        check(controller.hasMoreSearchResults, "search first page exposes more results")

        controller.loadMoreSearchResults()
        try await waitUntil { !controller.isSearching }
        check(
            controller.searchResults.map(\.id) == ["BV1PAGE1A", "BV1PAGE1B", "BV1PAGE2A"],
            "search pagination appends results"
        )

        controller.loadMoreSearchResults()
        try await waitUntil { !controller.isSearching }
        check(!controller.hasMoreSearchResults, "search pagination stops at remote end")

        let related = try await service.topRelatedVideo(
            for: fixtureVideo(id: "BV1RELATEDSOURCE", title: "推荐来源")
        )
        check(related?.id == "BV1RELATEDTOP", "related API uses Bilibili top 1")
        check(
            related?.creator == "推荐 UP"
                && related?.durationText == "2:40"
                && related?.coverURL?.scheme == "https",
            "related top 1 maps into the queue model"
        )
    }

    private static func verifyControllerQueueRemoval() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBilibiliURLProtocol.self]
        let queue = PlaybackQueue(storageURL: temporaryQueueURL())
        let controller = PlayerController(
            service: BilibiliService(session: URLSession(configuration: configuration)),
            playbackQueue: queue,
            audioCache: temporaryAudioCache(),
            restoresQueue: false,
            savedPlaylists: temporarySavedPlaylistStore()
        )
        let first = fixtureVideo(id: "BV1REMOVEFIRST", title: "待删除当前音频")
        let second = fixtureVideo(id: "BV1REMOVESECOND", title: "删除后接续音频")
        controller.createPlaylist()
        queue.enqueue(first)
        queue.enqueue(second)

        controller.playQueued(first)
        controller.removeFromQueue(first)
        check(controller.currentVideo == second, "removing current advances to the next queue item")
        check(queue.items == [second] && queue.current == second, "removing current keeps queue state consistent")

        controller.removeFromQueue(second)
        check(controller.currentVideo == nil, "removing final current clears player")
        check(controller.playbackState == .idle && queue.items.isEmpty, "removing final current stops playback")
    }

    private static func verifyRoamingRecommendationIntegration() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBilibiliURLProtocol.self]
        let queue = PlaybackQueue(storageURL: temporaryQueueURL())
        let controller = PlayerController(
            service: BilibiliService(session: URLSession(configuration: configuration)),
            playbackQueue: queue,
            audioCache: temporaryAudioCache(),
            restoresQueue: false,
            savedPlaylists: temporarySavedPlaylistStore()
        )
        let source = fixtureVideo(id: "BV1ROAMINGSOURCE", title: "漫游来源")
        let searched = fixtureVideo(id: "BV1ROAMINGSEARCH", title: "搜索指定下一首")

        controller.play(source)
        try await waitUntil {
            RoamingPlaylist.next(in: queue.items, currentID: source.id)?.id == "BV1RELATEDTOP"
        }
        check(
            queue.savedPlaylistID == RoamingPlaylist.id,
            "first playback stays in the roaming system playlist"
        )
        controller.enqueue(searched)
        check(
            RoamingPlaylist.next(in: queue.items, currentID: source.id) == searched,
            "search insertion overrides an automatic recommendation"
        )

        controller.play(searched)
        check(
            controller.currentVideo == searched
                && Array(queue.items.prefix(2)) == [source, searched],
            "selecting a search result replaces current playback immediately"
        )
        try await waitUntil {
            RoamingPlaylist.next(in: queue.items, currentID: searched.id)?.id == "BV1RELATEDTOP"
        }
        check(queue.items.count == 3, "new roaming playback refreshes Bilibili top 1 as next")
    }

    private static func waitUntil(
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        check(condition(), "asynchronous check completed before timeout")
    }

    private static func fixtureVideo(id: String, title: String) -> VideoSearchResult {
        VideoSearchResult(
            bvid: id,
            title: title,
            creator: "测试 UP",
            description: "",
            coverURL: URL(string: "https://example.com/cover.jpg"),
            durationText: "03:00",
            playCountText: "1万",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func verifyAudioCacheStore() {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/cache-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = AudioCacheStore(rootURL: rootURL, limitBytes: 12)
        let first = AudioCacheKey(bvid: "BV1CACHE1", cid: 1, representationID: 30280)
        store.updateContentInfo(for: first, contentLength: 6, mimeType: "audio/mp4")
        store.write(Data("abc".utf8), for: first, at: 0)
        store.write(Data("def".utf8), for: first, at: 3)
        store.finishAccess(for: first)
        check(store.completeFileURL(for: first) != nil, "cache range merging completes an asset")
        check(store.summary().usedBytes == 6, "cache usage accounting")

        let second = AudioCacheKey(bvid: "BV1CACHE2", cid: 2, representationID: 30280)
        store.updateContentInfo(for: second, contentLength: 8, mimeType: "audio/mp4")
        store.write(Data("12345678".utf8), for: second, at: 0)
        store.finishAccess(for: second)
        check(store.completeFileURL(for: first) == nil, "cache LRU eviction")
        check(store.completeFileURL(for: second) != nil, "cache keeps the active asset during eviction")

        store.clear()
        check(store.summary().usedBytes == 0 && store.summary().itemCount == 0, "cache clearing")
    }

    private static func temporaryQueueURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/queue-check-\(UUID().uuidString).json")
    }

    private static func temporaryAudioCache() -> AudioCache {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/audio-cache-\(UUID().uuidString)", isDirectory: true)
        return AudioCache(rootURL: rootURL)
    }

    private static func temporarySavedPlaylistStore() -> SavedPlaylistStore {
        let storageURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/playlists-check-\(UUID().uuidString).json")
        return SavedPlaylistStore(storageURL: storageURL)
    }
}
