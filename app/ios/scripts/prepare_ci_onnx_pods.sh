#!/usr/bin/env bash
set -euo pipefail

version="$(sed -nE 's/^onnxruntime = "([^"]+)"$/\1/p' gradle/libs.versions.toml)"
upstream=https://download.onnxruntime.ai
if curl -fsIL --max-time 15 "$upstream/pod-archive-onnxruntime-c-$version.zip" >/dev/null &&
   curl -fsIL --max-time 15 "$upstream/pod-archive-onnxruntime-objc-$version.zip" >/dev/null; then
    exit 0
fi

if [[ "$version" != 1.22.0 ]]; then
    echo "No alternate ONNX Runtime CocoaPods source is configured for $version." >&2
    exit 1
fi

# The NuGet release contains the iOS XCFramework and identifies the exact source commit.
nupkg_sha256=d571e63a2329baacb713f441e65ad75284de354db6e1ac435fe4bebbb417986a
source_revision=f217402897f40ebba457e2421bc0a4702771968e
work="$(mktemp -d "$RUNNER_TEMP/animeko-onnx-pods.XXXXXXXX")"
spec_repo="$work/specs"
download() {
    curl --fail --silent --show-error --location --retry 3 --proto '=https' --proto-redir '=https' "$@"
}

nupkg="$work/onnxruntime.nupkg"
download --output "$nupkg" \
    "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/$version/microsoft.ml.onnxruntime.$version.nupkg"
printf '%s  %s\n' "$nupkg_sha256" "$nupkg" | shasum -a 256 -c -
unzip -p "$nupkg" runtimes/ios/native/onnxruntime.xcframework.zip > "$work/xcframework.zip"
mkdir "$work/c"
unzip -q "$work/xcframework.zip" -d "$work/c"
unzip -p "$nupkg" LICENSE > "$work/c/LICENSE"
unzip -p "$nupkg" ThirdPartyNotices.txt > "$work/c/ThirdPartyNotices.txt"
cp -R "$work/c/onnxruntime.xcframework/ios-arm64/onnxruntime.framework/Headers" "$work/c/Headers"
(cd "$work/c" && zip -qry "$work/onnxruntime-c.zip" .)

git init --quiet "$work/source"
git -C "$work/source" -c fetch.fsckObjects=true fetch --quiet --depth=1 \
    https://github.com/Arm-China/Compass_Onnxruntime.git "$source_revision"
test "$(git -C "$work/source" rev-parse FETCH_HEAD)" = "$source_revision"
git -C "$work/source" archive --format=zip --output="$work/onnxruntime-objc.zip" FETCH_HEAD LICENSE objectivec

for kind in c objc; do
    pod_name="onnxruntime-$kind"
    case "$kind" in
        c) cdn_prefix=3/a/a ;;
        objc) cdn_prefix=8/2/b ;;
    esac
    spec_dir="$spec_repo/Specs/$pod_name/$version"
    mkdir -p "$spec_dir"
    spec="$spec_dir/$pod_name.podspec.json"
    download --output "$spec" \
        "https://cdn.cocoapods.org/Specs/$cdn_prefix/$pod_name/$version/$pod_name.podspec.json"
    ruby -rjson -ruri -rdigest -e '
      spec_path, archive, name, version = ARGV
      spec = JSON.parse(File.read(spec_path))
      abort "Unexpected podspec: #{spec_path}" unless spec["name"] == name && spec["version"] == version
      spec["source"] = {
        "http" => URI::DEFAULT_PARSER.escape("file://#{archive}"),
        "sha256" => Digest::SHA256.file(archive).hexdigest
      }
      File.write(spec_path, JSON.pretty_generate(spec))
    ' "$spec" "$work/$pod_name.zip" "$pod_name" "$version"
done

git init --quiet "$spec_repo"
git -C "$spec_repo" add Specs
git -C "$spec_repo" -c user.name=Animeko -c user.email=ci@animeko.invalid \
    -c commit.gpgsign=false commit --quiet -m "ONNX Runtime $version iOS podspecs"
printf 'ANIMEKO_IOS_ONNX_SPEC_REPO=file://%s\n' "$spec_repo" >> "$GITHUB_ENV"
