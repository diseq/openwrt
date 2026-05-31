#!/usr/bin/env bash
set -euo pipefail

script_path="${BASH_SOURCE[0]}"
script_dir="${script_path%/*}"
if [[ "$script_dir" == "$script_path" ]]; then
  script_dir="."
fi
REPO_ROOT="$(cd "$script_dir/.." && pwd -P)"

CUSTOM_FEED_NAME="${CUSTOM_FEED_NAME:-fluentbit}"
CUSTOM_FEED_DIR="${CUSTOM_FEED_DIR:-${REPO_ROOT}/openwrt-feed}"

if [[ ! -d "$CUSTOM_FEED_DIR" ]]; then
  echo "error: custom feed dir not found: $CUSTOM_FEED_DIR" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
Usage:
  scripts/build-openwrt.sh --board <target/subtarget> [--openwrt-version <X.Y.Z>] [--arch <openwrt-arch>] [--out <dir>] [--work <dir>]

Examples:
  scripts/build-openwrt.sh --board x86/64
  scripts/build-openwrt.sh --board ipq806x/generic

Notes:
  - Downloads the prebuilt OpenWrt SDK for the chosen board/version.
  - Builds fluent-bit from ./openwrt-feed, overriding OpenWrt's packages feed.
  - Produces a self-contained repository directory under --out.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command '$1' in PATH"
}

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.3}"
OPENWRT_BASE_URL="${OPENWRT_BASE_URL:-https://archive.openwrt.org/releases}"

BOARD=""
ARCH=""
OUT_DIR=""
WORK_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --board)
      BOARD="${2:-}"; shift 2 ;;
    --openwrt-version)
      OPENWRT_VERSION="${2:-}"; shift 2 ;;
    --arch)
      ARCH="${2:-}"; shift 2 ;;
    --out)
      OUT_DIR="${2:-}"; shift 2 ;;
    --work)
      WORK_DIR="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown arg: $1" ;;
  esac
done

[[ -n "$BOARD" ]] || { usage; die "--board is required"; }


TARGET="${BOARD%%/*}"
SUBTARGET="${BOARD#*/}"
[[ -n "$TARGET" && -n "$SUBTARGET" && "$TARGET" != "$SUBTARGET" ]] || die "--board must be like <target/subtarget> (got '$BOARD')"

sdk_filename=""
arch_default=""

# Keep this mapping explicit and pinned: it is the contract the pipeline depends on.
case "$BOARD" in
  x86/64)
    sdk_filename="openwrt-sdk-${OPENWRT_VERSION}-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
    arch_default="x86_64"
    ;;
  ipq806x/generic)
    sdk_filename="openwrt-sdk-${OPENWRT_VERSION}-ipq806x-generic_gcc-14.3.0_musl_eabi.Linux-x86_64.tar.zst"
    arch_default="arm_cortex-a15_neon-vfpv4"
    ;;
  *)
    die "Unsupported board '$BOARD' (supported: x86/64, ipq806x/generic)" ;;
 esac

need_cmd tar
need_cmd zstd
need_cmd sha256sum
need_cmd make
need_cmd perl
need_cmd python3
need_cmd git
need_cmd rsync
need_cmd xz
need_cmd wget
need_cmd openssl

if [[ -z "$ARCH" ]]; then
  ARCH="$arch_default"
fi

if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(pwd)/.work/openwrt-${OPENWRT_VERSION}/${BOARD}"
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$(pwd)/dist/openwrt-${OPENWRT_VERSION}/${BOARD}"
fi

mkdir -p "$WORK_DIR" "$OUT_DIR"

sdk_url="${OPENWRT_BASE_URL}/${OPENWRT_VERSION}/targets/${TARGET}/${SUBTARGET}/${sdk_filename}"
sdk_sha_url="${OPENWRT_BASE_URL}/${OPENWRT_VERSION}/targets/${TARGET}/${SUBTARGET}/sha256sums"

sdk_archive="${WORK_DIR}/${sdk_filename}"

if [[ ! -f "$sdk_archive" ]]; then
  echo "Downloading SDK: ${sdk_url}"
  wget -q -O "$sdk_archive" "$sdk_url"
fi

# Verify against published sha256sums.
# We avoid host-specific tools (awk/grep/head) and parse with python for robustness.
sha_line="$(SDK_SHA_URL="$sdk_sha_url" SDK_FILENAME="$sdk_filename" ${PYTHON:-python3} - <<'PY'
import os
import sys
import urllib.request

sdk_sha_url = os.environ['SDK_SHA_URL']
sdk_filename = os.environ['SDK_FILENAME']

with urllib.request.urlopen(sdk_sha_url) as r:
    for raw in r:
        line = raw.decode('utf-8', errors='replace').strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        if len(parts) != 2:
            continue
        sha, name = parts
        if name == f"*{sdk_filename}":
            sys.stdout.write(sha)
            sys.exit(0)

sys.exit(2)
PY
)"

[[ -n "$sha_line" ]] || die "Failed to locate sha256 for ${sdk_filename} in ${sdk_sha_url}"

echo "${sha_line}  ${sdk_archive}" | sha256sum -c - >/dev/null

sdk_root="${WORK_DIR}/sdk"
mkdir -p "$sdk_root"

# SDK tarball contains a single top-level directory. Reuse an existing
# extraction so interrupted local runs can resume already-built dependencies.
shopt -s nullglob
sdk_candidates=("$sdk_root"/*)
shopt -u nullglob

if [[ ${#sdk_candidates[@]} -eq 0 ]]; then
  zstd -d --stdout "$sdk_archive" | tar -C "$sdk_root" -xf -
  shopt -s nullglob
  sdk_candidates=("$sdk_root"/*)
  shopt -u nullglob
fi

[[ ${#sdk_candidates[@]} -eq 1 && -d "${sdk_candidates[0]}" ]] || die "SDK extraction did not produce exactly one top-level directory"
sdk_dir="${sdk_candidates[0]}"

pushd "$sdk_dir" >/dev/null
# If a persistent APK signing key is provided, install it before package/index
# so all target repositories are signed by the same trust root. Without this,
# the OpenWrt SDK generates a fresh per-workdir key, which is acceptable for
# throwaway local testing but unsuitable for a published feed.
if [[ -n "${OPENWRT_APK_PRIVATE_KEY_PEM:-}" ]]; then
  printf '%s\n' "${OPENWRT_APK_PRIVATE_KEY_PEM}" > private-key.pem
  chmod 0600 private-key.pem
  openssl ec -in private-key.pem -pubout > public-key.pem
fi


# Add our custom feed first so it overrides any same-named packages from default feeds.
custom_line="src-link ${CUSTOM_FEED_NAME} ${CUSTOM_FEED_DIR}"

if [[ -f feeds.conf.default ]]; then
  # Only add once.
  if ! grep -qxF "$custom_line" feeds.conf.default; then
    tmp_conf="$(mktemp)"
    printf '%s\n' "$custom_line" >"$tmp_conf"
    cat feeds.conf.default >>"$tmp_conf"
    mv "$tmp_conf" feeds.conf.default
  fi
else
  printf '%s\n' "$custom_line" > feeds.conf.default
fi

make_args=()
if [[ -n "${OPENWRT_MAKE_VERBOSE:-}" ]]; then
  make_args+=("V=${OPENWRT_MAKE_VERBOSE}")
fi

# Keep builds reasonably deterministic.
export LC_ALL=C
export TZ=UTC

# Ensure only the feeds needed for fluent-bit are present. Updating every SDK
# feed clones luci/routing/telephony/video and can dominate runtime before the
# package build even starts. The base feed is still required for core libraries
# such as openssl, ca-bundle, and related dependency metadata.
./scripts/feeds update "${CUSTOM_FEED_NAME}" base packages

# Install our package definition. The feeds script resolves dependent package
# definitions from the updated packages feed as needed; installing the entire
# packages feed is unnecessary and very slow.
./scripts/feeds install -f -p "${CUSTOM_FEED_NAME}" fluent-bit

# Build only the package requested here. The released SDK config is a buildbot
# config and may select every target module as =m; invoking a broad package
# target would then build unrelated kernel modules. Keep .config to the package
# we need and invoke the exact feed path.
cat > .config <<EOF
CONFIG_TARGET_${TARGET}=y
CONFIG_TARGET_${TARGET}_${SUBTARGET}=y
# CONFIG_ALL is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_ALL_NONSHARED is not set
CONFIG_PACKAGE_fluent-bit=m
# CONFIG_OPENSSL_ENGINE is not set
# CONFIG_OPENSSL_WITH_COMPRESSION is not set
EOF

make defconfig "${make_args[@]}"

package_path="package/feeds/${CUSTOM_FEED_NAME}/fluent-bit"
[[ -d "$package_path" ]] || die "Expected installed package path missing: ${package_path}"

make "${package_path}/clean" "${make_args[@]}"
make "${package_path}/compile" -j"$(nproc)" "${make_args[@]}"

# Build repository metadata for the produced packages.
make package/index "${make_args[@]}"

popd >/dev/null

# Collect only the custom feed for hosting. Dependencies are resolved from the
# normal OpenWrt repositories already configured on the device; republishing
# base/packages feed artifacts here makes the custom feed larger and harder to
# reason about.
repo_src="${sdk_dir}/bin/packages/${ARCH}/${CUSTOM_FEED_NAME}"
[[ -d "$repo_src" ]] || die "Expected custom feed output directory missing: ${repo_src}"

rm -rf "$OUT_DIR/packages"
mkdir -p "$OUT_DIR/packages/${CUSTOM_FEED_NAME}"
rsync -a --delete "$repo_src/" "$OUT_DIR/packages/${CUSTOM_FEED_NAME}/"
if [[ -f "${sdk_dir}/public-key.pem" ]]; then
  cp "${sdk_dir}/public-key.pem" "$OUT_DIR/public-key.pem"
  cp "${sdk_dir}/public-key.pem" "$OUT_DIR/packages/${CUSTOM_FEED_NAME}/public-key.pem"
fi


# Convenience metadata.
cat >"$OUT_DIR/BUILDINFO.txt" <<EOF
OPENWRT_VERSION=${OPENWRT_VERSION}
BOARD=${BOARD}
ARCH=${ARCH}
SDK_URL=${sdk_url}
EOF

echo "Wrote repository to: $OUT_DIR"
