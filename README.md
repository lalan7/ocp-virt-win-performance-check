# ocp-virt-win-performance-check

PowerShell validation and benchmark tool for Windows VMs running on OpenShift Virtualization (KVM/QEMU).

Checks that all performance-critical parameters are correctly configured: Hyper-V enlightenments, VirtIO drivers, OS tuning, and optional disk I/O benchmarks.

## Quick Start

Inside the Windows VM (as Administrator):

```powershell
# Allow script execution for this session
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Validation only
.\Test-VMPerformance.ps1

# With disk benchmark (30s per test)
.\Test-VMPerformance.ps1 -RunBenchmark

# Longer benchmark for more accurate results
.\Test-VMPerformance.ps1 -RunBenchmark -BenchmarkDuration 60
```

## What It Checks

| Category | Checks |
|---|---|
| Hyper-V Enlightenments | Hypervisor presence, SMBIOS platform (Red Hat/OpenShift), `useplatformclock` status |
| VirtIO Drivers | viostor, vioscsi, netkvm, balloon, vioserial, vioinput, viorng, viofs, QEMU Guest Agent |
| OS Optimization | Windows Search, SysMain/Superfetch, Scheduled Defrag, Power Plan, RSS offload |
| Memory/CPU | RAM total/free, CPU count, Balloon service status |
| Disk Benchmark | DiskSpd: sequential read 128K, random read/write 4K IOPS, mixed 70R/30W |

## Expected Results (VirtIO + Hyper-V Enlightenments, NVMe backend)

| Metric | Expected Range |
|---|---|
| Seq Read 128K | 1,000+ MB/s |
| Rand Read 4K | 30,000+ IOPS |
| Rand Write 4K | 40,000+ IOPS |
| Mixed 4K 70R/30W | 35,000+ IOPS |

Results will vary based on storage backend (local NVMe vs. networked storage like Ceph/ODF).

## Output Example

```
=== 1. HYPER-V ENLIGHTENMENTS ===
  [PASS] Hypervisor detected - Guest sees a hypervisor (Hyper-V interface)
  [PASS] Platform detection - Running on OpenShift Virtualization
  [PASS] useplatformclock - Not set (default=off on Win10+)

=== 2. VIRTIO DRIVERS ===
  [PASS] VirtIO Block Storage - v100.92.104.24500
  [PASS] VirtIO Network (NetKVM) - v100.92.104.24500
  [PASS] VirtIO Balloon (memory) - v100.92.104.24500
  [PASS] QEMU Guest Agent - Running

=== 3. OS OPTIMIZATION ===
  [PASS] Windows Search - Disabled/Stopped
  [PASS] SysMain (Superfetch) - Disabled/Stopped
  [WARN] Power Plan - Current: Balanced (set High Performance: powercfg /setactive 8c5e7fda-...)

=== SUMMARY ===
  Passed: 12 | Warnings: 1 | Failed: 0
```

## Getting the Script into the VM

**Option 1: Copy-paste** via VNC console into PowerShell ISE.

**Option 2: Download** (if VM has internet):
```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/<user>/ocp-virt-win-performance-check/main/Test-VMPerformance.ps1" -OutFile .\Test-VMPerformance.ps1
```

**Option 3: virtctl** (from host):
```bash
# Upload via guest agent (requires qemu-ga running in the VM)
virtctl ssh -n <namespace> <vm-name> -- powershell -Command "Set-Content -Path C:\Test-VMPerformance.ps1 -Value (Get-Content -Raw -Path /dev/stdin)" < Test-VMPerformance.ps1
```

## Why These Checks Matter

Windows on KVM without proper configuration can lose 30-50% performance vs. bare metal:

- **Missing VirtIO drivers**: Falls back to emulated IDE/e1000 (10x slower I/O)
- **Missing Hyper-V enlightenments**: Windows uses expensive trap-and-emulate paths instead of paravirt fast paths
- **Background services**: Windows Search, SysMain, Defrag cause unpredictable I/O spikes on virtual disks
- **Wrong power plan**: "Balanced" throttles CPU frequency in VMs

## References

| Resource | URL |
|---|---|
| Red Hat: Optimizing Windows VMs | https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_windows_virtual_machines/optimizing-windows-virtual-machines |
| Red Hat: Certified Guest OS (Windows) | https://access.redhat.com/articles/4234591 |
| Microsoft: DiskSpd | https://github.com/microsoft/diskspd |
| KubeVirt: Hyper-V Enlightenments | https://kubevirt.io/user-guide/user_workloads/guest_operating_system_information/ |

## Requirements

- Windows 10/11 or Windows Server 2019+
- PowerShell 5.1+ (built-in)
- Run as Administrator
- DiskSpd is auto-downloaded if `-RunBenchmark` is used (MIT license)

## License

MIT
