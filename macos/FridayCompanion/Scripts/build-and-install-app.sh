#!/bin/bash
# P2-PROD-BOOTSTRAP §B21 — the ONE development setup/install command.
# Builds FridayCompanion (release) and assembles a real, minimal
# FRIDAY.app bundle at ~/Applications/FRIDAY.app, ad-hoc signed, so that:
#   - SMAppService (login autostart, §B7) can register it — SMAppService
#     requires a real .app bundle, not a bare executable.
#   - the app can locate policyengined/capabilitybusd/friday-daemon via
#     Bundle.main.resourceURL, with NO environment variables required
#     (see AppDelegate.resolveBinaryConfiguration).
#
# P2-PROD-BOOTSTRAP-R2 §3 — the installed app is now SELF-CONTAINED for
# wake. Package.swift links the release binary with
# `-rpath @executable_path/../Resources/sherpa-onnx-lib` FIRST (before the
# absolute dev path), and this script (a) copies the vendored sherpa-onnx
# dylibs into `Contents/Resources/sherpa-onnx-lib/`, (b) unpacks the wake
# MODEL files directly into `Contents/Resources/sherpa-onnx-kws-model/`
# (see §3.2 below for why this is unpacked rather than the nested
# `.bundle` SwiftPM generates), and (c) verifies with `otool -l` that the
# bundled rpath wins. Result: the repository checkout may be moved,
# renamed, or absent and normal production operation is unaffected.
# (Developer `swift run` / `swift test` binaries under `.build/` still
# resolve via the absolute dev rpath / `Bundle.module`, which both fall
# through to the checkout because there is no sibling `Contents/Resources/`.)
#
# Usage:
#   ./Scripts/build-and-install-app.sh \
#       --policyengined /path/to/policyengined \
#       --capabilitybusd /path/to/capabilitybusd \
#       --friday-daemon /path/to/friday-daemon
#
# Or set FRIDAY_POLICYENGINED_PATH / FRIDAY_CAPABILITYBUSD_PATH /
# FRIDAY_DAEMON_PATH in the environment instead of passing flags.
#
# After this script succeeds once: quit any developer-mode FridayCompanion
# process, then launch ~/Applications/FRIDAY.app instead — Terminal is no
# longer needed for daily use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="FRIDAY.app"
INSTALL_ROOT="$HOME/Applications"
APP_PATH="$INSTALL_ROOT/$APP_NAME"

POLICY_BIN="${FRIDAY_POLICYENGINED_PATH:-}"
BUS_BIN="${FRIDAY_CAPABILITYBUSD_PATH:-}"
DAEMON_BIN="${FRIDAY_DAEMON_PATH:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policyengined) POLICY_BIN="$2"; shift 2 ;;
    --capabilitybusd) BUS_BIN="$2"; shift 2 ;;
    --friday-daemon) DAEMON_BIN="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Auto-resolve from the repository's own pre-built dev binaries
# (repo-root/.dev/bin/) when nothing was passed — the owner should not
# have to hand-type paths that this checkout already contains. Explicit
# flags / env vars always win over this fallback.
REPO_ROOT="$(cd "$PACKAGE_DIR/../.." && pwd)"
DEV_BIN_DIR="$REPO_ROOT/.dev/bin"
[[ -z "$POLICY_BIN"  && -x "$DEV_BIN_DIR/policyengined"   ]] && POLICY_BIN="$DEV_BIN_DIR/policyengined"
[[ -z "$BUS_BIN"     && -x "$DEV_BIN_DIR/capabilitybusd"  ]] && BUS_BIN="$DEV_BIN_DIR/capabilitybusd"
[[ -z "$DAEMON_BIN"  && -x "$DEV_BIN_DIR/friday-daemon"   ]] && DAEMON_BIN="$DEV_BIN_DIR/friday-daemon"
[[ -n "$POLICY_BIN" ]] && echo "Using policyengined:  $POLICY_BIN"
[[ -n "$BUS_BIN"    ]] && echo "Using capabilitybusd: $BUS_BIN"
[[ -n "$DAEMON_BIN" ]] && echo "Using friday-daemon:  $DAEMON_BIN"

fail_missing_binary() {
  local name="$1"
  echo "ERROR: $name binary path not provided." >&2
  echo "Pass --$name /path/to/$name, or set the corresponding FRIDAY_*_PATH env var." >&2
  echo "These are the SAME Go binaries developer mode already requires — this script" >&2
  echo "does not build them (no Go toolchain/source is assumed to be present)." >&2
  exit 1
}

[[ -n "$POLICY_BIN" ]] || fail_missing_binary "policyengined"
[[ -n "$BUS_BIN" ]] || fail_missing_binary "capabilitybusd"
[[ -n "$DAEMON_BIN" ]] || fail_missing_binary "friday-daemon"

for bin in "$POLICY_BIN" "$BUS_BIN" "$DAEMON_BIN"; do
  if [[ ! -x "$bin" ]]; then
    echo "ERROR: not an executable file: $bin" >&2
    exit 1
  fi
done

echo "=== FRIDAY install: building FridayCompanion (release) ==="
cd "$PACKAGE_DIR"
FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
swift build -c release --product FridayCompanion \
  -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" -Xlinker -rpath -Xlinker "$FW"

RELEASE_BINARY="$PACKAGE_DIR/.build/release/FridayCompanion"
if [[ ! -x "$RELEASE_BINARY" ]]; then
  echo "ERROR: release build did not produce $RELEASE_BINARY" >&2
  exit 1
fi

echo "=== Assembling $APP_PATH ==="
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$RELEASE_BINARY" "$APP_PATH/Contents/MacOS/FridayCompanion"
cp "$PACKAGE_DIR/Sources/FridayCompanion/Info.plist" "$APP_PATH/Contents/Info.plist"

cp "$POLICY_BIN" "$APP_PATH/Contents/Resources/policyengined"
cp "$BUS_BIN" "$APP_PATH/Contents/Resources/capabilitybusd"
cp "$DAEMON_BIN" "$APP_PATH/Contents/Resources/friday-daemon"
chmod +x "$APP_PATH/Contents/Resources/policyengined" "$APP_PATH/Contents/Resources/capabilitybusd" "$APP_PATH/Contents/Resources/friday-daemon"

# P2-PROD-BOOTSTRAP-R2 §3.2/§3.3 — the wake engine's vendored sherpa-onnx
# dylibs are now LOAD-BEARING inside the bundle: the release binary is
# linked with `-rpath @executable_path/../Resources/sherpa-onnx-lib`
# FIRST (see Package.swift), so the installed app resolves them from HERE,
# not from the development checkout. Fail closed if they are missing.
SHERPA_SRC="$PACKAGE_DIR/Vendor/sherpa-onnx/lib"
if [[ ! -f "$SHERPA_SRC/libsherpa-onnx-c-api.dylib" || ! -f "$SHERPA_SRC/libonnxruntime.dylib" ]]; then
  echo "ERROR: vendored sherpa-onnx dylibs not found under $SHERPA_SRC" >&2
  echo "The wake engine cannot run without them — refusing to produce a half-working bundle." >&2
  exit 1
fi
mkdir -p "$APP_PATH/Contents/Resources/sherpa-onnx-lib"
cp -R "$SHERPA_SRC/." "$APP_PATH/Contents/Resources/sherpa-onnx-lib/"

# P2-PROD-BOOTSTRAP-R2 §3.2 — the wake MODEL (encoder/decoder/joiner .onnx
# + tokens.txt) is an SPM resource bundle FridayCompanionKit vendors
# (Package.swift `resources: [.copy("Resources/sherpa-onnx-kws-model")]`),
# emitted at build time as `FridayCompanion_FridayCompanionKit.bundle`.
#
# TRIED AND REJECTED: copying that whole `.bundle` wrapper into the app
# (either at `Contents/Resources/` or the app's top level, which is where
# SwiftPM's generated `Bundle.module` accessor actually looks —
# `Bundle.main.bundleURL`, confirmed by reading
# `.build/.../DerivedSources/resource_bundle_accessor.swift`) — `codesign`
# REFUSED to seal it: "unsealed contents present in the bundle root".
#
# FIX: unpack just the model FILES straight into
# `Contents/Resources/sherpa-onnx-kws-model/` — plain files under
# Resources/, exactly like the dylibs/helper binaries already there, so
# codesign seals them normally. `SherpaOnnxWakeWordConfig.bundledDefault()`
# now checks `Bundle.main.resourceURL` for exactly this layout FIRST,
# falling back to `Bundle.module` only for `swift test`/`swift run` (no
# real .app wrapper).
KIT_BUNDLE="$PACKAGE_DIR/.build/release/FridayCompanion_FridayCompanionKit.bundle/sherpa-onnx-kws-model"
if [[ ! -d "$KIT_BUNDLE" ]]; then
  echo "ERROR: $KIT_BUNDLE not found after the release build — the wake model resource is missing." >&2
  exit 1
fi
rm -rf "$APP_PATH/Contents/Resources/sherpa-onnx-kws-model"
cp -R "$KIT_BUNDLE" "$APP_PATH/Contents/Resources/sherpa-onnx-kws-model"
if [[ ! -f "$APP_PATH/Contents/Resources/sherpa-onnx-kws-model/tokens.txt" ]]; then
  echo "ERROR: wake model files not present after copying." >&2
  exit 1
fi

echo "=== Ad-hoc code signing (local use only — no paid developer account needed) ==="
codesign --force --deep --sign - "$APP_PATH"

# P2-PROD-BOOTSTRAP-R2 §3.2 — actually inspect what shipped: confirm the
# @executable_path rpath is baked in and comes BEFORE any absolute dev
# path, so a moved/renamed/absent development checkout cannot break wake.
echo "=== Verifying self-contained runtime resolution ==="
RPATHS="$(otool -l "$APP_PATH/Contents/MacOS/FridayCompanion" | awk '/ cmd LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')"
echo "LC_RPATH entries (in dyld search order):"
echo "$RPATHS" | sed 's/^/  /'
BUNDLED_LINE="$(echo "$RPATHS" | grep -n '^@executable_path/\.\./Resources/sherpa-onnx-lib$' | head -1 | cut -d: -f1)"
ABS_LINE="$(echo "$RPATHS" | grep -n "^${SHERPA_SRC}\$" | head -1 | cut -d: -f1)"
if [[ -z "$BUNDLED_LINE" ]]; then
  echo "ERROR: '@executable_path/../Resources/sherpa-onnx-lib' rpath is missing — rebuild with the updated Package.swift." >&2
  exit 1
fi
if [[ -n "$ABS_LINE" && "$BUNDLED_LINE" -gt "$ABS_LINE" ]]; then
  echo "ERROR: the absolute dev rpath comes BEFORE the bundled one — the installed app would still prefer the checkout." >&2
  exit 1
fi
for dylib in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do
  [[ -f "$APP_PATH/Contents/Resources/sherpa-onnx-lib/$dylib" ]] || { echo "ERROR: bundled $dylib missing after signing." >&2; exit 1; }
done
echo "OK — wake dylibs + model resolve from inside the bundle; the development checkout is not required at runtime."

echo ""
echo "=== Done ==="
echo "Installed: $APP_PATH"
echo ""
echo "Next steps (see docs/phase2/P2-PROD-BOOTSTRAP-HARDWARE-ACCEPTANCE.md):"
echo "  1. Quit any developer-mode FridayCompanion process."
echo "  2. Launch $APP_PATH (double-click, or: open \"$APP_PATH\")."
echo "  3. Complete native setup (credentials, permissions, launch-at-login) in the window that appears."
echo "  4. The installed app is self-contained — the wake engine's sherpa-onnx dylibs and model"
echo "     now load from inside FRIDAY.app itself, so the repository checkout may be moved or"
echo "     renamed without breaking normal operation (P2-PROD-BOOTSTRAP-R2 §3)."
