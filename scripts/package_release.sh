#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
release_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' PaiDian/Info.plist)
release_root="$PWD/build/Release"
mkdir -p "$release_root"
xcodebuild -project PaiDian.xcodeproj -scheme PaiDian -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$release_root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
release_app="$release_root/DerivedData/Build/Products/Release-iphoneos/PaiDian.app"
[[ ! -e "$release_app/embedded.mobileprovision" && ! -e "$release_app/_CodeSignature" ]] || {
    print -u2 'Refusing to publish a signed application'; exit 1
}
if codesign --display "$release_app" >/dev/null 2>&1; then
    print -u2 'Refusing to publish an application with a code signature'; exit 1
fi
package_root=$(mktemp -d "$release_root/package.XXXXXX")
trap 'rm -rf "$package_root"' EXIT
mkdir "$package_root/Payload"
ditto "$release_app" "$package_root/Payload/PaiDian.app"
release_ipa="$release_root/PaiDian-v${release_version}-unsigned.ipa"
[[ ! -e "$release_ipa" ]] || rm "$release_ipa"
(cd "$package_root" && /usr/bin/zip -qry "$release_ipa" Payload)
(cd "$release_root" && shasum -a 256 "${release_ipa:t}" > SHA256SUMS.txt)
print "Unsigned release: $release_ipa"
