# Builds the compiled front ends (Ratatui and FTXUI) into menus\bin.
# Third-party sources are cloned into .build (git-ignored) at pinned revisions.
param(
    [string[]]$Target = 'all',   # all, ratatui, ftxui; "-Target ratatui,ftxui" also works with powershell -File
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$Target = @($Target | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$unknown = @($Target | Where-Object { $_ -notin @('all', 'ratatui', 'ftxui') })
if ($unknown) { throw "Unknown target(s): $($unknown -join ', '). Use all, ratatui or ftxui." }
$Root = Split-Path -Parent $PSScriptRoot
$Menus = $PSScriptRoot
$Build = Join-Path $Root '.build'
$Bin = Join-Path $Menus 'bin'
$Deps = @{
    ftxui = @{ Url = 'https://github.com/ArthurSonzogni/FTXUI.git'; Commit = '5cfed50702f52d51c1b189b5f97f8beaf5eaa2a6' }  # v6.1.9
}
if ($Target -contains 'all') { $Target = @('ratatui', 'ftxui') }

function Invoke-Native([string]$file, [string[]]$arguments) {
    Write-Host "+ $file $($arguments -join ' ')" -ForegroundColor DarkCyan
    & $file @arguments
    if ($LASTEXITCODE -ne 0) { throw "$file failed (exit $LASTEXITCODE)" }
}
function Assert-Tool([string[]]$names) {
    $missing = @($names | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing) { throw "Missing tools on PATH: $($missing -join ', ')" }
}
function Get-Dependency([string]$name) {
    $dir = Join-Path $Build $name
    $dep = $Deps[$name]
    if (-not (Test-Path (Join-Path $dir '.git'))) {
        Invoke-Native git @('clone', '--quiet', $dep.Url, $dir)
    }
    $head = (& git -C $dir rev-parse HEAD).Trim()
    if ($head -ne $dep.Commit) {
        & git -C $dir cat-file -e "$($dep.Commit)^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { Invoke-Native git @('-C', $dir, 'fetch', '--quiet', 'origin', $dep.Commit) }
        Invoke-Native git @('-C', $dir, '-c', 'advice.detachedHead=false', 'checkout', '--quiet', $dep.Commit)
    }
    return $dir
}
function Build-CMake([string]$name, [string]$buildDir, [string[]]$defines) {
    $dir = Join-Path $Build $buildDir
    if ($Clean -and (Test-Path $dir)) { Remove-Item -Recurse -Force $dir }
    $configure = @('-S', (Join-Path $Menus $name), '-B', $dir, '-G', 'MinGW Makefiles', '-DCMAKE_BUILD_TYPE=Release') + ($defines | ForEach-Object { "-D$_" })
    Invoke-Native cmake $configure
    Invoke-Native cmake @('--build', $dir, '--target', "qnx-menu-$name", '-j', '4')
    $exe = Get-ChildItem -Path $dir -Recurse -Filter "qnx-menu-$name.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $exe) { throw "qnx-menu-$name.exe was not produced" }
    Copy-Item -LiteralPath $exe.FullName -Destination $Bin -Force
}

New-Item -ItemType Directory -Force $Build, $Bin | Out-Null
$results = [ordered]@{}
foreach ($name in $Target) {
    Write-Host "`n=== $name ===" -ForegroundColor Cyan
    try {
        switch ($name) {
            'ratatui' {
                Assert-Tool @('cargo')
                $env:CARGO_TARGET_DIR = Join-Path $Build 'ratatui-target'
                if (-not $env:CARGO_HTTP_TIMEOUT) { $env:CARGO_HTTP_TIMEOUT = '120' }
                if ($Clean) { Invoke-Native cargo @('clean', '--manifest-path', (Join-Path $Menus 'ratatui\Cargo.toml')) }
                # Run from the crate directory so menus\ratatui\.cargo\config.toml (static CRT) applies.
                Push-Location (Join-Path $Menus 'ratatui')
                try { Invoke-Native cargo @('build', '--release', '--locked') } finally { Pop-Location }
                Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR 'release\qnx-menu-ratatui.exe') -Destination $Bin -Force
            }
            'ftxui' {
                Assert-Tool @('git', 'cmake', 'mingw32-make', 'g++')
                $ftxui = (Get-Dependency 'ftxui').Replace('\', '/')
                Build-CMake 'ftxui' 'ftxui-app' @("FETCHCONTENT_SOURCE_DIR_FTXUI=$ftxui", 'FTXUI_BUILD_EXAMPLES=OFF', 'FTXUI_BUILD_DOCS=OFF', 'FTXUI_BUILD_TESTS=OFF')
            }
        }
        $results[$name] = 'OK'
    } catch {
        $results[$name] = "FAILED: $_"
        Write-Host "[$name] $_" -ForegroundColor Red
    }
}

Write-Host "`n=== Summary (menus\bin) ===" -ForegroundColor Cyan
foreach ($entry in $results.GetEnumerator()) {
    $color = if ($entry.Value -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ('  {0,-9} {1}' -f $entry.Key, $entry.Value) -ForegroundColor $color
}
if ($results.Values | Where-Object { $_ -ne 'OK' }) { exit 1 }
