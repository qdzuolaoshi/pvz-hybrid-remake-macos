#!/bin/zsh
# Build a native macOS (Apple Silicon) app from the Windows release of "植物大战僵尸杂交重制版" (Godot 4.7 .NET).
# The game's managed C# assemblies are reused unchanged; the Windows engine binary and the Windows .NET runtime are
# replaced with the official macOS ones. The app gets a patched copy of the game's .pck (the user's pck is only read):
# one shader fix, two small GDScript add-ons and an override.cfg are appended by hybrid_mac/pck_patch.py (see
# "Game data" below).
#
# usage: ./build_hybrid_app.sh <game_dir> <template_app> <dotnet_runtime_dir> <out_dir> [--install]
#   game_dir            extracted Windows game folder (contains *.pck and data_PlantsVsZombies_windows_x86_64/)
#   template_app        macos_template.app from Godot_v4.7-stable_mono_export_templates.tpz (templates/macos.zip)
#                       https://github.com/godotengine/godot-builds/releases/download/4.7-stable/ (SHA512-SUMS.txt)
#   dotnet_runtime_dir  extracted dotnet-runtime-9.0.22-osx-arm64.tar.gz
#                       https://builds.dotnet.microsoft.com/dotnet/Runtime/9.0.22/dotnet-runtime-9.0.22-osx-arm64.tar.gz
#   out_dir             where 植物大战僵尸杂交版.app is written (updated in place)
#
# Bundle layout: Contents/MacOS/PvZHybrid is a small launcher (hybrid_mac/launcher.c) that execv()s the Godot engine
# Contents/MacOS/PvZHybrid.bin with DYLD_INSERT_LIBRARIES=Contents/Frameworks/libPvzHybridMac.dylib and the arguments
# unchanged (the engine finds Contents/Resources/PvZHybrid.pck by its base name; release templates reject --main-pack).
# The library (hybrid_mac/PvzHybridMac.m) locks the windowed aspect ratio and holds the PVZH_TEST_SCRIPT test driver,
# which is inactive unless that variable is set. res://override.cfg in the app's pack (hybrid_mac/override.cfg) registers
# the add-on autoloads and turns vsync on.
#
# Environment: ICONPNG (optional icon source); PVZH_SHADER_FIX=0 skips the character-shader fix (only for a future game
# version whose shader no longer needs it; the build otherwise stops when the shader is not the known 0.31 one).
set -euo pipefail
GAME=$1; TPL=$2; RT=$3; OUT=$4; INSTALL=0
[[ "${5:-}" == "--install" ]] && INSTALL=1

NAME="植物大战僵尸杂交版"
BIN="PvZHybrid"
BUNDLE_ID="local.pvzmac.hybrid030"           # kept from the first (0.30) build so macOS sees the same app
ASM="PlantsVsZombies"                      # dotnet/project/assembly_name in project.binary
NETVER="9.0.22"
WINDATA="$GAME/data_${ASM}_windows_x86_64"
PCK=$(ls "$GAME"/*.pck | head -1)
ICONPNG=${ICONPNG:-}                       # 256x256 PNG extracted from the pack's icon.png (optional)
PVZH_SHADER_FIX=${PVZH_SHADER_FIX:-1}
# Game version from the pack name, e.g. 植物大战僵尸杂交版发布版0.31.0.Csharp.pck -> 0.31.0
VERSION=$(print -r -- "${PCK:t}" | grep -oE '[0-9]+(\.[0-9]+){2}' | head -1 || true)
[[ -n "$VERSION" ]] || VERSION="0.0.0"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pvzhybrid.XXXXXX")
APP="$WORK/$NAME.app"
ditto "$TPL" "$APP"

# Engine: the official release template, thinned to arm64. It runs as <binary>.bin behind the launcher below.
lipo -thin arm64 "$APP/Contents/MacOS/godot_macos_release.universal" -output "$APP/Contents/MacOS/$BIN.bin"
rm -f "$APP/Contents/MacOS/godot_macos_release.universal" "$APP/Contents/MacOS/godot_macos_debug.universal"
chmod +x "$APP/Contents/MacOS/$BIN.bin"

# Launcher (CFBundleExecutable) and the in-process helper library.
HM="${0:A:h}/hybrid_mac"
mkdir -p "$APP/Contents/Frameworks"
clang -arch arm64 -mmacosx-version-min=11.0 -O2 -Wall -o "$APP/Contents/MacOS/$BIN" "$HM/launcher.c"
clang -arch arm64 -mmacosx-version-min=11.0 -O2 -Wall -fobjc-arc -dynamiclib -framework AppKit -framework QuartzCore \
  -install_name @rpath/libPvzHybridMac.dylib -o "$APP/Contents/Frameworks/libPvzHybridMac.dylib" "$HM/PvzHybridMac.m"

# Game data: the Windows .pck is platform independent; Godot loads <binary>.pck from Contents/Resources.
# The app's copy is patched by hybrid_mac/pck_patch.py: the original bytes are copied unchanged, the new files and a new
# directory are appended, and the header's directory offset is updated (about 3.6 MB more, mostly the new
# directory; nothing is re-encoded).
#  - addons/AdobeAnimateEditor/Rendering/AdobeAnimateManagedMultiMesh.gdshader: the character renderer's layer-mask
#    decoding rewritten with integer ops (hybrid_mac/shader_intmask.py). On Apple GPUs the
#    original float decoding hides visible body parts (normal zombie's tie and outer arm, parts of other characters).
#  - MacPort/ui_sfx_patch.gd: plays the game's own ButtonPress / GraveButtonPress entries (identical to the original
#    PvZ buttonclick.ogg / gravebutton.ogg) on buttons the game data leaves silent on every platform.
#  - MacPort/packet_name_tooltip.gd: plant-name tooltip under a hovered seed packet (not in the 0.31 remake).
#  - override.cfg: project-setting overrides (the two autoloads above, vsync on). Godot reads res://override.cfg and
#    then <binary dir>/override.cfg; keeping it in the pack keeps Contents/MacOS code-only, so the bundle passes
#    `codesign --verify --deep --strict`. A test copy can still add Contents/MacOS/override.cfg on top.
SHADER="addons/AdobeAnimateEditor/Rendering/AdobeAnimateManagedMultiMesh.gdshader"
SHADER_MD5="4e4ed18d3e1dbd210923a685ed3c8f22"          # original in 0.31 and 0.32, 43677 bytes
SHADER_FIXED_MD5="036826df28b26760ccf57f686c5e0320"
PCKARGS=(--add "MacPort/ui_sfx_patch.gd=$HM/ui_sfx_patch.gd"
         --add "MacPort/packet_name_tooltip.gd=$HM/packet_name_tooltip.gd"
         --add "override.cfg=$HM/override.cfg")
if [[ "$PVZH_SHADER_FIX" != 0 ]]; then
  python3 -I "$HM/pck_patch.py" extract "$PCK" "$SHADER" "$WORK/shader.gdshader"
  if [[ $(md5 -q "$WORK/shader.gdshader") != "$SHADER_MD5" ]]; then
    echo "error: $SHADER in this pack is not the known 0.31 version. Check whether the layer-mask fix" >&2
    echo "       (hybrid_mac/shader_intmask.py) is still needed and update it," >&2
    echo "       or build with PVZH_SHADER_FIX=0." >&2
    exit 1
  fi
  python3 -I "$HM/shader_intmask.py" "$WORK/shader.gdshader" "$WORK/shader.fixed.gdshader"
  [[ $(md5 -q "$WORK/shader.fixed.gdshader") == "$SHADER_FIXED_MD5" ]] || { echo "error: shader patch result differs" >&2; exit 1; }
  PCKARGS=(--expect "$SHADER=$SHADER_MD5" --replace "$SHADER=$WORK/shader.fixed.gdshader" "${PCKARGS[@]}")
else
  echo "warning: PVZH_SHADER_FIX=0, character shader left unpatched" >&2
fi
python3 -I "$HM/pck_patch.py" patch "$PCK" "$APP/Contents/Resources/$BIN.pck" "${PCKARGS[@]}"

# .NET: Godot looks for data_<assembly>_<platform>_<arch> next to the pack. Self-contained osx-arm64 runtime plus the
# game's managed assemblies (IL, platform independent). Windows-native runtime files and the win-x64 framework
# assemblies are left out; deps.json is retargeted to osx-arm64 below.
DATA="$APP/Contents/Resources/data_${ASM}_macos_arm64"
mkdir -p "$DATA"
ditto "$RT/shared/Microsoft.NETCore.App/$NETVER" "$DATA"
cp "$RT/host/fxr/$NETVER/libhostfxr.dylib" "$DATA/"
python3 -I - "$WINDATA" "$DATA" <<'EOF'
import os, sys, shutil, struct
src, dst = sys.argv[1], sys.argv[2]
def is_managed(path):
    try:
        with open(path, 'rb') as f:
            d = f.read(4096)
        if d[:2] != b'MZ': return False
        pe = struct.unpack('<I', d[0x3c:0x40])[0]
        magic = struct.unpack('<H', d[pe+24:pe+26])[0]
        dd = pe + 24 + (96 if magic == 0x10b else 112)
        clr_rva = struct.unpack('<I', d[dd+14*8:dd+14*8+4])[0]
        return clr_rva != 0
    except Exception:
        return False
copied = 0
for root, dirs, files in os.walk(src):
    rel = os.path.relpath(root, src)
    for fn in files:
        p = os.path.join(root, fn)
        if fn.endswith('.deps.json'): continue
        if fn.endswith('.runtimeconfig.json') or fn.endswith('.pdb'):
            pass
        elif not (fn.lower().endswith('.dll') and is_managed(p)):
            continue                                   # Windows native: coreclr.dll, hostfxr.dll, msquic.dll, *.exe ...
        out = os.path.join(dst, rel, fn) if rel != '.' else os.path.join(dst, fn)
        if rel == '.' and os.path.exists(out):
            continue                                   # framework assembly: keep the osx-arm64 build
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.copy2(p, out); copied += 1
print('managed files copied:', copied)
EOF
# A win-x64 publish marks the game assembly x64-only (PE32+, Machine AMD64, IL-only). The arm64 CoreCLR binder rejects
# it with CLR_E_BIND_ARCHITECTURE_MISMATCH (0x80132006), which Godot reports as "Failed to get GodotPlugins
# initialization function pointer". The image contains only IL (no ReadyToRun code), so marking it ARM64 is enough.
python3 -I - "$DATA" <<'EOF'
import os, struct, sys
root = sys.argv[1]
for dirpath, _, files in os.walk(root):
    for fn in files:
        if not fn.endswith('.dll'): continue
        p = os.path.join(dirpath, fn)
        with open(p, 'r+b') as f:
            d = f.read(4096)
            if d[:2] != b'MZ': continue
            pe = struct.unpack('<I', d[0x3c:0x40])[0]
            mach = struct.unpack('<H', d[pe+4:pe+6])[0]
            magic = struct.unpack('<H', d[pe+24:pe+26])[0]
            dd = pe + 24 + (96 if magic == 0x10b else 112)
            clr_rva = struct.unpack('<I', d[dd+14*8:dd+14*8+4])[0]
            if clr_rva and magic == 0x20b and mach == 0x8664:
                # IL-only check: COR20 header flags must not carry ReadyToRun/IL_LIBRARY code.
                f.seek(0); full = f.read()
                nsec = struct.unpack('<H', full[pe+6:pe+8])[0]; so = pe + 24 + struct.unpack('<H', full[pe+20:pe+22])[0]
                cor = None
                for i in range(nsec):
                    s = full[so+40*i:so+40*i+40]
                    vs, va, raw = struct.unpack('<III', s[8:20])[0], struct.unpack('<I', s[12:16])[0], struct.unpack('<I', s[20:24])[0]
                    if va <= clr_rva < va + max(vs, 1): cor = raw + clr_rva - va
                flags = struct.unpack('<I', full[cor+16:cor+20])[0]
                if flags & 0x4:
                    print('skip (ReadyToRun x64 code):', fn); continue
                f.seek(pe + 4); f.write(struct.pack('<H', 0xAA64))
                print('marked ARM64:', fn)
EOF
# deps.json: retarget the win-x64 manifest to osx-arm64 and list the macOS runtime pack (the win-x64 one names
# Windows-only files).
python3 -I - "$WINDATA/$ASM.deps.json" "$DATA/$ASM.deps.json" "$RT/shared/Microsoft.NETCore.App/$NETVER" "$NETVER" <<'EOF'
import json, os, sys
src, dst, rtdir, ver = sys.argv[1:5]
d = json.load(open(src))
old_t = d['runtimeTarget']['name']                     # .NETCoreApp,Version=v9.0/win-x64
new_t = old_t.rsplit('/', 1)[0] + '/osx-arm64'
d['runtimeTarget']['name'] = new_t
tgt = d['targets'].pop(old_t)
pack_key = 'runtimepack.Microsoft.NETCore.App.Runtime.osx-arm64/' + ver
runtime = {f: {} for f in sorted(os.listdir(rtdir)) if f.endswith('.dll')}
native = {f: {} for f in sorted(os.listdir(rtdir)) if f.endswith('.dylib')}
native['libhostfxr.dylib'] = {}
newtgt = {}
for k, v in tgt.items():
    if k.startswith('runtimepack.Microsoft.NETCore.App.Runtime.'):
        newtgt[pack_key] = {'runtime': runtime, 'native': native}
    else:
        newtgt[k] = v
d['targets'][new_t] = newtgt
libs = {}
for k, v in d['libraries'].items():
    libs[pack_key if k.startswith('runtimepack.Microsoft.NETCore.App.Runtime.') else k] = v
d['libraries'] = libs
json.dump(d, open(dst, 'w'), indent=2)
print('deps.json retargeted to', new_t, 'runtime', len(runtime), 'native', len(native))
EOF
python3 -I - "$DATA/$ASM.runtimeconfig.json" "$NETVER" <<'EOF'
import json, sys
p, ver = sys.argv[1], sys.argv[2]
d = json.load(open(p))
for fw in d['runtimeOptions'].get('includedFrameworks', []):
    if fw['name'] == 'Microsoft.NETCore.App': fw['version'] = ver
json.dump(d, open(p, 'w'), indent=2)
EOF

# Info.plist placeholders of the Godot template.
python3 -I - "$APP/Contents/Info.plist" "$BIN" "$NAME" "$BUNDLE_ID" "$VERSION" <<'EOF'
import sys
p, binary, name, bid, ver = sys.argv[1:6]
s = open(p, encoding='utf-8').read()
rep = {
    '$binary': binary, '$name': name, '$bundle_identifier': bid,
    '$short_version': ver, '$version': ver + '.0', '$signature': '????',
    '$platfbuild': '', '$sdkver': '', '$sdkbuild': '', '$sdkname': '', '$xcodever': '', '$xcodebuild': '',
    '$copyright': 'Game: 植物大战僵尸杂交重制版 %s (user-supplied). Engine: Godot 4.7 (MIT), .NET 9 (MIT).' % ver,
    '$app_category': 'games', '$min_version_arm64': '11.0', '$min_version_x86_64': '10.13',
    '$highres': '\t<true/>', '$liquid_glass_icon': '', '$usage_descriptions': '', '$additional_plist_content': '',
}
for k in sorted(rep, key=len, reverse=True):
    s = s.replace(k, rep[k])
assert '$' not in s, [l for l in s.splitlines() if '$' in l]
open(p, 'w', encoding='utf-8').write(s)
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Icon from the game's own icon.png.
if [[ -n "$ICONPNG" && -f "$ICONPNG" ]]; then
  SET="$WORK/icon.iconset"; mkdir -p "$SET"
  for s in 16 32 128 256; do
    sips -z $s $s "$ICONPNG" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d "$ICONPNG" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/icon.icns"
fi

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$OUT/$NAME.app"
rsync -a --delete "$APP/" "$OUT/$NAME.app/"
if (( INSTALL )); then
  mkdir -p "/Applications/$NAME.app"
  rsync -a --delete "$APP/" "/Applications/$NAME.app/"
  codesign --verify --deep "/Applications/$NAME.app"
  touch "/Applications/$NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$NAME.app"
  echo "Installed /Applications/$NAME.app"
fi
rm -rf "$WORK"
echo "Done: $OUT/$NAME.app"
