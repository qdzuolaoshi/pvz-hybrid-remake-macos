# Porting the Godot/.NET remake (植物大战僵尸杂交重制版) to macOS

Some "mods" are complete remakes on another engine. The 杂交重制版 (0.30–0.32) is Godot 4.7 with C#/.NET 9. The engine is already cross-platform, so the job is to swap the Windows engine and runtime for
the official macOS ones and keep the game's own pack and code. Reference: `build_hybrid_app.sh`.

**Triage.**
- Signs of such a build: a `*.pck` starting with `GDPC` (pack format, Godot version), a `data_<Assembly>_windows_x86_64/`
  folder (GodotSharp.dll, coreclr.dll), and an exe that contains `4.x.stable.mono.official`.
- Read the pack header: the flags bit 0 means the directory is encrypted, and each entry has its own flag (bit 0 =
  encrypted).
  - An encrypted pack needs the game's key; this project does not handle encrypted packs.
  - An unencrypted pack is reused as is.
- Read `project.binary` in the pack (ECFG key/value file) for the name, renderer, window size, stretch mode, max_fps,
  icon and `dotnet/project/assembly_name`.
- Scan the C# assembly for Windows-only APIs:
  - ASCII strings for P/Invoke DLL names;
  - UTF-16 user strings for `HKEY`, `C:`, `cmd.exe` and backslash paths.
  - Treat launchers (`*.hta`, `*.bat`) as plain text and never run them.

**Downloads.** Verify every download.
- Godot `Godot_v<ver>-stable_mono_export_templates.tpz` from godotengine/godot-builds; check it against SHA512-SUMS.txt.
  Only `templates/macos.zip` is needed.
- The matching `dotnet-runtime-<9.0.x>-osx-arm64.tar.gz` from builds.dotnet.microsoft.com; check its SHA-512 in the
  release metadata. Any 9.0.x patch version works.

**Assembly** (`build_hybrid_app.sh`).
- Thin the release template binary to arm64 and rename it. The pack becomes `Contents/Resources/<binary>.pck`.
- Create `Contents/Resources/data_<Assembly>_macos_arm64/` and fill it:
  - the osx-arm64 runtime (`shared/Microsoft.NETCore.App/<ver>/*` and `host/fxr/<ver>/libhostfxr.dylib`);
  - the game's managed assemblies, satellite resource folders and runtimeconfig. Leave out every Windows-native file and
    every win-x64 framework assembly.
- Fill the template's Info.plist `$placeholders`, build the icon from the pack's `icon.png`, and sign ad hoc.

**Bugs met when moving a Godot .NET game from Windows to Apple Silicon.**

| Symptom | Cause | Fix |
|---|---|---|
| Mac tools cannot unzip the archive ("Unsupported ZIP compression method 9") | Windows zipped it with Deflate64 | `tools/deflate64/` (inflate64.c and unzip64.py: GBK names, CRC check) |
| `.NET: Failed to get GodotPlugins initialization function pointer`; a probe shows rc 0x80132006 | The win-x64 publish marked the game assembly x64-only (PE32+, Machine AMD64, IL-only); the arm64 binder rejects it | Set the COFF Machine field to ARM64 (0xAA64) when the image is IL-only, not ReadyToRun |
| Component load problems without a manifest | Without deps.json the isolated load context receives every DLL in the folder, framework ones included | Retarget `<Assembly>.deps.json` to `osx-arm64` and list the macOS runtime pack |
| Same error with no host-side message | `COREHOST_TRACE` shows nothing | Probe with a 30-line C host: `hostfxr_initialize_for_dotnet_command_line`, then `load_assembly_and_get_function_pointer("GodotPlugins.Game.Main, <Assembly>", "InitializeFromGameProject", UNMANAGEDCALLERSONLY)`; print the rc |

**More macOS problems found in 0.31 and their fixes** (all live in `hybrid_mac/` and are applied by the build
script):

| Symptom | Cause | Fix |
|---|---|---|
| Characters lose parts: the normal zombie's tie and outer arm, the nut body under the flame, and others | The character shader (`AdobeAnimateManagedMultiMesh.gdshader`) decodes per-layer visibility bits with float maths (`mod(floor(mask / pow(2, bit)), 2)`). Apple GPUs compute it wrongly under Metal, MoltenVK and OpenGL alike | Rewrite the two mask functions with integer shifts and AND (`shader_intmask.py`, guarded by the original shader's md5) and write a patched copy of the pck with `pck_patch.py` |
| Buttons silent (mode stones, back arrows, every NinePatch button) | Data gaps that exist on Windows too: no `AudioPlay` in those handlers, and the default `ButtonClickPress` key is missing from AudioResource.json | GDScript autoload `ui_sfx_patch.gd` that hooks those buttons to the game's own `ButtonPress` / `GraveButtonPress` (identical to the original buttonclick/gravebutton) and skips buttons that already play a sound |
| No plant name when hovering a seed packet | Not implemented in 0.31 on any platform | Optional autoload `packet_name_tooltip.gd` that reads the packet's `config.name` through `tr()` |
| Choppy animation | The game's own option 选项 > 动画帧率 (config `AnimeFrameRate`, default 30) overwrites `max_fps`; with vsync off, frame pacing drifts | Ship `vsync_mode=1`; tell the user to set 动画帧率 to 60 (game speed does not change) |
| A loose override.cfg in Contents/MacOS breaks `codesign --strict` | Unsigned loose file | Put `res://override.cfg` inside the patched pck instead (the engine honours it) |
| Windowed resize changes the ratio | Godot has no aspect lock | Launcher (`launcher.c`) execs the engine with `DYLD_INSERT_LIBRARIES=libPvzHybridMac.dylib` (the template is ad-hoc signed, not hardened). The dylib applies `contentAspectRatio` plus GodotWindowDelegate hooks; this is the 4:3 lock of the original edition, ported |

**Test harness for Godot games** (the same dylib, only when `PVZH_TEST_SCRIPT` is set): it posts in-process NSEvents
(`click`, `move`, `drag`, `key`, `winsize`, `waitwin`, `log`, `quit`, in game logical coordinates) and logs `PVZH_TEST t=…`
lines to align with Movie Maker frames. No Accessibility permission is needed.
- Always use `--env HOME=<scratch>` so the user's `user://` saves are never touched.
- Before level tests, set the bool after `Backgrounder\0` in the scratch config.res to 1. The game pauses whenever its
  window is not focused.
- Give each test window its own position (`initial_position`): occluded Godot windows stop drawing.
- Release templates reject scene paths and `--main-pack`. To switch scenes or settings in a test copy, use an
  override.cfg.
- C# test scenes cannot be used, because their classes are stripped from the release build.

**Updating to a new release of the same game.** Extract the new zip with `tools/deflate64/`. Then check:
- the Godot version string in the exe;
- the .NET version in runtimeconfig.json;
- the pack's encryption flags;
- the shader md5 (the build script stops when it changes).

If the Godot and .NET versions are unchanged, rebuild without new downloads: use the engine binary (`lipo -create`
it back into a "universal" file) and the .NET runtime files from the installed app. Remove the game's own assemblies and
restore the Info.plist `$short_version`/`$version`/`$copyright` placeholders.

**Light acceptance for Godot builds.**
- Run in the background with `open -n -g --stdout … --args --windowed --write-movie <file>.avi --fixed-fps 30
  --quit-after N`. Movie Maker writes MJPEG frames (`00db` chunks) without any screen-recording permission.
- Check the log for .NET or script errors and for the game's own "resources ready" lines, and look at a few frames
  (loading screen, then title screen).
- Use a scratch `HOME` for test runs so real saves are never touched; delete the test user data (`~/Library/Application Support/Godot/app_userdata/<name>/`) so the user starts fresh.
- Windowing, Retina, framing, fonts and frame cap belong to the game and Godot. Change them only if they misbehave on
  macOS.
