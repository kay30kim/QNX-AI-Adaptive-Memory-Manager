# Interface selector: pick an interface, build it if it is missing or out of date, and run it.
#   .\menu-opciones.ps1                 interactive selector
#   .\menu-opciones.ps1 -Menu ratatui   launch one directly (builds it if needed)
#   .\menu-opciones.ps1 -Rebuild        rebuild every compiled interface and exit
param(
    [ValidateSet('dashboard', 'ratatui', 'ftxui')][string]$Menu,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Menus = Join-Path $Root 'menus'
$Bin = Join-Path $Menus 'bin'
$Options = @(
    @{ Key = 'dashboard'; Label = 'PowerShell dashboard (original)'; Lang = 'PowerShell' }
    @{ Key = 'ratatui';   Label = 'Ratatui (same layout as the original)'; Lang = 'Rust' }
    @{ Key = 'ftxui';     Label = 'FTXUI (same layout as the original)';   Lang = 'C++' }
)

function Get-MenuState([string]$key) {
    if ($key -eq 'dashboard') { return 'ready' }
    $exe = Join-Path $Bin "qnx-menu-$key.exe"
    if (-not (Test-Path -LiteralPath $exe)) { return 'not built' }
    $built = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $Menus $key) -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\target\\' })
    $sources += Get-Item -LiteralPath (Join-Path $Menus 'build.ps1')
    if (@($sources | Where-Object { $_.LastWriteTimeUtc -gt $built }).Count) { return 'out of date' }
    return 'ready'
}
function Invoke-Build([string[]]$targets) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Menus 'build.ps1') -Target ($targets -join ',')
    return $LASTEXITCODE -eq 0
}
function Start-Menu([string]$key) {
    if ($key -eq 'dashboard') { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'menu.ps1'); return }
    if ((Get-MenuState $key) -ne 'ready') {
        Write-Host "Building $key..." -ForegroundColor Cyan
        if (-not (Invoke-Build @($key))) {
            Write-Host "Could not build $key. Check the output above." -ForegroundColor Red
            if (-not (Test-Path -LiteralPath (Join-Path $Bin "qnx-menu-$key.exe"))) { return }
            Write-Host 'Using the previous executable.' -ForegroundColor Yellow
        }
    }
    $env:QNX_ROOT = $Root
    & (Join-Path $Bin "qnx-menu-$key.exe")
}

if ($Rebuild) { if (Invoke-Build @('all')) { exit 0 } else { exit 1 } }
if ($Menu) { Start-Menu $Menu; exit $LASTEXITCODE }

while ($true) {
    Clear-Host
    Write-Host ''
    Write-Host '  QNX CONTROL CENTER - interface selector' -ForegroundColor Cyan
    Write-Host '  ======================================================' -ForegroundColor DarkCyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $option = $Options[$i]; $state = Get-MenuState $option.Key
        $color = switch ($state) { 'ready' { 'Green' } 'out of date' { 'Yellow' } default { 'DarkGray' } }
        Write-Host ('  {0}. {1,-54}' -f ($i + 1), "$($option.Label) [$($option.Lang)]") -NoNewline -ForegroundColor White
        Write-Host $state -ForegroundColor $color
    }
    Write-Host '  ------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host '  R. Rebuild all interfaces    Q. Quit' -ForegroundColor Gray
    Write-Host '  Compiled interfaces work even when started outside the project root.' -ForegroundColor DarkGray
    $choice = (Read-Host '  Option').Trim().ToUpperInvariant()
    if ($choice -eq 'Q') { break }
    if ($choice -eq '') { continue }
    if ($choice -eq 'R') { [void](Invoke-Build @('all')); [void](Read-Host '  Press Enter to return'); continue }
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $Options.Count) {
        try { Start-Menu $Options[[int]$choice - 1].Key } catch { Write-Host "  Error: $_" -ForegroundColor Red; [void](Read-Host '  Press Enter to return') }
        continue
    }
    Write-Host '  Invalid option.' -ForegroundColor Yellow; Start-Sleep -Milliseconds 700
}
