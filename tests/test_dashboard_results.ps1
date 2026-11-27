$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$viewer = Join-Path $repo 'scripts/show-ai-status.ps1'
$fixture = Join-Path $repo ('.build/dashboard-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
function Require($condition, $message) { if (!$condition) { throw $message } }
$missing = (& $viewer -BatchPath $fixture) -join "`n"
Require ($missing -match 'Cannot read saved results' -and $missing -match 'NOT MEASURED') 'Missing files must not show success.'
'{"status":"running"}' | Set-Content (Join-Path $fixture 'experiment.json')
$incomplete = (& $viewer -BatchPath $fixture) -join "`n"
Require ($incomplete -match 'Batch incomplete' -and $incomplete -notmatch 'Measured runs:') 'Incomplete batch must not show completed statistics.'
'{"status":"complete","config":{"cache_bytes":8192,"pool_blocks":2}}' | Set-Content (Join-Path $fixture 'experiment.json')
'{"experiment_status":"complete","included_measurements":3,"complete_paired_repeats":1,"groups":[{"pattern":"steady","seed":42,"mode":"baseline","metrics":{"peak_owned_bytes":{"mean":4096},"latency_p99_us":{"mean":12},"throughput_rps":{"mean":100},"cache_hit_ratio":{"mean":null},"request_failures":{"mean":0}}}]}' | Set-Content (Join-Path $fixture 'report.json')
$saved = (& $viewer -BatchPath $fixture) -join "`n"
Require ($saved -match 'cache hit ratio=N/A' -and $saved -match 'peak payload=4096 B') 'Keep missing values distinct from zero and show recorded metrics.'
Require ($saved -match 'Offline AI evaluation: unavailable') 'Missing AI evaluation must be explicit.'
'broken json' | Set-Content (Join-Path $fixture 'report.json')
$broken = (& $viewer -BatchPath $fixture) -join "`n"
Require ($broken -match 'Cannot read saved results') 'Corrupt report must be explicit.'
# Exercise the actual dashboard action without starting SSH or the terminal loop.
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'menus/dashboard.ps1'), [ref]$null, [ref]$errors)
Require (!$errors) 'Dashboard must parse.'
$action = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-Action' }, $true)
Invoke-Expression $action.Extent.Text
$Root = $repo
$script:captured = New-Object 'System.Collections.Generic.List[string]'
function Start-LogSection {}
function Add-Log([string]$line) { $script:captured.Add($line) }
Start-Action 'A'
Require (($script:captured -join "`n") -match 'AI control: NOT CONNECTED') 'A must route to the results viewer.'
Require ($null -ne $script:aiChart -and $script:memoryOpen) 'A must open the chart panel.'
Start-Action 'M'
Require ($null -eq $script:aiChart) 'M must restore the guest/host panel.'
$chart = Join-Path $repo 'scripts/show-ai-chart.ps1'
New-Item -ItemType Directory -Path (Join-Path $fixture 'ai') -Force | Out-Null
'{"metrics":{"ridge":{"next_peak_owned_bytes":{"mae":5},"next_latency_p99_us":{"mae":0}},"persistence":{"next_peak_owned_bytes":{"mae":10},"next_latency_p99_us":{"mae":0}},"training_mean":{"next_peak_owned_bytes":{"mae":null},"next_latency_p99_us":{"mae":0}}}}' | Set-Content (Join-Path $fixture 'ai/report.json')
$bars = @(& $chart -BatchPath $fixture)
$solid = [regex]::Escape([string][char]0x2588)
Require (($bars -join "`n") -match "AI   $solid{7}") 'Half of maximum must fill seven cells.'
Require (($bars -join "`n") -match "Last $solid{14}") 'Maximum must fill fourteen cells.'
Require (($bars -join "`n") -match 'Mean N/A') 'Missing MAE must remain N/A.'
Require (($bars -join "`n") -notmatch 'unavailable') 'All-zero chart must not divide by zero.'
Require (($bars | Where-Object { $_.Length -gt 32 }).Count -eq 0) 'Chart must fit minimum middle-panel width.'
Write-Output 'PASS: dashboard action, missing/corrupt/incomplete reports, missing metrics and AI state.'
$helpFunction = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-KeyHelp' }, $true)
Invoke-Expression $helpFunction.Extent.Text
$Config = @{ GuestProbe = $true }
$script:aiChart = @('chart')
$script:recording = $false
$help = @(Get-KeyHelp)
Require (($help -join "`n") -match 'Return to live memory panel') 'M help must describe leaving AI charts.'
Require (($help -join "`n") -match 'sampling OFF') 'P help must describe the next action.'
Require (($help | Where-Object { $_.Length -gt 34 }).Count -eq 0) 'Help must fit the narrow left column.'
$script:aiChart = $null
$script:memoryOpen = $false
$script:recording = $true
$Config.GuestProbe = $false
$help = (Get-KeyHelp) -join "`n"
Require ($help -match 'Show memory panel' -and $help -match 'sampling ON' -and $help -match 'Stop recording') 'Help must reflect panel, sampling and recording state.'
Write-Output 'PASS: contextual keyboard help and footer width.'
