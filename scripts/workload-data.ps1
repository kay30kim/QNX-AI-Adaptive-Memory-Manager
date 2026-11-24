param(
    [ValidateSet('Validate', 'Replay')][string]$Action = 'Validate',
    [string]$InputPath,
    [switch]$Latest,
    [double]$Speed = 0,
    [switch]$IncludeSummary,
    [switch]$AllowIncomplete,
    [string]$OutputPath,
    [string]$PythonExe
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if ($Latest -and $InputPath) { throw 'Use InputPath or Latest, not both.' }
if ($Latest) {
    $latestFile = Get-ChildItem (Join-Path $repo 'measurements/workload-*.csv') |
        Sort-Object LastWriteTimeUtc, FullName -Descending | Select-Object -First 1
    if (!$latestFile) { throw 'No workload CSV recordings found.' }
    $InputPath = $latestFile.FullName
}
if (!$InputPath) {
    if ($Action -eq 'Replay') { throw 'Replay requires -InputPath <file.csv> or -Latest.' }
    $InputPath = Join-Path $repo 'measurements'
}
if (!$PythonExe) { $PythonExe = $env:QNX_PYTHON }
$runtimeFile = Join-Path $repo '.build/python-runtime.txt'
if (!$PythonExe -and (Test-Path $runtimeFile)) { $PythonExe = (Get-Content $runtimeFile -Raw).Trim() }
if (!$PythonExe) {
    $candidate = Get-Command python.exe, python3.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*Microsoft\WindowsApps*' } | Select-Object -First 1
    if ($candidate) { $PythonExe = $candidate.Source }
}
if (!$PythonExe) { throw 'Install Python 3 or supply -PythonExe <python.exe> (or set QNX_PYTHON).' }
$pythonArgs = @((Join-Path $PSScriptRoot 'workload_data.py'), $Action.ToLowerInvariant(), $InputPath)
if ($AllowIncomplete) { $pythonArgs += '--allow-incomplete' }
if ($Action -eq 'Replay') {
    $pythonArgs += @('--speed', $Speed.ToString([Globalization.CultureInfo]::InvariantCulture))
    if ($IncludeSummary) { $pythonArgs += '--include-summary' }
    if ($OutputPath) { $pythonArgs += @('--output', $OutputPath) }
} elseif ($IncludeSummary -or $OutputPath -or $PSBoundParameters.ContainsKey('Speed')) {
    throw 'Speed, IncludeSummary and OutputPath are Replay options.'
}
& $PythonExe @pythonArgs
exit $LASTEXITCODE
