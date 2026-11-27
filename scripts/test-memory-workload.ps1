param([string]$PythonExe)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (!$PythonExe) { $PythonExe = $env:QNX_PYTHON }
$runtimeFile = Join-Path $repo '.build/python-runtime.txt'
if (!$PythonExe -and (Test-Path $runtimeFile)) {
    $savedPython = (Get-Content $runtimeFile -Raw).Trim()
    if (Test-Path -LiteralPath $savedPython) { $PythonExe = $savedPython }
}
if (!$PythonExe) {
    $candidate = Get-Command python.exe, python3.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*Microsoft\WindowsApps*' } | Select-Object -First 1
    if ($candidate) { $PythonExe = $candidate.Source }
}
if (!$PythonExe) { throw 'Install Python 3.10+ or supply -PythonExe <python.exe> (or set QNX_PYTHON). Windows Store aliases cannot run this test.' }
$version = & $PythonExe -c 'import sys; print(310 if sys.version_info >= (3,10) else 0)'
if ($LASTEXITCODE -ne 0 -or $version -notcontains '310') { throw 'A working Python 3.10+ interpreter is required.' }
Write-Output "Testing with Python: $PythonExe"
& $PythonExe (Join-Path $PSScriptRoot 'test-memory-workload.py')
exit $LASTEXITCODE
