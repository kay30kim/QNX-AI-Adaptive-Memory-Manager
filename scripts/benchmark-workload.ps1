param(
    [string]$Patterns = 'steady,burst,ramp',
    [string]$Seeds = '42,43,44',
    [int]$Repeats = 3,
    [int]$Warmups = 1,
    [int]$Requests = 200,
    [int]$Keys = 64,
    [int]$Bytes = 4096,
    [int]$IntervalMs = 1,
    [int]$SampleEvery = 20,
    [int]$PoolBlocks = 8,
    [uint32]$CacheBytes = 32768,
    [int]$TimeoutSeconds = 180,
    [switch]$SkipAI,
    [switch]$Plan,
    [string]$ReportOnly,
    [string]$OutputDir,
    [string]$PythonExe
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (!$PythonExe) { $PythonExe = $env:QNX_PYTHON }
$runtimeFile = Join-Path $repo '.build/python-runtime.txt'
if (!$PythonExe -and (Test-Path $runtimeFile)) { $PythonExe = (Get-Content $runtimeFile -Raw).Trim() }
if (!$PythonExe) {
    $candidate = Get-Command python.exe, python3.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*Microsoft\WindowsApps*' } | Select-Object -First 1
    if ($candidate) { $PythonExe = $candidate.Source }
}
if (!$PythonExe) { throw 'Install Python 3.9+ or supply -PythonExe <python.exe> (or set QNX_PYTHON).' }
$pythonArgs = @((Join-Path $PSScriptRoot 'workload_benchmark.py'))
if ($ReportOnly) {
    if ($Plan -or $OutputDir) { throw 'ReportOnly cannot be combined with Plan or OutputDir.' }
    $pythonArgs += @('--report-only', $ReportOnly)
} else {
    $pythonArgs += @('--patterns', $Patterns, '--seeds', $Seeds, '--repeats', "$Repeats", '--warmups', "$Warmups",
        '--requests', "$Requests", '--keys', "$Keys", '--bytes', "$Bytes", '--interval-ms', "$IntervalMs",
        '--sample-every', "$SampleEvery", '--pool-blocks', "$PoolBlocks", '--cache-bytes', "$CacheBytes", '--timeout', "$TimeoutSeconds")
    if ($SkipAI) { $pythonArgs += '--skip-ai' }
    if ($Plan) { $pythonArgs += '--plan' }
    if ($OutputDir) { $pythonArgs += @('--output-dir', $OutputDir) }
}
& $PythonExe @pythonArgs
exit $LASTEXITCODE
