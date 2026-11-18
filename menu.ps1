param([switch]$Check, [switch]$Snapshot, [switch]$NonInteractive, [switch]$Prepare, [string]$Run, [switch]$Serve)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$ConfigPath = Join-Path $Root 'qnx.local.json'
$Config = @{ Vm = 'noname'; Backend = 'auto'; QemuPid = 0; QemuExecutable = ''; QemuArguments = ''; QemuRamMiB = 0; Host = ''; User = 'qnxuser'; Port = 22; SdkEnv = "$env:USERPROFILE\qnx800\qnxsdp-env.bat"; GuestProbe = $true; GuestProbeSeconds = 0.5 }
if (Test-Path $ConfigPath) {
    $saved = Get-Content -Raw $ConfigPath | ConvertFrom-Json
    foreach ($property in $saved.PSObject.Properties) { $Config[$property.Name] = $property.Value }
}
$VBox = Join-Path ${env:ProgramFiles} 'Oracle\VirtualBox\VBoxManage.exe'
# LogLevel=ERROR hides client banners (e.g. the post-quantum key exchange warning) that would pollute captured output.
$SshOptions = @('-o', 'ConnectTimeout=3', '-o', 'MACs=hmac-sha2-512', '-o', 'LogLevel=ERROR')
$script:MetricsConfiguredFor = ''

function Get-Sources {
    @(Get-ChildItem (Join-Path $Root 'src') -Recurse -File -Include *.cpp,*.cc,*.cxx,*.c | Where-Object {
        (Get-Content -Raw -LiteralPath $_.FullName) -match '(?m)\bmain\s*\('
    } | Sort-Object FullName)
}
function Get-VmInfo {
    $info = @{}
    $backend = [string]$Config.Backend
    if ($backend -notin @('auto','virtualbox','qemu')) { return @{ Backend = 'invalid'; VMState = 'unknown' } }
    if ($backend -ne 'qemu' -and (Test-Path $VBox)) {
        $lines = & $VBox showvminfo $Config.Vm --machinereadable 2>$null
        foreach ($line in $lines) { if ($line -match '^([^=]+)="?([^"\r\n]*)"?$') { $info[$matches[1]] = $matches[2] } }
        if ($info.VMState -eq 'running' -or ($backend -eq 'virtualbox' -and $info.VMState)) { $info.Backend = 'virtualbox'; return $info }
    }
    if ($backend -ne 'virtualbox') {
        $qemus = @(Get-Process -Name 'qemu-system-*' -ErrorAction SilentlyContinue)
        if ([int]$Config.QemuPid -gt 0) { $qemus = @($qemus | Where-Object { $_.Id -eq [int]$Config.QemuPid }) }
        if ($qemus.Count -eq 1) { return @{ Backend = 'qemu'; VMState = 'running'; ProcessId = $qemus[0].Id; memory = $Config.QemuRamMiB } }
        if ($qemus.Count -gt 1) { return @{ Backend = 'qemu'; VMState = 'ambiguous' } }
        if ($backend -eq 'qemu') { return @{ Backend = 'qemu'; VMState = 'poweroff'; memory = $Config.QemuRamMiB } }
    }
    if ($info.VMState) { $info.Backend = 'virtualbox'; return $info }
    return @{ Backend = $backend; VMState = 'unknown' }
}
function Get-GuestAddress($info) {
    if ($Config.Host) { return [string]$Config.Host }
    if ($info.Backend -eq 'qemu') { return '' }
    if (-not $info.VMState -or $info.VMState -ne 'running') { return '' }
    $properties = & $VBox guestproperty enumerate $Config.Vm 2>$null
    foreach ($line in $properties) {
        if ($line -match '/VirtualBox/GuestInfo/Net/\d+/V4/IP, value: (\d+\.\d+\.\d+\.\d+)') { if ($matches[1] -ne '127.0.0.1' -and $matches[1] -ne '0.0.0.0') { return $matches[1] } }
    }
    if ($info.macaddress1 -and (Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue)) {
        $mac = ($info.macaddress1 -replace '(..)(?!$)', '$1-')
        $neighbor = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.LinkLayerAddress -eq $mac -and $_.State -ne 'Unreachable' } | Select-Object -First 1
        if ($neighbor) { return $neighbor.IPAddress }
    }
    return ''
}
function Get-ExternalMetrics($info) {
    if ($info.VMState -ne 'running') { return $null }
    if ($info.Backend -eq 'qemu') {
        $proc = Get-Process -Id ([int]$info.ProcessId) -ErrorAction SilentlyContinue
        if (-not $proc -or $proc.ProcessName -notlike 'qemu-system-*') { return $null }
        return @{ ResidentBytes = [long]$proc.WorkingSet64; ConfiguredBytes = [long]$Config.QemuRamMiB * 1MB; Source = 'Windows QEMU working set'; Pid = $proc.Id }
    }
    if ($info.Backend -eq 'virtualbox') {
        if ($script:MetricsConfiguredFor -ne $Config.Vm) {
            $catalog = & $VBox metrics list $Config.Vm RAM/Usage/Used 2>$null
            $configured = $false
            # Period 1 s is the shortest VirtualBox supports; the dashboard polls it twice per second.
            foreach ($line in $catalog) { if ($line -match 'RAM/Usage/Used\s+kB\s+\d+\s+\d+\s+(\d+)\s+') { $configured = [int]$matches[1] -eq 1 } }
            if (-not $configured) { & $VBox metrics setup --period 1 --samples 1 $Config.Vm RAM/Usage 2>$null | Out-Null }
            $script:MetricsConfiguredFor = $Config.Vm
        }
        $rows = & $VBox metrics query $Config.Vm RAM/Usage/Used 2>$null
        foreach ($row in $rows) {
            if ($row -match 'RAM/Usage/Used\s+([\d,]+)\s+kB') {
                $value = [long]($matches[1] -replace ',', '') * 1KB
                return @{ ResidentBytes = $value; ConfiguredBytes = [long]$info.memory * 1MB; Source = 'VirtualBox RAM/Usage/Used'; Pid = $null }
            }
        }
    }
    return $null
}

# --- Guest-side telemetry (runs pidin/top inside QNX over SSH; optional, see GuestProbe) ---
# One persistent SSH session runs this script, instead of reconnecting for every sample.
# - Memory: every GuestProbeSeconds (default 0.5 s = 2 Hz) a sample framed by @@BEGIN/@@END
#   with pidin info and the pidin mem lines of the programs uploaded by this menu.
#   Those are named /tmp/qnx-menu-<32 hex>; pidin %N keeps only the last 18 characters,
#   so they are found by their hexadecimal suffix and matched exactly on the host side.
# - CPU: QNX top cannot measure windows shorter than 1 s, so one top runs continuously in the
#   background of the same session and its per-core lines arrive tagged "@@CPU" once per second.
# The QNX commands behind each metric. They are defined once: the probe runs them and the
# interfaces display them, so what is shown is always what is measured.
#  - Ram:     exact page counters (hex page counts x getconf PAGESIZE). pidin's FreeMem is rounded to MB.
#  - Procs:   visible process and thread counts.
#  - Cpu:     per-core idle % over a 1 s window (busy = 100 - idle).
#  - Program: data/stack/heap of a program launched from the menu ({0} = pid).
$GuestCommands = [ordered]@{
    Ram     = "grep -E '^(page_count|pages_free)=' /proc/vm/stats"
    Procs   = 'pidin info'
    Cpu     = 'top -b -D 1 -z 5'
    Program = 'pidin -p {0} mem'
}
function Get-GuestProbeScript([double]$seconds) {
    $pause = [math]::Max(0.1, $seconds).ToString('0.0##', [Globalization.CultureInfo]::InvariantCulture)
    $hex8 = '[0-9a-f]' * 8
    $memory = 'echo PAGESIZE=$ps; ' + (Get-GuestMemoryCommand) + '; pidin -F "%a %N" | while read pid name; do case "$name" in *' + $hex8 + ') echo "@@PROC $pid $name"; ' +
        ($GuestCommands.Program -f '$pid') + ' | grep -E "^ *[0-9]|[*][*]heap";; esac; done'
    $cpu = $GuestCommands.Cpu + ' | while read line; do case "$line" in "CPU "*) echo "@@CPU $line";; esac; done &'
    return "ps=`$(getconf PAGESIZE); $cpu while :; do echo @@BEGIN; $memory; echo @@END; sleep $pause; done"
}
function Get-GuestMemoryCommand { return "$($GuestCommands.Procs) | head -2; $($GuestCommands.Ram)" }
# The host-side source of the VM host figure, as shown in the interfaces.
function Get-HostMetricCommand($info) {
    if ($info.Backend -eq 'qemu') { return "(Get-Process -Id $($info.ProcessId)).WorkingSet64" }
    if ($info.Backend -eq 'virtualbox') { return "VBoxManage metrics query $($Config.Vm) RAM/Usage/Used" }
    return ''
}
# Mean of per-core busy percentages, in decimal arithmetic (no binary rounding).
function Get-CpuMean($cores) {
    if (-not $cores.Count) { return $null }
    $sum = [decimal]0
    foreach ($value in $cores.Values) { $sum += [decimal]$value }
    return $sum / $cores.Count
}
# pidin prints sizes as bytes, K, M or G. Memory is allocated in pages (4 KiB), so a value in
# bytes or K is exact; M and G values are rounded by pidin and are not stored in the CSV.
function Test-ExactSize([string]$value) { return $value -match '^\d+K?$' }
# Parses a top per-core line ("CPU  0:     98.4% ...", idle %) into the busy percentage.
function ConvertFrom-CpuLine([string]$line) {
    if ($line -notmatch '^\s*CPU\s+(\d+):\s+(\d+(?:\.\d+)?)%') { return $null }
    # Decimal arithmetic keeps top's figure exact (100 - 92.7 = 7.3, not 7.299999...).
    $idle = [decimal]::Parse($matches[2], [Globalization.CultureInfo]::InvariantCulture)
    return @{ Core = $matches[1]; Busy = [math]::Max([decimal]0, [math]::Min([decimal]100, [decimal]100 - $idle)) }
}
function ConvertTo-Bytes([string]$value) {
    if ($value -notmatch '^(\d+(?:\.\d+)?)([KMG]?)B?$') { return $null }
    $units = @{ '' = 1; K = 1KB; M = 1MB; G = 1GB }
    return [long]([double]::Parse($matches[1], [Globalization.CultureInfo]::InvariantCulture) * $units[$matches[2]])
}
function ConvertFrom-GuestSample([string[]]$lines) {
    $sample = @{ Time = [datetime]::UtcNow; Cores = [ordered]@{}; Programs = @(); MemoryExact = $false }
    $current = $null; $pageSize = $null; $pages = @{}
    foreach ($raw in $lines) {
        $line = $raw -replace '\x1b\[[0-9;]*[A-Za-z]', ''
        if ($line -match '^PAGESIZE=(\d+)$') { $pageSize = [long]$matches[1] }
        elseif ($line -match '^(page_count|pages_free)=0x([0-9a-fA-F]+)') { $pages[$matches[1]] = [Convert]::ToInt64($matches[2], 16) }
        elseif ($line -match 'FreeMem:\s*(\S+?)\s*/\s*(\S+)') {
            if ($null -eq $sample.FreeBytes) { $sample.FreeBytes = ConvertTo-Bytes $matches[1]; $sample.TotalBytes = ConvertTo-Bytes $matches[2] }
        } elseif ($line -match '^Processes:\s*(\d+),\s*Threads:\s*(\d+)') {
            $sample.Processes = [int]$matches[1]; $sample.Threads = [int]$matches[2]
        } elseif ($cpu = ConvertFrom-CpuLine $line) {
            $sample.Cores[$cpu.Core] = $cpu.Busy
        } elseif ($line -match '^@@PROC (\d+) (\S+)') {
            $current = @{ Pid = [long]$matches[1]; Name = $matches[2]; HeapBytes = [long]0; HeapExact = $true; SizesExact = $false }
            $sample.Programs += $current
        } elseif ($current -and $line -match '\*\*heap\*\*.*\s(\S+)\s*$') {
            $heap = ConvertTo-Bytes $matches[1]
            if ($null -ne $heap) { $current.HeapBytes += $heap }
            if (-not (Test-ExactSize $matches[1])) { $current.HeapExact = $false }
        } elseif ($current -and $line -match '^\s*(\d+)\s+\d+\s.*\s(\S+)\s+(\S+)\s+(\S+?)(?:/\S+)?\s*$' -and [long]$matches[1] -eq $current.Pid) {
            $current.CodeBytes = ConvertTo-Bytes $matches[2]; $current.DataBytes = ConvertTo-Bytes $matches[3]; $current.StackBytes = ConvertTo-Bytes $matches[4]
            $current.DataExact = Test-ExactSize $matches[3]; $current.StackExact = Test-ExactSize $matches[4]
        }
    }
    if ($pageSize -and $pages.ContainsKey('page_count') -and $pages.ContainsKey('pages_free')) {
        # Exact: whole pages times the page size.
        $sample.TotalBytes = $pages.page_count * $pageSize; $sample.FreeBytes = $pages.pages_free * $pageSize; $sample.MemoryExact = $true
    }
    if ($null -eq $sample.FreeBytes -or -not $sample.TotalBytes) { return $null }
    $sample.UsedBytes = $sample.TotalBytes - $sample.FreeBytes
    $sample.UsedPercent = [math]::Round(100 * $sample.UsedBytes / $sample.TotalBytes, 1)   # display only
    if ($sample.Cores.Count) { $sample.CpuMean = Get-CpuMean $sample.Cores; $sample.CpuTime = $sample.Time }
    return $sample
}
function Test-GuestProbeEnabled { return [bool]$Config.GuestProbe -and $Config.User -match '^[a-zA-Z0-9_.-]+$' }
function Invoke-Guest([string]$address, [string]$command, [switch]$Interactive) {
    if ($address -notmatch '^[a-zA-Z0-9.:-]+$' -or $Config.User -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'Invalid SSH address or username.' }
    Write-Host "+ ssh -o MACs=hmac-sha2-512 -p $($Config.Port) $($Config.User)@$address $command" -ForegroundColor Cyan
    $batch = if ($Interactive) { @() } else { @('-o', 'BatchMode=yes') }
    & ssh @SshOptions @batch -p $Config.Port "$($Config.User)@$address" $command
    if ($LASTEXITCODE -ne 0) { throw "SSH failed (exit $LASTEXITCODE). Check the address, port and credentials." }
}
function Run-Source($source, [string]$address) {
    if (-not $address) { throw 'No guest IP detected. Set Host/Port with option C in the dashboard or in qnx.local.json.' }
    if ($address -notmatch '^[a-zA-Z0-9.:-]+$' -or $Config.User -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'Invalid SSH address or username.' }
    if (-not (Test-Path $Config.SdkEnv)) { throw "QNX SDP environment not found: $($Config.SdkEnv)" }
    if ($source.FullName -match '["\r\n%!]') { throw 'The source path contains characters incompatible with cmd.exe.' }
    $buildDir = Join-Path $Root '.build'; New-Item -ItemType Directory -Force $buildDir | Out-Null
    $exe = Join-Path $buildDir 'qnx-program'
    $batch = Join-Path $buildDir 'compile.cmd'
    if ($Config.SdkEnv -match '["\r\n%!]') { throw 'The SDK path contains characters incompatible with cmd.exe.' }
    $compiler = if ($source.Extension -eq '.c') { 'qcc' } else { 'q++' }
    @('@echo off', "call `"$($Config.SdkEnv)`" >nul", '@echo off', 'if errorlevel 1 exit /b 1', "$compiler -Vgcc_ntox86_64 -Wall -Wextra -static `"$($source.FullName)`" -o `"$exe`"", 'exit /b %errorlevel%') | Set-Content -Encoding ASCII $batch
    Write-Host "+ load SDK: $($Config.SdkEnv)" -ForegroundColor Cyan
    Write-Host "+ $compiler -Vgcc_ntox86_64 -Wall -Wextra -static `"$($source.FullName)`" -o `"$exe`"" -ForegroundColor Cyan
    & cmd.exe /d /c "`"$batch`""
    if ($LASTEXITCODE -ne 0) { throw 'Compilation failed.' }
    $remote = '/tmp/qnx-menu-' + [guid]::NewGuid().ToString('N')
    Write-Host "+ scp -o MACs=hmac-sha2-512 -P $($Config.Port) $exe $($Config.User)@${address}:$remote" -ForegroundColor Cyan
    $batchOption = if ($NonInteractive) { @('-o', 'BatchMode=yes') } else { @() }
    & scp @SshOptions @batchOption -P $Config.Port -- $exe "$($Config.User)@${address}:$remote"
    if ($LASTEXITCODE -ne 0) { throw 'SCP transfer failed.' }
    if ($Prepare) { Write-Output "QNX_PREPARED_PATH=$remote"; return }
    Invoke-Guest $address "chmod 700 $remote && $remote; result=`$?; rm -f $remote; exit `$result" -Interactive:(-not $NonInteractive)
}
if ($Run) {
    $info = Get-VmInfo; $address = Get-GuestAddress $info
    $srcRoot = [IO.Path]::GetFullPath((Join-Path $Root 'src')).TrimEnd('\') + '\'
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $Root $Run))
    if (-not $sourcePath.StartsWith($srcRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or [IO.Path]::GetExtension($sourcePath) -notin @('.cpp', '.cc', '.cxx', '.c')) { throw "Source not found inside src: $Run" }
    $source = Get-Item -LiteralPath $sourcePath
    Run-Source $source $address
    exit 0
}
if ($Check -or $Snapshot) {
    $info = Get-VmInfo
    $address = Get-GuestAddress $info
    Write-Output "VM: $($Config.Vm); backend: $($info.Backend); state: $($info.VMState); IP: $address"
    if ($Snapshot) {
        $metric = Get-ExternalMetrics $info
        if ($metric) { Write-Output "VM host resident: $([math]::Round($metric.ResidentBytes / 1MB)) MiB ($($metric.Source))" } else { Write-Output 'VM host resident: unavailable' }
        $guest = $null
        if ((Test-GuestProbeEnabled) -and $info.VMState -eq 'running' -and $address -match '^[a-zA-Z0-9.:-]+$') {
            # Quick one-shot: pidin info only (no top), so snapshots stay fast.
            $lines = @(& ssh -o BatchMode=yes -o ConnectTimeout=2 @SshOptions -p $Config.Port "$($Config.User)@$address" "echo PAGESIZE=`$(getconf PAGESIZE); $(Get-GuestMemoryCommand)" 2>$null)
            $guest = ConvertFrom-GuestSample $lines
        }
        if ($guest) { Write-Output ('Guest RAM: {0:N0}/{1:N0} MiB used ({2:N1}%), {3} procs visible (pidin)' -f ($guest.UsedBytes / 1MB), ($guest.TotalBytes / 1MB), $guest.UsedPercent, $guest.Processes) }
        elseif (-not (Test-GuestProbeEnabled)) { Write-Output 'Guest RAM: probe disabled (host-only mode)' }
        else { Write-Output 'Guest RAM: unavailable (SSH/pidin)' }
    }
    if ($Snapshot) { Write-Output '--- PROGRAMS ---' }
    Get-Sources | ForEach-Object { $_.FullName.Substring($Root.Length + 1) }
    exit 0
}
& (Join-Path $Root 'menus\dashboard.ps1')
