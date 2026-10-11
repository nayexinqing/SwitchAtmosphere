# 指定固件版本的整合包发布 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 输入固件版本即可从锁定的 GitHub 资产生成候选包、公开 ZIP 和人工审核的 Draft Release。

**Architecture:** 扩展现有 `UpgradeSources` 的固件精确选择与基线入口；新增独立的发布封包脚本负责过滤、计划、SHA-256 和 ZIP；手动触发的 GitHub Actions 复用相同 PowerShell 入口。公开首版由本地 23.0.1 生成，后续 CI 以已发布 ZIP 为基线。

**Tech Stack:** PowerShell 7、GitHub Releases API、.NET ZipArchive、GitHub Actions、GitHub CLI（仅在 CI 发布 Draft）。

**Spec:** `docs/superpowers/specs/2026-10-11-firmware-release-design.md`

## Global Constraints

- `Atmosphere-<版本>` 的版本是目标 Switch 系统版本。
- 只选择 THZoria/NX_Firmware 中与目标版本完全一致的稳定 Release；其余三个来源沿用现有仓库与 SHA-256 校验。
- 公开 ZIP 完全排除 `lakka/`；拒绝密钥和未知顶层路径；不将当前原始整合包上传或纳入 Git。
- Release 必须是 Draft，只有维护者实机验证后才公开。

---

### Task 1: 指定固件版本与显式基线

**Files:** Modify `scripts/UpgradeSources.psm1`, `scripts/Start-LatestUpgrade.ps1`; Test `tests/Sources.Tests.ps1`, `tests/Upgrade.Tests.ps1`.

**Interfaces:** `Get-GitHubLatestReleases -TargetSystemVersion <string>` 返回四仓库 Release 表；`Select-GitHubReleaseAssets -Releases <IDictionary> -TargetSystemVersion <string>` 返回 schemaVersion 1 锁定清单；`Start-LatestUpgrade.ps1 -TargetSystemVersion <string> -BaseDirectory <string>` 使用显式目录。

- [ ] 测试：以 23.0.1 元数据选择 23.0.1 成功，选择 23.0.0 抛错；显式基线目录必须为 `Atmosphere-X.Y.Z`。
- [ ] 运行两组现有测试，确认新增断言先失败。
- [ ] 实现：精确固件 tag API 地址、目标版本校验、显式基线选择；保留不传参数时的兼容行为。
- [ ] 重跑两组测试并提交此任务。

### Task 2: 发布计划与安全封包

**Files:** Create `scripts/New-ReleaseBundle.ps1`, `tests/Release.Tests.ps1`; Modify `scripts/New-Upgrade.ps1`, `tests/Upgrade.Tests.ps1`.

**Interfaces:** 计划调用 `New-ReleaseBundle.ps1 -PackageDirectory <dir> -TargetSystemVersion <version> -PlanPath <json> -SourceManifestPath <json> -UpgradeReportPath <json>`；本地首版也先用真实锁定清单和 built 升级报告生成候选目录；构建调用再加 `-Build -OutputDirectory <new-dir> -ApprovedPlanSha256 <hex>`。输出 `Atmosphere-X.Y.Z.zip`、`.sha256` 和 `.release.json`，计划保留在本地。

- [ ] 测试：在小型候选目录中放入配置、图标、固件、Lakka 私钥、应用配置与游戏金手指；计划必须仅纳入安全文件并报告排除项。升级构建本身不复制 Lakka。
- [ ] 运行发布测试确认因脚本缺失而失败。
- [ ] 实现：路径白名单、敏感文件拒绝、逐文件哈希与计划落盘，且计划阶段不创建 ZIP；升级阶段排除 Lakka 并加强密钥路径检查。
- [ ] 测试：正确计划哈希生成 ZIP；源文件改变、错误计划哈希、未知顶层、非 Lakka 密钥均失败。
- [ ] 运行发布测试确认新增断言失败，再实现重验与 ZIP/摘要/元数据；重跑发布测试并提交此任务。

### Task 3: 手动 Draft Release 与操作说明

**Files:** Create `.github/workflows/draft-release.yml`; Modify `README.md`, `AGENTS.md`; Test `tests/Release.Tests.ps1`.

**Interfaces:** `workflow_dispatch` 输入 `target_version`、`base_version`、`base_sha256`；基线资产名 `Atmosphere-<base_version>.zip`，Release tag `fw-<base_version>`；产物 tag `fw-<target_version>`。

- [ ] 工作流检查：只允许手动触发；下载指定基线并验证 SHA-256；在线锁定/离线构建；发布脚本封包；`gh release create --draft` 上传 ZIP、摘要、计划与来源信息。
- [ ] 文档写出首次本地基线、后续目标版本、审阅计划、候选实机验证、Draft 发布与固件/插件兼容检查的确切命令。
- [ ] 运行所有测试、`git diff --check`、本地 23.0.1 发布计划；确认没有 Lakka/密钥路径进入纳入清单。
- [ ] 代码复核，修复问题，提交并推送隔离分支；不创建真实 Release。
