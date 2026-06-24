# MSBuild Command-Line Reference

## Finding MSBuild

Use vswhere to locate the MSBuild of the latest installed Visual Studio — this works for **any** VS version (2022/2019/2017), so the build adapts to the machine:
```powershell
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe
```

Typical paths (whichever is installed):
- `C:\Program Files\Microsoft Visual Studio\2022\<Edition>\MSBuild\Current\Bin\MSBuild.exe`
- `C:\Program Files (x86)\Microsoft Visual Studio\2019\<Edition>\MSBuild\Current\Bin\MSBuild.exe`
- `C:\Program Files (x86)\Microsoft Visual Studio\2017\<Edition>\MSBuild\15.0\Bin\MSBuild.exe`

## Detecting toolset + SDK (pass to MSBuild)

Detect the latest installed `PlatformToolset` and Windows SDK, then pass them explicitly so a project never fails because it pinned a version that isn't installed:

```powershell
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$ver = & $vswhere -latest -products * -property installationVersion
$major = ($ver -split '\.')[0]
$toolset = switch ($major) { 17 {'v143'} 16 {'v142'} 15 {'v141'} default {'v143'} }
$roots = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue
$sdk = (Get-ChildItem (Join-Path $roots.KitsRoot10 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
```

Then pass `/p:PlatformToolset=$toolset /p:WindowsTargetPlatformVersion=$sdk` on the build command. This overrides whatever the `.vcxproj` declares, so a project that pins a missing toolset/SDK still builds.


## Basic build commands

### Build entire solution
```powershell
& "path\to\MSBuild.exe" "Solution.sln" /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=$toolset /p:WindowsTargetPlatformVersion=$sdk /v:minimal /m
```

### Rebuild (clean + build)
```powershell
& "path\to\MSBuild.exe" "Solution.sln" /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=$toolset /p:WindowsTargetPlatformVersion=$sdk /v:minimal /m /t:Rebuild
```

### Build single project
```powershell
& "path\to\MSBuild.exe" "Project.vcxproj" /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=$toolset /p:WindowsTargetPlatformVersion=$sdk /v:minimal
```

## Key parameters

| Parameter | Description |
|-----------|-------------|
| `/p:Configuration=Release` | Build configuration (Debug/Release) |
| `/p:Platform=x64` | Target platform |
| `/v:minimal` | Verbosity (quiet/minimal/normal/detailed/diagnostic) |
| `/m` | Multi-processor build |
| `/t:Build` | Target (Build/Rebuild/Clean) |
| `/p:OutDir=path\` | Override output directory |
| `/p:TargetName=name` | Override output filename |
| `/p:PlatformToolset=v143` | Override toolset (use detected value: v143/v142/v141) |
| `/p:WindowsTargetPlatformVersion=10.0.x.0` | Override Windows SDK (use detected newest SDK) |

## Environment workaround: PATH/Path conflict

When running MSBuild outside the VS Developer Command Prompt, the environment may have both `PATH` and `Path` variables, causing:
```
error MSB6001: "CL.exe" ... System.ArgumentException: Item has already been added.
Key in dictionary: 'PATH' Key being added: 'Path'
```

**Fix**: Remove the uppercase `PATH` before invoking MSBuild:
```powershell
Remove-Item Env:\PATH -ErrorAction SilentlyContinue
```

## Escalation note

When deploying to directories outside the sandbox workspace (e.g., `E:\DeployDir`), use `require_escalated` sandbox mode.

When the SLN file is not tracked by git (e.g., part of a Git worktree), avoid using `git checkout` to revert it. Instead use PowerShell to reconstruct it.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `C2280: attempting to reference deleted function` | Type lacks default constructor for container op[] | Use `insert_or_assign` instead of `operator[]` |
| `C2679: binary '=': no operator found` | Type mismatch in assignment | Verify nested container type levels |
| `C2440: cannot convert FARPROC to FARPROC*` | Struct member declared as pointer-to-fnptr instead of fnptr | Change `FARPROC*` to `FARPROC` |
| `MSB6001: invalid command line switch for CL.exe` | Duplicate PATH env vars | Remove `$env:PATH` before MSBuild |
| `MSB8036: The Windows SDK version X was not found` | Project pinned an SDK that isn't installed | Pass `/p:WindowsTargetPlatformVersion=<detected>` |
| `MSB8020: The build tools cannot be found` | Project pinned a toolset that isn't installed | Pass `/p:PlatformToolset=<detected>` (v143/v142/v141) |
| `C1083: Cannot open include file '<h>.h'` | Third-party header not declared | Resolve via Phase 3b — auto-search or interactive (see dependency-resolution.md) |
| `LNK2019 / LNK1120 unresolved external symbol` | Third-party lib not linked | Resolve via Phase 3b — auto-search `.lib` / `dumpbin` or interactive |
| `error: pathspec did not match any file` | File not tracked by git | Use PowerShell to edit directly |
