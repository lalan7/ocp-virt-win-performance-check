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

.PARAMETER RunBenchmark
    If specified, runs DiskSpd disk benchmark after validation.

.PARAMETER BenchmarkDuration
    Duration in seconds for DiskSpd test (default: 30).

.PARAMETER OutputJson
    If specified, writes results to a JSON file at the given path.

.EXAMPLE
    .\Test-VMPerformance.ps1
    .\Test-VMPerformance.ps1 -RunBenchmark -BenchmarkDuration 60
    .\Test-VMPerformance.ps1 -RunBenchmark -OutputJson C:\results.json
#>

param(
    [switch]$RunBenchmark,
    [int]$BenchmarkDuration = 30,
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

$cpuCaption = (Get-CimInstance Win32_Processor).Caption
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
$cpuCount = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
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

        function Invoke-DiskSpd {
            param([string]$Args, [string]$TestName)
            Write-Host "  Running $TestName (${BenchmarkDuration}s)..." -ForegroundColor Gray
            $output = & $diskspdPath $Args.Split(' ') 2>&1 | Out-String
            try {
                [xml]$xml = $output
                $readCount = 0; $writeCount = 0; $readBytes = 0; $writeBytes = 0
                foreach ($thread in $xml.Results.TimeSpan.Thread) {
                    $readCount += [long]$thread.Target.ReadCount
                    $writeCount += [long]$thread.Target.WriteCount
                    $readBytes += [long]$thread.Target.ReadBytes
                    $writeBytes += [long]$thread.Target.WriteBytes
                }
                $duration = [double]$xml.Results.TimeSpan.TestTimeSeconds
                $totalCount = $readCount + $writeCount
                $totalBytes = $readBytes + $writeBytes
                if ($duration -gt 0 -and $totalCount -gt 0) {
                    $iops = [math]::Round($totalCount / $duration, 0)
                    $mbps = [math]::Round($totalBytes / $duration / 1MB, 2)
                    return "$iops IOPS ($mbps MB/s)"
                }
                return "No I/O recorded"
            } catch {
                return "Parse error: $_"
            }
        }

        $seqReadResult = Invoke-DiskSpd "-b128K -d$BenchmarkDuration -o4 -t2 -r -w0 -Sh -c1G -Rxml $testFile" "sequential read 128K"
        $randReadResult = Invoke-DiskSpd "-b4K -d$BenchmarkDuration -o32 -t2 -r -w0 -Sh -c1G -Rxml $testFile" "random read 4K"
        $randWriteResult = Invoke-DiskSpd "-b4K -d$BenchmarkDuration -o32 -t2 -r -w100 -Sh -c1G -Rxml $testFile" "random write 4K"
        $mixedResult = Invoke-DiskSpd "-b4K -d$BenchmarkDuration -o32 -t2 -r -w30 -Sh -c1G -Rxml $testFile" "mixed 4K 70R/30W"

        Write-Host ""
        Write-Check "Seq Read 128K" "INFO" "$seqReadResult"
        Write-Check "Rand Read 4K" "INFO" "$randReadResult"
        Write-Check "Rand Write 4K" "INFO" "$randWriteResult"
        Write-Check "Mixed 4K 70R/30W" "INFO" "$mixedResult"

        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
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

Write-Host "`n  Docs: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_windows_virtual_machines/optimizing-windows-virtual-machines" -ForegroundColor Gray
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
