# Switch Atmosphere 整合包升级

本仓库保存经过本地定制的 Nintendo Switch Atmosphere 整合包。`Atmosphere-<版本>` 指目标 Switch 系统版本，不是 Atmosphère 软件版本。当前最近一次反馈可用的本地基线是 `Atmosphere-23.0.1/`；实机验证范围见 [23.0.1 升级记录](UPGRADE-23.0.1.md)。

## 指定固件版本并制作 Release

维护者每次明确输入目标系统版本，例如 `23.0.1`。脚本只下载 [THZoria/NX_Firmware](https://github.com/THZoria/NX_Firmware/releases) 中**同一版本 tag** 的固件；Atmosphère、hekate 和 impeeza/sys-patch 取运行时最新稳定 Release，并将 tag、资产名、来源 URL 与 SHA-256 锁定。最新版本不保证兼容目标固件，因此脚本只生成候选包或 **Draft Release**，公开前仍需核对发布说明并实机验证。

首次可从已验证的本地 `Atmosphere-23.0.1/` 制作干净基线。这里的原目录含 Lakka 本地数据，不可直接上传；发布脚本完全排除 `lakka/`，还排除游戏补丁/金手指文件和 `switch/*/*.config` 应用配置，保留启动配置、图标、系统模块、第三方应用与 23.0.1 固件。删除这些内容后的公开 ZIP 与已实机验证的原目录并非逐字节相同，发布前要再次检查实际使用的功能。

在隔离分支所在目录运行下面两步；`-PlanPath` 和 `-OutputDirectory` 可改为其他新路径，输出保存在已忽略的 `.upgrade-cache/` 中：

```powershell
$base = 'D:\Codes\SwitchAtmosphere\Atmosphere-23.0.1'
$plan = '.upgrade-cache/reports/seed-23.0.1-release-plan.json'
# 先用真实锁定清单构建一个候选目录，并生成 built=true 的升级报告：
pwsh -NoProfile -File scripts/Start-LatestUpgrade.ps1 -PackageRoot '.upgrade-cache' `
  -BaseDirectory $base -TargetSystemVersion 23.0.1 `
  -ManifestPath '.upgrade-cache/locks/release-lock-23.0.1.json' `
  -AssetDirectory '.upgrade-cache/assets' -OutputDirectory '.upgrade-cache/candidates/Atmosphere-23.0.1' `
  -ReportPath '.upgrade-cache/reports/upgrade-23.0.1.json' -Offline -Build
pwsh -NoProfile -File scripts/New-ReleaseBundle.ps1 -PackageDirectory '.upgrade-cache/candidates/Atmosphere-23.0.1' `
  -TargetSystemVersion 23.0.1 -PlanPath $plan `
  -SourceManifestPath '.upgrade-cache/locks/release-lock-23.0.1.json' `
  -UpgradeReportPath '.upgrade-cache/reports/upgrade-23.0.1.json'

# 审阅计划的 included/excluded、图标和配置内容之后，再用计划摘要封包：
$approved = (Get-FileHash -LiteralPath $plan -Algorithm SHA256).Hash.ToLowerInvariant()
pwsh -NoProfile -File scripts/New-ReleaseBundle.ps1 -PackageDirectory '.upgrade-cache/candidates/Atmosphere-23.0.1' `
  -TargetSystemVersion 23.0.1 -PlanPath $plan -Build `
  -SourceManifestPath '.upgrade-cache/locks/release-lock-23.0.1.json' `
  -UpgradeReportPath '.upgrade-cache/reports/upgrade-23.0.1.json' `
  -ApprovedPlanSha256 $approved -OutputDirectory '.upgrade-cache/releases/Atmosphere-23.0.1'
```

封包产物为 `Atmosphere-23.0.1.zip`、`.sha256` 和 `.release.json`；ZIP 解压后内容直接对应 SD 卡根目录。封包时会重新计算每个纳入文件的哈希，计划之后有变化就中止。不要把原始目录、计划中的排除路径或 `.upgrade-cache/` 整目录上传。公开首版经检查后，以 `fw-23.0.1` 为 tag 上传这三个产物，供后续 CI 作为基线。

首版发布后，可以在 GitHub Actions 手动运行 [`Build draft Atmosphere release`](.github/workflows/draft-release.yml)，输入 `target_version`、`base_version` 和上版 ZIP 的 `base_sha256`。工作流先核验上版 Release 与 ZIP，再锁定指定固件、构建候选包、过滤文件并创建 `fw-<目标版本>` **Draft Release**。锁定清单与升级报告一同附在草稿 Release；维护者完成实机测试后再公开。该工作流不会每日自动打包或删除旧版 Release，且只有进入仓库默认分支后才能从 Actions 页面手动触发。

## 以后如何升级

需要 PowerShell 7。先备份 SD 卡和当前可用整合包，在仓库根目录执行：

```powershell
pwsh -NoProfile -File scripts/Start-LatestUpgrade.ps1
```

如果脚本所在工作树与整合包目录分开，另传 `-PackageRoot '<整合包仓库路径>'`；脚本仍使用自身仓库里的已验证基线登记表。

默认只生成计划，不创建新整合包。脚本从 [`config/verified-bases.json`](config/verified-bases.json) 选取**本地目录存在且标记已验证的最高系统版本**作为基线；指定 `-TargetSystemVersion 23.0.1` 时只选同版本固件，其他三项取最新稳定 Release，锁定 tag、资产名、下载链接和 GitHub 提供的 SHA-256 摘要，下载到 `.upgrade-cache/assets/` 并重新计算哈希。不指定目标版本时仍兼容旧流程，选择最新固件。CI 可传 `-BaseDirectory` 指向从已发布 ZIP 解压出的基线。

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
  -TargetSystemVersion '<版本>' `
  -ManifestPath '.upgrade-cache/locks/release-lock-<版本>-<时间>.json' -Build
```

当固件版本高于基线版本时，默认候选包为 `Atmosphere-<固件版本>/`；同一系统版本更新组件时默认为 `Atmosphere-<固件版本>-candidate/`。目标目录已有文件时脚本会拒绝覆盖，可另传 `-OutputDirectory` 指向全新目录。离线重放会再次校验缓存 SHA-256；缓存缺失时必须先在线运行计划。脚本不会向 Switch 写入系统固件，也不会修改基线目录。`New-Upgrade.ps1` 复制基线时完全排除 `lakka/`，因此新候选包也不包含 Lakka 本地数据。

候选包经实机验证后，再把新目录和版本加入 [`config/verified-bases.json`](config/verified-bases.json)，设置 `verified: true`。未验证的版本可记录为 `false`，不会被自动选为下次基线。建议至少检查系统版本与启动环境、冷启动、经 hekate 重启、休眠唤醒、相册入口、sys-patch 实际效果、常用游戏与插件；不要仅凭可进入系统就认定全部功能正常。

## 本地定制与安全边界

升级时保留 `bootloader/hekate_ipl.ini`、`bootloader/ini/`、`bootloader/res/`、根目录 `exosphere.ini`、当前生效的 `atmosphere/config/`、其他 `atmosphere/contents/`、第三方 `switch/` 应用与悬浮插件及 Sphaira 入口；完全排除 `lakka/`。[Ultrahand](https://github.com/ppkantorski/Ultrahand-Overlay/releases) 等第三方插件保持基线版本，需单独评估后升级。只替换脚本明确列出的上游文件；遇到未知的发布包结构会中止，需人工检查脚本规则。旧固件目录不会复制进候选包。公开封包还会排除游戏修改、应用私有配置和常见数据目录；从公开包升级时，这些文件也不会重新出现。

密钥文件不得进入整合包构建、锁定清单或 Git 提交。`.upgrade-cache/` 已被忽略；整合包目录可能含用户数据，请只按文件路径选择性暂存代码与文档，不要批量提交整个目录。

本地测试：

```powershell
pwsh -NoProfile -File tests/Sources.Tests.ps1
pwsh -NoProfile -File tests/Upgrade.Tests.ps1
pwsh -NoProfile -File tests/Release.Tests.ps1
```
