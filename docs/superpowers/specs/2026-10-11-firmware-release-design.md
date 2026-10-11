# 指定固件版本的整合包发布设计

## 目标

维护者输入目标 Switch 固件版本，例如 `23.0.1`，脚本从指定版本的 THZoria 固件 Release 和 Atmosphère、hekate、impeeza/sys-patch 的最新稳定 Release 锁定资产及 SHA-256，以已验证的整合包为基线生成候选包。候选包保留本仓库的启动配置、图标和其他未明确升级的文件。构建公开 ZIP 时排除 Lakka、游戏修改及本地数据，生成可审核的文件清单与校验值。GitHub Actions 只在手动触发时从指定的已发布基线构建 Draft Release，实机验证后由维护者发布。

## 数据流与边界

1. 本地首次制作公开基线：以已验证的 `Atmosphere-23.0.1` 目录为输入，运行发布计划与封包脚本；该目录本身不提交 Git、不直接上传。发布脚本只放行 Atmosphère、bootloader、config、switch、warmboot、目标固件及少数顶层文件；完全排除 `lakka/`，排除 `atmosphere/contents/` 中非已知系统模块的游戏修改，拒绝密钥及未知顶层路径。生成的 ZIP 是 SD 根目录内容，不含外层版本文件夹。
2. 后续升级：`Start-LatestUpgrade.ps1 -TargetSystemVersion X.Y.Z` 请求固件的精确 Release tag，同时查询其他三项最新稳定 Release；在线阶段锁定资产，离线阶段按同一锁定清单构建候选包。可传显式基线目录供 CI 使用；未传时仍选本地最高已验证目录。
3. 本地发布计划枚举纳入与排除的相对路径；仅对纳入文件记录大小和 SHA-256，并记录上游锁定清单与升级报告摘要。封包阶段要求提供计划 SHA-256，重新检查源文件，再创建 ZIP、ZIP SHA-256 文件和发布元数据。公开元数据只记录排除数量，不公开本地排除路径。任何源文件变化、未知路径或密钥迹象均中止。
4. GitHub Actions 的 `workflow_dispatch` 接收目标版本、基线版本、基线 ZIP 摘要；从本仓库既有 Release 下载并校验基线，运行升级与封包，创建 Draft Release。工作流不定时自动发布、不删除旧版。首个干净基线尚未公开前，CI 构建不能运行。

## 保留与更新

更新范围沿用现有逐文件升级规则：Atmosphère 官方核心文件、hekate/Nyx、fusee、impeeza/sys-patch 与指定固件。`bootloader/hekate_ipl.ini`、本地图标、`exosphere.ini`、当前配置、第三方应用保持基线原样，并在报告中列出；第三方插件是否兼容新固件仍需人工确认。公开 ZIP 排除 Lakka；用户可从其官方来源单独安装。公开 ZIP 不包含从基线带来的游戏补丁、金手指数据、存档或密钥。金手指入口和插件二进制是否可运行仍需实机验证。

## 验证与失败行为

PowerShell 7 的离线测试覆盖指定版本选择、基线过滤、发布计划与篡改拒绝。用本地 `23.0.1` 做真实发布计划，确认 Lakka 与密钥不进入 ZIP。GitHub Release 来源、tag、文件名和摘要不匹配时中止。候选包及 Draft Release 只表示构建完成，不表示目标固件已通过设备测试。
