---
name: cpp-dev-flow
description: "Full C++ development workflow for DLL projects on Windows (x64). The compiler/toolset is auto-detected from the installed Visual Studio (v143/v142/v141) rather than hardcoded. Covers requirements analysis, design docs, code generation (.hpp/.cc), VS solution/project (.sln/.vcxproj) configuration, MSBuild command-line compilation, adaptive third-party dependency resolution (interactive or project-tree auto-search for missing headers/unresolved symbols), and deployment. Use when the user wants to: (1) Create a new C++ DLL or test project from requirements, (2) Set up a Visual Studio solution with proper project references, (3) Compile through MSBuild command line, (4) Resolve missing third-party include/lib dependencies, (5) Deploy compiled outputs to a runtime directory, or (6) Add test projects that dynamically load and verify DLL exports."
---

# C++ Dev Flow

End-to-end C++ development workflow: requirements to deployed binary.

## Conventions

| Item | Convention |
|------|-----------|
| Headers | `.hpp` |
| Sources | `.cc` |
| Solution | `{name}.sln` (Format 12.00, VS Version adapts to installed VS) |
| Project | `{name}.vcxproj` |
| Toolset | **Adaptive** — detected via vswhere, picks latest installed (v143/v142/v141). Never hardcode. |
| Windows SDK | **Adaptive** — latest installed SDK version, not pinned to 10.0 |
| Platform | x64 |
| C++ std | C++17 (Debug) / C++20 (Release) |
| Output | `bin\x64\{Config}\` relative to `.sln` |
| Include dirs | `include/` (public), `src/` (internal), project root |
| Third-party deps | **Not hardcoded.** Resolved on-demand when a missing header or unresolved symbol appears (see Phase 3b). |

## Phases

### Phase 0: Requirements & Design

Before writing code:

1. Read the existing project structure: headers in `include/`, sources in `src/`, configs in `config/`
2. Identify the public API surface (functions/types to export from DLL)
3. Identify dependencies — do **not** assume versions. Note only the *names* of libraries the code touches (e.g. "uses OpenCV", "uses OpenSSL"). Concrete include/lib paths are resolved later by the build/dependency phase, never guessed up front.
4. Produce a short design note covering: API signatures, new files, project dependency graph
5. When converting Chinese comments to English: use `python` with UTF-8 file I/O, NOT PowerShell heredocs (they corrupt CJK characters)

**Detect the build environment up front** (Phase 0a below) so generated `.vcxproj` files use the actually-installed toolset and SDK.

### Phase 0a: Detect Build Environment

Before generating project files, probe the machine for the installed toolchain. **Never assume VS 2022 / v143.** Use vswhere to enumerate installed Visual Studio instances and pick the latest; map its version to a `PlatformToolset`; list the installed Windows SDKs and pick the newest.

```powershell
# 1. Latest installed Visual Studio + its version
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
    -latest -products * -property installationPath
$ver = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
    -latest -products * -property installationVersion   # e.g. 17.x / 16.x / 15.x

# 2. Map VS major version -> PlatformToolset
$major = ($ver -split '\.')[0]
$toolset = switch ($major) { 17 {'v143'} 16 {'v142'} 15 {'v141'} default {'v143'} }

# 3. Newest installed Windows 10/11 SDK (read installed SDK versions from the registry)
$roots = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue
$sdk = if ($roots -and $roots.KitsRoot10) {
    (Get-ChildItem (Join-Path $roots.KitsRoot10 'Lib') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1).Name   # e.g. 10.0.22621.0
} else { '10.0' }
```

Apply the result:
- `PlatformToolset` = detected toolset (v143/v142/v141)
- `WindowsTargetPlatformVersion` = newest installed SDK full version string (e.g. `10.0.22621.0`), **not** a bare `10.0`
- `.sln` header: `# Visual Studio Version 17/16/15` and `VisualStudioVersion` matching the detected install

**For an existing `.vcxproj` that already declares a `PlatformToolset`**: respect it, but if the build fails with `error MSB8036: The Windows SDK version was not found` or `MSB8020: The build tools cannot be found`, fall back to the detected toolset/SDK rather than failing.

Keep the detected values in a small note (`toolset`, `sdk`, `vsVersion`) so every generated project file in this session reuses the same ones.

### Phase 1: Code Generation

Generate `.hpp` and `.cc` files following these rules:

- Public API headers go in `include/`, internal headers in `src/{module}/`
- Source files in `src/` with subdirectories by module (`core/`, `nodes/`, `utils/`)
- Use `#pragma once` for include guards
- Keep edits scoped; do not refactor unrelated code
- Add `ClCompile`/`ClInclude` entries to the `.vcxproj` for each new file
- Add ASCII-only English comments

**Inline comment replacement (when fixing garbled CJK)**:
Use Python line-index-based replacement, not text-based matching. PowerShell heredocs corrupt CJK UTF-8 bytes. Pattern:
```python
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()
replacements = {idx_0based: "// english comment"}
for idx, repl in replacements.items():
    indent = lines[idx][:len(lines[idx]) - len(lines[idx].lstrip())]
    lines[idx] = indent + repl + "\n"
```

**Common fixes for compilation errors**:
- `C2679 binary '='`: container type depth mismatch -> increase nesting level of `unordered_map` or `vector` type
- `C2280 deleted function`: `std::unordered_map::operator[]` requires default-constructible value -> use `insert_or_assign` instead
- `FARPROC*` vs `FARPROC`: struct member for `GetProcAddress` result should be `FARPROC` (function pointer), not `FARPROC*` (pointer-to-pointer)
- `C1083: Cannot open include file 'xxx.h'` (a third-party header not declared in the project) -> **do not guess a path or pin a version**. Enter Phase 3b to resolve the include interactively or via project-tree auto-search.
- `LNK2019: unresolved external symbol` / `LNK1120` (a third-party function symbol not linked) -> **do not guess a lib or version**. Enter Phase 3b to resolve the lib interactively or via project-tree auto-search.

### Phase 2: VS Solution Setup

**For a new project**: create `.vcxproj` with `ProjectGuid`, proper `ConfigurationType` (DynamicLibrary for DLL, Application for EXE), and correct `OutDir`/`IntDir`.

**For adding to existing solution**: insert project block and build configs into the `.sln` file. Each project needs a unique GUID.

See [references/vs-project-config.md](references/vs-project-config.md) for complete XML templates.

**Test project setup**:
- Place output in same directory as DLL (`$(SolutionDir)bin\$(Platform)\$(Configuration)\`)
- Use `<ProjectReference>` to ensure DLL builds first and links against its import library
- Test loads DLL dynamically via `LoadLibrary`/`GetProcAddress`
- Use synthetic OpenCV images for pipeline tests (no external assets needed)
- Skip pipeline tests gracefully when Init fails (missing AI models/config)

**When DLL has post-build xcopy to deploy dir**: the deploy directory write requires sandbox escalation (`require_escalated`).

### Phase 3: Compilation

Use MSBuild command line. Find MSBuild via vswhere first:

```powershell
$msbuild = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
```

**Key environment fix** before building:
```powershell
Remove-Item Env:\PATH -ErrorAction SilentlyContinue
```
This fixes the PATH/Path duplicate key error (`MSB6001: CL.exe`).

**Build command**:
```powershell
& $msbuild "Solution.sln" /p:Configuration=Release /p:Platform=x64 /v:minimal /m /t:Build
```

Use `/t:Rebuild` for clean rebuild. Set `timeout_ms` to at least 180000 (3 min).

See [references/msbuild-reference.md](references/msbuild-reference.md) for full command reference and troubleshooting.

**Sandbox**: use `sandbox_permissions: "require_escalated"` with `workdir` set to the `.sln` directory. Request a `prefix_rule` that covers MSBuild + solution path for future builds.

### Phase 3b: Resolve Missing Third-Party Dependencies (adaptive)

Triggered whenever a build fails on an **undeclared** third-party header (`C1083: Cannot open include file`) or an **unresolved** third-party symbol (`LNK2019`/`LNK1120`). The skill ships **no** preset third-party versions or paths — every dependency is resolved on demand.

Two resolution paths, tried in this order:

**Path A — Auto-search the project tree (try first, non-interactive):**
1. From the solution root, search for the missing header by basename, then by its include-relative path. Known roots to scan: `RunEnvInclude/`, `ThirdDepends/`, `ThirdPDFLib/`, plus any `**/include` dir. Example for `opencv2/opencv.hpp`:
   ```powershell
   Get-ChildItem -Path $solutionRoot -Recurse -Filter 'opencv.hpp' -File -ErrorAction SilentlyContinue | Select-Object -First 5 FullName
   ```
   The directory *containing* the `opencv2` folder is the include root.
2. For an unresolved symbol, scan the project tree for `.lib` files, then narrow by likely lib name (the symbol's namespace/prefix often matches a lib, e.g. `cv::` → `opencv_world*.lib`):
   ```powershell
   Get-ChildItem -Path $solutionRoot -Recurse -Filter '*.lib' -File -ErrorAction SilentlyContinue | Select-Object FullName
   ```
   When the owning lib is ambiguous, confirm with `dumpbin /symbols <lib.lib> | Select-String '<symbol-name>'` (run inside a Developer Command Prompt, or call `vcvarsall.bat` first).
3. Add the discovered include dir to `<AdditionalIncludeDirectories>` and the lib to `<AdditionalDependencies>` (with its `<AdditionalLibraryDirectories>` if the lib is not on the default lib path). Rebuild.

**Path B — Interactive prompt (when auto-search finds nothing or is ambiguous):**
Ask the user with a focused question (use the `AskUserQuestion` tool or an inline prompt). Provide the auto-search results as context so the user can confirm or correct. Ask only what is still unknown:
- the **include directory** for the missing header (absolute path), and/or
- the **library file** (and its directory) that provides the unresolved symbol.

Apply the user's answer to the `.vcxproj` `<ItemDefinitionGroup>` and rebuild. Remember the resolved path(s) in the session note so the same dependency isn't re-prompted.

**Never** invent a versioned path like `C:\opencv\4.5.5\...` or hardcode `opencv_world455.lib`. Only use paths that were detected (Path A) or confirmed by the user (Path B).

See [references/dependency-resolution.md](references/dependency-resolution.md) for the full worked example (OpenCV + OpenSSL) and the exact `<AdditionalIncludeDirectories>` / `<AdditionalDependencies>` XML to insert.

### Phase 4: Deployment & Testing

After successful compilation:

1. Verify output files exist in both `bin\x64\{Config}\` and deploy directory
2. For test EXE: copy/rename to deploy dir if needed (`Copy-Item` with escalation)
3. Confirm the test can find the DLL (same directory or PATH)

**Test execution flow**:
- If test runner is provided, execute it from the deploy directory
- The test loads DLL via `LoadLibrary`, resolves symbols, runs synthetic pipeline tests
- Expect env-dependent tests to skip gracefully when AI models are unavailable

## File editing reliability

- Prefer `apply_patch` for small targeted edits
- Use Python `with open(...)` for creating new files or bulk replacements
- Use PowerShell `Set-Content` only for pure ASCII content
- Avoid PowerShell heredocs (`@'...'@`) when content contains CJK characters or nested quote-rich strings (XML, Python triple-quotes)
- When `apply_patch` fails due to whitespace mismatch, fall back to PowerShell `-replace` on a single-line pattern and verify with `Select-String`
- For `.sln` files not tracked by git: reconstruct from scratch rather than using `git checkout`

## Bundled resources

- [references/vs-project-config.md](references/vs-project-config.md) — VS project XML templates (adaptive toolset/SDK), solution format, post-build deployment
- [references/msbuild-reference.md](references/msbuild-reference.md) — MSBuild commands, parameters, environment workarounds, troubleshooting
- [references/dependency-resolution.md](references/dependency-resolution.md) — Adaptive resolution of missing third-party headers/symbols (auto-search + interactive)
- [scripts/build.ps1](scripts/build.ps1) — Reusable build script that auto-detects MSBuild/toolset/SDK, builds, and optionally deploys
