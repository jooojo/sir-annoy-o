#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
sdk_path="${ANNOYO_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"

cd "$repo_root"

file_contains() {
    /usr/bin/grep -Fq -- "$1" "$2"
}

matching_line_count() {
    /usr/bin/grep -F -c -- "$1" "$2" || true
}

tree_contains() {
    /usr/bin/grep -R -Fq -- "$1" "$2"
}

xcrun swift-format lint \
    --strict \
    --configuration .swift-format \
    --recursive \
    Sources \
    Tests \
    Packaging \
    Package.swift

ui_shell_failed=0
if file_contains 'Canvas {' Sources/AnnoyO/StatusBarIcon.swift; then
    echo "FAILED: menu bar label uses Canvas instead of a system-renderable image" >&2
    ui_shell_failed=1
else
    echo "PASS: menu bar label avoids Canvas rendering"
fi

settings_row_hover_count="$(matching_line_count '.buttonStyle(SettingsRowButtonStyle())' Sources/AnnoyO/AccountView.swift)"
settings_accessory_hover_count="$(matching_line_count '.buttonStyle(SettingsAccessoryButtonStyle())' Sources/AnnoyO/AccountView.swift)"
if (( settings_row_hover_count >= 2 && settings_accessory_hover_count >= 2 )); then
    echo "PASS: settings rows and accessory actions expose hover highlighting"
else
    echo "FAILED: expected hover highlighting on settings rows and accessory actions" >&2
    ui_shell_failed=1
fi

if file_contains 'ForEach(player.savedPlaylists.playlists)' Sources/AnnoyO/AccountView.swift; then
    echo "FAILED: account popover still renders the saved-playlist browser" >&2
    ui_shell_failed=1
elif file_contains 'player.playbackQueue.savedPlaylistID' Sources/AnnoyO/AccountView.swift \
    && file_contains 'SettingsRow' Sources/AnnoyO/AccountView.swift \
    && file_contains '.frame(width: 304)' Sources/AnnoyO/AccountView.swift; then
    echo "PASS: settings popover is compact and targets the currently browsed playlist"
else
    echo "FAILED: settings popover lacks compact shared rows or browsed-playlist deletion" >&2
    ui_shell_failed=1
fi

if file_contains 'struct SearchView' Sources/AnnoyO/MenuBarView.swift \
    || file_contains 'SearchView(' Sources/AnnoyO/AccountView.swift; then
    echo "FAILED: obsolete popover search implementation still exists" >&2
    ui_shell_failed=1
elif file_contains 'HeaderSearchControl' Sources/AnnoyO/MenuBarView.swift \
    && file_contains 'isHeaderSearchExpanded = false' Sources/AnnoyO/MenuBarView.swift \
    && file_contains '.frame(width: isHeaderSearchExpanded ? 0 : 112' Sources/AnnoyO/MenuBarView.swift \
    && file_contains '.frame(width: isExpanded ? 152 : 29' Sources/AnnoyO/MenuBarView.swift \
    && file_contains 'TapGesture().onEnded { collapseHeaderSearch() }' Sources/AnnoyO/MenuBarView.swift \
    && file_contains 'private var rollerHeight: CGFloat { 270 }' Sources/AnnoyO/MenuBarView.swift \
    && file_contains 'Image(systemName: "gearshape")' Sources/AnnoyO/MenuBarView.swift \
    && file_contains 'SearchResultsRoller' Sources/AnnoyO/MenuBarView.swift \
    && file_contains '返回播放列表' Sources/AnnoyO/MenuBarView.swift; then
    echo "PASS: main panel owns search while the right toolbar button opens settings"
else
    echo "FAILED: main search field, result roller, return action or settings icon is missing" >&2
    ui_shell_failed=1
fi
if (( ui_shell_failed )); then
    exit 1
fi

if file_contains 'registerRemoteCommand(commands.togglePlayPauseCommand)' Sources/AnnoyO/PlayerController.swift; then
    echo "PASS: media play/pause toggle command registration"
else
    echo "FAILED: media play/pause toggle command is not registered" >&2
    exit 1
fi

if file_contains '.onReceive(controller.playbackQueue.$currentID)' Sources/AnnoyO/MenuBarView.swift; then
    echo "FAILED: queue roller resubscribes to the current item during view refresh" >&2
    exit 1
else
    echo "PASS: queue roller recenters only when the current item actually changes"
fi

ui_contract_failed=0
if file_contains '.highPriorityGesture(scrubGesture' Sources/AnnoyO/MenuBarView.swift; then
    echo "FAILED: scrub gesture takes priority over current-row buttons" >&2
    ui_contract_failed=1
else
    echo "PASS: current-row buttons retain normal click priority"
fi

if file_contains 'seekAction: { controller.seekAndResume' Sources/AnnoyO/MenuBarView.swift; then
    echo "FAILED: scrub completion forces paused playback to resume" >&2
    ui_contract_failed=1
else
    echo "PASS: scrub completion preserves playback state"
fi
if (( ui_contract_failed )); then
    exit 1
fi

roaming_role_failed=0
if file_contains 'case roamingPrevious' Sources/AnnoyO/MenuBarView.swift \
    && file_contains '.help("替换成下一首")' Sources/AnnoyO/MenuBarView.swift \
    && file_contains 'case roamingNext' Sources/AnnoyO/MenuBarView.swift \
    && file_contains '.help("换一首推荐")' Sources/AnnoyO/MenuBarView.swift \
    && file_contains 'if role == .regular {' Sources/AnnoyO/MenuBarView.swift; then
    echo "PASS: roaming rows expose role-specific actions without delete controls"
else
    echo "FAILED: roaming previous, current and next rows do not enforce their action contracts" >&2
    roaming_role_failed=1
fi

if file_contains '? Array(0...6)' Sources/AnnoyO/RollerLoopLayout.swift \
    && file_contains 'recenterIfNeeded(clipView)' Sources/AnnoyO/MenuBarView.swift \
    && ! tree_contains 'boundaryWrapTarget' Sources/AnnoyO; then
    echo "PASS: sparse rollers use complete repeated cycles and distance-preserving recentering"
else
    echo "FAILED: queue roller still relies on a boundary jump or lacks complete sparse cycles" >&2
    roaming_role_failed=1
fi

if (( roaming_role_failed )); then
    exit 1
fi

mkdir -p .build/check-cache

SDKROOT="$sdk_path" \
CLANG_MODULE_CACHE_PATH="$repo_root/.build/check-cache" \
swiftc \
    -parse-as-library \
    -sdk "$sdk_path" \
    Sources/AnnoyO/Models.swift \
    Sources/AnnoyO/RollerLoopLayout.swift \
    Sources/AnnoyO/AudioReactiveLevel.swift \
    Sources/AnnoyO/AudioCache.swift \
    Sources/AnnoyO/PlaybackQueue.swift \
    Sources/AnnoyO/SavedPlaylistStore.swift \
    Sources/AnnoyO/WBISigner.swift \
    Sources/AnnoyO/BilibiliService.swift \
    Sources/AnnoyO/PlayerController.swift \
    Tests/AnnoyOChecks/MockBilibiliURLProtocol.swift \
    Tests/AnnoyOChecks/MockAudioRangeURLProtocol.swift \
    Tests/AnnoyOChecks/main.swift \
    -o .build/annoyo-checks

.build/annoyo-checks
