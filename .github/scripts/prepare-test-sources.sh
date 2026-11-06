#!/bin/bash
# SPDX-License-Identifier: MIT
# Prepare the actual patched sources, not concatenated diff fragments.
set -euo pipefail
shopt -s nullglob
export LC_ALL=C

pin() {
  awk -F '"' -v key="$1" '$1 == key "=" {print $2; exit}' "$2"
}

# ffmpeg.org often refuses or resets connections from hosted runners, so every error is
# retried, and archives are kept in CB1_SOURCE_CACHE when a workflow caches them. A kept
# archive is used only while it matches its pinned checksum.
download() {
  local archive="$archive_root/${2##*/}"
  if ! printf '%s  %s\n' "$3" "$archive" | sha256sum --check --status 2>/dev/null; then
    curl --fail --silent --show-error --location --connect-timeout 30 \
      --retry 6 --retry-delay 20 --retry-all-errors "$1" --output "$archive"
  fi
  printf '%s  %s\n' "$3" "$archive" | sha256sum --check
  ln -s "$archive" "$2"
}

test_root=$(mktemp -d "${RUNNER_TEMP:?}/cb1-tests.XXXXXX")
archive_root=${CB1_SOURCE_CACHE:-$test_root/archives}
mkdir -p "$archive_root"
kodi_version=$(pin PKG_VERSION packages/mediacenter/kodi/package.mk)
ffmpeg_version=$(pin PKG_VERSION packages/multimedia/ffmpeg/package.mk)
placebo_recipe=packages/addons/addon-depends/multimedia-tools-depends/libplacebo/package.mk
placebo_version=$(pin PKG_VERSION "$placebo_recipe")
bluray_recipe=packages/multimedia/libbluray/package.mk
bluray_version=$(pin PKG_VERSION "$bluray_recipe")
test -n "$kodi_version" && test -n "$ffmpeg_version" && test -n "$placebo_version" && test -n "$bluray_version"
download "https://github.com/xbmc/xbmc/archive/$kodi_version.tar.gz" \
  "$test_root/kodi.tar.gz" "$(pin PKG_SHA256 packages/mediacenter/kodi/package.mk)"
download "https://ffmpeg.org/releases/ffmpeg-$ffmpeg_version.tar.xz" \
  "$test_root/ffmpeg.tar.xz" "$(pin PKG_SHA256 packages/multimedia/ffmpeg/package.mk)"
download "https://github.com/haasn/libplacebo/archive/$placebo_version.tar.gz" \
  "$test_root/libplacebo.tar.gz" "$(pin PKG_SHA256 "$placebo_recipe")"
download "https://download.videolan.org/pub/videolan/libbluray/$bluray_version/libbluray-$bluray_version.tar.xz" \
  "$test_root/libbluray.tar.xz" "$(pin PKG_SHA256 "$bluray_recipe")"

python3 scripts/cb1-stage.py
mkdir "$test_root/kodi" "$test_root/ffmpeg" "$test_root/libplacebo" "$test_root/libbluray"
tar -xf "$test_root/kodi.tar.gz" -C "$test_root/kodi" --strip-components=1
tar -xf "$test_root/ffmpeg.tar.xz" -C "$test_root/ffmpeg" --strip-components=1
tar -xf "$test_root/libplacebo.tar.gz" -C "$test_root/libplacebo" --strip-components=1
tar -xf "$test_root/libbluray.tar.xz" -C "$test_root/libbluray" --strip-components=1
for patch_file in packages/mediacenter/kodi/patches/*.patch projects/Generic/patches/kodi/*.patch \
                  projects/Generic/patches/kodi/x86/*.patch; do
  patch --batch --forward --fuzz=0 -p1 -d "$test_root/kodi" < "$patch_file"
done
for patch_file in packages/multimedia/ffmpeg/patches/postproc/*.patch \
                  packages/multimedia/ffmpeg/patches/libreelec/*.patch \
                  projects/Generic/patches/ffmpeg/*.patch; do
  patch --batch --forward --fuzz=0 -p1 -d "$test_root/ffmpeg" < "$patch_file"
done
for patch_file in CB1/patches/libplacebo/*.patch; do
  patch --batch --forward --fuzz=0 -p1 -d "$test_root/libplacebo" < "$patch_file"
done
python3 CB1/tools/verify.py --ffmpeg-source "$test_root/ffmpeg" \
  --libplacebo-source "$test_root/libplacebo"
# Generate the pinned public headers; these CPU probes do not need a GPU backend.
meson setup "$test_root/placebo-build" "$test_root/libplacebo" --wrap-mode=nofallback \
  -Ddemos=false -Dvulkan=disabled -Dopengl=disabled -Dd3d11=disabled \
  -Dglslang=disabled -Dshaderc=disabled -Dlcms=disabled -Dlibdovi=disabled \
  -Dunwind=disabled -Dxxhash=disabled
(
  cd "$test_root/ffmpeg"
  ./configure --prefix="$test_root/prefix" --disable-everything --disable-programs \
    --disable-doc --disable-network --disable-autodetect --disable-x86asm \
    --enable-gpl --enable-version3 --enable-shared --disable-static \
    --enable-filter=buffer,buffersink,hstack,settb --enable-decoder=hevc,pgssub \
    --enable-demuxer=mov,mpegts,matroska --enable-parser=hevc,ac3 --enable-protocol=file \
    --enable-bsf=hevc_mp4toannexb,dovi_split,extract_extradata
  make -j2
  make install
)
printf '%s\n' \
  "KODI_NATIVE_SOURCE_TREE=$test_root/kodi" \
  "KODI_UPSTREAM_ARCHIVE=$test_root/kodi.tar.gz" \
  "CB1_DRM_STATE_SOURCE=$test_root/kodi" \
  "FFMPEG_TEST_PREFIX=$test_root/prefix" \
  "FFMPEG_PGS_TEST_PREFIX=$test_root/prefix" \
  "LIBBLURAY_TEST_INCLUDE=$test_root/libbluray/src" \
  "CPATH=$test_root/libplacebo/src/include:$test_root/placebo-build/src/include" \
  "CB1_FMT_INCLUDE=/usr/include" \
  "FFMPEG_MATCHED_SOURCE=$test_root/ffmpeg" \
  "FFMPEG_SOURCE_ARCHIVE=$test_root/ffmpeg.tar.xz" \
  "LD_LIBRARY_PATH=$test_root/prefix/lib" >> "${GITHUB_ENV:?}"
