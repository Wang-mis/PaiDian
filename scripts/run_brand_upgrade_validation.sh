#!/bin/zsh
# Usage: zsh scripts/run_brand_upgrade_validation.sh path/to/old/AnyListen
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
legacy_sources="${1:?Supply the pre-rename AnyListen source directory}"
legacy_sources="${legacy_sources:A}"
[[ -f "$legacy_sources/Persistence/MusicStore.swift" ]] || { print -u2 'Missing old persistence sources'; exit 1; }
mkdir -p build/HostModuleCache
scratch=$(mktemp -d /private/tmp/paidian-upgrade.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
compile_module() {
    local module_name="$1" source_root="$2" executable="$3"
    local sources=("$source_root"/Domain/*.swift "$source_root"/Queue/*.swift
        "$source_root"/Lyrics/*.swift "$source_root"/Infrastructure/*.swift
        "$source_root"/Persistence/*.swift "$source_root"/Sources/*.swift
        "$source_root"/Catalog/*.swift "$source_root"/Search/*.swift
        "$source_root"/Playback/AudioResourceLoader.swift "$source_root"/Playback/AudioEngine.swift
        "$source_root"/Playback/PlaybackCoordinator.swift scripts/BrandUpgradeValidation.swift)
    xcrun swiftc -swift-version 5 -D HOST_TESTS -module-name "$module_name" \
        -module-cache-path build/HostModuleCache -o "$executable" "${sources[@]}"
}
compile_module AnyListen "$legacy_sources" "$scratch/old-module"
"$scratch/old-module" seed "$scratch/fixture"
compile_module PaiDian "$PWD/PaiDian" "$scratch/new-module"
"$scratch/new-module" verify "$scratch/fixture"
