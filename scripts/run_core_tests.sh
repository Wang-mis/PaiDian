#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/HostModuleCache
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
sources=(PaiDian/Domain/*.swift PaiDian/Queue/*.swift PaiDian/Lyrics/*.swift PaiDian/Infrastructure/*.swift PaiDian/Persistence/*.swift PaiDian/Sources/*.swift PaiDian/Catalog/*.swift PaiDian/Search/*.swift PaiDian/Playback/AudioResourceLoader.swift PaiDian/Playback/AudioEngine.swift PaiDian/Playback/PlaybackCoordinator.swift PaiDianTests/TestSupport.swift PaiDianTests/CoreValidation.swift PaiDianTests/BundledSourceValidation.swift PaiDianTests/PlaybackValidation.swift PaiDianTests/QualityLyricsValidation.swift PaiDianTests/AudioCacheValidation.swift scripts/LiveValidation.swift scripts/HostTestMain.swift)
xcrun swiftc -swift-version 5 -D HOST_TESTS -sdk "$sdk_path" -module-cache-path build/HostModuleCache -o build/CoreValidation "${sources[@]}"
build/CoreValidation "$@"
