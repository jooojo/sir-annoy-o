import AppKit
import SwiftUI

struct GlassContentDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(height: 1)
    }
}

private enum MainPanelMode {
    case playlist
    case search
}

struct MenuBarView: View {
    @ObservedObject var controller: PlayerController
    private let initialSearchResults: [VideoSearchResult]
    @State private var showsSettings = false
    @State private var mainPanelMode = MainPanelMode.playlist
    @State private var headerSearchText = ""
    @State private var displayedSearchResults: [VideoSearchResult] = []
    @State private var activeSearchTransitionID: UUID?
    @State private var panelTransitionTask: Task<Void, Never>?
    @State private var rollerBlur: CGFloat = 0
    @State private var rollerCompression: CGFloat = 1
    @State private var isRollerAnimating = false
    @State private var isRenamingPlaylist = false
    @State private var playlistNameDraft = ""
    @State private var playlistScrollOffsets: [UUID: CGFloat] = [:]
    @State private var restoringScrollForPlaylistID: UUID?
    @FocusState private var playlistNameIsFocused: Bool

    init(
        controller: PlayerController,
        initialSearchText: String = "",
        initialSearchResults: [VideoSearchResult] = []
    ) {
        _controller = ObservedObject(wrappedValue: controller)
        self.initialSearchResults = initialSearchResults
        _headerSearchText = State(initialValue: initialSearchText)
    }

    private var playlistSlideTransition: AnyTransition {
        let movesForward = controller.playlistTransitionDirection >= 0
        return .asymmetric(
            insertion: .move(edge: movesForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movesForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                mainHeader(using: scrollProxy)
                ZStack {
                    if mainPanelMode == .playlist {
                        queueList(
                            using: scrollProxy,
                            playlistID: controller.playbackQueue.savedPlaylistID
                        )
                            .id(controller.playbackQueue.savedPlaylistID)
                            .transition(playlistSlideTransition)
                    } else {
                        searchResultsPanel(using: scrollProxy)
                            .id("search-results")
                            .transition(.opacity)
                    }
                }
                .clipped()
                .animation(
                    .easeInOut(duration: 0.28),
                    value: controller.playbackQueue.savedPlaylistID
                )
                .animation(.easeInOut(duration: 0.24), value: mainPanelMode)
            }
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .task { controller.refreshAccount() }
        .onAppear {
            guard !initialSearchResults.isEmpty,
                  displayedSearchResults.isEmpty
            else { return }
            displayedSearchResults = initialSearchResults
            mainPanelMode = .search
        }
        .onReceive(controller.$searchResults) { results in
            guard activeSearchTransitionID == nil else { return }
            guard !(mainPanelMode == .search
                && results.isEmpty
                && !displayedSearchResults.isEmpty)
            else { return }
            displayedSearchResults = results
        }
        .onDisappear {
            panelTransitionTask?.cancel()
        }
        .contextMenu {
            if controller.currentVideo != nil {
                Button("在 Bilibili 打开", systemImage: "safari") {
                    controller.openCurrentVideo()
                }
                Divider()
            }
            Button("退出 AnnoyO", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func mainHeader(using scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 4) {
            Button {
                cancelRenamingPlaylist()
                controller.switchPlaylist(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(PlaylistToolbarButtonStyle())
            .disabled(!controller.canSwitchPlaylist)
            .help("上一个播放列表")

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                ZStack(alignment: .leading) {
                    if isRenamingPlaylist {
                        TextField("列表名称", text: $playlistNameDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .focused($playlistNameIsFocused)
                            .onSubmit { finishRenamingPlaylist() }
                            .onExitCommand { cancelRenamingPlaylist() }
                    } else if controller.playbackQueue.isRoaming {
                        Text(controller.playbackQueue.displayName)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    } else {
                        Text(controller.playbackQueue.displayName)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .contentShape(Rectangle())
                            .onTapGesture { beginRenamingPlaylist() }
                            .help("点击重命名")
                    }
                }
                .layoutPriority(1)

                Text("\(controller.playbackQueue.items.count) 项")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .id(controller.playbackQueue.savedPlaylistID)
            .transition(playlistSlideTransition)
            .animation(
                .easeInOut(duration: 0.28),
                value: controller.playbackQueue.savedPlaylistID
            )
            .frame(minWidth: 54, maxWidth: 74, alignment: .leading)
            .layoutPriority(3)

            Button {
                cancelRenamingPlaylist()
                controller.switchPlaylist(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(PlaylistToolbarButtonStyle())
            .disabled(!controller.canSwitchPlaylist)
            .help("下一个播放列表")

            Button {
                cancelRenamingPlaylist()
                controller.createPlaylist()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(PlaylistToolbarButtonStyle())
            .help("新建播放列表")

            HeaderSearchField(
                text: $headerSearchText,
                isSearching: controller.isSearching
            ) {
                beginSearchTransition(using: scrollProxy)
            }
            .frame(width: 88)
            .layoutPriority(2)

            playbackControls(using: scrollProxy)

            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(MainToolbarButtonStyle())
            .help("设置")
            .popover(isPresented: $showsSettings, arrowEdge: .top) {
                SettingsPopoverView(controller: controller) {
                    showsSettings = false
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
    }

    private func playbackControls(using scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            Button {
                controller.togglePlayback()
            } label: {
                Group {
                    if case .resolving = controller.playbackState {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: controller.playbackState.showsPauseControl ? "pause.fill" : "play.fill")
                            .offset(x: controller.playbackState.showsPauseControl ? 0 : 0.5)
                    }
                }
                .frame(width: 27, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(controller.currentVideo == nil || controller.playbackState == .resolving)
            .help(controller.playbackState.showsPauseControl ? "暂停" : "播放")

            Rectangle()
                .fill(.secondary.opacity(0.18))
                .frame(width: 1, height: 13)

            Button {
                returnToPlayingAndAnimate(using: scrollProxy)
            } label: {
                Image(systemName: "scope")
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                mainPanelMode == .search
                    || !controller.canReturnToPlayingPlaylist
                    || isRollerAnimating
            )
            .help("回到当前播放")

            Rectangle()
                .fill(.secondary.opacity(0.18))
                .frame(width: 1, height: 13)

            Button {
                controller.cyclePlaybackOrderMode()
            } label: {
                Image(systemName: playbackOrderModeIcon)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.currentVideo == nil)
            .help(playbackOrderModeHelp)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .background(.secondary.opacity(0.08), in: Capsule())
    }

    private var playbackOrderModeIcon: String {
        switch controller.playbackOrderMode {
        case .repeatAll: "repeat"
        case .repeatOne: "repeat.1"
        case .shuffle: "shuffle"
        }
    }

    private var playbackOrderModeHelp: String {
        switch controller.playbackOrderMode {
        case .repeatAll: "列表循环；点击切换为单曲循环"
        case .repeatOne: "单曲循环；点击切换为列表随机"
        case .shuffle: "列表随机；点击切换为列表循环"
        }
    }

    private func queueList(
        using scrollProxy: ScrollViewProxy,
        playlistID: UUID?
    ) -> some View {
        VStack(spacing: 0) {
            GlassContentDivider()

            if controller.playbackQueue.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 24, weight: .light))
                        Text("从搜索结果加入想听的内容")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                    .frame(height: rollerHeight)
            } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: rollerEndInset)
                            ForEach(rollerItems) { item in
                                let video = item.video
                                let isCurrent = video.id == displayedCurrentVideo?.id
                                GeometryReader { geometry in
                                    RollerQueueRow(
                                        index: item.logicalIndex + 1,
                                        video: video,
                                        isCurrent: isCurrent,
                                        playbackState: isCurrent ? controller.playbackState : .idle,
                                        elapsed: isCurrent ? controller.elapsed : 0,
                                        duration: isCurrent ? controller.duration : 0,
                                        audioLevel: controller.audioLevel,
                                        togglePlaybackAction: { controller.togglePlayback() },
                                        seekAction: { controller.seek(to: $0) },
                                        playAction: { controller.playQueued(video) },
                                        pinAction: {
                                            withAnimation(.easeInOut(duration: 0.22)) {
                                                controller.playbackQueue.moveToTop(video)
                                            }
                                        },
                                        removeAction: { controller.removeFromQueue(video) },
                                        openOriginalAction: { controller.openVideo(video) }
                                    )
                                    .scaleEffect(rollerScale(for: geometry))
                                    .offset(x: rollerHorizontalInset(for: geometry))
                                    .opacity(rollerOpacity(for: geometry))
                                    .preference(
                                        key: RollerCenterPreferenceKey.self,
                                        value: [RollerCenterCandidate(
                                            id: item.id,
                                            cycle: item.cycle,
                                            videoID: video.id,
                                            distance: abs(rollerPosition(for: geometry))
                                        )]
                                    )
                                }
                                .frame(height: isCurrent ? 100 : 46)
                                .id(item.id)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                ))
                            }
                            Color.clear.frame(height: rollerEndInset)
                        }
                        .blur(radius: rollerBlur)
                        .scaleEffect(x: 1, y: rollerCompression, anchor: .center)
                        .background {
                            if let playlistID {
                                RollerScrollPositionBridge(
                                    initialOffset: playlistScrollOffsets[playlistID],
                                    loopsAtBoundaries: RollerLoopLayout.usesCompactLoop(
                                        forItemCount: controller.playbackQueue.items.count
                                    ),
                                    onOffsetChange: { offset in
                                        rememberScrollOffset(offset, for: playlistID)
                                    },
                                    onRestoreCompleted: {
                                        finishRestoringScroll(for: playlistID)
                                    }
                                )
                            }
                        }
                    }
                    .coordinateSpace(name: "queueRoller")
                    .scrollIndicators(.never)
                    .frame(height: rollerHeight)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white, location: 0.09),
                                .init(color: .white, location: 0.91),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .onAppear {
                        restoringScrollForPlaylistID = playlistID
                        if let playlistID {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                finishRestoringScroll(for: playlistID)
                            }
                        }
                        if playlistID.flatMap({ playlistScrollOffsets[$0] }) == nil {
                            scrollToCurrent(
                                for: playlistID,
                                using: scrollProxy,
                                animated: false
                            )
                        }
                    }
                    .onReceive(controller.playbackQueue.currentSelectionChanged) {
                        scrollToCurrent(
                            for: playlistID,
                            using: scrollProxy
                        )
                    }
                    .onPreferenceChange(RollerCenterPreferenceKey.self) { candidates in
                        recenterLoopIfNeeded(
                            candidates,
                            for: playlistID,
                            using: scrollProxy
                        )
                    }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func searchResultsPanel(using scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            GlassContentDivider()

            if displayedSearchResults.isEmpty {
                VStack(spacing: 8) {
                    if controller.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: controller.notice == nil ? "music.note.list" : "exclamationmark.bubble")
                            .font(.system(size: 24, weight: .light))
                    }
                    Text(controller.isSearching ? "正在搜索…" : controller.notice ?? "没有找到相关视频")
                        .font(.system(size: 10, weight: .medium))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.tertiary)
                .frame(height: searchRollerHeight)
                .blur(radius: rollerBlur)
                .scaleEffect(x: 1, y: rollerCompression, anchor: .center)
            } else {
                SearchResultsRoller(
                    controller: controller,
                    results: displayedSearchResults,
                    height: searchRollerHeight,
                    blur: rollerBlur,
                    compression: rollerCompression,
                    resultID: searchResultID
                )
            }

            GlassContentDivider()

            Button {
                returnToPlaylist(using: scrollProxy)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.backward")
                        .frame(width: 14)
                    Text("返回播放列表")
                    Spacer()
                }
                .font(.system(size: 10, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SearchReturnButtonStyle())
            .foregroundStyle(.secondary)
            .disabled(isRollerAnimating)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var searchRollerHeight: CGFloat { rollerHeight - 41 }

    private func beginSearchTransition(using proxy: ScrollViewProxy) {
        let query = headerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        panelTransitionTask?.cancel()
        let transitionID = UUID()
        activeSearchTransitionID = transitionID
        isRollerAnimating = true
        withAnimation(.easeIn(duration: 0.16)) {
            rollerBlur = 5
            rollerCompression = 0.94
        }
        controller.search(query)

        panelTransitionTask = Task { @MainActor in
            var step = 0
            repeat {
                guard !Task.isCancelled,
                      activeSearchTransitionID == transitionID
                else { return }
                spinVisibleRoller(using: proxy, step: step)
                step += 1
                try? await Task.sleep(for: .milliseconds(130))
            } while controller.isSearching || step < 4

            guard !Task.isCancelled,
                  activeSearchTransitionID == transitionID
            else { return }
            displayedSearchResults = controller.searchResults
            withAnimation(.easeInOut(duration: 0.22)) {
                mainPanelMode = .search
            }
            try? await Task.sleep(for: .milliseconds(80))
            if let first = displayedSearchResults.first {
                proxy.scrollTo(searchResultID(first.id), anchor: .top)
            }
            withAnimation(.timingCurve(0.08, 0.72, 0.12, 1, duration: 0.62)) {
                rollerBlur = 0
                rollerCompression = 1
            }
            try? await Task.sleep(for: .milliseconds(640))
            guard activeSearchTransitionID == transitionID else { return }
            activeSearchTransitionID = nil
            isRollerAnimating = false
        }
    }

    private func returnToPlaylist(using proxy: ScrollViewProxy) {
        guard mainPanelMode == .search else { return }
        panelTransitionTask?.cancel()
        activeSearchTransitionID = nil
        isRollerAnimating = true
        withAnimation(.easeIn(duration: 0.16)) {
            rollerBlur = 5
            rollerCompression = 0.94
        }

        panelTransitionTask = Task { @MainActor in
            for step in 0 ..< 3 {
                guard !Task.isCancelled else { return }
                spinVisibleRoller(using: proxy, step: step)
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                mainPanelMode = .playlist
            }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.timingCurve(0.08, 0.72, 0.12, 1, duration: 0.62)) {
                rollerBlur = 0
                rollerCompression = 1
            }
            try? await Task.sleep(for: .milliseconds(640))
            guard !Task.isCancelled else { return }
            isRollerAnimating = false
        }
    }

    private func spinVisibleRoller(using proxy: ScrollViewProxy, step: Int) {
        let targetID: String?
        switch mainPanelMode {
        case .playlist:
            let items = controller.playbackQueue.items
            guard !items.isEmpty else { return }
            let item = items[step % items.count]
            let cycles = RollerLoopLayout.cycles(forItemCount: items.count)
            let cycle = cycles[step % cycles.count]
            targetID = loopID(videoID: item.id, cycle: cycle)
        case .search:
            guard !displayedSearchResults.isEmpty else { return }
            let result = displayedSearchResults[step % displayedSearchResults.count]
            targetID = searchResultID(result.id)
        }
        guard let targetID else { return }
        withAnimation(.linear(duration: 0.13)) {
            proxy.scrollTo(targetID, anchor: .center)
        }
    }

    private func searchResultID(_ videoID: String) -> String {
        "search-\(videoID)"
    }

    private var displayedCurrentVideo: VideoSearchResult? {
        if let currentVideo = controller.currentVideo {
            return controller.isDisplayingPlayingPlaylist ? currentVideo : nil
        }
        return controller.playbackQueue.current
    }

    private var rollerAnchorVideo: VideoSearchResult? {
        displayedCurrentVideo ?? controller.playbackQueue.current
    }

    private var rollerItems: [RollerLoopItem] {
        let items = controller.playbackQueue.items
        guard !items.isEmpty else { return [] }
        let cycles = RollerLoopLayout.cycles(forItemCount: items.count)
        return cycles.flatMap { cycle in
            items.enumerated().map { index, video in
                RollerLoopItem(
                    id: loopID(videoID: video.id, cycle: cycle),
                    cycle: cycle,
                    logicalIndex: index,
                    video: video
                )
            }
        }
    }

    private var rollerHeight: CGFloat { 334 }
    private var rollerEndInset: CGFloat { 117 }

    private func rollerPosition(for geometry: GeometryProxy) -> CGFloat {
        let center = rollerHeight / 2
        return (geometry.frame(in: .named("queueRoller")).midY - center) / center
    }

    private func rollerScale(for geometry: GeometryProxy) -> CGFloat {
        max(0.90, 1 - abs(rollerPosition(for: geometry)) * 0.07)
    }

    private func rollerHorizontalInset(for geometry: GeometryProxy) -> CGFloat {
        abs(rollerPosition(for: geometry)) * 7
    }

    private func rollerOpacity(for geometry: GeometryProxy) -> Double {
        Double(max(0.72, 1 - abs(rollerPosition(for: geometry)) * 0.18))
    }

    private func scrollToCurrent(
        for playlistID: UUID?,
        using proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        guard let videoID = rollerAnchorVideo?.id else { return }
        let id = loopID(videoID: videoID, cycle: 1)
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func rememberScrollOffset(_ offset: CGFloat, for playlistID: UUID) {
        if let previousOffset = playlistScrollOffsets[playlistID],
           abs(previousOffset - offset) <= 0.5 {
            return
        }
        playlistScrollOffsets[playlistID] = offset
    }

    private func finishRestoringScroll(for playlistID: UUID) {
        guard restoringScrollForPlaylistID == playlistID else { return }
        restoringScrollForPlaylistID = nil
    }

    private func animateRollerToCurrent(
        using proxy: ScrollViewProxy,
        targetVideoID: String
    ) {
        guard !isRollerAnimating else { return }

        isRollerAnimating = true
        let currentID = loopID(videoID: targetVideoID, cycle: 1)
        let flybyCycle = RollerLoopLayout.usesCompactLoop(
            forItemCount: controller.playbackQueue.items.count
        ) ? 1 : 2
        let flybyID = controller.playbackQueue.items
            .last(where: { $0.id != targetVideoID })
            .map { loopID(videoID: $0.id, cycle: flybyCycle) }

        withAnimation(.easeIn(duration: 0.18)) {
            rollerBlur = 5
            rollerCompression = 0.94
        }
        if let flybyID {
            withAnimation(.linear(duration: 0.20)) {
                proxy.scrollTo(flybyID, anchor: .center)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.timingCurve(0.08, 0.72, 0.12, 1, duration: 0.82)) {
                proxy.scrollTo(currentID, anchor: .center)
            }
            withAnimation(.easeOut(duration: 0.82)) {
                rollerBlur = 0
                rollerCompression = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.84) {
                isRollerAnimating = false
            }
        }
    }

    private func returnToPlayingAndAnimate(using proxy: ScrollViewProxy) {
        let switchesPlaylist = !controller.isDisplayingPlayingPlaylist
        guard let currentVideoID = controller.currentVideo?.id,
              controller.returnToPlayingPlaylist()
        else { return }
        let delay = switchesPlaylist ? 0.32 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            animateRollerToCurrent(
                using: proxy,
                targetVideoID: currentVideoID
            )
        }
    }

    private func recenterLoopIfNeeded(
        _ candidates: [RollerCenterCandidate],
        for playlistID: UUID?,
        using proxy: ScrollViewProxy
    ) {
        guard controller.playbackQueue.savedPlaylistID == playlistID,
              controller.playbackQueue.items.count > 1,
              !isRollerAnimating,
              restoringScrollForPlaylistID != playlistID,
              let nearest = candidates.min(by: { $0.distance < $1.distance }),
              nearest.cycle != 1
        else { return }

        let middleID = loopID(videoID: nearest.videoID, cycle: 1)
        DispatchQueue.main.async {
            proxy.scrollTo(middleID, anchor: .center)
        }
    }

    private func loopID(videoID: String, cycle: Int) -> String {
        "\(cycle)-\(videoID)"
    }

    private func beginRenamingPlaylist() {
        guard !controller.playbackQueue.isRoaming,
              controller.playbackQueue.savedPlaylistID != nil,
              let name = controller.playbackQueue.savedPlaylistName
        else { return }
        playlistNameDraft = name
        isRenamingPlaylist = true
        DispatchQueue.main.async {
            playlistNameIsFocused = true
        }
    }

    private func finishRenamingPlaylist() {
        guard isRenamingPlaylist else { return }
        guard let id = controller.playbackQueue.savedPlaylistID,
              let playlist = controller.savedPlaylists.playlists.first(where: { $0.id == id })
        else {
            cancelRenamingPlaylist()
            return
        }
        controller.renameSavedPlaylist(playlist, to: playlistNameDraft)
        isRenamingPlaylist = false
        playlistNameDraft = ""
    }

    private func cancelRenamingPlaylist() {
        isRenamingPlaylist = false
        playlistNameDraft = ""
    }

}

private struct RollerLoopItem: Identifiable {
    let id: String
    let cycle: Int
    let logicalIndex: Int
    let video: VideoSearchResult
}

private struct RollerCenterCandidate: Equatable {
    let id: String
    let cycle: Int
    let videoID: String
    let distance: CGFloat
}

private struct RollerCenterPreferenceKey: PreferenceKey {
    static let defaultValue: [RollerCenterCandidate] = []

    static func reduce(
        value: inout [RollerCenterCandidate],
        nextValue: () -> [RollerCenterCandidate]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct RollerScrollPositionBridge: NSViewRepresentable {
    let initialOffset: CGFloat?
    let loopsAtBoundaries: Bool
    let onOffsetChange: (CGFloat) -> Void
    let onRestoreCompleted: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            initialOffset: initialOffset,
            loopsAtBoundaries: loopsAtBoundaries,
            onOffsetChange: onOffsetChange,
            onRestoreCompleted: onRestoreCompleted
        )
    }

    func makeNSView(context: Context) -> RollerScrollProbeView {
        let view = RollerScrollProbeView(frame: .zero)
        view.onMoveToWindow = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            DispatchQueue.main.async {
                coordinator.attach(to: view)
            }
        }
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: RollerScrollProbeView, context: Context) {
        context.coordinator.update(
            loopsAtBoundaries: loopsAtBoundaries,
            onOffsetChange: onOffsetChange,
            onRestoreCompleted: onRestoreCompleted
        )
        DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
            guard let nsView, let coordinator else { return }
            coordinator.attach(to: nsView)
        }
    }

    static func dismantleNSView(
        _ nsView: RollerScrollProbeView,
        coordinator: Coordinator
    ) {
        nsView.onMoveToWindow = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var scrollView: NSScrollView?
        private let initialOffset: CGFloat?
        private var onOffsetChange: (CGFloat) -> Void
        private var onRestoreCompleted: () -> Void
        private var didApplyInitialOffset = false
        private var loopsAtBoundaries: Bool
        private var scrollWheelMonitor: RollerScrollWheelMonitorToken?

        init(
            initialOffset: CGFloat?,
            loopsAtBoundaries: Bool,
            onOffsetChange: @escaping (CGFloat) -> Void,
            onRestoreCompleted: @escaping () -> Void
        ) {
            self.initialOffset = initialOffset
            self.loopsAtBoundaries = loopsAtBoundaries
            self.onOffsetChange = onOffsetChange
            self.onRestoreCompleted = onRestoreCompleted
        }

        func update(
            loopsAtBoundaries: Bool,
            onOffsetChange: @escaping (CGFloat) -> Void,
            onRestoreCompleted: @escaping () -> Void
        ) {
            self.loopsAtBoundaries = loopsAtBoundaries
            self.onOffsetChange = onOffsetChange
            self.onRestoreCompleted = onRestoreCompleted
        }

        func attach(to view: NSView) {
            guard let enclosingScrollView = view.enclosingScrollView else { return }

            if scrollView !== enclosingScrollView {
                detach()
                scrollView = enclosingScrollView
                enclosingScrollView.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(boundsDidChange(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: enclosingScrollView.contentView
                )
                installScrollWheelMonitor()
            }

            guard !didApplyInitialOffset else { return }
            didApplyInitialOffset = true

            DispatchQueue.main.async { [weak self, weak enclosingScrollView] in
                guard let self, let enclosingScrollView else { return }
                if let initialOffset = self.initialOffset {
                    self.restore(initialOffset, in: enclosingScrollView)
                } else {
                    self.reportCurrentOffset()
                }
                self.onRestoreCompleted()
            }
        }

        func detach() {
            if let scrollView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView
                )
            }
            if let scrollWheelMonitor {
                NSEvent.removeMonitor(scrollWheelMonitor.value)
                self.scrollWheelMonitor = nil
            }
            scrollView = nil
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            onOffsetChange(clipView.bounds.origin.y)
        }

        private func restore(_ offset: CGFloat, in scrollView: NSScrollView) {
            let documentBounds = scrollView.documentView?.bounds ?? .zero
            let viewportHeight = scrollView.contentView.bounds.height
            let minimumOffset = documentBounds.minY
            let maximumOffset = max(
                minimumOffset,
                documentBounds.maxY - viewportHeight
            )
            let restoredOffset = min(
                max(minimumOffset, offset),
                maximumOffset
            )

            scrollView.contentView.scroll(
                to: NSPoint(
                    x: scrollView.contentView.bounds.origin.x,
                    y: restoredOffset
                )
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func reportCurrentOffset() {
            guard let scrollView else { return }
            onOffsetChange(scrollView.contentView.bounds.origin.y)
        }

        private func installScrollWheelMonitor() {
            guard scrollWheelMonitor == nil else { return }
            let monitor = NSEvent.addLocalMonitorForEvents(
                matching: .scrollWheel
            ) { [weak self] event in
                self?.wrapCompactRollerIfNeeded(for: event)
                return event
            }
            if let monitor {
                scrollWheelMonitor = RollerScrollWheelMonitorToken(value: monitor)
            }
        }

        private func wrapCompactRollerIfNeeded(for event: NSEvent) {
            guard loopsAtBoundaries,
                  let scrollView,
                  event.window === scrollView.window
            else { return }

            let location = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(location) else { return }

            let documentBounds = scrollView.documentView?.bounds ?? .zero
            let viewportHeight = scrollView.contentView.bounds.height
            let minimumOffset = documentBounds.minY
            let maximumOffset = max(
                minimumOffset,
                documentBounds.maxY - viewportHeight
            )
            guard let targetOffset = RollerLoopLayout.boundaryWrapTarget(
                currentOffset: scrollView.contentView.bounds.origin.y,
                minimumOffset: minimumOffset,
                maximumOffset: maximumOffset,
                scrollingDeltaY: event.scrollingDeltaY
            ) else { return }

            scrollView.contentView.scroll(
                to: NSPoint(
                    x: scrollView.contentView.bounds.origin.x,
                    y: targetOffset
                )
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        deinit {
            if let scrollWheelMonitor {
                NSEvent.removeMonitor(scrollWheelMonitor.value)
            }
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private final class RollerScrollWheelMonitorToken: @unchecked Sendable {
    let value: Any

    init(value: Any) {
        self.value = value
    }
}

private final class RollerScrollProbeView: NSView {
    var onMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?()
    }
}

private struct AnimatedPlaybackPattern: View {
    let isAnimating: Bool
    let audioLevel: AudioReactiveLevel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isAnimating)) { _ in
            let motion = audioLevel.snapshot
            Canvas { context, size in
                for lineIndex in 0 ..< 7 {
                    var path = Path()
                    let line = Double(lineIndex)
                    let baseY = size.height * (0.15 + CGFloat(lineIndex) * 0.115)
                    let bassMotion = motion.low * 0.58
                        + motion.lowMid * 0.28
                        + motion.energy * 0.14
                    let energyScale = 0.68 + bassMotion * 1.02 + motion.pulse * 0.26
                    let amplitude = (3.5 + line * 0.65) * energyScale
                    let secondaryAmplitude = 0.82 + motion.midHigh * 1.45

                    for x in stride(from: CGFloat.zero, through: size.width, by: 3) {
                        let progress = Double(x / max(size.width, 1))
                        let frequency = 2.2 + line * 0.11
                        let primaryPhase = progress * Double.pi * frequency
                            + motion.phase * (0.88 + line * 0.045)
                            + line * (0.72 + motion.lowMid * 0.035)
                        let secondaryPhase = progress * Double.pi * 4.0
                            - motion.phase * (0.32 + motion.lowMid * 0.08)
                            + line + motion.midHigh * 0.24
                        let wave = sin(primaryPhase)
                        let secondary = cos(secondaryPhase)
                        let onsetShape = sin(
                            progress * Double.pi * 3.0 + line * 0.55
                        ) * motion.pulse * (1.15 + line * 0.08)
                        let y = baseY + CGFloat(
                            wave * amplitude
                                + secondary * secondaryAmplitude
                                + onsetShape
                        )
                        if x == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }

                    let isStrongLine = lineIndex.isMultiple(of: 3)
                    let baseOpacity = isStrongLine ? 0.050 : 0.027
                    let detailOpacity = isStrongLine ? motion.low * 0.006 : motion.high * 0.007
                    let opacity = baseOpacity + motion.energy * 0.017 + detailOpacity
                    context.stroke(
                        path,
                        with: .color(Color.primary.opacity(opacity)),
                        lineWidth: isStrongLine ? 1.0 : 0.65
                    )
                }

                for stripe in stride(from: -size.height, through: size.width, by: 18) {
                    var path = Path()
                    path.move(to: CGPoint(x: stripe, y: size.height))
                    path.addLine(to: CGPoint(x: stripe + size.height, y: 0))
                    context.stroke(
                        path,
                        with: .color(Color.primary.opacity(0.014 + motion.high * 0.008)),
                        lineWidth: 0.6
                    )
                }

                let glowX = size.width * CGFloat(0.5 + sin(motion.phase * 0.55) * 0.32)
                let glowY = size.height * CGFloat(0.48 + cos(motion.phase * 0.38) * 0.18)
                let glowRadiusValue = 24.0
                    + motion.low * 10
                    + motion.energy * 4
                    + motion.pulse * 3
                let glowRadius = CGFloat(glowRadiusValue)
                let glowRect = CGRect(
                    x: glowX - glowRadius,
                    y: glowY - glowRadius,
                    width: glowRadius * 2,
                    height: glowRadius * 2
                )
                context.fill(
                    Path(ellipseIn: glowRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color.primary.opacity(0.015 + motion.energy * 0.018),
                            .clear
                        ]),
                        center: CGPoint(x: glowX, y: glowY),
                        startRadius: 0,
                        endRadius: glowRadius
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct RollerQueueRow: View {
    let index: Int
    let video: VideoSearchResult
    let isCurrent: Bool
    let playbackState: PlaybackState
    let elapsed: TimeInterval
    let duration: TimeInterval
    let audioLevel: AudioReactiveLevel
    let togglePlaybackAction: () -> Void
    let seekAction: (TimeInterval) -> Void
    let playAction: () -> Void
    let pinAction: () -> Void
    let removeAction: () -> Void
    let openOriginalAction: () -> Void
    @State private var isDeleting = false
    @State private var isHovering = false
    @State private var scrubStartProgress: Double?
    @State private var scrubProgress: Double?

    @ViewBuilder
    var body: some View {
        Group {
            if isCurrent {
                currentRow
            } else {
                queuedRow
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.13)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button("在 Bilibili 打开", systemImage: "safari", action: openOriginalAction)
        }
    }

    private var currentRow: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("当前播放", systemImage: "waveform")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Button(action: togglePlaybackAction) {
                            Group {
                                if playbackState == .resolving {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: playbackState.showsPauseControl ? "pause.fill" : "play.fill")
                                        .font(.system(size: 9, weight: .bold))
                                }
                            }
                            .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help(playbackState.showsPauseControl ? "暂停" : "播放")
                        .disabled(playbackState == .resolving)

                        Button(action: beginDeletion) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help("删除当前播放")
                        .disabled(isDeleting)
                    }
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                }

                Text(video.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(video.creator)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack(alignment: .leading) {
                    Color.primary.opacity(0.018)
                    Color.primary.opacity(scrubProgress == nil ? 0.050 : 0.072)
                        .frame(width: geometry.size.width * displayedProgress)
                        .animation(
                            scrubProgress == nil ? .linear(duration: 0.48) : nil,
                            value: displayedProgress
                        )
                    AnimatedPlaybackPattern(
                        isAnimating: playbackState.isPlaying,
                        audioLevel: audioLevel
                    )
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(scrubGesture(width: geometry.size.width))
            .help("长按后左右拖动以调整播放位置")
            .overlay(alignment: .top) {
                GlassContentDivider()
            }
            .overlay(alignment: .bottom) {
                GlassContentDivider()
            }
            .offset(x: isDeleting ? 24 : 0)
            .opacity(isDeleting ? 0 : 1)
            .animation(.easeOut(duration: 0.16), value: isDeleting)
        }
    }

    private var playbackProgress: Double {
        guard duration.isFinite, duration > 0, elapsed.isFinite else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    private var displayedProgress: CGFloat {
        CGFloat(scrubProgress ?? playbackProgress)
    }

    private var canScrub: Bool {
        guard duration.isFinite, duration > 0 else { return false }
        return switch playbackState {
        case .playing, .paused, .buffering:
            true
        case .idle, .resolving, .failed:
            false
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard canScrub, width > 0 else { return }
                switch value {
                case .first(true):
                    beginScrubbingIfNeeded()
                case let .second(true, drag?):
                    beginScrubbingIfNeeded()
                    guard let scrubStartProgress else { return }
                    scrubProgress = min(
                        max(scrubStartProgress + Double(drag.translation.width / width), 0),
                        1
                    )
                default:
                    break
                }
            }
            .onEnded { value in
                defer {
                    scrubStartProgress = nil
                    scrubProgress = nil
                }
                guard canScrub,
                      case let .second(true, drag?) = value,
                      abs(drag.translation.width) >= 1,
                      let scrubProgress
                else { return }
                seekAction(scrubProgress * duration)
            }
    }

    private func beginScrubbingIfNeeded() {
        guard scrubStartProgress == nil else { return }
        scrubStartProgress = playbackProgress
        scrubProgress = playbackProgress
    }

    private var queuedRow: some View {
        HStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", index))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(video.creator)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
            }

            HStack(spacing: 5) {
                Button(action: playAction) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(.plain)
                .help("立即播放")

                Button(action: pinAction) {
                    Image(systemName: "arrow.up.to.line")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 19, height: 28)
                }
                .buttonStyle(.plain)
                .help("下一首播放")

                Button(action: beginDeletion) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 19, height: 28)
                }
                .buttonStyle(.plain)
                .help("从播放列表移除")
                .disabled(isDeleting)
            }
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            GlassContentDivider()
                .padding(.leading, 35)
        }
        .offset(x: isDeleting ? 24 : 0)
        .opacity(isDeleting ? 0 : 1)
        .animation(.easeOut(duration: 0.16), value: isDeleting)
    }

    private func beginDeletion() {
        guard !isDeleting else { return }
        isDeleting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.easeInOut(duration: 0.22)) {
                removeAction()
            }
        }
    }
}

private struct HeaderSearchField: View {
    @Binding var text: String
    let isSearching: Bool
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .focused($isFocused)
                .frame(width: isSearching ? 38 : 54)
                .onSubmit(onSubmit)
            if isSearching {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 27)
        .clipped()
        .background(
            Color.primary.opacity(isFocused ? 0.08 : 0.055),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .help("搜索 Bilibili 视频")
    }
}

private struct SearchResultsRoller: View {
    @ObservedObject var controller: PlayerController
    let results: [VideoSearchResult]
    let height: CGFloat
    let blur: CGFloat
    let compression: CGFloat
    let resultID: (String) -> String

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                Color.clear.frame(height: 8)
                ForEach(results) { video in
                    GeometryReader { geometry in
                        SearchResultRow(
                            video: video,
                            isCurrent: video == controller.currentVideo,
                            isPlaying: video == controller.currentVideo
                                && controller.playbackState.isPlaying,
                            isQueued: controller.playbackQueue.contains(video),
                            enqueueHelp: controller.playbackQueue.isRoaming
                                ? "设为漫游下一首"
                                : "加入播放队列",
                            enqueueAction: { controller.enqueue(video) }
                        ) {
                            controller.play(video)
                        }
                        .scaleEffect(scale(for: geometry))
                        .offset(x: horizontalInset(for: geometry))
                        .opacity(opacity(for: geometry))
                    }
                    .frame(height: 50)
                    .id(resultID(video.id))
                }
                paginationFooter
                Color.clear.frame(height: endInset)
            }
        }
        .coordinateSpace(name: "searchResultsRoller")
        .scrollIndicators(.never)
        .frame(height: height)
        .blur(radius: blur)
        .scaleEffect(x: 1, y: compression, anchor: .center)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.09),
                    .init(color: .white, location: 0.91),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var endInset: CGFloat { max(0, (height - 50) / 2) }

    private func position(for geometry: GeometryProxy) -> CGFloat {
        let center = height / 2
        return (geometry.frame(in: .named("searchResultsRoller")).midY - center) / center
    }

    private func scale(for geometry: GeometryProxy) -> CGFloat {
        max(0.92, 1 - abs(position(for: geometry)) * 0.06)
    }

    private func horizontalInset(for geometry: GeometryProxy) -> CGFloat {
        abs(position(for: geometry)) * 6
    }

    private func opacity(for geometry: GeometryProxy) -> Double {
        Double(max(0.68, 1 - abs(position(for: geometry)) * 0.2))
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if let error = controller.searchPaginationError {
            Button {
                controller.retryLoadingSearchResults()
            } label: {
                Label("加载失败，点击重试", systemImage: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(error)
            .frame(height: 38)
        } else if controller.isSearching {
            ProgressView()
                .controlSize(.small)
                .frame(height: 38)
        } else if controller.hasMoreSearchResults {
            ProgressView()
                .controlSize(.small)
                .frame(height: 38)
                .onAppear { controller.loadMoreSearchResults() }
        } else {
            Text("没有更多结果")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(height: 38)
        }
    }
}

private struct SearchReturnButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.11 : isHovered ? 0.07 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct SettingsPopoverView: View {
    @ObservedObject var controller: PlayerController
    let onClose: () -> Void

    var body: some View {
        AccountView(player: controller, onClose: onClose)
    }
}

private struct SearchResultRow: View {
    let video: VideoSearchResult
    let isCurrent: Bool
    let isPlaying: Bool
    let isQueued: Bool
    let enqueueHelp: String
    let enqueueAction: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: action) {
                HStack(spacing: 10) {
                AsyncImage(url: video.coverURL) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.12)
                            .overlay { Image(systemName: "play.rectangle").foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 58, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title)
                        .font(.system(size: 11, weight: isCurrent ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 5) {
                        Text(video.creator).lineLimit(1)
                        Text("·")
                        Text(video.playCountText)
                        Text("·")
                        Text(video.durationText)
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }

                    Spacer(minLength: 4)

                    if isPlaying {
                        Image(systemName: "waveform")
                            .foregroundStyle(.primary)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .padding(7)
                            .background(.secondary.opacity(0.1), in: Circle())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: enqueueAction) {
                Image(systemName: isQueued ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(
                        isQueued ? Color(nsColor: .secondaryLabelColor) : Color.primary
                    )
            }
            .buttonStyle(.plain)
            .disabled(isQueued)
            .help(isQueued ? "已在当前列表" : enqueueHelp)
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .background(isCurrent ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MainToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 29, height: 29)
            .background(configuration.isPressed ? Color.secondary.opacity(0.13) : .clear, in: Circle())
            .contentShape(Circle())
    }
}

private struct PlaylistToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 27)
            .background(
                configuration.isPressed ? Color.secondary.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
