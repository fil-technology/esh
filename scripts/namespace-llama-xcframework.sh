#!/usr/bin/env bash
# esh v2.4.0-rc.4 — make esh's llama.cpp artifact coexistence-safe.
#
# Transforms an upstream-built llama.cpp xcframework (framework "llama", Clang module "llama", install name
# @rpath/llama.framework/...) into an esh-private "esh_llama" xcframework. This lets EshLlamaCpp be linked
# into the same app as another llama.cpp consumer (e.g. LLM.swift, which ships its own llama.framework/llama)
# without "Multiple commands produce llama.framework", module redefinition, or dyld install-name clashes.
#
# Why renaming is sufficient (no native symbol prefixing): the artifact is a SELF-CONTAINED DYNAMIC framework
# (a single dylib that bundles llama + ggml + gguf, Metal embedded, depends only on system frameworks). On
# Apple, dynamic frameworks use a two-level namespace: an app that links two DISTINCTLY NAMED dynamic
# frameworks binds each caller to its own framework's symbols, so duplicate llama_*/ggml_* symbol NAMES across
# the two frameworks do NOT produce duplicate-symbol link errors, and each dylib keeps its own ggml globals at
# runtime. Static libraries would require symbol prefixing; this dynamic framework does not. (See RC4 report.)
#
# Pure post-build transform (rename + install_name_tool + modulemap + Info.plist ids + ad-hoc re-sign);
# deterministic; same upstream bits. Usage:
#   namespace-llama-xcframework.sh <in .../llama.xcframework> <out .../esh_llama.xcframework>
set -euo pipefail

IN="${1:?usage: namespace-llama-xcframework.sh <in llama.xcframework> <out esh_llama.xcframework>}"
OUT="${2:?usage: namespace-llama-xcframework.sh <in llama.xcframework> <out esh_llama.xcframework>}"

OLD=llama
NEW=esh_llama
# CFBundleIdentifier allows only alphanumerics, '-' and '.' (NO underscore — Xcode's app embed phase rejects
# it: "invalid CFBundleIdentifier"). The framework bundle name and Clang module keep the underscore (valid
# there); only the identifier is hyphenated.
BUNDLE_ID="technology.fil.esh.esh-llama"

[ -f "$IN/Info.plist" ] || { echo "error: $IN is not an xcframework (no Info.plist)"; exit 1; }

rm -rf "$OUT"
cp -R "$IN" "$OUT"
# Drop AppleDouble sidecars that appear on non-APFS volumes (would break signing/globs).
find "$OUT" -name '._*' -delete 2>/dev/null || true

write_modulemap() {
  cat > "$1" <<MODMAP
framework module ${NEW} {
    header "llama.h"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"
    export *
}
MODMAP
}

for fwdir in "$OUT"/*/"${OLD}.framework"; do
  [ -d "$fwdir" ] || continue
  slice="$(dirname "$fwdir")"
  newfw="$slice/${NEW}.framework"
  mv "$fwdir" "$newfw"

  if [ -d "$newfw/Versions" ]; then
    # macOS: versioned bundle with symlinks.
    mv "$newfw/Versions/A/$OLD" "$newfw/Versions/A/$NEW"
    rm -f "$newfw/$OLD"
    ln -s "Versions/Current/$NEW" "$newfw/$NEW"
    bin="$newfw/Versions/A/$NEW"
    plist="$newfw/Versions/A/Resources/Info.plist"
    modmap="$newfw/Versions/A/Modules/module.modulemap"
    install_name_tool -id "@rpath/${NEW}.framework/Versions/Current/${NEW}" "$bin"
  else
    # iOS device / simulator: flat bundle.
    mv "$newfw/$OLD" "$newfw/$NEW"
    bin="$newfw/$NEW"
    plist="$newfw/Info.plist"
    modmap="$newfw/Modules/module.modulemap"
    install_name_tool -id "@rpath/${NEW}.framework/${NEW}" "$bin"
  fi

  write_modulemap "$modmap"

  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${NEW}" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName ${NEW}" "$plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${NEW}" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$plist"

  # install_name_tool invalidated the ad-hoc signature; re-seal the whole bundle. Strip extended attributes,
  # stale seals, and AppleDouble sidecars first — they appear when the source artifact was built/stored on a
  # non-APFS volume and make codesign choke with "In subcomponent ._<name>". Order matters: clear xattrs and
  # remove old seals, THEN delete any ._* those steps materialised, THEN sign (no --remove-signature: --force
  # overwrites, and --remove-signature can itself re-create a top-level ._<name> on a symlinked bundle).
  xattr -cr "$newfw" 2>/dev/null || true
  rm -rf "$newfw/Versions/A/_CodeSignature" "$newfw/_CodeSignature" 2>/dev/null || true
  find "$newfw" -name '._*' -delete 2>/dev/null || true
  codesign --force --sign - "$newfw"
done

# Drop the bundled dSYMs. Upstream ships per-slice dSYMs named after the binary (llama.dSYM); Xcode copies
# them next to the app's build products, so a second llama.cpp consumer (LLM.swift, also shipping/producing
# llama.dSYM) triggers "Multiple commands produce llama.dSYM". Renaming them would work, but dropping is
# leaner (removes ~3x the artifact size) and safe: Xcode still generates esh_llama.dSYM from the embedded
# framework binary at app-build time, and dSYMs are never embedded in the shipped .app so app size is
# unchanged. Consumers who need llama.cpp symbolication can rebuild from source via build-llama-xcframework.sh.
# Remove the dSYM directories and the DebugSymbolsPath entries that point at them.
rm -rf "$OUT"/*/dSYMs
i=0
while /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:${i}:LibraryIdentifier" "$OUT/Info.plist" >/dev/null 2>&1; do
  /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:${i}:DebugSymbolsPath" "$OUT/Info.plist" 2>/dev/null || true
  i=$((i+1))
done

# xcframework top-level Info.plist: point Library/Binary paths at the renamed framework/binary.
# Order matters — rewrite the longer (binary) paths before the bare framework path.
/usr/bin/sed -i '' \
  -e "s#${OLD}\.framework/Versions/A/${OLD}#${NEW}.framework/Versions/A/${NEW}#g" \
  -e "s#${OLD}\.framework/${OLD}#${NEW}.framework/${NEW}#g" \
  -e "s#>${OLD}\.framework<#>${NEW}.framework<#g" \
  "$OUT/Info.plist"

echo "Namespaced $IN -> $OUT (framework=${NEW}.framework, module=${NEW}, id=${BUNDLE_ID})"
