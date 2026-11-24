param(
    [ValidateSet('baseline', 'pool')][string]$Mode = 'baseline',
    [ValidateRange(1, 4096)][int]$PoolBlocks = 8,
    [ValidateSet('steady', 'burst', 'ramp')][string]$Pattern = 'steady',
    [uint32]$Seed = 42,
    [ValidateRange(1, 1000000)][int]$Requests = 1000,
    [ValidateRange(1, 1000000)][int]$Keys = 64,
    [ValidateRange(1, 16777216)][int]$Bytes = 65536,
    [ValidateRange(0, 1000)][int]$IntervalMs = 10,
    [ValidateRange(1, 1000000)][int]$SampleEvery = 100
)
$ErrorActionPreference = 'Stop'
$entry = Join-Path (Split-Path $PSScriptRoot -Parent) 'menu.ps1'
$workloadArgs = "--mode $Mode --pool-blocks $PoolBlocks --pattern $Pattern --seed $Seed --requests $Requests --keys $Keys --bytes $Bytes --interval-ms $IntervalMs --sample-every $SampleEvery"
& $entry -NonInteractive -Run 'src\workloads\memory_workload.cpp' -RunArgs $workloadArgs -MetricsCsv
