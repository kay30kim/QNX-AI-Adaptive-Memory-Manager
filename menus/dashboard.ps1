# Invoked by menu.ps1, which supplies configuration and discovery functions.
# With menu.ps1 -Serve it runs headless as the engine of the compiled front ends
# (menus/ratatui, menus/ftxui): state frames go to stdout and commands come from stdin.
$script:serve = [bool]$Serve
$script:serveOut = $null
if (-not $script:serve -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
    Write-Host 'The dashboard requires an interactive terminal. Use menu.ps1 -Check for a non-interactive check.'
    return
}

$lines = New-Object 'System.Collections.Generic.List[string]'
$cache = @{}
$script:task = $null
$script:external = $null
$script:lastSample = $null
$script:info = @{}
$script:address = ''
$script:inputText = ''
$script:inputMode = 'command'
$script:focus = 'menu'
$script:programInput = ''
$script:configDraft = @{}
$script:page = 0
$script:logTop = $null
$script:logMaxTop = 0
$script:latestLogIndex = 0
$script:lastCommandIndex = $null
$script:maxPage = 0
$script:nextProbe = [datetime]::MinValue
$script:nextDiscovery = [datetime]::MinValue
$script:sources = @()
$script:treeMode = $false
$script:treeEntries = @()
$script:treeCursor = 0
$script:treeExpanded = @{}
$script:treeExpanded[(Join-Path $Root 'src')] = $true
$script:memoryOpen = $true
$script:memoryHistory = New-Object 'System.Collections.Generic.List[double]'
$script:baselineUsed = $null
$script:peakUsed = $null
$script:currentUsed = $null
$script:lastUsedChange = $null
$script:historyTarget = ''
$script:recordPath = $null
$script:recording = $false
# Guest telemetry: one persistent SSH session sampling pidin/top inside QNX (toggle with P).
$script:guestProbe = $null
$script:guestLines = $null
$script:guest = $null
$script:guestHistory = New-Object 'System.Collections.Generic.List[double]'
$script:cpuHistory = New-Object 'System.Collections.Generic.List[double]'
$script:HistoryLimit = 240   # samples kept for the live charts (2 minutes at 2 Hz)
# Latest per-core CPU busy % from the background top in the probe session (updated once per second).
$script:guestCpu = [ordered]@{}
$script:guestCpuTime = [datetime]::MinValue
$script:guestNextStart = [datetime]::MinValue
$script:guestStatus = ''
# Program launched from this dashboard (/tmp/qnx-menu-<hex>) and its pidin memory figures.
$script:programRemote = ''
$script:programSource = ''   # src-relative path of the program launched from the menu (CSV 'program' column)
$script:program = $null
$script:programPeakData = $null
$script:programPeakHeap = $null

function Add-TreeEntries([string]$path, [int]$depth, $result) {
    foreach ($item in @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Sort-Object @{Expression={-not $_.PSIsContainer}}, Name)) {
        if ($item.PSIsContainer) {
            $expanded = $script:treeExpanded.ContainsKey($item.FullName) -and $script:treeExpanded[$item.FullName]
            $result.Add(@{ Path = $item.FullName; Name = $item.Name; Depth = $depth; Directory = $true; Expanded = $expanded })
            if ($expanded -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Add-TreeEntries $item.FullName ($depth + 1) $result }
        } else {
            $result.Add(@{ Path = $item.FullName; Name = $item.Name; Depth = $depth; Directory = $false; Cpp = ($item.Extension -ieq '.cpp') })
        }
    }
}
function Refresh-Tree {
    $list = New-Object 'System.Collections.Generic.List[object]'
    Add-TreeEntries (Join-Path $Root 'src') 0 $list
    $script:treeEntries = @($list.ToArray())
    $script:treeCursor = [math]::Max(0, [math]::Min($script:treeCursor, $script:treeEntries.Count - 1))
}
# One CSV row per QNX sample (2 Hz), or per host sample when no guest sample is available
# (probe off or SSH down). Only exact values; an empty cell means unavailable or only rounded.
function New-MeasurementRecord {
    $host_ = $script:external; $g = $script:guest; $p = $script:program
    $inv = [Globalization.CultureInfo]::InvariantCulture
    [PSCustomObject][ordered]@{
        timestamp_utc = $(if ($g) { $g.Time } else { [datetime]::UtcNow }).ToString('o')
        program = if ($script:programRemote) { $script:programSource } else { $null }
        guest_used_bytes = if ($g -and $g.MemoryExact) { $g.UsedBytes } else { $null }
        guest_free_bytes = if ($g -and $g.MemoryExact) { $g.FreeBytes } else { $null }
        guest_cpu_busy_percent = if ($g -and $null -ne $g.CpuMean) { ([decimal]$g.CpuMean).ToString('0.############', $inv) } else { $null }
        program_heap_bytes = if ($p -and $p.HeapExact) { $p.HeapBytes } else { $null }
        host_resident_bytes = if ($host_) { $script:currentUsed } else { $null }
    }
}
function Write-Measurement {
    if (-not $script:recording -or -not $script:recordPath -or -not ($script:external -or $script:guest)) { return }
    $csv = @(New-MeasurementRecord | ConvertTo-Csv -NoTypeInformation)
    try { [IO.File]::AppendAllText($script:recordPath, $csv[1] + "`r`n", [Text.Encoding]::UTF8) }
    catch { $script:recording = $false; Add-Log "[CSV recording failed: $_]" }
}
function Format-Size($bytes) {
    if ($null -eq $bytes) { return '?' }
    if ($bytes -lt 1MB) { return '{0:N0}K' -f ($bytes / 1KB) }
    return '{0:N1}M' -f ($bytes / 1MB)
}
# Splits a command into "$ ..." lines that fit the metrics column (continuation lines are indented).
function Split-CommandLine([string]$command, [int]$width) {
    if (-not $command) { return @() }
    $room = [math]::Max(8, $width - 3)
    $result = @(); $rest = $command
    while ($rest.Length) {
        $take = $rest.Length
        if ($take -gt $room) { $space = $rest.LastIndexOf(' ', $room); $take = if ($space -gt 0) { $space } else { $room } }   # break at a space when possible
        $result += $(if ($result.Count) { '   ' } else { ' $ ' }) + $rest.Substring(0, $take)
        $rest = $rest.Substring($take).TrimStart()
    }
    return $result
}
function Format-Sparkline($values) {
    $history = @($values)
    if (-not $history.Count) { return $null }
    $low = ($history | Measure-Object -Minimum).Minimum; $high = ($history | Measure-Object -Maximum).Maximum
    $chartLow = [math]::Max(0, [math]::Floor($low / 10) * 10); $chartHigh = [math]::Max($chartLow + 10, [math]::Ceiling($high / 10) * 10)
    $bars = -join @($history | ForEach-Object { [char](0x2581 + [math]::Min(7, [math]::Max(0, [int][math]::Floor(8 * ($_ - $chartLow) / ($chartHigh - $chartLow))))) })
    return @{ Bars = $bars; Low = $chartLow; High = $chartHigh }
}
function Set-GuestStatus([string]$status, [string]$message) {
    if ($script:guestStatus -eq $status) { return }
    $script:guestStatus = $status
    if ($message) { Add-Log $message }
}
function Stop-GuestProbe {
    $job = $script:guestProbe
    if ($job) { try { if (-not $job.process.HasExited) { $job.process.Kill() } } catch {}; $job.process.Dispose() }
    $script:guestProbe = $null; $script:guestLines = $null
    $script:guestCpu = [ordered]@{}; $script:guestCpuTime = [datetime]::MinValue
}
function Receive-GuestSample([string[]]$sampleLines) {
    $sample = ConvertFrom-GuestSample $sampleLines
    if (-not $sample) { return }
    # Memory arrives twice per second; CPU comes from the continuous top (once per second).
    if (-not $sample.Cores.Count -and $script:guestCpu.Count -and ([datetime]::UtcNow - $script:guestCpuTime).TotalSeconds -lt 5) {
        foreach ($core in $script:guestCpu.Keys) { $sample.Cores[$core] = $script:guestCpu[$core] }
        $sample.CpuMean = Get-CpuMean $sample.Cores; $sample.CpuTime = $script:guestCpuTime
    }
    $script:guest = $sample
    $script:guestHistory.Add($sample.UsedBytes / 1MB)
    while ($script:guestHistory.Count -gt $script:HistoryLimit) { $script:guestHistory.RemoveAt(0) }
    if ($null -ne $sample.CpuMean) {
        $script:cpuHistory.Add([double]$sample.CpuMean)
        while ($script:cpuHistory.Count -gt $script:HistoryLimit) { $script:cpuHistory.RemoveAt(0) }
    }
    $script:program = $null
    if ($script:programRemote) {
        foreach ($candidate in $sample.Programs) { if ($candidate.Name.Length -ge 8 -and $script:programRemote.EndsWith($candidate.Name)) { $script:program = $candidate } }
    }
    if ($script:program) {
        if ($null -ne $script:program.DataBytes -and ($null -eq $script:programPeakData -or $script:program.DataBytes -gt $script:programPeakData)) { $script:programPeakData = $script:program.DataBytes }
        if ($null -eq $script:programPeakHeap -or $script:program.HeapBytes -gt $script:programPeakHeap) { $script:programPeakHeap = $script:program.HeapBytes }
    }
    Write-Measurement
    Set-GuestStatus 'ok' '[guest probe: receiving pidin/top samples over SSH]'
}
function Poll-GuestProbe {
    $job = $script:guestProbe
    foreach ($stream in @('out', 'err')) {
        while ($job[$stream] -and $job[$stream].IsCompleted) {
            $value = $job[$stream].GetAwaiter().GetResult()
            if ($null -eq $value) { $job[$stream] = $null; break }
            if ($stream -eq 'out') {
                if ($value.StartsWith('@@CPU ')) {
                    $cpu = ConvertFrom-CpuLine $value.Substring(6)
                    if ($cpu) { $script:guestCpu[$cpu.Core] = $cpu.Busy; $script:guestCpuTime = [datetime]::UtcNow }
                }
                elseif ($value -eq '@@BEGIN') { $script:guestLines = New-Object 'System.Collections.Generic.List[string]' }
                # Compare with $null explicitly: an empty List is falsy in PowerShell.
                elseif ($value -eq '@@END') { if ($null -ne $script:guestLines) { Receive-GuestSample $script:guestLines.ToArray() }; $script:guestLines = $null }
                elseif ($null -ne $script:guestLines -and $script:guestLines.Count -lt 500) { $script:guestLines.Add($value) }
            } elseif ($value.Trim()) { $job.lastError = $value.Trim() }
            $reader = if ($stream -eq 'out') { $job.process.StandardOutput } else { $job.process.StandardError }
            $job[$stream] = $reader.ReadLineAsync()
        }
    }
    return ($job.process.HasExited -and -not $job.out -and -not $job.err)
}
function Update-GuestProbe {
    $ready = (Test-GuestProbeEnabled) -and $script:info.VMState -eq 'running' -and $script:address -match '^[a-zA-Z0-9.:-]+$'
    $job = $script:guestProbe
    if ($job -and (-not $ready -or $job.address -ne $script:address)) { Stop-GuestProbe; $job = $null }
    if ($job -and (Poll-GuestProbe)) {
        $code = $job.process.ExitCode; $detail = if ($job.lastError) { ": $($job.lastError)" } else { '' }
        Stop-GuestProbe
        Set-GuestStatus "stopped$code" "[guest probe stopped (exit $code)$detail; retrying in 10 s]"
        $script:guestNextStart = [datetime]::UtcNow.AddSeconds(10)
    } elseif (-not $job -and $ready -and [datetime]::UtcNow -ge $script:guestNextStart) {
        $seconds = [math]::Max(0.2, [double]$Config.GuestProbeSeconds)
        $args = "-o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o MACs=hmac-sha2-512 -o LogLevel=ERROR -p $($Config.Port) $($Config.User)@$($script:address) $(Quote-WindowsArgument (Get-GuestProbeScript $seconds))"
        $script:guestProbe = Start-Captured 'ssh.exe' $args
        $script:guestProbe.address = $script:address
        $script:guestNextStart = [datetime]::UtcNow.AddSeconds(10)
    }
    # Drop a stale sample so the panel never presents old figures as current.
    $maxAge = [math]::Max(10, 3 * [double]$Config.GuestProbeSeconds + 4)
    if ($script:guest -and ([datetime]::UtcNow - $script:guest.Time).TotalSeconds -gt $maxAge) { $script:guest = $null; $script:program = $null }
}

function ConvertTo-CleanText([string]$value) { return [regex]::Replace($value, '[\x00-\x08\x0B-\x1F\x7F]', '?').Replace("`t", '    ') }
function Get-LogKind([string]$clean) {
    # Same classification as the output colors in Render.
    if ($clean -match '^\s*(\+|> RUN)') { return 'cmd' }
    if ($clean -match '(?i)(error|failed|invalid|unavailable|exit(ed)?: [1-9])') { return 'err' }
    if ($clean -match '(?i)\[process exited: 0\]') { return 'ok' }
    return 'text'
}
function Add-Log([string]$line) {
    if ($null -eq $line) { return }
    if ($line -match '^\s*\+') { $script:lastCommandIndex = $lines.Count }
    if ($script:serveOut) { $clean = ConvertTo-CleanText $line; $script:serveOut.Write("@@LOG`t$(Get-LogKind $clean)`t$clean`n") }
    $lines.Add($line)
    while ($lines.Count -gt 2000) {
        $lines.RemoveAt(0); $script:latestLogIndex = [math]::Max(0, $script:latestLogIndex - 1)
        if ($null -ne $script:lastCommandIndex) { if ($script:lastCommandIndex -eq 0) { $script:lastCommandIndex = $null } else { $script:lastCommandIndex-- } }
    }
}
function Start-LogSection {
    $script:latestLogIndex = $lines.Count
    $script:lastCommandIndex = $null
    $script:logTop = $null
}
function Quote-WindowsArgument([string]$value) {
    # Preserve quotes and backslashes through Windows' native argument parser.
    return '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}
function Start-Captured([string]$file, [string]$arguments, [bool]$allowInput = $false) {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $file; $start.Arguments = $arguments
    $start.WorkingDirectory = $Root; $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "Failed to start $file" }
    if (-not $allowInput) { $process.StandardInput.Close() }
    $job = @{ process = $process; sample = New-Object 'System.Collections.Generic.List[string]'; input = $allowInput; kind = 'ordinary'; partial = ''; remote = '' }
    if ($allowInput) {
        $job.outBuffer = New-Object char[] 1024; $job.errBuffer = New-Object char[] 1024
        $job.out = $process.StandardOutput.ReadAsync($job.outBuffer, 0, $job.outBuffer.Length)
        $job.err = $process.StandardError.ReadAsync($job.errBuffer, 0, $job.errBuffer.Length)
    } else { $job.out = $process.StandardOutput.ReadLineAsync(); $job.err = $process.StandardError.ReadLineAsync() }
    return $job
}
function Start-Remote([string]$command) {
    $wrapped = "stty -echo 2>/dev/null; $command"
    $args = "-tt -o BatchMode=yes -o ConnectTimeout=3 -o MACs=hmac-sha2-512 -o LogLevel=ERROR -p $($Config.Port) $($Config.User)@$($script:address) $(Quote-WindowsArgument $wrapped)"
    $job = Start-Captured 'ssh.exe' $args $true
    $job.kind = 'interactive'
    return $job
}
function Poll-Captured($job) {
    if (-not $job) { return $false }
    foreach ($stream in @('out', 'err')) {
        while ($job[$stream] -and $job[$stream].IsCompleted) {
            $value = $job[$stream].GetAwaiter().GetResult()
            if ($job.input) {
                if ($value -eq 0) { $job[$stream] = $null; break }
                $buffer = if ($stream -eq 'out') { $job.outBuffer } else { $job.errBuffer }
                $chunk = -join $buffer[0..($value - 1)]
                $chunk = $chunk.Replace("`r", '')
                $parts = ($job.partial + $chunk).Split("`n")
                for ($i = 0; $i -lt $parts.Length - 1; $i++) { Add-Log $parts[$i] }
                $job.partial = $parts[$parts.Length - 1]
                if ($stream -eq 'out') { $job.out = $job.process.StandardOutput.ReadAsync($job.outBuffer, 0, $job.outBuffer.Length) }
                else { $job.err = $job.process.StandardError.ReadAsync($job.errBuffer, 0, $job.errBuffer.Length) }
                continue
            }
            if ($null -eq $value) { $job[$stream] = $null; break }
            if ($job.kind -eq 'prepare' -and $value -match '^QNX_PREPARED_PATH=(/tmp/qnx-menu-[0-9a-f]{32})$') { $job.remote = $matches[1] }
            else { Add-Log $value }
            $reader = if ($stream -eq 'out') { $job.process.StandardOutput } else { $job.process.StandardError }
            $job[$stream] = $reader.ReadLineAsync()
        }
    }
    if ($job.process.HasExited -and -not $job.out -and -not $job.err) {
        if ($job.input -and $job.partial) { Add-Log $job.partial; $job.partial = '' }
        $job.exitCode = $job.process.ExitCode
        if ($job.kind -ne 'prepare') { Add-Log "[process exited: $($job.exitCode)]" }
        $job.process.Dispose()
        return $true
    }
    return $false
}
function Start-Program([string]$path) {
        if ($script:task) { Add-Log '[a command is already running]'; return }
        $relative = $path.Substring($Root.Length + 1)
        if ($relative -match '["\r\n]') { Add-Log '[unsupported source path]'; return }
        Start-LogSection; Add-Log "> RUN $relative"; $script:programSource = $relative
        $ps = Join-Path $PSHOME 'powershell.exe'
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$Root\menu.ps1`" -NonInteractive -Prepare -Run `"$relative`""
        $script:task = Start-Captured $ps $args
        $script:task.kind = 'prepare'
}
function Start-Action([string]$choice) {
    if ($choice -eq '') { return }
    if ($choice -match '^\d+$') {
        $index = [int]$choice - 1
        if ($index -lt 0 -or $index -ge $script:sources.Count) { Add-Log '[invalid program number]'; return }
        Start-Program $script:sources[$index].FullName
        return
    }
    switch ($choice.ToUpperInvariant()) {
        'Q' { $script:quitting = $true }
        'I' {
            if ($script:task) { Add-Log '[a command is already running]'; return }
            if ($script:info.VMState -eq 'running') { Add-Log '[VM is already running]'; return }
            if ($script:info.Backend -eq 'qemu') {
                if (-not $Config.QemuExecutable -or -not (Test-Path -LiteralPath $Config.QemuExecutable)) { Add-Log '[configure QemuExecutable and QemuArguments in qnx.local.json]'; return }
                $launch = @{ FilePath = $Config.QemuExecutable; WindowStyle = 'Hidden'; PassThru = $true }
                if ($Config.QemuArguments) { $launch.ArgumentList = $Config.QemuArguments }
                $qemu = Start-Process @launch
                Start-LogSection; Add-Log "+ QEMU start: $($Config.QemuExecutable) $($Config.QemuArguments)"; Add-Log "[QEMU started: PID $($qemu.Id)]"
                $script:nextDiscovery = [datetime]::MinValue; return
            }
            if (-not (Test-Path $VBox)) { Add-Log '[VirtualBox not found]'; return }
            if ($Config.Vm -match '["\r\n]') { Add-Log '[invalid VM name]'; return }
            Start-LogSection; Add-Log "+ VBoxManage startvm $($Config.Vm) --type gui"
            $script:task = Start-Captured $VBox "startvm `"$($Config.Vm)`" --type gui"
            $script:nextDiscovery = [datetime]::MinValue
        }
        'M' {
            if ($script:serve) { return }   # the front end owns its layout
            $script:memoryOpen = -not $script:memoryOpen; $script:cache = @{}; [Console]::Clear()
            if ($script:memoryOpen -and [Console]::WindowWidth -lt 100) { Add-Log '[widen terminal to 100 columns to show metrics panel]' }
        }
        'H' {
            Start-LogSection
            if ($script:external) {
                Add-Log "[host view: $($script:external.Source), backend $($script:info.Backend)]"
                Add-Log "[VM host resident: $([math]::Round($script:external.ResidentBytes / 1MB, 1)) MiB]"
                if ($script:external.ConfiguredBytes -gt 0) { Add-Log "[configured guest RAM: $([math]::Round($script:external.ConfiguredBytes / 1MB)) MiB]" }
            } else { Add-Log '[VM host memory unavailable; check the hypervisor and selected VM.]' }
            if ($script:task) { Add-Log '[a command is already running; pidin details skipped]'; return }
            if ($script:address -notmatch '^[a-zA-Z0-9.:-]+$' -or $Config.User -notmatch '^[a-zA-Z0-9_.-]+$') { Add-Log '[guest address unavailable; pidin details skipped]'; return }
            # Guest view: one-off pidin run inside QNX (visibility limited to the SSH user's processes).
            Add-Log "+ ssh $($Config.User)@$($script:address) pidin info; pidin mem"
            $script:task = Start-Captured 'ssh.exe' "-o BatchMode=yes -o ConnectTimeout=3 -o MACs=hmac-sha2-512 -o LogLevel=ERROR -p $($Config.Port) $($Config.User)@$($script:address) `"pidin info; pidin mem`""
        }
        'P' {
            $Config.GuestProbe = -not [bool]$Config.GuestProbe
            $Config | ConvertTo-Json | Set-Content -Encoding UTF8 $ConfigPath
            if ($Config.GuestProbe) { $script:guestNextStart = [datetime]::MinValue; $script:guestStatus = ''; Add-Log '[guest probe ON: pidin/top run inside QNX over one SSH session]' }
            else { Stop-GuestProbe; $script:guest = $null; $script:program = $null; $script:guestStatus = 'off'; Add-Log '[guest probe OFF: host-only measurement, nothing runs inside QNX]' }
        }
        'V' {
            if ($script:task) { Add-Log '[a command is already running]'; return }
            Start-LogSection; Add-Log '[Host hypervisor diagnostics]'
            Add-Log "[VirtualBox: $(if (Test-Path $VBox) { 'installed' } else { 'not found' })]"
            $qemuProcesses = @(Get-Process -Name 'qemu-system-*' -ErrorAction SilentlyContinue)
            Add-Log "[QEMU processes running: $($qemuProcesses.Count)]"
            Add-Log "[Selected backend: $($script:info.Backend); state: $($script:info.VMState)]"
        }
        'T' { $script:treeMode = $true; $script:treeCursor = 0; Refresh-Tree }
        'G' {
            if ($script:recording) { $script:recording = $false; Add-Log "[CSV recording stopped: $($script:recordPath)]" }
            else {
                $dir = Join-Path $Root 'measurements'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
                $script:recordPath = Join-Path $dir ('qnx-metrics-' + [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.csv')
                [IO.File]::WriteAllText($script:recordPath, @(New-MeasurementRecord | ConvertTo-Csv -NoTypeInformation)[0] + "`r`n", [Text.Encoding]::UTF8)
                $script:recording = $true; Add-Log "[CSV recording started: $($script:recordPath)]"
            }
        }
        'S' {
            if ($script:task) { Add-Log '[a command is already running]'; return }
            if (-not $script:address) { Add-Log '[guest address unavailable]'; return }
            $script:inputMode = 'ssh'
        }
        'C' { $script:configDraft = @{}; $script:inputMode = 'host'; Add-Log '[configure connection in the left panel; Enter keeps the current value]' }
        '[' { $script:page = [math]::Max(0, $script:page - 1) }
        ']' { $script:page++ }
        default { Add-Log '[unknown option]' }
    }
}
function Submit-Input {
    $value = $script:inputText.Trim(); $script:inputText = ''
    switch ($script:inputMode) {
        'command' { Start-Action $value }
        'ssh' {
            if (-not $value) { $script:inputMode = 'command'; return }
            if ($script:task) { Add-Log '[a command is already running]'; $script:inputMode = 'command'; return }
            if ($script:address -notmatch '^[a-zA-Z0-9.:-]+$' -or $Config.User -notmatch '^[a-zA-Z0-9_.-]+$') { Add-Log '[invalid SSH address or username]'; $script:inputMode = 'command'; return }
            Start-LogSection; Add-Log "+ ssh $($Config.User)@$($script:address) $value"
            $script:task = Start-Remote $value
            $script:inputMode = 'command'
        }
        'host' { $script:configDraft.Host = if ($value -eq '-') { '' } elseif ($value) { $value } else { $Config.Host }; $script:inputMode = 'user' }
        'user' { $script:configDraft.User = if ($value) { $value } else { $Config.User }; $script:inputMode = 'port' }
        'port' {
            if ($value -and ($value -notmatch '^\d+$' -or [int]$value -lt 1 -or [int]$value -gt 65535)) { Add-Log '[invalid SSH port]'; return }
            $script:configDraft.Port = if ($value) { [int]$value } else { $Config.Port }; $script:inputMode = 'vm'
        }
        'vm' {
            $script:configDraft.Vm = if ($value) { $value } else { $Config.Vm }
            if ($script:configDraft.User -notmatch '^[a-zA-Z0-9_.-]+$' -or ($script:configDraft.Host -and $script:configDraft.Host -notmatch '^[a-zA-Z0-9.:-]+$')) { Add-Log '[invalid host or SSH user; settings unchanged]'; $script:inputMode = 'command'; return }
            foreach ($key in $script:configDraft.Keys) { $Config[$key] = $script:configDraft[$key] }
            $Config | ConvertTo-Json | Set-Content -Encoding UTF8 $ConfigPath
            $script:inputMode = 'command'; $script:nextDiscovery = [datetime]::MinValue; Add-Log '[connection settings saved]'
        }
    }
}
function Get-PromptText {
    if ($script:treeMode) { return '  Tree: ' }
    switch ($script:inputMode) {
        'host' { '  Host/IP (- for auto): ' } 'user' { '  SSH user: ' }
        'port' { '  SSH port: ' } 'vm' { '  VM name: ' } 'ssh' { '  SSH command: ' } default { '  Select: ' }
    }
}
function Send-ProgramInput([string]$text) {
    try {
        if (-not $script:task -or -not $script:task.input -or $script:task.process.HasExited) { throw 'Program is no longer running.' }
        if ($script:task.partial) { Add-Log $script:task.partial; $script:task.partial = '' }
        $script:task.process.StandardInput.WriteLine($text)
        $script:task.process.StandardInput.Flush()
        Add-Log ('> ' + $text)
        return $true
    } catch { Add-Log "[input error: $_]"; return $false }
}
function Invoke-TreeKey([string]$key) {
    $entry = if ($script:treeEntries.Count -gt 0) { $script:treeEntries[$script:treeCursor] } else { $null }
    switch ($key) {
        'enter' {
            if (-not $entry) { return }
            if ($entry.Directory) { $script:treeExpanded[$entry.Path] = -not $entry.Expanded; Refresh-Tree }
            elseif ($entry.Cpp) { $script:treeMode = $false; try { Start-Program $entry.Path } catch { Add-Log "[error: $_]" } }
            else { Add-Log '[select a .cpp file to compile and run]' }
        }
        'up' { $script:treeCursor = [math]::Max(0, $script:treeCursor - 1) }
        'down' { $script:treeCursor = [math]::Min([math]::Max(0, $script:treeEntries.Count - 1), $script:treeCursor + 1) }
        'esc' { $script:treeMode = $false }
        'right' { if ($entry -and $entry.Directory) { $script:treeExpanded[$entry.Path] = $true; Refresh-Tree } }
        'left' { if ($entry -and $entry.Directory) { $script:treeExpanded[$entry.Path] = $false; Refresh-Tree } }
    }
}
function Render {
    $width = [Console]::WindowWidth; $height = [Console]::WindowHeight
    if ($width -lt 70 -or $height -lt 20) {
        [Console]::SetCursorPosition(0, 0); [Console]::Write('Expand terminal to at least 70 columns x 20 rows. Press Q then Enter to quit.'.PadRight([math]::Max(1, $width - 1)).Substring(0, [math]::Max(1, $width - 1)))
        $script:cache = @{}; return
    }
    $showMemory = $script:memoryOpen -and $width -ge 100
    $leftWidth = if ($showMemory) { [math]::Min(42, [math]::Max(34, [int]($width * 0.30))) } else { [math]::Min(60, [math]::Max(38, [int]($width * 0.46))) }
    $middleWidth = if ($showMemory) { [math]::Min(60, [math]::Max(32, [int]($width * 0.35))) } else { 0 }   # room for the command lines
    $rightWidth = $width - $leftWidth - 4 - $(if ($showMemory) { $middleWidth + 3 } else { 0 })
    $state = if ($script:info.VMState) { $script:info.VMState.ToUpperInvariant() } else { 'UNKNOWN' }
    $guest = if ($script:address) { $script:address } else { 'not detected' }
    $activity = if ($script:task) { 'BUSY' } else { 'READY' }
    $left = New-Object 'System.Collections.Generic.List[string]'
    $g = $script:guest
    $memoryColor = if ($g -and $g.UsedPercent -ge 90) { [ConsoleColor]::Red } elseif ($g -and $g.UsedPercent -ge 75) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Cyan }
    foreach ($item in @('    ___  _   _ __  __','   / _ \| \ | |\ \/ /','  | | | |  \| | \  /','  | |_| | |\  | /  \','   \__\_\_| \_|/_/\_\','  CONTROL CENTER',"  TARGET  $($Config.Vm)  |  $state","  ADDRESS $guest",'  ----------------------------------------')) { $left.Add($item) }
    if ($g) { $left.Add(('  QNX RAM  {0:N0}/{1:N0} MiB  {2:N0}%' -f ($g.UsedBytes / 1MB), ($g.TotalBytes / 1MB), $g.UsedPercent)) }
    elseif (-not (Test-GuestProbeEnabled)) { $left.Add('  QNX RAM  probe off (P)') }
    else { $left.Add('  QNX RAM  waiting for pidin...') }
    if ($script:external) { $left.Add(('  VM HOST  {0:N0} MiB resident' -f ($script:external.ResidentBytes / 1MB))) } else { $left.Add('  VM HOST  unavailable') }
    $cpuText = if ($g -and $null -ne $g.CpuMean) { '  CPU {0:N1}%' -f $g.CpuMean } else { '' }
    $left.Add(('  Backend: {0}{1}' -f $script:info.Backend, $cpuText))
    $left.Add('  ----------------------------------------')
    if ($script:treeMode) { $left.Add('  SRC TREE  Up/Down Enter Esc') } else { $left.Add("  PROGRAMS  [$activity] (number + Enter)") }
    $pageSize = [math]::Max(1, $height - 22)
    $maxPage = [math]::Max(0, [math]::Ceiling($script:sources.Count / $pageSize) - 1)
    $script:maxPage = $maxPage
    $script:page = [math]::Min($script:page, $maxPage)
    if ($script:treeMode) {
        $treeStart = [math]::Max(0, $script:treeCursor - $pageSize + 1)
        for ($i = $treeStart; $i -lt [math]::Min($script:treeEntries.Count, $treeStart + $pageSize); $i++) {
            $entry = $script:treeEntries[$i]; $pointer = if ($i -eq $script:treeCursor) { '>' } else { ' ' }
            $icon = if ($entry.Directory) { if ($entry.Expanded) { '[-]' } else { '[+]' } } else { '   ' }
            $left.Add(($pointer + ' ' + ('  ' * $entry.Depth) + $icon + ' ' + $entry.Name))
        }
        if ($script:treeEntries.Count -eq 0) { $left.Add('  The src folder is empty') }
    } else {
        for ($i = $script:page * $pageSize; $i -lt [math]::Min($script:sources.Count, ($script:page + 1) * $pageSize); $i++) {
            $relative = $script:sources[$i].FullName.Substring($Root.Length + 1)
            $left.Add(('  {0}. {1}' -f ($i + 1), $relative))
        }
    }
    while ($left.Count -lt $height - 7) { $left.Add('') }
    if ($script:treeMode) { $left.Add('  Up/Down move  Enter open  Esc back') } else { $left.Add("  Page $($script:page + 1)/$($maxPage + 1)  <-/-> programs") }
    $left.Add($(if ($script:recording) { ' T Tree M Panel H pidin G REC S SSH' } else { ' T Tree M Panel H pidin G CSV S SSH' }))
    if ($script:treeMode) { $left.Add('  Enter: open/run .cpp   Esc: back') } else { $left.Add(' I VM C Cfg P Probe V Tools Q Quit') }
    $prompt = Get-PromptText
    $availableInput = [math]::Max(1, $leftWidth - $prompt.Length)
    $visibleInput = if ($script:inputText.Length -gt $availableInput) { $script:inputText.Substring($script:inputText.Length - $availableInput) } else { $script:inputText }
    $left.Add($prompt + $visibleInput)
    $middle = New-Object 'System.Collections.Generic.List[string]'
    if ($showMemory) {
        # Guest view: what QNX itself reports (pidin/top over SSH).
        $addCommand = { param([string]$command) foreach ($commandLine in (Split-CommandLine $command ($middleWidth - 3))) { $middle.Add($commandLine) } }
        $middle.Add(' QNX GUEST  pidin/top via SSH')
        $middle.Add($(if ($script:recording) { ' [REC] CSV recording active' } else { ' -----------------------------' }))
        if (-not (Test-GuestProbeEnabled)) { $middle.Add(' Probe OFF: host-only mode'); $middle.Add(' P + Enter to enable') }
        elseif ($g) {
            & $addCommand "ssh $($Config.User)@$($script:address)  (1 session, every $([double]$Config.GuestProbeSeconds) s)"
            $middle.Add((' RAM {0:N0}/{1:N0} MiB  {2:N1}%' -f ($g.UsedBytes / 1MB), ($g.TotalBytes / 1MB), $g.UsedPercent))
            & $addCommand "$($GuestCommands.Ram)  (pages x getconf PAGESIZE)"
            $filled = [int][math]::Round($g.UsedPercent * 0.26)
            $middle.Add(' [' + ('#' * $filled) + ('-' * (26 - $filled)) + ']')
            $middle.Add((' Visible procs {0}  threads {1}' -f $g.Processes, $g.Threads))
            & $addCommand $GuestCommands.Procs
            if ($g.Cores.Count) { $middle.Add(' CPU ' + (@($g.Cores.GetEnumerator() | ForEach-Object { '{0}:{1:N1}%' -f $_.Key, $_.Value }) -join ' ')); & $addCommand "$($GuestCommands.Cpu)  (busy = 100 - idle per CPU)" }
            # 26 columns of 2 samples each (highest of the pair): about 26 s at 2 Hz.
            $recent = @($script:guestHistory.ToArray() | Select-Object -Last 52)
            $pairs = New-Object 'System.Collections.Generic.List[double]'
            for ($end = $recent.Count; $end -gt 0; $end -= 2) { $pairs.Insert(0, [math]::Max($recent[[math]::Max(0, $end - 2)], $recent[$end - 1])) }
            $trend = Format-Sparkline $pairs.ToArray()
            if ($trend) { $middle.Add(' ' + $trend.Bars); $middle.Add((' used {0:N0}..{1:N0} MiB -> now' -f $trend.Low, $trend.High)) }
        } else { $middle.Add(' Waiting for guest sample...') }
        if ($script:programRemote) {
            $middle.Add(' PROGRAM (pidin mem)')
            if ($script:program) {
                & $addCommand ($GuestCommands.Program -f $script:program.Pid)
                $middle.Add((' pid {0}' -f $script:program.Pid))
                $middle.Add((' data {0}  heap {1}' -f (Format-Size $script:program.DataBytes), (Format-Size $script:program.HeapBytes)))
                $middle.Add((' peak data {0}  heap {1}' -f (Format-Size $script:programPeakData), (Format-Size $script:programPeakHeap)))
            } elseif (Test-GuestProbeEnabled) { $middle.Add(' waiting for pidin...') }
            else { $middle.Add(' needs guest probe (P)') }
        }
        $middle.Add('')
        # Host view: what the hypervisor process costs on Windows (nothing runs in QNX).
        $middle.Add(' VM HOST  hypervisor process')
        $middle.Add(' -----------------------------')
        if ($script:external) {
            $middle.Add((' Resident {0:N0} MiB' -f ($script:external.ResidentBytes / 1MB)))
            if ($null -ne $script:baselineUsed -and $null -ne $script:currentUsed) {
                $middle.Add((' Since start {0:+0;-0;0}  peak {1:N0} MiB' -f (($script:currentUsed - $script:baselineUsed) / 1MB), ($script:peakUsed / 1MB)))
            }
            & $addCommand (Get-HostMetricCommand $script:info)
        } else { $middle.Add(' Unavailable') }
        $middle.Add($(if ($script:recording) { ' G stop CSV  P guest probe' } else { ' G record CSV  P guest probe' }))
    }
    $wrapped = New-Object 'System.Collections.Generic.List[object]'
    $latestWrapped = 0; $entryIndex = 0; $commandStart = $null; $commandEnd = $null
    foreach ($entry in $lines) {
        if ($entryIndex -eq $script:latestLogIndex) { $latestWrapped = $wrapped.Count }
        $isLastCommand = $null -ne $script:lastCommandIndex -and $entryIndex -eq $script:lastCommandIndex
        if ($isLastCommand) { $commandStart = $wrapped.Count }
        $entryIndex++
        $clean = [regex]::Replace($entry, '[\x00-\x08\x0B-\x1F\x7F]', '?').Replace("`t", '    ')
        $entryColor = if ($clean -match '^\s*(\+|> RUN)') { [ConsoleColor]::Magenta }
            elseif ($clean -match '(?i)(error|failed|invalid|unavailable|exit(ed)?: [1-9])') { [ConsoleColor]::Red }
            elseif ($clean -match '(?i)\[process exited: 0\]') { [ConsoleColor]::Green }
            else { [ConsoleColor]::Gray }
        if ($clean.Length -eq 0) { $wrapped.Add(@{ Text = ''; Color = $entryColor }); continue }
        for ($pos = 0; $pos -lt $clean.Length; $pos += $rightWidth) { $wrapped.Add(@{ Text = $clean.Substring($pos, [math]::Min($rightWidth, $clean.Length - $pos)); Color = $entryColor }) }
        if ($isLastCommand) { $commandEnd = $wrapped.Count }
    }
    if ($script:task -and $script:task.input -and $script:task.partial) {
        $partial = [regex]::Replace($script:task.partial, '[\x00-\x1F\x7F]', '?')
        for ($pos = 0; $pos -lt $partial.Length; $pos += $rightWidth) { $wrapped.Add(@{ Text = $partial.Substring($pos, [math]::Min($rightWidth, $partial.Length - $pos)); Color = [ConsoleColor]::White }) }
    }
    $hasProgramInput = $script:task -and $script:task.input
    $inputRowCount = if ($hasProgramInput) { 1 } else { 0 }
    $commandRows = if ($null -ne $commandEnd) { $commandEnd - $commandStart } else { 0 }
    # Keep at least one output line visible; unusually tall commands remain in scrollback.
    $canPin = $commandRows -gt 0 -and $commandRows -le ($height - 5 - $inputRowCount)
    $pinnedRows = if ($canPin) { $commandRows + 1 } else { 0 }
    $liveFloor = if ($canPin) { $commandEnd } else { $latestWrapped }
    $script:logMaxTop = [math]::Max($liveFloor, $wrapped.Count - ($height - 3 - $pinnedRows - $inputRowCount))
    if ($null -eq $script:logTop) { $logStart = $script:logMaxTop }
    else { $script:logTop = [math]::Max(0, [math]::Min($script:logTop, $script:logMaxTop)); $logStart = $script:logTop }
    $pin = $canPin -and ($null -eq $script:logTop -or $logStart -ge $commandEnd)
    for ($row = 0; $row -lt $height - 1; $row++) {
        $leftText = if ($row -lt $left.Count) { $left[$row] } else { '' }
        if ($leftText.Length -gt $leftWidth) { $leftText = $leftText.Substring(0, $leftWidth - 1) + '~' }
        $rightEntry = $null
        if ($row -ge 2 -and -not ($hasProgramInput -and $row -eq $height - 2)) {
            if ($pin -and $row -lt (2 + $commandRows)) { $rightEntry = $wrapped[$commandStart + $row - 2] }
            elseif (-not $pin -or $row -gt (2 + $commandRows)) {
                $offset = if ($pin) { $row - 3 - $commandRows } else { $row - 2 }
                if (($logStart + $offset) -ge 0 -and ($logStart + $offset) -lt $wrapped.Count) { $rightEntry = $wrapped[$logStart + $offset] }
            }
        }
        $rightText = if ($row -eq 0) { if ($null -eq $script:logTop) { ' OUTPUT [LIVE]   Up/PgUp: history' } else { ' OUTPUT [PAUSED] End: live' } } elseif ($row -eq 1) { '-' * [math]::Min($rightWidth, 40) } elseif ($hasProgramInput -and $row -eq $height - 2) {
            $inputPrefix = if ($script:focus -eq 'program') { ' INPUT > ' } else { ' [Tab] input > ' }
            $room = [math]::Max(1, $rightWidth - $inputPrefix.Length)
            $tail = if ($script:programInput.Length -gt $room) { $script:programInput.Substring($script:programInput.Length - $room) } else { $script:programInput }
            $inputPrefix + $tail
        } elseif ($rightEntry) { $rightEntry.Text } else { '' }
        if ($rightText.Length -gt $rightWidth) { $rightText = $rightText.Substring(0, $rightWidth) }
        $leftColor = if ($row -lt 6) { [ConsoleColor]::Cyan }
            elseif ($row -eq 6) { if ($state -eq 'RUNNING') { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow } }
            elseif ($row -eq 7) { [ConsoleColor]::Gray }
            elseif ($row -in @(8, 12)) { [ConsoleColor]::DarkGray }
            elseif ($row -in @(9, 10)) { $memoryColor }
            elseif ($row -eq 13) { [ConsoleColor]::Cyan }
            elseif ($leftText -match '^> ') { [ConsoleColor]::Cyan }
            elseif ($leftText -match '^  \d+\.') { [ConsoleColor]::White }
            elseif ($leftText -match '^\s+(I VM|T Tree|Q Quit|Select:|Host/IP|SSH user|SSH port|SSH command|VM name)') { [ConsoleColor]::Cyan }
            else { [ConsoleColor]::Gray }
        $rightColor = if ($row -lt 2 -or ($hasProgramInput -and $row -eq $height - 2)) { [ConsoleColor]::Cyan } elseif ($rightEntry) { $rightEntry.Color } else { [ConsoleColor]::Gray }
        $middleText = if ($showMemory -and $row -lt $middle.Count) { $middle[$row] } else { '' }
        if ($middleText.Length -gt $middleWidth -and $showMemory) { $middleText = $middleText.Substring(0, $middleWidth - 1) + '~' }
        $middleColor = if ($middleText -match '\[REC\]') { [ConsoleColor]::Red } elseif ($middleText -match '^ (\$ |  )') { [ConsoleColor]::DarkGray } elseif ($middleText -match '^ (QNX GUEST|VM HOST|PROGRAM)') { [ConsoleColor]::Cyan } elseif ($middleText -match '^ \[#') { $memoryColor } elseif ($middleText -match '[\u2581-\u2588]') { $memoryColor } else { [ConsoleColor]::Gray }
        $text = "$leftColor|$middleColor|$rightColor|" + $leftText.PadRight($leftWidth) + ' | ' + $(if ($showMemory) { $middleText.PadRight($middleWidth) + ' | ' } else { '' }) + $rightText.PadRight($rightWidth)
        if (-not $script:cache.ContainsKey($row) -or $script:cache[$row] -ne $text) {
            [Console]::SetCursorPosition(0, $row)
            [Console]::ForegroundColor = $leftColor
            [Console]::Write($leftText.PadRight($leftWidth))
            [Console]::ForegroundColor = [ConsoleColor]::DarkGray; [Console]::Write(' | ')
            if ($showMemory) { [Console]::ForegroundColor = $middleColor; [Console]::Write($middleText.PadRight($middleWidth)); [Console]::ForegroundColor = [ConsoleColor]::DarkGray; [Console]::Write(' | ') }
            [Console]::ForegroundColor = $rightColor
            [Console]::Write($rightText.PadRight($rightWidth)); $script:cache[$row] = $text
        }
    }
    [Console]::ResetColor()
    if ($script:focus -eq 'program' -and $hasProgramInput) {
        $rightStart = $leftWidth + 3 + $(if ($showMemory) { $middleWidth + 3 } else { 0 })
        [Console]::SetCursorPosition([math]::Min($width - 2, $rightStart + $rightText.Length), $height - 2)
    } else {
        $cursorRow = [math]::Min($height - 2, $left.Count - 1)
        [Console]::SetCursorPosition([math]::Min($leftWidth - 1, ($prompt + $visibleInput).Length), $cursorRow)
    }
}

# One engine iteration: discovery, task output, host sampling, CSV and the guest probe.
function Step-Engine {
    $now = [datetime]::UtcNow
    if ($now -ge $script:nextDiscovery) {
        $script:info = Get-VmInfo; $script:address = Get-GuestAddress $script:info; $script:sources = @(Get-Sources)
        $targetKey = "$($script:info.Backend)|$($Config.Vm)|$($script:info.ProcessId)"
        if ($targetKey -ne $script:historyTarget) {
            $script:historyTarget = $targetKey; $script:memoryHistory.Clear(); $script:baselineUsed = $null; $script:peakUsed = $null; $script:currentUsed = $null; $script:lastUsedChange = $null; $script:external = $null; $script:lastSample = $null
            Stop-GuestProbe; $script:guest = $null; $script:guestHistory.Clear(); $script:cpuHistory.Clear(); $script:guestNextStart = [datetime]::MinValue
        }
        if ($script:treeMode) { Refresh-Tree }
        $script:nextDiscovery = $now.AddSeconds(5)
    }
    if ($script:task -and (Poll-Captured $script:task)) {
        $finished = $script:task; $script:task = $null; $script:nextDiscovery = [datetime]::MinValue
        if ($finished.kind -eq 'prepare') {
            if ($finished.exitCode -eq 0 -and $finished.remote) {
                $remote = $finished.remote
                $command = "chmod 700 $remote && $remote; result=`$?; rm -f $remote; exit `$result"
                Add-Log "+ ssh -tt $($Config.User)@$($script:address) $command"
                $script:task = Start-Remote $command
                $script:programRemote = $remote; $script:program = $null; $script:programPeakData = $null; $script:programPeakHeap = $null
            } else { Add-Log "[build or transfer failed: $($finished.exitCode)]" }
        } elseif ($finished.kind -eq 'interactive') {
            $script:focus = 'menu'; $script:programInput = ''
            if ($script:programRemote -and $null -ne $script:programPeakData) { Add-Log "[program memory peak (pidin): data $(Format-Size $script:programPeakData), heap $(Format-Size $script:programPeakHeap)]" }
            $script:programRemote = ''; $script:program = $null
        }
    }
    if ($now -ge $script:nextProbe) {
        $script:nextProbe = $now.AddMilliseconds(500)   # host sampling and CSV rows at 2 Hz
        try { $script:external = Get-ExternalMetrics $script:info } catch { $script:external = $null }
        if ($script:external) {
            $used = [long]$script:external.ResidentBytes
            $script:lastUsedChange = if ($null -eq $script:currentUsed) { $null } else { $used - $script:currentUsed }
            $script:currentUsed = $used
            if ($null -eq $script:baselineUsed) { $script:baselineUsed = $used }
            if ($null -eq $script:peakUsed -or $used -gt $script:peakUsed) { $script:peakUsed = $used }
            $script:memoryHistory.Add($used / 1MB)
            while ($script:memoryHistory.Count -gt $script:HistoryLimit) { $script:memoryHistory.RemoveAt(0) }
            $script:lastSample = [datetime]::UtcNow
        }
        if (-not $script:guest) { Write-Measurement }   # host-only rows; with a live guest sample, rows follow the QNX samples
    }
    if ($script:lastSample -and ([datetime]::UtcNow - $script:lastSample).TotalSeconds -gt 8) { $script:external = $null; $script:lastSample = $null }
    Update-GuestProbe
}

# --- Serve mode: the protocol spoken with the compiled front ends ---
# stdout: "@@LOG<TAB>kind<TAB>text" lines and "@@FRAME" ... "@@END" blocks of "key<TAB>value" lines.
# stdin:  "submit<TAB>text", "escape", "program<TAB>text", "tree<TAB>up|down|left|right|enter|esc", "quit".
# Add-Field $b key value [value...]: one line, values separated by tabs.
function Add-Field($builder, [string]$key) {
    [void]$builder.Append($key)
    foreach ($value in $args) { [void]$builder.Append("`t").Append((ConvertTo-CleanText ([string]$value))) }
    [void]$builder.Append("`n")
}
function Format-Series($values) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    return [string]::Join(' ', [string[]]@(foreach ($value in $values) { $value.ToString('0.0', $inv) }))
}
function Get-ServeFrame {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $b = New-Object Text.StringBuilder
    Add-Field $b 'target' $Config.Vm
    Add-Field $b 'state' $(if ($script:info.VMState) { $script:info.VMState.ToUpperInvariant() } else { 'UNKNOWN' })
    Add-Field $b 'address' $script:address
    Add-Field $b 'backend' $script:info.Backend
    Add-Field $b 'busy' $(if ($script:task) { 1 } else { 0 })
    Add-Field $b 'probe' $(if (Test-GuestProbeEnabled) { 1 } else { 0 })
    Add-Field $b 'recording' $(if ($script:recording) { 1 } else { 0 })
    Add-Field $b 'mode' $script:inputMode
    Add-Field $b 'prompt' (Get-PromptText)
    $interactive = $script:task -and $script:task.input
    Add-Field $b 'interactive' $(if ($interactive) { 1 } else { 0 })
    if ($interactive -and $script:task.partial) { Add-Field $b 'partial' $script:task.partial }
    $g = $script:guest
    if ($g) {
        Add-Field $b 'guest_used' ($g.UsedBytes / 1MB).ToString('0.0', $inv)
        Add-Field $b 'guest_total' ($g.TotalBytes / 1MB).ToString('0.0', $inv)
        Add-Field $b 'guest_pct' ([double]$g.UsedPercent).ToString('0.0', $inv)
        Add-Field $b 'guest_procs' $g.Processes
        Add-Field $b 'guest_threads' $g.Threads
        if ($null -ne $g.CpuMean) { Add-Field $b 'guest_cpu' ([double]$g.CpuMean).ToString('0.0', $inv) }
        foreach ($core in $g.Cores.GetEnumerator()) { Add-Field $b 'core' $core.Key ([double]$core.Value).ToString('0.0', $inv) }
        Add-Field $b 'hist' (Format-Series $script:guestHistory)
        Add-Field $b 'hist_cpu' (Format-Series $script:cpuHistory)
    }
    if ($script:programRemote) {
        Add-Field $b 'program_active' 1
        if ($script:program) {
            Add-Field $b 'program_pid' $script:program.Pid
            Add-Field $b 'program_data' (Format-Size $script:program.DataBytes)
            Add-Field $b 'program_heap' (Format-Size $script:program.HeapBytes)
            Add-Field $b 'program_peak_data' (Format-Size $script:programPeakData)
            Add-Field $b 'program_peak_heap' (Format-Size $script:programPeakHeap)
        }
    }
    if ($script:external) {
        Add-Field $b 'host_resident' ($script:external.ResidentBytes / 1MB).ToString('0.0', $inv)
        if ($null -ne $script:baselineUsed -and $null -ne $script:currentUsed) {
            Add-Field $b 'host_delta' (($script:currentUsed - $script:baselineUsed) / 1MB).ToString('0.0', $inv)
            Add-Field $b 'host_peak' ($script:peakUsed / 1MB).ToString('0.0', $inv)
        }
        Add-Field $b 'host_source' $script:external.Source
        Add-Field $b 'hist_host' (Format-Series $script:memoryHistory)
    }
    # The exact commands behind each metric (shown under each section).
    Add-Field $b 'cmd_ssh' "ssh $($Config.User)@$($script:address)  (1 session, every $([double]$Config.GuestProbeSeconds) s)"
    Add-Field $b 'cmd_ram' "$($GuestCommands.Ram)  (pages x getconf PAGESIZE)"
    Add-Field $b 'cmd_procs' $GuestCommands.Procs
    Add-Field $b 'cmd_cpu' "$($GuestCommands.Cpu)  (busy = 100 - idle per CPU)"
    Add-Field $b 'cmd_program' ($GuestCommands.Program -f $(if ($script:program) { $script:program.Pid } else { '<pid>' }))
    Add-Field $b 'cmd_host' (Get-HostMetricCommand $script:info)
    Add-Field $b 'tree' $(if ($script:treeMode) { 1 } else { 0 })
    if ($script:treeMode) {
        Add-Field $b 'tree_cursor' $script:treeCursor
        foreach ($entry in $script:treeEntries) { Add-Field $b 'node' $entry.Depth $(if ($entry.Directory) { 1 } else { 0 }) $(if ($entry.Expanded) { 1 } else { 0 }) $entry.Name }
    }
    foreach ($source in $script:sources) { Add-Field $b 'src' $source.FullName.Substring($Root.Length + 1) }
    return $b.ToString()
}
function Invoke-ServeCommand([string]$line) {
    $parts = $line.Split([char[]]@([char]9), 2)
    $argument = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    switch ($parts[0]) {
        'submit' { $script:inputText = $argument; try { Submit-Input } catch { Add-Log "[error: $_]"; $script:inputMode = 'command' } }
        'escape' { $script:inputText = ''; $script:inputMode = 'command' }
        'program' { $null = Send-ProgramInput $argument }
        'tree' { Invoke-TreeKey $argument }
        'quit' { $script:quitting = $true }
    }
}
function Start-Serve {
    $stdin = New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding($false)))
    $pending = $stdin.ReadLineAsync()
    $lastFrame = ''
    while (-not $script:quitting) {
        $null = Step-Engine
        while ($pending.IsCompleted) {
            $command = $pending.GetAwaiter().GetResult()
            if ($null -eq $command) { $script:quitting = $true; break }   # the front end closed the pipe
            $null = Invoke-ServeCommand $command
            $pending = $stdin.ReadLineAsync()
        }
        $frame = Get-ServeFrame
        if ($frame -ne $lastFrame) { $script:serveOut.Write("@@FRAME`n$frame@@END`n"); $lastFrame = $frame }
        Start-Sleep -Milliseconds 100
    }
}

try {
    if ($script:serve) {
        $script:serveOut = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object Text.UTF8Encoding($false)))
        $script:serveOut.AutoFlush = $true
    } else {
        $script:originalOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)   # the OEM code page lacks the trend characters
        [Console]::Clear()
    }
    Add-Log '[dashboard started]'
    Add-Log '[host view: VirtualBox VBoxManage metrics / QEMU process working set]'
    if (Test-GuestProbeEnabled) { Add-Log '[guest view: pidin/top inside QNX over one SSH session; P toggles it off]' }
    else { Add-Log '[guest view OFF (host-only mode); press P then Enter to enable]' }
    $script:quitting = $false
    if ($script:serve) { Start-Serve; return }
    if ([Console]::WindowWidth -lt 100) { Add-Log '[widen terminal to 100 columns to show metrics panel]' }
    while (-not $script:quitting) {
        Step-Engine
        Render
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Tab') {
                if ($script:focus -eq 'program') { $script:focus = 'menu' }
                elseif ($script:task -and $script:task.input -and -not $script:treeMode) { $script:focus = 'program'; $script:logTop = $null }
            }
            elseif ($script:focus -eq 'program') {
                if ($key.Key -eq 'Enter') {
                    if (Send-ProgramInput $script:programInput) { $script:logTop = $null } else { $script:focus = 'menu' }
                    $script:programInput = ''
                }
                elseif ($key.Key -eq 'Backspace' -and $script:programInput.Length -gt 0) { $script:programInput = $script:programInput.Substring(0, $script:programInput.Length - 1) }
                elseif (-not [char]::IsControl($key.KeyChar) -and $script:programInput.Length -lt 2048) { $script:programInput += $key.KeyChar }
            }
            elseif ($script:treeMode) {
                $treeKey = @{ Enter = 'enter'; UpArrow = 'up'; DownArrow = 'down'; Escape = 'esc'; RightArrow = 'right'; LeftArrow = 'left' }[[string]$key.Key]
                if ($treeKey) { Invoke-TreeKey $treeKey }
            }
            elseif ($key.Key -eq 'Enter') { try { Submit-Input } catch { Add-Log "[error: $_]"; $script:inputMode = 'command' } }
            elseif ($key.Key -eq 'UpArrow') {
                if ($null -eq $script:logTop) { $script:logTop = $script:logMaxTop }
                $script:logTop = [math]::Max(0, $script:logTop - 1)
            }
            elseif ($key.Key -eq 'DownArrow' -and $null -ne $script:logTop) {
                if ($script:logTop -ge $script:logMaxTop - 1) { $script:logTop = $null }
                else { $script:logTop++ }
            }
            elseif ($key.Key -eq 'PageUp') {
                if ($null -eq $script:logTop) { $script:logTop = $script:logMaxTop }
                $script:logTop = [math]::Max(0, $script:logTop - [math]::Max(1, [Console]::WindowHeight - 4))
            }
            elseif ($key.Key -eq 'PageDown' -and $null -ne $script:logTop) {
                $script:logTop += [math]::Max(1, [Console]::WindowHeight - 4)
                if ($script:logTop -ge $script:logMaxTop) { $script:logTop = $null }
            }
            elseif ($key.Key -eq 'End') { $script:logTop = $null }
            elseif ($key.Key -eq 'LeftArrow' -and $script:inputMode -eq 'command') { $script:page = [math]::Max(0, $script:page - 1) }
            elseif ($key.Key -eq 'RightArrow' -and $script:inputMode -eq 'command') { $script:page = [math]::Min($script:maxPage, $script:page + 1) }
            elseif ($key.Key -eq 'Backspace' -and $script:inputText.Length -gt 0) { $script:inputText = $script:inputText.Substring(0, $script:inputText.Length - 1) }
            elseif ($key.Key -eq 'Escape') { $script:inputText = ''; $script:inputMode = 'command' }
            elseif (-not [char]::IsControl($key.KeyChar) -and $script:inputText.Length -lt 2048) { $script:inputText += $key.KeyChar }
        }
        Start-Sleep -Milliseconds 100
    }
} finally {
    foreach ($job in @($script:task)) { if ($job) { if (-not $job.process.HasExited) { $job.process.Kill() }; $job.process.Dispose() } }
    Stop-GuestProbe
    if (-not $script:serve) {
        [Console]::ResetColor(); [Console]::Clear()
        if ($script:originalOutputEncoding) { [Console]::OutputEncoding = $script:originalOutputEncoding }
    }
}
