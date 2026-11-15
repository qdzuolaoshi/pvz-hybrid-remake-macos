# pvz-hybrid-remake-macos

把 Windows 版「植物大战僵尸杂交重制版」（Godot 4.7 + C#/.NET 9 的同人重制游戏）做成 **Apple Silicon Mac 原生应用** 的构建脚本和补丁。

> 本仓库**不包含任何游戏文件**（资源包、程序、图片、音效）。你需要自己合法获得 Windows 版游戏，脚本只在本机读取它，生成仅供个人使用的 Mac 应用。游戏版权归原作者所有。

## 思路

这个游戏不是在原版 PvZ 程序上改的，而是用 Godot 引擎重新做的，而 Godot 本身支持 macOS。所以不需要逆向游戏代码，只需要：

1. 保留游戏自己的资源包（`.pck`）和 C# 程序集；
2. 把 Windows 版的 Godot 引擎和 .NET 运行库，换成官方的 macOS 版；
3. 修正几个只在 Mac / Apple 芯片上出现的问题。

## 已解决的 Mac 问题

| 问题 | 原因 | 处理 |
|---|---|---|
| Mac 解压不了 Windows 打的压缩包 | 用了 Deflate64 压缩 | `tools/deflate64/`（带 GBK 文件名和 CRC 校验） |
| 启动报错「Failed to get GodotPlugins initialization function pointer」 | Windows 发布时把游戏程序集标成了「只能在 x64 上运行」 | 程序集是纯 IL，把架构标记改成 ARM64 |
| .NET 加载组件失败 | 依赖清单是 win-x64 的 | 把 `deps.json` 改成 osx-arm64 |
| 角色缺部件（普通僵尸的领带和手臂、坚果本体等） | 角色着色器用浮点运算解码「部件是否可见」，苹果 GPU 算错 | `hybrid_mac/shader_intmask.py` 改成整数位运算；只改补丁版资源包副本 |
| 有些按钮没有音效 | 游戏数据里本来就没配（Windows 版同样） | `ui_sfx_patch.gd` 接上游戏自带的按键音 |
| 鼠标停在卡槽上不显示植物名 | 原作没有这个功能 | 可选的 `packet_name_tooltip.gd` |
| 动画卡顿 | 游戏「选项 > 动画帧率」默认 30；垂直同步关闭 | 打开垂直同步；在游戏里把动画帧率调到 60 |
| 窗口可以被拉成任意比例 | Godot 没有窗口比例锁定 | 启动器 `launcher.c` + 注入库 `PvzHybridMac.m`（`contentAspectRatio`），窗口只能等比例缩放，全屏不受影响 |

详细原理和排查方法见 [docs/PORTING_GUIDE.md](docs/PORTING_GUIDE.md)（英文）。

## 需要准备

- Apple Silicon Mac，macOS 11 或更高；Xcode Command Line Tools（`clang`、`codesign`）；Python 3。
- Windows 版游戏（已测试 0.31、0.32），解压后的文件夹里有 `*.pck` 和 `data_PlantsVsZombies_windows_x86_64/`。
- 官方 Godot 4.7-stable mono 导出模板：`Godot_v4.7-stable_mono_export_templates.tpz`（[godotengine/godot-builds](https://github.com/godotengine/godot-builds/releases/tag/4.7-stable)，用 SHA512-SUMS.txt 校验），取出其中的 `templates/macos.zip` 并解压，得到 `macos_template.app`。
- 微软官方 .NET 运行库：`dotnet-runtime-9.0.22-osx-arm64.tar.gz`（builds.dotnet.microsoft.com），解压到一个文件夹。

## 构建

```bash
# 1) 如果压缩包是 Deflate64 格式，先用自带工具解压
clang -O2 -o tools/deflate64/inflate64 tools/deflate64/inflate64.c
python3 tools/deflate64/unzip64.py <游戏压缩包.zip> <解压目录> tools/deflate64/inflate64

# 2) （可选）取出游戏自带图标
python3 hybrid_mac/pck_patch.py extract <游戏目录>/*.pck icon.png icon.png

# 3) 构建（加 --install 会装进「应用程序」）
ICONPNG=icon.png zsh build_hybrid_app.sh <游戏目录> <macos_template.app> <dotnet-runtime 目录> <输出目录> [--install]
```

脚本会：把引擎精简为 arm64；复制 .NET 运行库和游戏程序集；生成一份打过补丁的资源包副本（你的原始 `.pck` 只读不改）；编译启动器和辅助库；ad-hoc 签名。

存档位置：`~/Library/Application Support/Godot/app_userdata/植物大战僵尸杂交版/`。

## 更新到游戏新版本

如果新版本的 Godot 版本和 .NET 版本没变（看 exe 里的 `4.x.stable.mono` 字样和 `runtimeconfig.json`），直接用新游戏目录重新运行构建脚本即可。角色着色器如果被作者改了，脚本会停下并提示，需要先确认修复是否仍然需要。

## 许可

本仓库中的代码和文档以 [MIT](LICENSE) 许可发布。Godot（MIT）、.NET（MIT）和游戏本身不包含在本仓库中，各自遵循其原有许可。

---

## English summary

Build scripts and fixes that turn the Windows release of the fan remake *植物大战僵尸杂交重制版* (Godot 4.7, C#/.NET 9) into a native Apple Silicon macOS app. **No game files are included**; you need your own copy of the game. The game's pack and managed assemblies are reused; the Windows engine and .NET runtime are replaced with the official macOS ones; Apple-GPU and macOS-specific problems are fixed (Deflate64 archives, x64-only IL assembly, deps.json, a float bit-decoding bug in the character shader, silent buttons, an optional seed-packet tooltip, vsync, a windowed aspect lock). See [docs/PORTING_GUIDE.md](docs/PORTING_GUIDE.md).
