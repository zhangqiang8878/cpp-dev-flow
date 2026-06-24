# cpp-dev-flow

> Windows 平台下 C++ DLL 项目的端到端开发工作流 Skill —— 从需求分析到编译部署，全程自适应你机器上实际安装的工具链。

`cpp-dev-flow` 是一个面向 AI 编码助手（Claude Code / Codex 等）的 **Skill**（技能包）。它把「写一个 Windows C++ DLL 工程」这件事拆成清晰的阶段，并内置了一套**不写死版本、按需探测环境**的工作流规范，让助手在不同机器、不同 Visual Studio 版本上都能稳定地生成工程、命令行编译、解决第三方依赖并完成部署。

---

## 这个 Skill 解决什么问题

在 Windows 上用命令行驱动 MSBuild 构建 C++ 工程，常见的坑包括：

- **工具链版本写死**：把 `v143`、`10.0` SDK、VS 2022 路径硬编码进 `.vcxproj`，换台机器就崩。
- **第三方依赖靠猜**：遇到 `C1083 找不到头文件` 或 `LNK2019 未解析符号`，就凭印象拼一个 `C:\opencv\4.5.5\...` 路径，结果驴唇不对马嘴。
- **CJK 注释乱码**：用 PowerShell heredoc 写中文注释，UTF-8 字节被破坏。
- **PATH 冲突**：MSBuild 报 `MSB6001: CL.exe`，因为环境里 `PATH` / `Path` 大小写键重复。

本 Skill 用一套明确的「阶段 + 约定 + 自适应探测」规范，系统性地规避了这些问题。

---

## 核心特性

| 特性 | 说明 |
|------|------|
| **工具链自适应** | 通过 `vswhere` 探测已安装的最新 Visual Studio，自动映射 `PlatformToolset`（v143/v142/v141），绝不硬编码。 |
| **Windows SDK 自适应** | 从注册表读取已安装的最新 SDK 完整版本号（如 `10.0.22621.0`），而非裸 `10.0`。 |
| **依赖按需解析** | 不预设任何第三方库版本/路径。编译失败时再触发解析：先在工程目录树自动搜索，找不到或有歧义再向用户提问确认。 |
| **命令行编译** | 通过 vswhere 定位 MSBuild，自动修复 `PATH/Path` 冲突，命令行完成构建。 |
| **测试工程支持** | 生成动态加载 DLL（`LoadLibrary`/`GetProcAddress`）并验证导出符号的测试工程。 |
| **可复用构建脚本** | 附带 `scripts/build.ps1`，独立于 AI 助手也能直接跑构建与部署。 |

---

## 工程约定（Conventions）

| 项目 | 约定 |
|------|------|
| 头文件 | `.hpp` |
| 源文件 | `.cc` |
| 解决方案 | `{name}.sln`（格式 12.00，VS 版本随安装环境自适应） |
| 工程文件 | `{name}.vcxproj` |
| 工具集 | **自适应** —— vswhere 探测，取最新已装（v143/v142/v141） |
| Windows SDK | **自适应** —— 取最新已装完整版本号 |
| 平台 | x64 |
| C++ 标准 | C++17（Debug）/ C++20（Release） |
| 输出目录 | 相对 `.sln` 的 `bin\x64\{Config}\` |
| 头文件目录 | `include/`（公开）、`src/`（内部）、工程根目录 |
| 第三方依赖 | **不硬编码**，缺失时按需解析（见阶段 3b） |

---

## 工作流阶段（Phases）

```
Phase 0   需求与设计      —— 读现有结构、确定导出 API、列出依赖名（不猜版本）、产出设计说明
Phase 0a  探测构建环境    —— vswhere 枚举 VS、映射工具集、读注册表取最新 SDK
Phase 1   代码生成        —— 生成 .hpp/.cc，#pragma once，纯 ASCII 英文注释，登记到 .vcxproj
Phase 2   VS 解决方案配置 —— 创建/插入 .vcxproj 与 .sln，配置 GUID、输出目录、ProjectReference
Phase 3   命令行编译      —— vswhere 定位 MSBuild，修复 PATH 冲突，执行 Build/Rebuild
Phase 3b  依赖自适应解析  —— C1083/LNK2019 触发：先工程树自动搜索，再交互确认，写回 .vcxproj
Phase 4   部署与测试      —— 校验产物、拷贝到部署目录、动态加载 DLL 跑测试
```

### Phase 0a：环境探测要点

```powershell
# 取最新 VS 安装路径与版本
$ver = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
    -latest -products * -property installationVersion   # 例：17.x / 16.x / 15.x

# 主版本号 -> PlatformToolset
$toolset = switch (($ver -split '\.')[0]) { 17 {'v143'} 16 {'v142'} 15 {'v141'} default {'v143'} }

# 从注册表取最新已装 Windows SDK
$roots = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
$sdk = (Get-ChildItem (Join-Path $roots.KitsRoot10 'Lib') -Directory |
        Sort-Object Name -Descending | Select-Object -First 1).Name   # 例：10.0.22621.0
```

> 对已声明 `PlatformToolset` 的既有工程：优先尊重其声明；仅当出现 `MSB8036`（SDK 未找到）/ `MSB8020`（构建工具未找到）时，才回退到探测出的工具集/SDK。

### Phase 3b：依赖解析的两条路径

触发条件：编译命中**未声明**的第三方头文件（`C1083`）或**未解析**的第三方符号（`LNK2019`/`LNK1120`）。

- **路径 A — 工程树自动搜索（优先，非交互）**
  从解决方案根目录按文件名、再按 include 相对路径搜索头文件；扫描 `.lib` 并按符号命名空间/前缀缩小范围（如 `cv::` → `opencv_world*.lib`），歧义时用 `dumpbin /symbols` 确认。把发现的目录写入 `<AdditionalIncludeDirectories>`、库写入 `<AdditionalDependencies>` 后重建。
- **路径 B — 交互确认（自动搜索无果或有歧义时）**
  携带自动搜索结果作为上下文，仅就「头文件 include 目录」「提供符号的 .lib 文件及目录」向用户提问，应用回答后重建，并在会话内记住路径避免重复提问。

> **绝不**臆造 `C:\opencv\4.5.5\...` 这类带版本号的路径，也不硬编码 `opencv_world455.lib`。只用「探测到」或「用户确认」的路径。

---

## 目录结构

```
cpp-dev-flow/
├── SKILL.md                              # Skill 主文件：阶段、约定、规则（AI 助手读取的入口）
├── README.md                             # 本文档
├── agents/
│   └── openai.yaml                       # Agent 接口元信息（显示名、简介、默认提示词）
├── references/
│   ├── vs-project-config.md              # VS 工程 XML 模板（自适应工具集/SDK）、sln 格式、部署后处理
│   ├── msbuild-reference.md              # MSBuild 命令、参数、环境绕坑、故障排查
│   └── dependency-resolution.md          # 第三方头文件/符号自适应解析（OpenCV + OpenSSL 完整示例）
└── scripts/
    └── build.ps1                         # 可复用构建脚本：自动探测 MSBuild/工具集/SDK，构建并可选部署
```

---

## 直接使用构建脚本

`scripts/build.ps1` 可脱离 AI 助手单独运行，自动探测工具链、修复 PATH 冲突、构建并可选部署：

```powershell
# 最简：Release / x64
./scripts/build.ps1 -SolutionPath "D:\path\to\YourSolution.sln"

# 指定配置并部署到运行目录
./scripts/build.ps1 -SolutionPath "D:\path\to\YourSolution.sln" `
    -Configuration Release -Platform x64 `
    -DeployDir "D:\path\to\RunEnvBin_x64"

# 临时覆盖自动探测的工具集 / SDK
./scripts/build.ps1 -SolutionPath ".\YourSolution.sln" -ForceToolset v142 -ForceSdk 10.0.19041.0
```

| 参数 | 说明 | 默认 |
|------|------|------|
| `-SolutionPath` | `.sln` 路径（必填） | —— |
| `-Configuration` | `Release` / `Debug` | `Release` |
| `-Platform` | 目标平台 | `x64` |
| `-DeployDir` | 部署目录，给定则把产物拷贝过去 | 空 |
| `-ExtraMsBuildArgs` | 附加 MSBuild 参数 | 空 |
| `-ForceToolset` | 覆盖自动探测的工具集（如 `v142`） | 自动探测 |
| `-ForceSdk` | 覆盖自动探测的 SDK 版本 | 自动探测 |

---

## 常见编译错误速查

| 错误 | 处理方式 |
|------|----------|
| `C2679 binary '='` | 容器类型嵌套层级不匹配 → 增加 `unordered_map`/`vector` 的嵌套层级 |
| `C2280 deleted function` | `operator[]` 要求值类型可默认构造 → 改用 `insert_or_assign` |
| `FARPROC*` vs `FARPROC` | `GetProcAddress` 结果成员应为 `FARPROC`（函数指针），而非 `FARPROC*` |
| `C1083 找不到头文件` | 进入 Phase 3b 解析，**不要猜路径/版本** |
| `LNK2019` / `LNK1120` | 进入 Phase 3b 解析，**不要猜 lib/版本** |
| `MSB6001: CL.exe` | 构建前执行 `Remove-Item Env:\PATH`（PATH/Path 重复键冲突） |
| `MSB8036` / `MSB8020` | 回退到探测出的工具集/SDK |

---

## 文件编辑可靠性约定

- 小范围精准修改优先用 `apply_patch`。
- 新建文件或批量替换用 Python `with open(...)`。
- 纯 ASCII 内容才用 PowerShell `Set-Content`。
- **含 CJK 字符或 XML/Python 三引号等富引号内容时，避免 PowerShell heredoc（`@'...'@`）** —— 会破坏 UTF-8 字节。
- 修复乱码中文注释用「Python 按行号索引替换」，而非文本匹配。

---

## 适用场景

当你需要让 AI 助手完成以下任意一项时，本 Skill 会被触发：

1. 根据需求新建一个 C++ DLL 或测试工程；
2. 搭建带正确工程引用的 Visual Studio 解决方案；
3. 通过 MSBuild 命令行编译；
4. 解决缺失的第三方 include/lib 依赖；
5. 把编译产物部署到运行目录；
6. 新增动态加载并验证 DLL 导出符号的测试工程。

---

## License

未声明开源协议；如需对外分发请补充 LICENSE 文件。
