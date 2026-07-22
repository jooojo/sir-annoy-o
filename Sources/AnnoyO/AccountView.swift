import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
final class QRCodeLoginController: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var statusText = "正在生成二维码…"
    @Published private(set) var isLoading = false
    @Published private(set) var isComplete = false
    @Published private(set) var errorMessage: String?

    private let service: BilibiliService
    private var task: Task<Void, Never>?

    init(service: BilibiliService = .shared) {
        self.service = service
    }

    func start() {
        task?.cancel()
        image = nil
        errorMessage = nil
        isComplete = false
        isLoading = true
        statusText = "正在生成二维码…"

        task = Task { [weak self, service] in
            do {
                let session = try await service.beginQRCodeLogin()
                guard !Task.isCancelled else { return }
                self?.image = Self.makeQRCode(session.url.absoluteString)
                self?.isLoading = false
                self?.statusText = "打开手机 Bilibili 扫码"
                try await self?.poll(session)
            } catch is CancellationError {
                return
            } catch {
                self?.isLoading = false
                self?.errorMessage = error.localizedDescription
                self?.statusText = "二维码生成失败"
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func poll(_ session: QRCodeLoginSession) async throws {
        while !Task.isCancelled {
            let status = try await service.pollQRCodeLogin(key: session.key)
            switch status {
            case .waitingForScan:
                statusText = "打开手机 Bilibili 扫码"
            case .waitingForConfirmation:
                statusText = "已扫码，请在手机上确认"
            case .confirmed:
                statusText = "登录成功"
                isComplete = true
                return
            case .expired:
                statusText = "二维码已过期"
                errorMessage = "请刷新二维码后重试"
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private static func makeQRCode(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct AccountView: View {
    @ObservedObject var player: PlayerController
    let onClose: () -> Void
    private let previewAccount: BilibiliAccount?
    private let usesPreviewCacheSummary: Bool
    @StateObject private var login = QRCodeLoginController()
    @State private var cacheSummary: AudioCacheSummary

    init(
        player: PlayerController,
        onClose: @escaping () -> Void,
        previewAccount: BilibiliAccount? = nil,
        previewCacheSummary: AudioCacheSummary? = nil
    ) {
        self.player = player
        self.onClose = onClose
        self.previewAccount = previewAccount
        usesPreviewCacheSummary = previewCacheSummary != nil
        _cacheSummary = State(
            initialValue: previewCacheSummary
                ?? AudioCacheSummary(
                    usedBytes: 0,
                    limitBytes: 2 * 1024 * 1024 * 1024,
                    itemCount: 0
                )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let account = displayedAccount {
                loggedInView(account)
            } else {
                qrLoginView
            }

            settingsDivider
            deleteCurrentPlaylistButton
            settingsDivider
            cacheView
            settingsDivider
            quitApplicationButton
        }
        .padding(10)
        .frame(width: 304)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if !usesPreviewCacheSummary { refreshCacheSummary() }
            if displayedAccount == nil { login.start() }
        }
        .onDisappear { login.cancel() }
        .onReceive(login.$isComplete) { complete in
            guard complete else { return }
            player.refreshAccount()
        }
    }

    private var displayedAccount: BilibiliAccount? {
        previewAccount ?? player.account
    }

    private var settingsDivider: some View {
        GlassContentDivider()
            .padding(.vertical, 3)
            .padding(.leading, SettingsRow.contentLeadingInset)
    }

    private var qrLoginView: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.07), radius: 9, y: 3)
                if let image = login.image {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 158, height: 158)
                } else if login.isLoading {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 184, height: 184)

            Text(login.statusText)
                .font(.system(size: 11, weight: .semibold))

            if let error = login.errorMessage {
                Button("刷新二维码") { login.start() }
                    .buttonStyle(.borderedProminent)
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("不会读取或保存你的账号密码")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private func loggedInView(_ account: BilibiliAccount) -> some View {
        SettingsRow(
            systemImage: "person.crop.circle",
            title: account.name,
            subtitle: "Bilibili 已登录"
        ) {
            Button("退出账号") {
                player.logOut()
                onClose()
            }
            .buttonStyle(SettingsAccessoryButtonStyle())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
        }
    }

    private var cacheView: some View {
        SettingsRow(
            systemImage: "internaldrive",
            title: "音频缓存",
            subtitle: "已缓存 \(cacheSummary.itemCount) 个音频"
        ) {
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(formattedBytes(cacheSummary.usedBytes)) / \(formattedBytes(cacheSummary.limitBytes))")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("清理缓存") {
                    player.clearAudioCache()
                    refreshCacheSummary()
                }
                .buttonStyle(SettingsAccessoryButtonStyle())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .disabled(cacheSummary.usedBytes == 0)
            }
        }
    }

    private var deleteCurrentPlaylistButton: some View {
        Button {
            guard let playlist = currentBrowsedPlaylist, !playlist.isRoaming else { return }
            player.deleteSavedPlaylist(playlist)
        } label: {
            SettingsRow(
                systemImage: "xmark",
                title: "删除当前列表",
                trailingText: player.playbackQueue.displayName
            )
        }
        .buttonStyle(SettingsRowButtonStyle())
        .foregroundStyle(.primary)
        .disabled(currentBrowsedPlaylist?.isRoaming != false)
        .help(
            currentBrowsedPlaylist?.isRoaming == true
                ? "漫游列表不可删除"
                : "删除当前浏览列表"
        )
    }

    private var quitApplicationButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            SettingsRow(
                systemImage: "power",
                title: "退出 AnnoyO"
            )
        }
        .buttonStyle(SettingsRowButtonStyle())
        .foregroundStyle(.primary)
        .help("退出 AnnoyO")
    }

    private var currentBrowsedPlaylist: SavedPlaylist? {
        guard let playlistID = player.playbackQueue.savedPlaylistID else { return nil }
        return player.savedPlaylists.playlists.first { $0.id == playlistID }
    }

    private func refreshCacheSummary() {
        cacheSummary = player.cacheSummary()
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let kilobyte = Double(1024)
        let megabyte = kilobyte * 1024
        let gigabyte = megabyte * 1024
        let value = Double(max(0, bytes))
        if value >= gigabyte {
            let amount = value / gigabyte
            return amount.rounded() == amount
                ? String(format: "%.0f GB", amount)
                : String(format: "%.1f GB", amount)
        }
        if value >= megabyte { return String(format: "%.1f MB", value / megabyte) }
        return String(format: "%.0f KB", value / kilobyte)
    }
}

private struct SettingsRow: View {
    static let horizontalPadding: CGFloat = 8
    static let iconWidth: CGFloat = 18
    static let spacing: CGFloat = 8
    static let contentLeadingInset = horizontalPadding + iconWidth + spacing

    let systemImage: String
    let title: String
    let subtitle: String?
    private let accessory: AnyView

    init(
        systemImage: String,
        title: String,
        subtitle: String? = nil,
        trailingText: String? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        if let trailingText {
            accessory = AnyView(
                Text(trailingText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            )
        } else {
            accessory = AnyView(EmptyView())
        }
    }

    init<Accessory: View>(
        systemImage: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.accessory = AnyView(accessory())
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: subtitle == nil ? 40 : 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct SettingsRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.42)
            .background(
                Color.primary.opacity(backgroundOpacity(isPressed: configuration.isPressed)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = isEnabled && hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0 }
        if isPressed { return 0.11 }
        return isHovered ? 0.07 : 0
    }
}

private struct SettingsAccessoryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .opacity(isEnabled ? 1 : 0.38)
            .background(
                Color.primary.opacity(backgroundOpacity(isPressed: configuration.isPressed)),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = isEnabled && hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0 }
        if isPressed { return 0.11 }
        return isHovered ? 0.07 : 0
    }
}
