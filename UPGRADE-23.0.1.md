# Atmosphere-23.0.1 升级记录（实机启动成功）

记录日期：2026-10-11。目标目录是 `Atmosphere-23.0.1/`，以已知可用且经过本地定制的 `Atmosphere-22.0.0/` 为基线。这里的 23.0.1 指目标 Switch 系统版本。**用户反馈直接覆盖替换后，系统版本与启动环境、冷启动、经 hekate 重启及休眠唤醒均验证正常，金手指入口可正常打开；其他功能尚未逐项验证。**

## 来源与校验

| 发布文件 | 版本 | SHA-256 |
| --- | --- | --- |
| [Atmosphere 发布包](https://github.com/Atmosphere-NX/Atmosphere/releases/tag/1.12.0) `atmosphere-1.12.0-master-28d6a2e11+hbl-2.4.5+hbmenu-3.6.1.zip` | 1.12.0 | `14451a033935962a9ed800db6918706e372de4370e8d04ea3fc9728a937249e1` |
| [fusee.bin](https://github.com/Atmosphere-NX/Atmosphere/releases/tag/1.12.0) | 1.12.0 | `6559017e4df5ac418ce09fb347c32d071649f8b6d3d4bac9a874505fc8bed1bd` |
| [hekate 载荷](https://github.com/CTCaer/hekate/releases/tag/v6.5.4) `hekate_ctcaer_6.5.4.bin` | 6.5.4 | `95f6e933e32e028f3ae90f0b0857ff47800e834bdace38a0ab019d8ed35a8c24` |
| [hekate/Nyx 发布包](https://github.com/CTCaer/hekate/releases/tag/v6.5.4) `hekate_ctcaer_6.5.4_Nyx_1.9.4.zip` | 6.5.4 / 1.9.4 | `a5ee4faa956f1ffe49fdd31d795be3fd556c8dffd9cbed69cec7cff92b8b43f6` |
| [sys-patch 发布包](https://github.com/impeeza/sys-patch/releases/tag/v1.6.2.3) `sys-patch-v1.6.2.3.zip` | 1.6.2.3 | `3e4fc59d4fd084d707c1c42388e1acafb41b97531295d11c4690d3c0307fa13d` |
| [固件发布包](https://github.com/THZoria/NX_Firmware/releases/tag/23.0.1) `Firmware.23.0.1.zip` | 23.0.1 | `5337647d78584d046b6c8f46792a07c3701d7ee68473620d5008f18fc7604781` |

下载文件的哈希与 GitHub 发布资产元数据中的摘要一致；现有 `Firmware.23.0.1/` 中 238 个文件也逐一与本地已校验 ZIP 的同名文件核对了 SHA-256。

## 已更新：18 个文件

以下路径均相对于 `Atmosphere-23.0.1/`。

**Atmosphere 1.12.0 发布包：**

- `atmosphere/package3`
- `atmosphere/stratosphere.romfs`
- `atmosphere/config_templates/exosphere.ini`
- `atmosphere/config_templates/override_config.ini`
- `atmosphere/config_templates/stratosphere.ini`
- `atmosphere/config_templates/system_settings.ini`
- `switch/daybreak.nro`
- `switch/haze.nro`
- `switch/reboot_to_payload.nro`

**hekate 6.5.4 / Nyx 1.9.4：**

- `payload.bin`
- `bootloader/update.bin`
- `bootloader/sys/emummc.kipm`
- `bootloader/sys/nyx.bin`
- `bootloader/sys/l4t/sc7exit_b01.bin`
- `atmosphere/reboot_payload.bin`：写入新版 hekate 载荷，延续基线包“重启进入 hekate”的设置；没有使用 Atmosphere 发布包中指向 fusee 的同名文件。

**Atmosphere fusee 1.12.0：**

- `bootloader/payloads/fusee.bin`

**sys-patch 1.6.2.3：**

- `atmosphere/contents/420000000000000B/exefs.nsp`
- `switch/.overlays/sys-patch-overlay.ovl`

## 保持原样

- `Firmware.23.0.1.zip` 与 `Firmware.23.0.1/`：已与官方发布文件核对，无需替换；准备整合包时未对设备执行系统升级，后续实机反馈见下文。
- `bootloader/hekate_ipl.ini`、`bootloader/ini/`、`bootloader/bootlogo.bmp`、`bootloader/res/` 中的定制资源，以及根目录 `boot.dat`、`sdloader.enc`：保留原有引导配置和界面。其中 `bootloader/res/icon_switch.bmp` 与官方 hekate 发布包不同，特意保留本地版本。
- 根目录 `exosphere.ini`、`atmosphere/config/`、`config/`：保留当前生效配置；更新的仅是 Atmosphere 的 `config_templates/`。
- `atmosphere/contents/` 中除上述 sys-patch 文件外的系统模块与补丁、`switch/` 中除上述文件外的应用与悬浮插件、`lakka/`、`warmboot_mariko/`、`hbmenu.nsp`：未改动，兼容性尚未逐项验证。根目录 `hbmenu.nro` 也保留基线版本；其 SHA-256 与 `switch/sphaira/sphaira.nro` 一致，属于原有的相册入口定制，相册功能尚未单独验证。
- 官方发布包内与原文件哈希相同的文件（如 `atmosphere/hbl.nsp`、部分 `bootloader/sys/` 文件，以及 sys-patch 的 `toolbox.json` 和 `boot2.flag`）：无需重复覆盖。

## 与 Atmosphere-AIO 发布包对照

2026-10-11 对照了 [zghenhen/Atmosphere-AIO 1.12.0](https://github.com/zghenhen/Atmosphere-AIO/releases/tag/1.12.0) 的 `NS23.0.0-AMS1.12.0-V1.7z`。该仓库 README 明确称以莱莱整合包为底包，但 GitHub 仓库本身是 Atmosphere 源码仓库的 fork；其发布说明只标注支持系统 23.0.0，不能作为 23.0.1 的兼容性证明，且压缩包不含 23.0.1 固件。

- 发布包 107 个文件中，本地包有 62 个同路径同哈希、42 个同路径但内容不同、3 个本地包没有。`payload.bin`、`bootloader/update.bin`、`atmosphere/reboot_payload.bin`、`atmosphere/package3`、`bootloader/payloads/fusee.bin` 及两个 sys-patch 文件均已与该发布包一致，无须再次覆盖。
- 不合并 `bootloader/hekate_ipl.ini`（对方 `autoboot=0`，本地 `autoboot=2`，且启动菜单不同）、根目录 `exosphere.ini`（对方 `blank_prodinfo_sysmmc=0`，本地为 `1`）、`config/ultrahand/config.ini`（快捷键不同）及第三方汉化 `bootloader/sys/nyx.bin`。其他配置、主题、NRO 和悬浮插件仍按原有定制保留，若需更新应逐项核对来源与兼容性。
- 对方归档上传时间早于 [hekate 6.5.4 发布页](https://github.com/CTCaer/hekate/releases/tag/v6.5.4) 所述的同日 ZIP 休眠修复；其 `bootloader/sys/l4t/sc7exit_b01.bin` 与本地已校验的官方 ZIP 不同。无法仅凭文件差异断定故障原因，但不能用对方文件覆盖本地官方版本。
- 对方包将 `hbmenu.nro` 设为新版 Sphaira；本地原有 `hbmenu.nro` 与 `switch/sphaira/sphaira.nro` 哈希相同，仍保留为相册入口定制。`bootloader/payloads/Warmboot_Extractor.bin`、`warmboot_mariko/wb_18.bin` 和 `switch/dbi/translation.bin` 是对方包多出的文件，本次未加入；前两项涉及 Mariko 休眠，需先确认设备型号及适用性。
- 对方另提供可选超频文件，但发布说明警告 `hoc.kip` 尚不兼容 23.0.0；不将其用于本地 23.0.1 包。

## 核验结果与待验证项

- 18 个目标文件的 SHA-256 均与已校验发布包中相应文件一致；三个 hekate 载荷位置 `payload.bin`、`bootloader/update.bin`、`atmosphere/reboot_payload.bin` 的哈希相同。
- 与 `Atmosphere-22.0.0/` 逐文件比较，排除固件后共比较 589 个文件，恰好只有上述 18 个文件不同；基线目录未修改。
- `bootloader/hekate_ipl.ini` 仍引用 `atmosphere/package3`，对应文件已更新并存在。
- Atmosphere 1.12.0 和 hekate 6.5.4 的发布说明明确写到系统 23.0.0，未明确写 23.0.1；sys-patch 1.6.2.3 发布于系统 23.0.0 之前。用户的实机结果已确认这套文件能够进入破解系统，但不能据此断言所有功能、机型和配置完全兼容。
- [Atmosphere 1.12.0 发布说明](https://github.com/Atmosphere-NX/Atmosphere/releases/tag/1.12.0) 提醒系统 23.0.0 可供自定义系统模块使用的内存减少。当前包内 sys-patch 与 `atmosphere/contents/420000000007E51A`（Tesla-ultrahand）都有 `boot2.flag`；后者保持原样，稳定性仍需核对。
- 2026-10-11 用户反馈：直接用 `Atmosphere-23.0.1/` 覆盖替换后，可正常进入破解系统；前述验证清单第 1、2 项正常，即系统版本与启动环境符合预期，冷启动、经 hekate 重启及休眠唤醒正常。金手指入口可正常打开，但尚未确认金手指效果；相册/Sphaira、sys-patch、常用游戏及其他插件功能尚未收到单独验证结果。
