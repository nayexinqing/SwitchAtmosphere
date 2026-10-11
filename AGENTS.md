# 仓库工作指引

## 项目性质

- 本仓库保存 Nintendo Switch Atmosphere 整合包的多个目标系统版本及相关插件、固件文件，主要是预编译文件和配置，不是 Atmosphere 源码构建仓库。`Atmosphere-<版本>` 中的版本号指目标 Switch 系统版本，不代表 Atmosphere 本身的发布版本。
- `Atmosphere-22.0.0/` 是已知可用的基线整合包：最初从 <https://github.com/laila509/hekate_ipl> 下载，之后做过局部修改与替换。该上游仓库已停止更新，不能将现有目录视作未经修改的上游原包。
- `Atmosphere-23.0.1/` 是从上述基线复制的整合包，已放入 `Firmware.23.0.1/`，并按 `UPGRADE-23.0.1.md` 更新了 18 个 Atmosphere、hekate、fusee 与 sys-patch 文件。用户已反馈直接覆盖替换后，系统版本与启动环境、冷启动、经 hekate 重启及休眠唤醒正常，金手指入口可正常打开；其他功能尚未逐项验证。它是目前 `config/verified-bases.json` 中最高版本的已验证本地基线。
- 固件下载页为 <https://github.com/THZoria/NX_Firmware/releases>，sys-patch 下载页为 <https://github.com/impeeza/sys-patch/releases>；这两处是后续升级时核对发布版本和文件的来源。
- 根目录 `README.md` 说明升级流程；`scripts/Start-LatestUpgrade.ps1` 查询 Atmosphere、hekate、sys-patch 与固件的 GitHub 最新稳定 Release，下载并锁定资产摘要，`scripts/New-Upgrade.ps1` 按锁定清单生成逐文件报告和候选包。核对来源和版本时以实际发布信息为准。
- 与用户沟通及新增的项目说明使用简体中文；保留上游项目名、文件名和配置键的原文。

## 目录与修改范围

- `Atmosphere-<版本>/` 是各自独立的套件快照，通常含 `atmosphere/`、`bootloader/`、`config/`、`switch/` 和固件目录。固件目录名称存在 `Firmware-<版本>` 与 `Firmware.<版本>` 两种形式，以实际目录为准。
- `sys-patch-v*/` 保存独立的插件文件；根目录的压缩包受 `.gitignore` 中的 `*.zip` 规则影响。
- 开始修改前先查看 `git status --short`，确认目标版本及文件。仓库可能有未跟踪的版本目录；不要清理、覆盖或批量暂存与当前任务无关的文件。
- 只修改任务涉及的版本和路径。不要把不同版本的固件、引导文件、插件或配置混用；保留原有目录层级与文件名。
- 后续升级以 `config/verified-bases.json` 中本地存在且最高版本的已验证包为基线；先识别并保留本地定制，再逐项核对 Atmosphere、hekate、sys-patch、插件和配置对目标系统版本的兼容性；不要把复制目录加上新固件等同于完成升级。
- 对 `.ini`、`.json` 等文本配置做最小范围修改。对 `.nca`、`.nro`、`.nsp`、`.bin` 等预编译或固件文件，除非任务明确要求替换，否则不要改写或格式化。
- 涉及密钥材料时，不要在回复、日志或新文档中输出其内容，也不要顺手新增或提交密钥文件。

## 验证与交付

- PowerShell 7 测试入口为 `tests/Sources.Tests.ps1` 和 `tests/Upgrade.Tests.ps1`。升级默认只生成计划，需明确传 `-Build` 才构建；先审阅报告再构建。
- 替换发布文件时，核对目标版本、来源、目录结构及可获得的校验值；不要仅凭文件名判断兼容性。
- 交付前检查 `git diff --check` 和 `git status --short`，说明修改了哪个版本、验证了什么；未进行实机测试时不要声称已验证设备启动或运行。
