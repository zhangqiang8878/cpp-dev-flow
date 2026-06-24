# Adaptive Third-Party Dependency Resolution

This skill ships **no** preset third-party library versions or paths. Every external dependency (OpenCV, OpenSSL, MuPDF, Poppler, ONNX Runtime, etc.) is resolved on demand only when a build fails because of it.

## When to enter this flow

Enter this flow when the build emits either of:

- **`C1083: Cannot open include file '<header>.h'`** — a third-party header is used but its include directory is not declared.
- **`LNK2019: unresolved external symbol <symbol>`** / **`LNK1120: N unresolved externals`** — a third-party function is called but the providing `.lib` is not linked.

Do **not** enter this flow for:
- Standard library / compiler-internal headers (`<vector>`, `<windows.h>` basics) — those come with the toolset.
- Symbols from a sibling project in the same solution — fix with `<ProjectReference>`, not external libs.

## Resolution order

### Path A — Auto-search the project tree (try first)

Search from the solution root. Common roots in this repo: `RunEnvInclude/`, `RunEnvLib_x64/`, `ThirdDepends/`, `ThirdPDFLib/`. The auto-search never assumes a version — it discovers whatever is actually present.

**Missing header (`C1083`):**

```powershell
# 1. Find the header by basename anywhere under the solution
Get-ChildItem -Path $solutionRoot -Recurse -Filter 'opencv.hpp' -File -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

# 2. The include root is the directory ABOVE the first path segment.
#    e.g. found .../ThirdDepends/opencv/include/opencv2/opencv.hpp
#         -> include dir = ...\ThirdDepends\opencv\include
```

Add that directory to `<AdditionalIncludeDirectories>` in the failing project's `<ItemDefinitionGroup><ClCompile>`.

**Unresolved symbol (`LNK2019`/`LNK1120`):**

```powershell
# 1. List candidate .lib files in the tree
Get-ChildItem -Path $solutionRoot -Recurse -Filter '*.lib' -File -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

# 2. Narrow by likely name. The symbol's namespace/prefix usually hints at the lib:
#    cv:: / cv2::  -> opencv_world*.lib, opencv_*.lib
#    avcodec/avformat -> avcodec.lib, avformat.lib
#    mupdf::       -> libmupdf*.lib
#    BN_/SSL_/EVP_ -> libcrypto.lib, libssl.lib
Get-ChildItem -Path $solutionRoot -Recurse -Filter 'opencv_world*.lib' -File -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName

# 3. If ambiguous, confirm the symbol actually lives in a candidate lib.
#    Run from a Developer Command Prompt (or after vcvarsall.bat):
& dumpbin /symbols "C:\path\to\opencv_world.lib" | Select-String 'cv::imread'
```

Add the lib to `<AdditionalDependencies>` and, if it is not on the default lib search path, its directory to `<AdditionalLibraryDirectories>` inside `<Link>`.

### Path B — Interactive prompt (fallback)

If Path A finds nothing, or returns several conflicting candidates, stop and ask the user. Surface the auto-search results so the user can confirm or correct. Ask only what is still unknown — typically:

1. The **include directory** (absolute path) for the missing header, and/or
2. The **library file** plus its **directory** for the unresolved symbol.

Use a focused question (`AskUserQuestion` tool, or an inline numbered prompt). Example prompt shape:

> Build failed: `C1083: Cannot open include file: 'mupdf.h'`.
> Auto-search found no `mupdf.h` under the solution root.
> What is the absolute include directory that contains `mupdf/` (or `mupdf.h`)?

Apply the user's answer to the `.vcxproj` and rebuild. Record the resolved path(s) in the session note so the same dependency is not re-prompted.

## Where to apply the result in the .vcxproj

```xml
<ItemDefinitionGroup>
  <ClCompile>
    <!-- prepend detected include dirs; keep project-relative ones after -->
    <AdditionalIncludeDirectories>C:\Detected\Path\opencv\include;$(SolutionDir)include;$(SolutionDir)src;$(SolutionDir);%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
  </ClCompile>
  <Link>
    <AdditionalLibraryDirectories>C:\Detected\Path\opencv\lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
    <!-- list only libs that were detected or user-confirmed; never invent versioned names -->
    <AdditionalDependencies>opencv_world.lib;%(AdditionalDependencies)</AdditionalDependencies>
  </Link>
</ItemDefinitionGroup>
```

Use `%(AdditionalIncludeDirectories)` / `%(AdditionalDependencies)` (not the bare property name) when appending, so you do not overwrite values set elsewhere.

## Worked example

Symptom: `C1083: Cannot open include file: 'opencv2/opencv.hpp'`, then after adding the include, `LNK2019: unresolved external symbol "void __cdecl cv::imread(...)"`.

1. Auto-search:
   ```powershell
   Get-ChildItem -Path $solutionRoot -Recurse -Filter 'opencv.hpp' -File -ErrorAction SilentlyContinue | Select -ExpandProperty FullName
   # -> D:\HXWork\HXDiffProject\ThirdDepends\opencv\include\opencv2\opencv.hpp
   # include dir = D:\HXWork\HXDiffProject\ThirdDepends\opencv\include
   ```
2. Add include dir → rebuild → now `LNK2019` on `cv::imread`.
3. Auto-search libs:
   ```powershell
   Get-ChildItem -Path $solutionRoot -Recurse -Filter 'opencv_world*.lib' -File -ErrorAction SilentlyContinue | Select -ExpandProperty FullName
   # -> D:\HXWork\HXDiffProject\ThirdDepends\opencv\lib\opencv_world.lib
   ```
4. Confirm symbol: `dumpbin /symbols opencv_world.lib | Select-String 'cv::imread'` → match.
5. Add `D:\...\opencv\lib` to `<AdditionalLibraryDirectories>` and `opencv_world.lib` to `<AdditionalDependencies>`. Rebuild → success.

No version number was assumed at any step — only the files actually present on disk were used.

## Anti-patterns to avoid

- ❌ Writing `opencv_world455.lib` or `C:\opencv\4.5.5\include` into a project file from memory.
- ❌ Pinning `OpenCV 4.5.5`, `MuPDF 1.25.2`, etc. in design docs. Note the library *name* only; the path is a build-time concern.
- ❌ Silently guessing a path and moving on — if auto-search is empty or ambiguous, ask the user (Path B).
- ❌ Overwriting `<AdditionalIncludeDirectories>` with `=`; always append with `;%(AdditionalIncludeDirectories)`.
