param([string]$BatchPath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Format-Number($value) {
    if ($null -eq $value -or "$value" -eq '') { return 'N/A' }
    try {
        $number = [double]$value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return 'N/A' }
        return $number.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
    } catch { return 'N/A' }
}
Write-Output '=== AI / CACHE RESULTS (saved recordings, not live) ==='
Write-Output 'AI control: NOT CONNECTED. Runtime resize API: available.'
Write-Output 'AI memory savings: NOT MEASURED (static/rules/AI comparison pending).'
if (!$BatchPath) {
    $base = Join-Path $repo 'measurements/benchmarks'
    $latest = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'experiment.json') } |
        Sort-Object { (Get-Item -LiteralPath (Join-Path $_.FullName 'experiment.json')).LastWriteTimeUtc } -Descending |
        Select-Object -First 1
    if (!$latest) {
        Write-Output 'No saved benchmark. Run scripts/benchmark-workload.ps1 with QNX and SSH ready.'
        return
    }
    $BatchPath = $latest.FullName
}
try {
    $manifestPath = Join-Path $BatchPath 'experiment.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Write-Output "Batch: $BatchPath"
    Write-Output "Saved UTC: $((Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Output "Experiment status: $($manifest.status)"
    if ($manifest.status -ne 'complete') {
        Write-Output 'Batch incomplete: results are not presented as a completed comparison.'
        return
    }
    $report = Get-Content -LiteralPath (Join-Path $BatchPath 'report.json') -Raw | ConvertFrom-Json
    if ($report.experiment_status -ne 'complete' -or !$report.groups) { throw 'Missing or incomplete comparison report.' }
    Write-Output "Measured runs: $($report.included_measurements); matched triples: $($report.complete_paired_repeats)"
    Write-Output "Fixed cache budget: $(Format-Number $manifest.config.cache_bytes) B; pool cap: $(Format-Number $manifest.config.pool_blocks) blocks"
    Write-Output 'Runtime comparison: baseline / pool / cache (NOT AI control)'
    Write-Output 'Each row: mean across repeats for this pattern/seed/mode.'
    foreach ($group in $report.groups) {
        Write-Output "[$($group.pattern) seed=$($group.seed) $($group.mode)]"
        Write-Output ("  peak payload={0} B; p99={1} us; throughput={2} req/s" -f
            (Format-Number $group.metrics.peak_owned_bytes.mean),
            (Format-Number $group.metrics.latency_p99_us.mean),
            (Format-Number $group.metrics.throughput_rps.mean))
        Write-Output ("  cache hit ratio={0}; request failures={1}" -f
            (Format-Number $group.metrics.cache_hit_ratio.mean), (Format-Number $group.metrics.request_failures.mean))
    }
    Write-Output 'Payload is application-owned buffer memory, not QNX RAM or RSS.'
    Write-Output "Charts: $(Join-Path $BatchPath 'report.html')"
    $aiPath = Join-Path $BatchPath 'ai/report.json'
    if (!(Test-Path -LiteralPath $aiPath)) { Write-Output 'Offline AI evaluation: unavailable for this batch.'; return }
    $ai = Get-Content -LiteralPath $aiPath -Raw | ConvertFrom-Json
    Write-Output '--- OFFLINE AI PREDICTION: lower MAE is better ---'
    Write-Output "Training examples: $($ai.training_examples); held-out examples: $($ai.examples)"
    foreach ($target in @('next_peak_owned_bytes', 'next_latency_p99_us')) {
        $unit = if ($target -eq 'next_peak_owned_bytes') { 'B' } else { 'us' }
        Write-Output $target
        foreach ($method in @('ridge', 'persistence', 'training_mean')) {
            Write-Output "  $method MAE: $(Format-Number $ai.metrics.$method.$target.mae) $unit"
        }
    }
    Write-Output 'Persistence = next value equals current value. Training mean = constant prediction.'
    foreach ($warning in $ai.warnings) { Write-Output "Note: $warning" }
    Write-Output 'Prediction accuracy does not demonstrate memory savings.'
} catch {
    Write-Output "Cannot read saved results: $($_.Exception.Message)"
    Write-Output 'No efficiency conclusion is available. Check the batch files and regenerate its report.'
}
