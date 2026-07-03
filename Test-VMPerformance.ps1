#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Validates Windows VM performance configuration on OpenShift Virtualization (KVM/QEMU).
    Checks Hyper-V enlightenments, VirtIO drivers, OS tuning, and runs optional benchmarks.

.DESCRIPTION
    Run inside the Windows guest as Administrator.
    Categories:
      1. Hyper-V enlightenment detection (guest-side)
      2. VirtIO driver verification
      3. OS optimization checks
      4. Disk benchmark (DiskSpd)
      5. Diagnostics (disk, network, drivers, VSS, BitLocker, performance)

.PARAMETER RunBenchmark
    If specified, runs DiskSpd disk benchmark after validation.

.PARAMETER BenchmarkDuration
    Duration in seconds for DiskSpd test (default: 30).

.PARAMETER RunDiagnostics
    If specified, runs troubleshooting diagnostic commands (disk, network, drivers, etc.).

.PARAMETER OutputJson
    If specified, writes results to a JSON file at the given path.

.EXAMPLE
    .\Test-VMPerformance.ps1
    .\Test-VMPerformance.ps1 -RunBenchmark -BenchmarkDuration 60
    .\Test-VMPerformance.ps1 -RunDiagnostics
    .\Test-VMPerformance.ps1 -RunBenchmark -RunDiagnostics -OutputJson "$env:TEMP\results.json"
#>

param(
    [switch]$RunBenchmark,
    [int]$BenchmarkDuration = 30,
    [switch]$RunDiagnostics,
    [string]$OutputJson
)

$ErrorActionPreference = "Continue"
$results = @()
$passed = 0
$warned = 0
$failed = 0

function Write-Check {
    param([string]$Name, [string]$Status, [string]$Detail)
    $color = switch ($Status) {
        "PASS" { "Green" }
        "WARN" { "Yellow" }
        "FAIL" { "Red" }
        "INFO" { "Cyan" }
        default { "White" }
    }
    Write-Host "  [$Status] " -ForegroundColor $color -NoNewline
    Write-Host "$Name" -NoNewline
    if ($Detail) { Write-Host " - $Detail" -ForegroundColor Gray } else { Write-Host "" }

    $script:results += [PSCustomObject]@{ Check = $Name; Status = $Status; Detail = $Detail }
    switch ($Status) {
        "PASS" { $script:passed++ }
        "WARN" { $script:warned++ }
        "FAIL" { $script:failed++ }
    }
}

# =============================================================================
Write-Host "`n=== 1. HYPER-V ENLIGHTENMENTS ===" -ForegroundColor Cyan
# =============================================================================

$hypervisorPresent = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
if ($hypervisorPresent) {
    Write-Check "Hypervisor detected" "PASS" "Guest sees a hypervisor (Hyper-V interface)"
} else {
    Write-Check "Hypervisor detected" "FAIL" "No hypervisor detected; enlightenments inactive"
    Write-Host "    KCS: https://access.redhat.com/articles/4234591" -ForegroundColor Gray
    Write-Host "    Docs: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_windows_virtual_machines/optimizing-windows-virtual-machines" -ForegroundColor Gray
}

$hvInfo = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters" -ErrorAction SilentlyContinue
if ($hvInfo) {
    Write-Check "Hyper-V Guest Parameters" "PASS" "Registry key present (integration active)"
} else {
    Write-Check "Hyper-V Guest Parameters" "INFO" "Registry key not present (normal on KVM with enlightenments)"
}

# Detect platform via SMBIOS
$csProduct = Get-CimInstance Win32_ComputerSystemProduct
Write-Check "SMBIOS Manufacturer" "INFO" "$($csProduct.Vendor)"
Write-Check "SMBIOS Product" "INFO" "$($csProduct.Name)"
if ($csProduct.Vendor -match "Red Hat" -or $csProduct.Name -match "OpenShift") {
    Write-Check "Platform detection" "PASS" "Running on OpenShift Virtualization"
} elseif ($csProduct.Vendor -match "QEMU" -or $csProduct.Name -match "KVM") {
    Write-Check "Platform detection" "PASS" "Running on KVM/QEMU"
} else {
    Write-Check "Platform detection" "WARN" "Unexpected platform: $($csProduct.Vendor) / $($csProduct.Name)"
}

$cpuInfo = Get-CimInstance Win32_Processor
$cpuCaption = ($cpuInfo | Select-Object -First 1).Caption
Write-Check "CPU model" "INFO" "$cpuCaption"

# Check useplatformclock (should be off for best timer performance)
$bcdOutput = bcdedit /enum "{current}" 2>&1 | Out-String
if ($bcdOutput -match "useplatformclock\s+No") {
    Write-Check "useplatformclock" "PASS" "Disabled (better timer performance)"
} elseif ($bcdOutput -match "useplatformclock\s+Yes") {
    Write-Check "useplatformclock" "WARN" "Enabled; disable with: bcdedit /set useplatformclock No"
} else {
    Write-Check "useplatformclock" "PASS" "Not set (default=off on Win10+)"
}

# Check Hyper-V integration services (evidence of enlightenments from guest side)
$hvServices = Get-Service | Where-Object { $_.DisplayName -match "Hyper-V" }
if ($hvServices) {
    $running = ($hvServices | Where-Object { $_.Status -eq "Running" }).Count
    Write-Check "Hyper-V Integration Services" "PASS" "$running services running"
} else {
    Write-Check "Hyper-V Integration Services" "INFO" "No Hyper-V services found (KVM uses QEMU GA instead)"
}

# Verify specific Hyper-V enlightenments via WMI/registry indicators
# Windows exposes synthetic interrupt controller (synic) and timers via services
$hvTimeSvc = Get-Service "vmictimesync" -ErrorAction SilentlyContinue
if ($hvTimeSvc -and $hvTimeSvc.Status -eq "Running") {
    Write-Check "hv-time/hv-reenlightenment" "PASS" "Time Synchronization IC active"
} else {
    Write-Check "hv-time/hv-reenlightenment" "INFO" "Time Sync IC not running (KVM exposes via CPUID directly)"
}

# Check for synthetic timer via clocksource
$tscSource = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\stimer" -ErrorAction SilentlyContinue
$hyperVTimer = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\vmtimesync" -ErrorAction SilentlyContinue
if ($tscSource -or $hyperVTimer) {
    Write-Check "hv-stimer (synthetic timer)" "PASS" "Synthetic timer driver registered"
} else {
    Write-Check "hv-stimer (synthetic timer)" "INFO" "No synthetic timer driver (check host-side QEMU args)"
}

# Check for hypervisor scheduler type (evidence of hv-vpindex, hv-runtime)
$schedulerType = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization" -Name "SchedulerType" -ErrorAction SilentlyContinue
if ($schedulerType) {
    Write-Check "hv-vpindex/hv-runtime" "PASS" "Scheduler type: $($schedulerType.SchedulerType)"
} else {
    Write-Check "hv-vpindex/hv-runtime" "INFO" "Scheduler key not present (normal on KVM)"
}

Write-Host ""
Write-Host "  NOTE: Full individual enlightenment verification requires host-side inspection." -ForegroundColor DarkGray
Write-Host "  From the OpenShift host, run:" -ForegroundColor DarkGray
Write-Host "    oc get vmi -A -o json | python3 -c \"...\"  (see README)" -ForegroundColor DarkGray
Write-Host "  Or check QEMU args:" -ForegroundColor DarkGray
Write-Host "    oc logs <virt-launcher-pod> -c compute | grep 'hv-'" -ForegroundColor DarkGray

# =============================================================================
Write-Host "`n=== 2. VIRTIO DRIVERS ===" -ForegroundColor Cyan
# =============================================================================

$expectedDrivers = @(
    @{ Name = "viostor";  Desc = "VirtIO Block Storage"; Critical = $true },
    @{ Name = "vioscsi";  Desc = "VirtIO SCSI";         Critical = $false },
    @{ Name = "netkvm";   Desc = "VirtIO Network";      Critical = $true },
    @{ Name = "vioser";   Desc = "VirtIO Serial";       Critical = $false },
    @{ Name = "balloon";  Desc = "VirtIO Balloon";      Critical = $false },
    @{ Name = "vioinput"; Desc = "VirtIO Input";        Critical = $false },
    @{ Name = "viogpudo"; Desc = "VirtIO GPU";          Critical = $false },
    @{ Name = "viorng";   Desc = "VirtIO RNG";          Critical = $false },
    @{ Name = "viofs";    Desc = "VirtIO FS";           Critical = $false }
)

$installedDrivers = Get-WindowsDriver -Online -All -ErrorAction SilentlyContinue |
    Where-Object { $_.OriginalFileName -match "virtio|vioscsi|viostor|netkvm|balloon|vioinput|viogpudo|viorng|viofs|vioser" }

foreach ($drv in $expectedDrivers) {
    $found = $installedDrivers | Where-Object { $_.OriginalFileName -match $drv.Name }
    if ($found) {
        $version = ($found | Select-Object -First 1).Version
        Write-Check "$($drv.Desc)" "PASS" "v$version"
    } else {
        if ($drv.Critical) {
            Write-Check "$($drv.Desc)" "FAIL" "NOT INSTALLED (critical for performance)"
        } else {
            Write-Check "$($drv.Desc)" "WARN" "Not found (optional)"
        }
    }
}

# QEMU Guest Agent
$qga = Get-Service "QEMU-GA" -ErrorAction SilentlyContinue
if ($qga -and $qga.Status -eq "Running") {
    Write-Check "QEMU Guest Agent" "PASS" "Running"
} elseif ($qga) {
    Write-Check "QEMU Guest Agent" "WARN" "Installed but $($qga.Status)"
} else {
    Write-Check "QEMU Guest Agent" "WARN" "Not installed (provides metadata exchange with host)"
}

# =============================================================================
Write-Host "`n=== 3. OS OPTIMIZATION ===" -ForegroundColor Cyan
# =============================================================================

# Windows Search
$wsearch = Get-Service "WSearch" -ErrorAction SilentlyContinue
if (-not $wsearch -or $wsearch.Status -ne "Running") {
    Write-Check "Windows Search" "PASS" "Disabled/Stopped"
} else {
    Write-Check "Windows Search" "WARN" "Running (disable: Set-Service WSearch -StartupType Disabled; Stop-Service WSearch)"
}

# SysMain (Superfetch)
$sysmain = Get-Service "SysMain" -ErrorAction SilentlyContinue
if (-not $sysmain -or $sysmain.Status -ne "Running") {
    Write-Check "SysMain (Superfetch)" "PASS" "Disabled/Stopped"
} else {
    Write-Check "SysMain (Superfetch)" "WARN" "Running (disable: Set-Service SysMain -StartupType Disabled; Stop-Service SysMain)"
}

# Scheduled Defrag
$defrag = Get-ScheduledTask -TaskName "ScheduledDefrag" -ErrorAction SilentlyContinue
if ($defrag -and $defrag.State -eq "Disabled") {
    Write-Check "Scheduled Defrag" "PASS" "Disabled (not needed on virtual disks)"
} elseif ($defrag) {
    Write-Check "Scheduled Defrag" "WARN" "Enabled (disable: Disable-ScheduledTask -TaskName 'ScheduledDefrag')"
} else {
    Write-Check "Scheduled Defrag" "PASS" "Not found"
}

# Windows Update (informational only)
$wuauserv = Get-Service "wuauserv" -ErrorAction SilentlyContinue
if ($wuauserv -and $wuauserv.Status -eq "Running") {
    Write-Check "Windows Update" "INFO" "Running (can cause I/O spikes during updates)"
} else {
    Write-Check "Windows Update" "INFO" "Stopped"
}

# Power plan
$powerPlan = (powercfg /getactivescheme) -replace '.*:\s+', '' -replace '\s+\(.*', ''
if ($powerPlan -match "High performance|8c5e7fda") {
    Write-Check "Power Plan" "PASS" "High Performance"
} else {
    Write-Check "Power Plan" "WARN" "Current: $powerPlan (fix: powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c)"
}

# Network RSS
$netAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
foreach ($adapter in $netAdapters) {
    $rss = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.RegistryKeyword -eq "*RSS" }
    if ($rss -and $rss.RegistryValue -eq "1") {
        Write-Check "RSS ($($adapter.Name))" "PASS" "Enabled"
    } elseif ($rss) {
        Write-Check "RSS ($($adapter.Name))" "WARN" "Disabled (enable: Set-NetAdapterAdvancedProperty -Name '$($adapter.Name)' -RegistryKeyword '*RSS' -RegistryValue 1)"
    } else {
        Write-Check "RSS ($($adapter.Name))" "INFO" "Property not available"
    }
}

# =============================================================================
Write-Host "`n=== 4. MEMORY & CPU ===" -ForegroundColor Cyan
# =============================================================================

$os = Get-CimInstance Win32_OperatingSystem
$totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$cpuCount = ($cpuInfo | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
Write-Check "Total RAM" "INFO" "${totalRAM} GB"
Write-Check "Free RAM" "INFO" "${freeRAM} GB"
Write-Check "Logical CPUs" "INFO" "$cpuCount"

$balloonSvc = Get-Service "BalloonService" -ErrorAction SilentlyContinue
if ($balloonSvc -and $balloonSvc.Status -eq "Running") {
    Write-Check "Balloon Service" "PASS" "Running (memory ballooning active)"
} else {
    Write-Check "Balloon Service" "INFO" "Not running"
}

# =============================================================================
# 5. DISK BENCHMARK (optional)
# =============================================================================

if ($RunBenchmark) {
    Write-Host "`n=== 5. DISK BENCHMARK (DiskSpd) ===" -ForegroundColor Cyan

    $diskspdPath = "$env:TEMP\diskspd.exe"
    if (-not (Test-Path $diskspdPath)) {
        Write-Host "  Downloading DiskSpd..." -ForegroundColor Gray
        $diskspdUrl = "https://github.com/microsoft/diskspd/releases/latest/download/DiskSpd.zip"
        $zipPath = "$env:TEMP\diskspd.zip"
        try {
            Invoke-WebRequest -Uri $diskspdUrl -OutFile $zipPath -UseBasicParsing
            Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\diskspd_extract" -Force
            $exe = Get-ChildItem "$env:TEMP\diskspd_extract" -Recurse -Filter "diskspd.exe" |
                Where-Object { $_.FullName -match "amd64" } | Select-Object -First 1
            if (-not $exe) {
                $exe = Get-ChildItem "$env:TEMP\diskspd_extract" -Recurse -Filter "diskspd.exe" | Select-Object -First 1
            }
            if (-not $exe) { throw "diskspd.exe not found in extracted archive" }
            Copy-Item $exe.FullName $diskspdPath
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Write-Check "DiskSpd download" "PASS" "Downloaded from official Microsoft GitHub"
        } catch {
            Write-Check "DiskSpd download" "FAIL" "$_"
            $RunBenchmark = $false
        }
    } else {
        Write-Check "DiskSpd" "PASS" "Already present at $diskspdPath"
    }

    if ($RunBenchmark) {
        $testFile = "$env:TEMP\diskspd_test.dat"

        # Minimum floor thresholds: below these values indicates misconfiguration
        # (emulated disk, missing VirtIO, wrong cache mode)
        $thresholds = @{
            "Seq Read 128K"    = @{ MinIOPS = 400;  MinMBps = 50 }
            "Rand Read 4K"     = @{ MinIOPS = 1000; MinMBps = 4 }
            "Rand Write 4K"    = @{ MinIOPS = 500;  MinMBps = 2 }
            "Mixed 4K 70R/30W" = @{ MinIOPS = 500;  MinMBps = 2 }
        }

        function Invoke-DiskSpd {
            param([string[]]$DiskSpdArgs, [string]$TestName)
            Write-Host "  Running $TestName (${BenchmarkDuration}s)..." -ForegroundColor Gray
            $allArgs = $DiskSpdArgs + @($testFile)
            $output = & $diskspdPath $allArgs 2>&1 | Out-String

            # DiskSpd text output: Total IO section appears first, then Read IO, Write IO
            # Format: total:  <bytes>  |  <I/Os>  |  <MiB/s>  |  <I/O per s>  |  <AvgLat>  | ...
            $lines = $output -split "`r?`n" | Where-Object { $_ -match "^\s*total:" }
            if ($lines) {
                $firstLine = ($lines | Select-Object -First 1).Trim()
                $fields = $firstLine -split '\|' | ForEach-Object { $_.Trim() }
                if ($fields.Count -ge 4) {
                    $mbps = $fields[2] -as [double]
                    $iops = $fields[3] -as [double]
                    if ($null -ne $mbps -and $null -ne $iops) {
                        return @{ IOPS = $iops; MBps = $mbps }
                    }
                    return @{ Error = "Non-numeric values in fields: MiB/s='$($fields[2])' IOPS='$($fields[3])'" }
                }
                return @{ Error = "Parsed $($fields.Count) fields: $firstLine" }
            }

            if ($output -match "Usage:") {
                return @{ Error = "DiskSpd printed usage help (bad arguments)" }
            }
            $debugFile = "$env:TEMP\diskspd_debug.txt"
            $output | Set-Content -Path $debugFile -Encoding UTF8
            return @{ Error = "Could not parse output (saved to $debugFile)" }
        }

        function Format-BenchResult {
            param([hashtable]$Result, [string]$TestName)
            if ($Result.Error) {
                Write-Check $TestName "FAIL" $Result.Error
                return
            }
            $iops = $Result.IOPS
            $mbps = $Result.MBps
            $display = "{0:N2} IOPS ({1:N2} MiB/s)" -f $iops, $mbps
            $t = $thresholds[$TestName]
            if ($t -and ($iops -lt $t.MinIOPS)) {
                Write-Check $TestName "WARN" "$display  [below $($t.MinIOPS) IOPS floor: check VirtIO driver and disk cache mode]"
            } else {
                Write-Check $TestName "PASS" $display
            }
        }

        $baseArgs = @("-d$BenchmarkDuration", "-Sh", "-c1G")
        $seqReadResult = Invoke-DiskSpd ($baseArgs + @("-b128K", "-o4", "-t2", "-r", "-w0")) "sequential read 128K"
        $randReadResult = Invoke-DiskSpd ($baseArgs + @("-b4K", "-o32", "-t2", "-r", "-w0")) "random read 4K"
        $randWriteResult = Invoke-DiskSpd ($baseArgs + @("-b4K", "-o32", "-t2", "-r", "-w100")) "random write 4K"
        $mixedResult = Invoke-DiskSpd ($baseArgs + @("-b4K", "-o32", "-t2", "-r", "-w30")) "mixed 4K 70R/30W"

        Write-Host ""
        Format-BenchResult $seqReadResult "Seq Read 128K"
        Format-BenchResult $randReadResult "Rand Read 4K"
        Format-BenchResult $randWriteResult "Rand Write 4K"
        Format-BenchResult $mixedResult "Mixed 4K 70R/30W"
        Write-Host ""
        Write-Host "  NOTE: Results depend on storage backend (local NVMe > SAN > ODF/Ceph RBD > NFS)." -ForegroundColor Gray
        Write-Host "        Floor thresholds detect misconfiguration only (emulated disk, missing VirtIO)." -ForegroundColor Gray
        Write-Host "        Compare against your own baseline for the same storage class." -ForegroundColor Gray

        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# 6. DIAGNOSTICS (optional)
# =============================================================================

if ($RunDiagnostics) {
    function Write-DiagSection {
        param([string]$Title)
        Write-Host "`n  --- $Title ---" -ForegroundColor White
    }

    function Run-DiagCmd {
        param([string]$Label, [scriptblock]$Command)
        Write-Host "  > $Label" -ForegroundColor Gray
        try {
            $result = & $Command 2>&1 | Out-String
            if ($result.Trim()) {
                $result.Trim().Split("`n") | ForEach-Object { Write-Host "    $_" }
            } else {
                Write-Host "    (no output)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "    ERROR: $_" -ForegroundColor Red
        }
        Write-Host ""
    }

    Write-Host "`n=== 6. DIAGNOSTICS ===" -ForegroundColor Cyan

    # --- Disk, Boot & File System ---
    Write-DiagSection "Disk, Boot & File System"
    Run-DiagCmd "Disk health status" {
        Get-CimInstance Win32_DiskDrive | Select-Object Model, MediaType, Status, Size |
            Format-Table -AutoSize
    }
    Run-DiagCmd "Volume inventory" {
        Get-CimInstance Win32_LogicalDisk | Select-Object DeviceID, VolumeName, FileSystem,
            @{N="Size(GB)";E={[math]::Round($_.Size/1GB,1)}},
            @{N="Free(GB)";E={[math]::Round($_.FreeSpace/1GB,1)}} |
            Format-Table -AutoSize
    }
    Run-DiagCmd "Boot Configuration (BCD)" { bcdedit /enum "{current}" }

    # --- Networking ---
    Write-DiagSection "Networking"
    Run-DiagCmd "NIC status" {
        Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.NetEnabled } |
            Select-Object Name, Speed, MACAddress | Format-Table -AutoSize
    }
    Run-DiagCmd "IP configuration" { ipconfig /all }
    Run-DiagCmd "Routing table" { route print }
    Run-DiagCmd "Firewall state" { netsh advfirewall show allprofiles state }

    # --- Device Drivers ---
    Write-DiagSection "Device Drivers"
    Run-DiagCmd "PnP driver status (VirtIO/QEMU)" {
        Get-CimInstance Win32_PnPSignedDriver |
            Where-Object { $_.Manufacturer -match "Red Hat|QEMU|VirtIO" } |
            Select-Object DeviceName, DriverVersion, Status |
            Format-Table -AutoSize
    }
    Run-DiagCmd "Devices with problems" {
        Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
            Select-Object Name, ConfigManagerErrorCode | Format-Table -AutoSize
    }

    # --- Backup & Snapshot (VSS / QEMU-GA) ---
    Write-DiagSection "Backup & Snapshot"
    Run-DiagCmd "QEMU Guest Agent status" { sc.exe query QEMU-GA }
    Run-DiagCmd "VSS Writers" { vssadmin list writers }
    Run-DiagCmd "VSS Providers" { vssadmin list providers }

    # --- BitLocker & Encryption ---
    Write-DiagSection "BitLocker & Encryption"
    Run-DiagCmd "BitLocker status" { manage-bde -status }

    # --- Hibernation & Fast Startup ---
    Write-DiagSection "Hibernation & Fast Startup"
    Run-DiagCmd "Available sleep states" { powercfg /a }

    # --- Performance ---
    Write-DiagSection "Performance Snapshot"
    Run-DiagCmd "System info (summary)" {
        $osInfo = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        "OS: $($osInfo.Caption) $($osInfo.Version)"
        "Uptime: $((Get-Date) - $osInfo.LastBootUpTime)"
        "CPU: $($cpu.Name) ($($cpu.NumberOfLogicalProcessors) cores)"
        "RAM: $([math]::Round($osInfo.TotalVisibleMemorySize/1MB,1)) GB total, $([math]::Round($osInfo.FreePhysicalMemory/1MB,1)) GB free"
    }
    Run-DiagCmd "Top 10 processes by CPU" {
        Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, Id,
            @{N="CPU(s)";E={[math]::Round($_.CPU,1)}},
            @{N="Mem(MB)";E={[math]::Round($_.WS/1MB,1)}} |
            Format-Table -AutoSize
    }

    # --- Logs ---
    Write-DiagSection "Recent Critical/Error Events"
    Run-DiagCmd "System event log (last 10 errors)" {
        Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=(Get-Date).AddHours(-24)} -MaxEvents 10 -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, Id, Message | Format-Table -AutoSize -Wrap
    }

    # Check for MTV firstboot log
    $firstbootLog = "$env:SystemDrive\Program Files\Guestfs\Firstboot\log.txt"
    if (Test-Path $firstbootLog) {
        Run-DiagCmd "MTV Firstboot log (last 20 lines)" {
            Get-Content $firstbootLog -Tail 20
        }
    }
}

# =============================================================================
Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
# =============================================================================

$summaryColor = if ($failed -gt 0) { "Red" } elseif ($warned -gt 0) { "Yellow" } else { "Green" }
Write-Host "  Passed: $passed | Warnings: $warned | Failed: $failed" -ForegroundColor $summaryColor
Write-Host ""

if ($failed -gt 0) {
    Write-Host "  CRITICAL: Fix failed checks before running production workloads." -ForegroundColor Red
    Write-Host "  Configure Hyper-V enlightenments:" -ForegroundColor Gray
    Write-Host "    KCS: https://access.redhat.com/articles/4234591" -ForegroundColor Gray
    Write-Host "    Docs: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_windows_virtual_machines/optimizing-windows-virtual-machines" -ForegroundColor Gray
}

if ($warned -gt 0) {
    Write-Host "  Recommendations:" -ForegroundColor Yellow
    $results | Where-Object { $_.Status -eq "WARN" } | ForEach-Object {
        Write-Host "    - $($_.Check): $($_.Detail)" -ForegroundColor Yellow
    }
}

Write-Host "`n  References:" -ForegroundColor Gray
Write-Host "    KCS: https://access.redhat.com/articles/4234591" -ForegroundColor Gray
Write-Host "    Docs: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_windows_virtual_machines/optimizing-windows-virtual-machines" -ForegroundColor Gray
Write-Host ""

# Export JSON if requested
if ($OutputJson) {
    $resolvedPath = [System.IO.Path]::GetFullPath($OutputJson)
    $allowedRoots = @($env:TEMP, $env:USERPROFILE, "C:\Results", "C:\Logs")
    $pathAllowed = $false
    foreach ($root in $allowedRoots) {
        if ($root -and $resolvedPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $pathAllowed = $true
            break
        }
    }
    if (-not $pathAllowed) {
        Write-Host "  [WARN] OutputJson path '$resolvedPath' is outside allowed directories." -ForegroundColor Yellow
        Write-Host "         Allowed: `$env:TEMP, `$env:USERPROFILE, C:\Results, C:\Logs" -ForegroundColor Yellow
        Write-Host "         Skipping JSON export." -ForegroundColor Yellow
    } else {
        $output = @{
            Timestamp = (Get-Date -Format "o")
            Platform  = "$($csProduct.Vendor) / $($csProduct.Name)"
            Summary   = @{ Passed = $passed; Warnings = $warned; Failed = $failed }
            Checks    = $results
        }
        $output | ConvertTo-Json -Depth 3 | Set-Content -Path $resolvedPath -Encoding UTF8
        Write-Host "  Results saved to: $resolvedPath" -ForegroundColor Gray
    }
}
