param(
    [ValidateSet('Train', 'Evaluate', 'Predict')][string]$Action = 'Train',
    [string]$InputPath,
    [string]$OutputDir,
    [string]$ModelPath,
    [int]$Seed = 42,
    [double]$TestFraction = 0.25,
    [double]$Alpha = 1.0,
    [string]$PythonExe
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (!$InputPath) { $InputPath = Join-Path $repo 'measurements' }
if (!$PythonExe) { $PythonExe = $env:QNX_PYTHON }
$runtimeFile = Join-Path $repo '.build/python-runtime.txt'
if (!$PythonExe -and (Test-Path $runtimeFile)) { $PythonExe = (Get-Content $runtimeFile -Raw).Trim() }
if (!$PythonExe) {
    $candidate = Get-Command python.exe, python3.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*Microsoft\WindowsApps*' } | Select-Object -First 1
    if ($candidate) { $PythonExe = $candidate.Source }
}
if (!$PythonExe) { throw 'Install Python 3 or supply -PythonExe <python.exe> (or set QNX_PYTHON).' }
$pythonArgs = @((Join-Path $PSScriptRoot 'workload_ai.py'), $Action.ToLowerInvariant(), $InputPath)
if ($OutputDir) { $pythonArgs += @('--output-dir', $OutputDir) }
if ($Action -eq 'Train') {
    if ($ModelPath) { throw 'ModelPath is for Evaluate/Predict; Train creates a new model.' }
    $pythonArgs += @('--seed', "$Seed", '--test-fraction', $TestFraction.ToString([Globalization.CultureInfo]::InvariantCulture),
                     '--alpha', $Alpha.ToString([Globalization.CultureInfo]::InvariantCulture))
} else {
    if (!$ModelPath) { throw 'Evaluate/Predict requires -ModelPath <model.json>.' }
    if ($PSBoundParameters.ContainsKey('Seed') -or $PSBoundParameters.ContainsKey('TestFraction') -or $PSBoundParameters.ContainsKey('Alpha')) {
        throw 'Seed, TestFraction and Alpha are Train options.'
    }
    $pythonArgs += @('--model', $ModelPath)
}
& $PythonExe @pythonArgs
exit $LASTEXITCODE
