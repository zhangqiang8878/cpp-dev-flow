# VS Solution & Project Configuration Reference

## File naming conventions

- Headers: `.hpp`
- Source files: `.cc` (not `.cpp`)
- Solution: `{ProjectName}.sln`
- Project: `{ProjectName}.vcxproj`

## Solution file format (.sln)

Visual Studio Version 17, Format Version 12.00. Each project needs a unique GUID.

```
Microsoft Visual Studio Solution File, Format Version 12.00
# Visual Studio Version 17
VisualStudioVersion = 17.0.31903.59
MinimumVisualStudioVersion = 10.0.40219.1
Project("{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}") = "ProjectName", "path\ProjectName.vcxproj", "{GUID-HERE}"
EndProject
Global
    GlobalSection(SolutionConfigurationPlatforms) = preSolution
        Debug|x64 = Debug|x64
        Release|x64 = Release|x64
    EndGlobalSection
    GlobalSection(ProjectConfigurationPlatforms) = postSolution
        {GUID}.Debug|x64.ActiveCfg = Debug|x64
        {GUID}.Debug|x64.Build.0 = Debug|x64
        {GUID}.Release|x64.ActiveCfg = Release|x64
        {GUID}.Release|x64.Build.0 = Release|x64
    EndGlobalSection
    GlobalSection(SolutionProperties) = preSolution
        HideSolutionNode = FALSE
    EndGlobalSection
EndGlobal
```

## Project file (.vcxproj) key settings

### Globals (toolset + SDK — adaptive)

Every `.vcxproj` opens with a Globals `PropertyGroup`. The `PlatformToolset` and `WindowsTargetPlatformVersion` here are **substituted from detection** (Phase 0a), never hardcoded:

```xml
<PropertyGroup Label="Globals">
  <VCProjectVersion>17.0</VCProjectVersion>
  <ProjectGuid>{NEW-GUID}</ProjectGuid>
  <RootNamespace>MyLib</RootNamespace>
  <WindowsTargetPlatformVersion>$(SDK_VER)</WindowsTargetPlatformVersion>   <!-- e.g. 10.0.22621.0 -->
  <PlatformToolset>$(TOOLSET)</PlatformToolset>                            <!-- v143 / v142 / v141 -->
</PropertyGroup>
```

### Dynamic library (DLL)

```xml
<PropertyGroup>
  <ConfigurationType>DynamicLibrary</ConfigurationType>
  <TargetName>MyLib</TargetName>
  <TargetExt>.dll</TargetExt>
  <OutDir>$(SolutionDir)bin\$(Platform)\$(Configuration)\</OutDir>
  <IntDir>$(SolutionDir)obj\$(ProjectName)\$(Platform)\$(Configuration)\</IntDir>
</PropertyGroup>
<ItemDefinitionGroup>
  <ClCompile>
    <LanguageStandard>stdcpp17</LanguageStandard>
    <MultiProcessorCompilation>true</MultiProcessorCompilation>
    <AdditionalIncludeDirectories>$(SolutionDir)include;$(SolutionDir)src;$(SolutionDir)</AdditionalIncludeDirectories>
    <PreprocessorDefinitions>HXAICOMPARE_EXPORTS;%(PreprocessorDefinitions)</PreprocessorDefinitions>
  </ClCompile>
  <Link><SubSystem>Windows</SubSystem></Link>
</ItemDefinitionGroup>
```

### Console application (Test EXE)

```xml
<PropertyGroup>
  <ConfigurationType>Application</ConfigurationType>
  <TargetName>MyTest</TargetName>
  <TargetExt>.exe</TargetExt>
  <OutDir>$(SolutionDir)bin\$(Platform)\$(Configuration)\</OutDir>
</PropertyGroup>
<ItemDefinitionGroup>
  <ClCompile>
    <LanguageStandard>stdcpp17</LanguageStandard>
    <MultiProcessorCompilation>true</MultiProcessorCompilation>
    <AdditionalIncludeDirectories>$(SolutionDir)include;$(SolutionDir)src;$(SolutionDir)</AdditionalIncludeDirectories>
  </ClCompile>
  <Link><SubSystem>Console</SubSystem></Link>
</ItemDefinitionGroup>
<ItemGroup>
  <ProjectReference Include="$(SolutionDir)MainProject.vcxproj">
    <Project>{MAIN-PROJECT-GUID}</Project>
  </ProjectReference>
</ItemGroup>
```

### Platform / Toolset defaults

Toolset and SDK are **not hardcoded**. They are detected at generation time (see SKILL.md "Phase 0a: Detect Build Environment") and substituted into the project XML below. The detected values come from vswhere + the installed Windows SDKs registry; pick the latest installed.

| Setting | Value |
|---------|-------|
| PlatformToolset | **detected** — latest installed: `v143` (VS 2022) / `v142` (VS 2019) / `v141` (VS 2017) |
| WindowsTargetPlatformVersion | **detected** — newest installed SDK full version (e.g. `10.0.22621.0`), never a bare `10.0` |
| CharacterSet | Unicode (Debug) / MultiByte (Release) |
| Platform | x64 |

When the detected toolset is not v143, also set the `.sln` header line and `VisualStudioVersion` accordingly:

| VS major | `.sln` line | `VisualStudioVersion` example | PlatformToolset |
|----------|-------------|-------------------------------|-----------------|
| 17 (2022) | `# Visual Studio Version 17` | `17.0.31903.59` | v143 |
| 16 (2019) | `# Visual Studio Version 16` | `16.0.32001.0` | v142 |
| 15 (2017) | `# Visual Studio Version 15` | `15.0.28307.0` | v141 |

If an existing project pins a toolset/SDK that is not installed, MSBuild emits `MSB8036` (SDK not found) or `MSB8020` (build tools not found). Do not fail — substitute the detected toolset/SDK and rebuild.

#### Detection snippet (PowerShell)

```powershell
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$ver = & $vswhere -latest -products * -property installationVersion   # 17.x / 16.x / 15.x
$major = ($ver -split '\.')[0]
$toolset = switch ($major) { 17 {'v143'} 16 {'v142'} 15 {'v141'} default {'v143'} }
# Newest installed Windows SDK full version
$sdk = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
$sdkVer = if ($sdk) { (Get-ChildItem (Join-Path $sdk 'Lib') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1).Name } else { '10.0' }
```

Substitute `$(TOOLSET)` and `$(SDK_VER)` into the XML templates above.

### Include directory priorities

```
$(SolutionDir)include    # Public headers
$(SolutionDir)src        # Internal headers
$(SolutionDir)           # Project root
```

### Output directories

- DLL/EXE: `$(SolutionDir)bin\$(Platform)\$(Configuration)\`
- Obj/intermediates: `$(SolutionDir)obj\$(ProjectName)\$(Platform)\$(Configuration)\`

## Post-build deployment

To auto-copy outputs to a deploy directory, add PostBuildEvent:

```xml
<PostBuildEvent>
  <Command>xcopy /Y /D "$(OutDir)*.dll" "E:\DeployDir\" 2&gt;nul</Command>
</PostBuildEvent>
```

### Test project special config

- Place output in same directory as DLL for LoadLibrary compatibility
- Use `<ProjectReference>` to ensure DLL builds first
- Copy config files via PostBuildEvent to output dir
