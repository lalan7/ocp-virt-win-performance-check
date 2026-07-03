# ocp-virt-win-performance-check

PowerShell validation and benchmark tool for Windows VMs running on OpenShift Virtualization (KVM/QEMU).

Checks that all performance-critical parameters are correctly configured: Hyper-V enlightenments, VirtIO drivers, OS tuning, storage optimization, and optional disk I/O benchmarks.

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

# Run troubleshooting diagnostics
.\Test-VMPerformance.ps1 -RunDiagnostics

# Everything
.\Test-VMPerformance.ps1 -RunBenchmark -RunDiagnostics -OutputJson "$env:TEMP\results.json"
```

## What It Checks

### 1. Hyper-V Enlightenments

| Check | Why It Matters |
|---|---|
| Hypervisor presence | Confirms Windows sees the KVM hypervisor via Hyper-V interface (CPUID leaf 0x40000000) |
| SMBIOS platform (Red Hat/OpenShift) | Validates the VM is running on OpenShift Virtualization, not another hypervisor |
| `useplatformclock` | When enabled, forces Windows to use a slow platform timer instead of TSC. Should be off |
| Hyper-V Integration Services | Running services indicate enlightenment features are active |
| hv-time/hv-reenlightenment | Time synchronization IC provides accurate guest clock and handles TSC frequency changes during live migration |
| hv-stimer (synthetic timer) | Low-latency timer interrupts without expensive VM exits |
| hv-vpindex/hv-runtime | Virtual processor index and runtime tracking enable better guest scheduling |

**Reference**: [Red Hat: Optimizing Windows VMs (Hyper-V Enlightenments)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_windows_virtual_machines/optimizing-windows-virtual-machines)

### 2. VirtIO Drivers

| Driver | Purpose | Impact if Missing |
|---|---|---|
| viostor | VirtIO block storage | Falls back to emulated IDE (10x slower) |
| vioscsi | VirtIO SCSI controller | No SCSI multiqueue, no TRIM/unmap |
| netkvm | VirtIO network (NetKVM) | Falls back to emulated e1000 (1Gbps cap, high CPU) |
| vioser | VirtIO serial | No serial console communication |
| balloon | VirtIO memory ballooning | Host cannot reclaim unused guest memory |
| vioinput | VirtIO input | Mouse/keyboard via emulated USB (higher latency) |
| viogpudo | VirtIO GPU | No paravirt display |
| viorng | VirtIO RNG | Slow entropy generation (affects crypto, SSH keygen) |
| viofs | VirtIO filesystem | No shared folders with host |
| QEMU Guest Agent | Management agent | No graceful shutdown, no IP reporting, no VSS quiesce for snapshots |

**Reference**: [Red Hat: Installing VirtIO drivers](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_windows_virtual_machines/optimizing-windows-virtual-machines)

### 3. OS Optimization

| Check | Why It Matters |
|---|---|
| Windows Search (WSearch) | Indexes files continuously, causing random I/O spikes on virtual disks |
| SysMain/Superfetch | Prefetches data to RAM based on usage patterns; pointless in VMs with volatile memory |
| Scheduled Defrag | Defragments disks on schedule; unnecessary on virtual disks (host storage handles layout) |
| Power Plan | "Balanced" throttles CPU frequency; "High Performance" prevents p-state transitions |
| RSS (Receive Side Scaling) | Distributes network interrupt processing across multiple CPUs |
| Checksum Offload | Offloads TCP/UDP checksum to NIC hardware/driver; reduces CPU usage |
| LSO/TSO (TCP Segmentation Offload) | Offloads large TCP segment splitting to NIC; improves throughput |

**Reference**: [cr0x.net: 8 settings that matter for Windows VMs](https://cr0x.net/en/proxmox-windows-vm-slow-settings/)

### 3b. Storage Optimization

| Check | Why It Matters |
|---|---|
| TRIM (DisableDeleteNotify) | When enabled (value=0), Windows sends TRIM/unmap commands to reclaim deleted blocks. Critical for thin-provisioned storage to prevent bloat |
| Storage Controller type | VirtIO SCSI/Block vs emulated IDE. Emulated IDE has no multiqueue, no TRIM, 10x slower |
| Pagefile location | Pagefile should be on VirtIO disk, not an emulated device |
| Disk Queue Length | High queue depth (>4) at rest indicates I/O bottleneck or missing IOThreads on host |

**Reference**: [virtio-win issue #666: TRIM/Discard optimization](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/666) (set `discard_granularity=32M` on host for fast TRIM)

### 4. Memory & CPU

| Check | Why It Matters |
|---|---|
| Balloon Service | Enables host to reclaim unused guest memory dynamically |
| Memory Compression | Windows 10+ compresses pages before swapping; may conflict with balloon driver |
| NUMA Topology | Guest should see correct NUMA layout matching host for optimal memory locality |
| Visual Effects | Animations, transparency, and smooth scrolling waste CPU in headless/VM scenarios |
| Timer Resolution | Apps requesting high-res timers (1ms) increase interrupt rate and power usage |

**Reference**: [SmolVM: Windows Guest Deep Dive](https://github.com/celestoai/smolvm/blob/main/docs/deep-dive/windows-guest-qemu.md)

### 5. Disk Benchmark (DiskSpd)

| Test | Pattern | What It Measures |
|---|---|---|
| Seq Read 128K | Sequential, large block, 100% read | Throughput (streaming reads, backups, large file copies) |
| Rand Read 4K | Random, small block, 100% read | IOPS (database reads, OS boot, app loading) |
| Rand Write 4K | Random, small block, 100% write | IOPS (database writes, logging, journaling) |
| Mixed 4K 70R/30W | Random, small block, 70% read / 30% write | Real-world mixed workload (typical application I/O) |

**Reference**: [Microsoft DiskSpd](https://github.com/microsoft/diskspd), [Proxmox Benchmark Tutorial](https://forum.proxmox.com/threads/proxmox-ve-7-2-benchmark-aio-native-io_uring-and-iothreads.116755/)

### 6. Diagnostics (`-RunDiagnostics`)

| Category | Commands |
|---|---|
| Disk, Boot & FS | Disk health, volume inventory, BCD boot config |
| Networking | NIC status, IP config, routing table, firewall state |
| Device Drivers | VirtIO/QEMU PnP drivers, devices with problems |
| Backup & Snapshot | QEMU Guest Agent, VSS writers/providers |
| BitLocker | Encryption status for all volumes |
| Hibernation | Available sleep states (should show hibernation off) |
| Performance | System info, top 10 processes by CPU |
| Logs | Last 10 system errors (24h), MTV firstboot log |

## Host-Side Verification (OpenShift/KVM)

Individual Hyper-V enlightenment parameters cannot be fully enumerated from inside the Windows guest. For per-parameter verification, run from the OpenShift host:

```bash
# Check all running VMs for missing enlightenments
oc get vmi -A -o json | python3 -c "
import json, sys
expected = {'hv-frequencies','hv-ipi','hv-reenlightenment','hv-relaxed','hv-reset','hv-runtime','hv-spinlocks','hv-stimer','hv-synic','hv-tlbflush','hv-vapic','hv-vpindex'}
data = json.load(sys.stdin)
for item in data.get('items', []):
    ns = item['metadata']['namespace']
    name = item['metadata']['name']
    hyperv = item.get('spec',{}).get('domain',{}).get('features',{}).get('hyperv',{})
    mapping = {'frequencies':'hv-frequencies','ipi':'hv-ipi','reenlightenment':'hv-reenlightenment',
               'relaxed':'hv-relaxed','reset':'hv-reset','runtime':'hv-runtime','spinlocks':'hv-spinlocks',
               'synic':'hv-synic','synictimer':'hv-stimer','tlbflush':'hv-tlbflush','vapic':'hv-vapic','vpindex':'hv-vpindex'}
    found = {mapping[k] for k in hyperv if k in mapping}
    missing = expected - found
    if not hyperv:
        print(f'NO HYPERV: {ns}/{name}')
    elif missing:
        print(f'MISSING: {ns}/{name} -> {sorted(missing)}')
    else:
        print(f'OK: {ns}/{name} (all 12 enlightenments present)')
"
```

### Host-Side Performance Tuning Checklist

These settings are configured on the OpenShift/KVM host (not inside the guest) and have significant impact on Windows VM performance:

| Setting | Recommended | Impact |
|---|---|---|
| IOThreads | 1 per disk | Moves I/O off VCPU thread; ~15% latency improvement at QD=1 |
| Disk cache | `cache=none` | Prevents double-caching (host page cache + guest cache) |
| AIO mode | `native` (raw block) or `io_uring` (file-backed) | Async I/O; `threads` is legacy and slow |
| Discard | `discard=unmap, detect-zeroes=unmap` | Passes TRIM to host; qcow2 files shrink |
| discard_granularity | `32M` | Fixes 10-15 min defrag times (matches Hyper-V behavior) |
| CPU model | `host-passthrough` or `host-model` | Exposes host CPU features; required for some enlightenments |
| Machine type | q35 | Modern chipset; required for PCIe, IOMMU groups |
| Hugepages | Optional (1-2% gain) | Static 1 GiB hugepages beat THP slightly under contention |
| CPU pinning | Optional (single-digit % gain) | Only helps under host contention; reduces scheduler flexibility |

**References**:
- [Blockbridge: aio=native vs io_uring benchmark](https://kb.blockbridge.com/technote/proxmox-aio-vs-iouring/)
- [Proxmox Forum: IOThreads benchmark](https://forum.proxmox.com/threads/proxmox-ve-7-2-benchmark-aio-native-io_uring-and-iothreads.116755/)
- [Medium: Improving Windows on QEMU](https://leduccc.medium.com/improving-the-performance-of-a-windows-10-guest-on-qemu-a5b3f54d9cf5)

## Benchmark Thresholds

The script uses minimum floor thresholds to detect misconfigured storage. Results below these values trigger a `WARN`:

| Test | Floor (IOPS) | Typical Local NVMe | Typical ODF/Ceph RBD | Typical NFS |
|---|---|---|---|---|
| Seq Read 128K | 400 | 4,000-16,000+ | 1,500-6,000 | 500-2,000 |
| Rand Read 4K | 1,000 | 10,000-100,000+ | 5,000-30,000 | 1,000-5,000 |
| Rand Write 4K | 500 | 10,000-80,000+ | 2,000-15,000 | 500-3,000 |
| Mixed 4K 70R/30W | 500 | 8,000-60,000+ | 3,000-20,000 | 1,000-4,000 |

Results above the floor get `PASS`. Actual performance depends on:
- **Storage backend**: local NVMe > SAN/FC > ODF/Ceph RBD > NFS
- **Network**: 10GbE vs 25GbE vs storage-dedicated network
- **Cache mode**: `writeback` vs `writethrough` vs `none`
- **Queue depth and threads**: configured in DiskSpd via `-o` and `-t`

Compare against your own baseline for the same storage class.

## Getting the Script into the VM

**Option 1: Download** (if VM has internet):
```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/lalan7/ocp-virt-win-performance-check/main/Test-VMPerformance.ps1" -OutFile "$env:TEMP\Test-VMPerformance.ps1" -UseBasicParsing
& "$env:TEMP\Test-VMPerformance.ps1" -RunBenchmark
```

**Option 2: Copy-paste** via VNC/RDP console into PowerShell ISE.

**Option 3: virtctl** (from host):
```bash
virtctl ssh -n <namespace> <vm-name> -- powershell -Command "Set-Content -Path C:\Test-VMPerformance.ps1 -Value (Get-Content -Raw -Path /dev/stdin)" < Test-VMPerformance.ps1
```

## References

| Resource | URL |
|---|---|
| Red Hat: Optimizing Windows VMs (RHEL 10) | https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_windows_virtual_machines/optimizing-windows-virtual-machines |
| Red Hat: Certified Guest OS (Windows) | https://access.redhat.com/articles/4234591 |
| Microsoft: DiskSpd | https://github.com/microsoft/diskspd |
| KubeVirt: Hyper-V Enlightenments | https://kubevirt.io/user-guide/user_workloads/guest_operating_system_information/ |
| Proxmox: aio/IOThread benchmark | https://forum.proxmox.com/threads/proxmox-ve-7-2-benchmark-aio-native-io_uring-and-iothreads.116755/ |
| Blockbridge: aio=native vs io_uring | https://kb.blockbridge.com/technote/proxmox-aio-vs-iouring/ |
| cr0x.net: 8 Windows VM settings | https://cr0x.net/en/proxmox-windows-vm-slow-settings/ |
| SmolVM: Windows Guest QEMU deep dive | https://github.com/celestoai/smolvm/blob/main/docs/deep-dive/windows-guest-qemu.md |
| Medium: Windows 11 on QEMU performance | https://leduccc.medium.com/improving-the-performance-of-a-windows-10-guest-on-qemu-a5b3f54d9cf5 |
| virtio-win: TRIM/Discard fix (issue #666) | https://github.com/virtio-win/kvm-guest-drivers-windows/issues/666 |

## Requirements

- Windows 10/11 or Windows Server 2019+
- PowerShell 5.1+ (built-in)
- Run as Administrator
- DiskSpd is auto-downloaded if `-RunBenchmark` is used (MIT license)

## License

MIT
