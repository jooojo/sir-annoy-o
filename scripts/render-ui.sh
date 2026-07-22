#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
sdk_path="${ANNOYO_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"

cd "$repo_root"
mkdir -p .build/visual-cache Artifacts

SDKROOT="$sdk_path" \
CLANG_MODULE_CACHE_PATH="$repo_root/.build/visual-cache" \
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
    Sources/AnnoyO/StatusBarIcon.swift \
    Sources/AnnoyO/MenuBarView.swift \
    Sources/AnnoyO/AccountView.swift \
    Tests/AnnoyOVisualChecks/main.swift \
    -o .build/annoyo-visual-checks

.build/annoyo-visual-checks
