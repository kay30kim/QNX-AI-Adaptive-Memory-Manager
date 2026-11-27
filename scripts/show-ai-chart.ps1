param([string]$BatchPath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
' AI PREDICTION / SAVED RESULTS'
' Lower error (MAE) is better'
' AI control: not connected'
try {
    if (!$BatchPath) {
        $latest = Get-ChildItem -LiteralPath (Join-Path $repo 'measurements/benchmarks') -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'experiment.json') } |
            Sort-Object { (Get-Item -LiteralPath (Join-Path $_.FullName 'experiment.json')).LastWriteTimeUtc } -Descending |
            Select-Object -First 1
        if (!$latest) { ' No saved benchmark available'; return }
        $BatchPath = $latest.FullName
    }
    $manifestPath = Join-Path $BatchPath 'experiment.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.status -ne 'complete') { ' Latest batch incomplete'; ' No completed AI chart available'; return }
    $ai = Get-Content -LiteralPath (Join-Path $BatchPath 'ai/report.json') -Raw | ConvertFrom-Json
    ' Saved: ' + (Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc.ToString('MM-dd HH:mm') + ' UTC'
    foreach ($target in @('next_peak_owned_bytes', 'next_latency_p99_us')) {
        ''
        if ($target -eq 'next_peak_owned_bytes') { ' MEMORY prediction error (B)' }
        else { ' LATENCY prediction error (us)' }
        $values = @()
        foreach ($method in @('ridge', 'persistence', 'training_mean')) {
            $raw = $ai.metrics.$method.$target.mae
            $value = $null
            if ($null -ne $raw -and "$raw" -ne '') {
                $parsed = 0.0
                if ([double]::TryParse([string]$raw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and
                    ![double]::IsNaN($parsed) -and ![double]::IsInfinity($parsed) -and $parsed -ge 0) { $value = $parsed }
            }
            $values += $value
        }
        $max = ($values | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum
        $labels = @('AI', 'Last', 'Mean')
        for ($i = 0; $i -lt 3; $i++) {
            $value = $values[$i]
            if ($null -eq $value) { ' {0,-4} N/A' -f $labels[$i]; continue }
            $cells = if ($max -gt 0) { [int][math]::Floor(14 * $value / $max) } else { 0 }
            $bar = (([string][char]0x2588) * $cells).PadRight(14, [char]0x00B7)
            $tiny = if ($value -gt 0 -and $cells -eq 0) { '*' } else { '' }
            ' {0,-4} {1} {2}{3}' -f $labels[$i], $bar, $value.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture), $tiny
        }
    }
    ''
    ' Each chart: linear, 0 to max'
    ' * positive, less than one cell'
    ' Last = current value repeated'
    ' Mean = training average'
    ' Prediction, not memory savings'
    ' Small sample; see output notes'
    ' A refresh | M return to metrics'
} catch {
    ' AI chart unavailable'
    ' Missing or invalid saved files'
    ' See A output for batch details'
}
