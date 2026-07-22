import AppKit
import SwiftUI

@main
@MainActor
enum AnnoyOVisualChecks {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let controller = PlayerController(
            service: .shared,
            playbackQueue: PlaybackQueue(storageURL: temporaryQueueURL()),
            audioCache: temporaryAudioCache(),
            restoresQueue: false,
            savedPlaylists: temporarySavedPlaylistStore()
        )
        controller.volume = 0
        let emptyOutput = render(
            controller: controller,
            name: "annoyo-empty-light.png",
            settleTime: 0.5
        )
        let iconOutput = render(
            view: StatusBarIcon(isPlaying: false)
                .foregroundStyle(.black)
                .padding(3)
                .background(.white),
            width: 24,
            name: "annoyo-status-icon-light.png",
            settleTime: 0.2
        )
        let playingIconOutput = render(
            view: StatusBarIcon(isPlaying: true)
                .foregroundStyle(.black)
                .padding(3)
                .background(.white),
            width: 24,
            name: "annoyo-status-icon-playing-light.png",
            settleTime: 0.2
        )
        let previous = sampleVideo(id: "BV1VISUAL1", title: "适合工作时听的轻音乐")
        let current = sampleVideo(id: "BV1VISUAL2", title: "深夜电台：慢下来听一会儿")
        let next = sampleVideo(id: "BV1VISUAL3", title: "雨夜白噪音与城市漫步")
        controller.playbackQueue.replace(
            items: [previous, current, next],
            currentID: current.id,
            resumePartIndex: 0,
            resumePosition: 0,
            savedPlaylistID: RoamingPlaylist.id,
            savedPlaylistName: RoamingPlaylist.name
        )
        let mainQueueOutput = render(
            controller: controller,
            name: "annoyo-main-queue-light.png",
            settleTime: 0.8
        )
        let staticSearchResults = [
            sampleVideo(id: "BV1SEARCH1", title: "夜晚工作时适合听的爵士乐"),
            sampleVideo(id: "BV1SEARCH2", title: "城市散步：雨声与环境音乐"),
            sampleVideo(id: "BV1SEARCH3", title: "安静读书用的钢琴曲合集"),
            sampleVideo(id: "BV1SEARCH4", title: "凌晨电台与温柔的人声"),
            sampleVideo(id: "BV1SEARCH5", title: "无歌词专注音乐 90 分钟"),
            sampleVideo(id: "BV1SEARCH6", title: "周末咖啡馆背景音乐")
        ]
        let searchResultsOutput = render(
            view: MenuBarView(
                controller: controller,
                initialSearchText: "爵士乐",
                initialSearchResults: staticSearchResults
            )
            .background(.regularMaterial),
            width: 360,
            name: "annoyo-main-search-results-light.png",
            settleTime: 0.8
        )
        let previewAccount = BilibiliAccount(name: "神奇的 jo 喵", avatarURL: nil)
        let previewCacheSummary = AudioCacheSummary(
            usedBytes: 215_167_795,
            limitBytes: 2 * 1024 * 1024 * 1024,
            itemCount: 34
        )
        let accountOutput = render(
            view: SettingsPopoverView(
                controller: controller,
                previewAccount: previewAccount,
                previewCacheSummary: previewCacheSummary,
                onClose: {}
            )
                .background(.regularMaterial),
            width: 304,
            name: "annoyo-settings-roaming-light.png",
            settleTime: 0.5
        )
        controller.createPlaylist()
        let userPlaylistItems = (1 ... 20).map { index in
            sampleVideo(
                id: "BV1LIST\(index)",
                title: "播放列表里的第 \(index) 首音频"
            )
        }
        controller.playbackQueue.replace(
            items: userPlaylistItems,
            currentID: userPlaylistItems[9].id,
            resumePartIndex: 0,
            resumePosition: 0,
            savedPlaylistID: controller.playbackQueue.savedPlaylistID,
            savedPlaylistName: controller.playbackQueue.savedPlaylistName
        )
        let userPlaylistOutput = render(
            controller: controller,
            name: "annoyo-main-user-playlist-light.png",
            settleTime: 0.8
        )
        let userPlaylistAccountOutput = render(
            view: SettingsPopoverView(
                controller: controller,
                previewAccount: previewAccount,
                previewCacheSummary: previewCacheSummary,
                onClose: {}
            )
                .background(.regularMaterial),
            width: 304,
            name: "annoyo-settings-user-playlist-light.png",
            settleTime: 0.5
        )
        let darkSettingsOutput = render(
            view: SettingsPopoverView(
                controller: controller,
                previewAccount: previewAccount,
                previewCacheSummary: previewCacheSummary,
                onClose: {}
            )
                .background(.regularMaterial),
            width: 304,
            name: "annoyo-settings-user-playlist-dark.png",
            settleTime: 0.5,
            colorScheme: .dark
        )
        if ProcessInfo.processInfo.environment["ANNOYO_STATIC_VISUALS"] == "1" {
            print(emptyOutput.path)
            print(iconOutput.path)
            print(playingIconOutput.path)
            print(mainQueueOutput.path)
            print(searchResultsOutput.path)
            print(accountOutput.path)
            print(userPlaylistOutput.path)
            print(userPlaylistAccountOutput.path)
            print(darkSettingsOutput.path)
            return
        }

        controller.playbackQueue.clear()
        controller.search("周杰伦")

        wait(until: { !controller.isSearching }, timeout: 20)
        guard let first = controller.searchResults.first else {
            fail("No search results available for visual check")
        }
        let liveSearchResultsOutput = render(
            view: MenuBarView(
                controller: controller,
                initialSearchText: "周杰伦",
                initialSearchResults: controller.searchResults
            )
            .background(.regularMaterial),
            width: 360,
            name: "annoyo-main-search-results-live-light.png",
            settleTime: 1
        )

        controller.play(first)
        wait(until: {
            controller.playbackState.isPlaying || {
                if case .failed = controller.playbackState { return true }
                return false
            }()
        }, timeout: 35)

        if case let .failed(message) = controller.playbackState {
            fail("Playback failed during visual check: \(message)")
        }
        guard controller.playbackState.isPlaying else {
            fail("Playback did not start before visual check timeout")
        }

        let playingOutput = render(
            controller: controller,
            name: "annoyo-playing-light.png",
            settleTime: 3
        )

        controller.togglePlayback()
        print(emptyOutput.path)
        print(iconOutput.path)
        print(playingIconOutput.path)
        print(mainQueueOutput.path)
        print(accountOutput.path)
        print(userPlaylistOutput.path)
        print(userPlaylistAccountOutput.path)
        print(darkSettingsOutput.path)
        print(searchResultsOutput.path)
        print(liveSearchResultsOutput.path)
        print(playingOutput.path)
    }

    private static func render(
        controller: PlayerController,
        name: String,
        settleTime: TimeInterval
    ) -> URL {
        render(
            view: MenuBarView(controller: controller)
                .background(.regularMaterial),
            width: 360,
            name: name,
            settleTime: settleTime
        )
    }

    private static func render<Content: View>(
        view: Content,
        width: CGFloat,
        name: String,
        settleTime: TimeInterval,
        colorScheme: ColorScheme = .light
    ) -> URL {
        let rootView = view
            .environment(\.colorScheme, colorScheme)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderBack(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(settleTime))
        let fittingHeight = ceil(hostingView.fittingSize.height)
        guard fittingHeight > 0, fittingHeight <= 600 else {
            fail("Unexpected adaptive panel height: \(fittingHeight)")
        }
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: fittingHeight)
        window.setContentSize(hostingView.frame.size)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            fail("Could not create bitmap representation")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            fail("Could not encode PNG")
        }

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Artifacts/\(name)")
        do {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: output, options: .atomic)
        } catch {
            fail("Could not write visual artifact: \(error.localizedDescription)")
        }

        window.close()
        return output
    }

    private static func wait(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }

    private static func temporaryQueueURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/visual-queue-\(UUID().uuidString).json")
    }

    private static func temporaryAudioCache() -> AudioCache {
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/visual-audio-cache-\(UUID().uuidString)", isDirectory: true)
        return AudioCache(rootURL: rootURL)
    }

    private static func temporarySavedPlaylistStore() -> SavedPlaylistStore {
        let storageURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/visual-playlists-\(UUID().uuidString).json")
        return SavedPlaylistStore(storageURL: storageURL)
    }

    private static func sampleVideo(id: String, title: String) -> VideoSearchResult {
        VideoSearchResult(
            bvid: id,
            title: title,
            creator: "AnnoyO 测试 UP",
            description: "",
            coverURL: nil,
            durationText: "03:30",
            playCountText: "1.2万",
            publishedAt: nil
        )
    }
}
