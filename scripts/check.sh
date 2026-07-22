#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
sdk_path="${ANNOYO_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"

cd "$repo_root"

ui_shell_failed=0
if rg -Fq 'Canvas {' Sources/AnnoyO/StatusBarIcon.swift; then
    echo "FAILED: menu bar label uses Canvas instead of a system-renderable image" >&2
    ui_shell_failed=1
else
    echo "PASS: menu bar label avoids Canvas rendering"
fi

account_hover_action_count="$(rg -F -c '.buttonStyle(AccountHoverHighlight' Sources/AnnoyO/AccountView.swift || true)"
if (( account_hover_action_count >= 4 )); then
    echo "PASS: account actions expose hover highlighting"
else
    echo "FAILED: expected hover highlighting on playlist, logout, cache and app quit actions" >&2
    ui_shell_failed=1
fi

if rg -Fq 'ForEach(player.savedPlaylists.playlists)' Sources/AnnoyO/AccountView.swift; then
    echo "FAILED: account popover still renders the saved-playlist browser" >&2
    ui_shell_failed=1
elif rg -Fq 'player.playbackQueue.savedPlaylistID' Sources/AnnoyO/AccountView.swift \
    && rg -Fq 'AccountActionRowLabel' Sources/AnnoyO/AccountView.swift; then
    echo "PASS: account deletion targets the currently browsed playlist with aligned action rows"
else
    echo "FAILED: account popover lacks a browsed-playlist delete action or shared row layout" >&2
    ui_shell_failed=1
fi

if rg -Fq 'struct SearchView' Sources/AnnoyO/MenuBarView.swift \
    || rg -Fq 'SearchView(' Sources/AnnoyO/AccountView.swift; then
    echo "FAILED: obsolete popover search implementation still exists" >&2
    ui_shell_failed=1
elif rg -Fq 'HeaderSearchField' Sources/AnnoyO/MenuBarView.swift \
    && rg -Fq 'Image(systemName: "gearshape")' Sources/AnnoyO/MenuBarView.swift \
    && rg -Fq 'SearchResultsRoller' Sources/AnnoyO/MenuBarView.swift \
    && rg -Fq '返回播放列表' Sources/AnnoyO/MenuBarView.swift; then
    echo "PASS: main panel owns search while the right toolbar button opens settings"
else
    echo "FAILED: main search field, result roller, return action or settings icon is missing" >&2
    ui_shell_failed=1
fi
if (( ui_shell_failed )); then
    exit 1
fi

if rg -q 'togglePlayPauseCommand\.addTarget' Sources/AnnoyO/PlayerController.swift; then
    echo "PASS: media play/pause toggle command registration"
else
    echo "FAILED: media play/pause toggle command is not registered" >&2
    exit 1
fi

if rg -Fq '.onReceive(controller.playbackQueue.$currentID)' Sources/AnnoyO/MenuBarView.swift; then
    echo "FAILED: queue roller resubscribes to the current item during view refresh" >&2
    exit 1
else
    echo "PASS: queue roller recenters only when the current item actually changes"
fi

ui_contract_failed=0
if rg -Fq '.highPriorityGesture(scrubGesture' Sources/AnnoyO/MenuBarView.swift; then
    echo "FAILED: scrub gesture takes priority over current-row buttons" >&2
    ui_contract_failed=1
else
    echo "PASS: current-row buttons retain normal click priority"
fi

if rg -Fq 'seekAction: { controller.seekAndResume' Sources/AnnoyO/MenuBarView.swift; then
    echo "FAILED: scrub completion forces paused playback to resume" >&2
    ui_contract_failed=1
else
    echo "PASS: scrub completion preserves playback state"
fi
if (( ui_contract_failed )); then
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
    Tests/AnnoyOChecks/main.swift \
    -o .build/annoyo-checks

.build/annoyo-checks
