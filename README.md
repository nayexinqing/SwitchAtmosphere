# Switch Atmosphere 整合包升级

本仓库保存经过本地定制的 Nintendo Switch Atmosphere 整合包。`Atmosphere-<版本>` 指目标 Switch 系统版本，不是 Atmosphère 软件版本。当前最近一次反馈可用的本地基线是 `Atmosphere-23.0.1/`；实机验证范围见 [23.0.1 升级记录](UPGRADE-23.0.1.md)。

## 以后如何升级

需要 PowerShell 7。先备份 SD 卡和当前可用整合包，在仓库根目录执行：

```powershell
pwsh -NoProfile -File scripts/Start-LatestUpgrade.ps1
```

如果脚本所在工作树与整合包目录分开，另传 `-PackageRoot '<整合包仓库路径>'`；脚本仍使用自身仓库里的已验证基线登记表。

默认只生成计划，不创建新整合包。脚本从 [`config/verified-bases.json`](config/verified-bases.json) 选取**本地目录存在且标记已验证的最高系统版本**作为基线；查询下列四个仓库的 GitHub 最新稳定 Release，锁定 tag、资产名、下载链接和 GitHub 提供的 SHA-256 摘要，下载到 `.upgrade-cache/assets/` 并重新计算哈希：

| 组件 | GitHub Release 来源 | 候选包中的更新范围 |
| --- | --- | --- |
| Atmosphère、fusee | [Atmosphere-NX/Atmosphere](https://github.com/Atmosphere-NX/Atmosphere/releases) | `atmosphere/` 的官方核心文件与配置模板、Daybreak 等官方 NRO；fusee 放到 `bootloader/payloads/fusee.bin` |
| hekate、Nyx | [CTCaer/hekate](https://github.com/CTCaer/hekate/releases) | `payload.bin`、`bootloader/update.bin`、`bootloader/sys/`；`atmosphere/reboot_payload.bin` 沿用指向 hekate 的本地设置 |
| sys-patch | [impeeza/sys-patch](https://github.com/impeeza/sys-patch/releases) | 对应系统模块及 `sys-patch-overlay.ovl` |
| 固件 | [THZoria/NX_Firmware](https://github.com/THZoria/NX_Firmware/releases) | 用该 Release 的固件文件创建 `Firmware.<系统版本>/` |

脚本把锁定清单写入 `.upgrade-cache/locks/`，把逐文件升级计划写入 `.upgrade-cache/reports/`。报告中的 `changes` 分别标记 `add`、`replace`、`identical`，`preservedBasePaths` 列出原样保留的基线文件，`removedFirmwareDirectories` 列出候选包中不再复制的旧固件目录，`ignoredUpstreamPaths` 列出因本地定制而忽略的上游文件。请先核对这些项目及各 Release 对目标系统版本的兼容说明；**最新 Release 不自动等于兼容**，尤其是 sys-patch 与其他第三方插件。

确认计划后，用刚生成的锁定清单构建，避免再次查询最新版本造成前后不一致：

```powershell
pwsh -NoProfile -File scripts/Start-LatestUpgrade.ps1 -Offline `
  -ManifestPath '.upgrade-cache/locks/release-lock-<版本>-<时间>.json' -Build
```

当固件版本高于基线版本时，默认候选包为 `Atmosphere-<固件版本>/`；同一系统版本更新组件时默认为 `Atmosphere-<固件版本>-candidate/`。目标目录已有文件时脚本会拒绝覆盖，可另传 `-OutputDirectory` 指向全新目录。离线重放会再次校验缓存 SHA-256；缓存缺失时必须先在线运行计划。脚本不会向 Switch 写入系统固件，也不会修改基线目录。

候选包经实机验证后，再把新目录和版本加入 [`config/verified-bases.json`](config/verified-bases.json)，设置 `verified: true`。未验证的版本可记录为 `false`，不会被自动选为下次基线。建议至少检查系统版本与启动环境、冷启动、经 hekate 重启、休眠唤醒、相册入口、sys-patch 实际效果、常用游戏与插件；不要仅凭可进入系统就认定全部功能正常。

## 本地定制与安全边界

升级时保留 `bootloader/hekate_ipl.ini`、`bootloader/ini/`、`bootloader/res/`、根目录 `exosphere.ini`、当前生效的 `atmosphere/config/`、其他 `atmosphere/contents/`、第三方 `switch/` 应用与悬浮插件、Sphaira 入口和 Lakka 等本地文件。[Ultrahand](https://github.com/ppkantorski/Ultrahand-Overlay/releases) 等第三方插件需单独评估后升级。只替换脚本明确列出的上游文件；遇到未知的发布包结构会中止，需人工检查脚本规则。旧固件目录不会复制进候选包。

密钥文件不得进入整合包构建、锁定清单或 Git 提交。`.upgrade-cache/` 已被忽略；整合包目录可能含用户数据，请只按文件路径选择性暂存代码与文档，不要批量提交整个目录。

本地测试：

```powershell
pwsh -NoProfile -File tests/Sources.Tests.ps1
pwsh -NoProfile -File tests/Upgrade.Tests.ps1
```
