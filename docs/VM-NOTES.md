# Running the driver in a QEMU/KVM (Proxmox) macOS VM

Notes from one setup: Proxmox VE (Linux 6.17), QEMU with `isa-applesmc`, OpenCore, a macOS 15.8.1 guest, an RTX 2060 Super
passed through with VFIO, a 6-core desktop CPU as the host, driver 2.2.0 with this fork's changes. Labels follow
[CONTRIBUTING.md](../CONTRIBUTING.md); nothing here has been checked on another host or guest.

## A display must be connected when the GPU starts

When the VM's only display is the passed-through GPU (`-vga none`), NVRMFB enumerates the connected monitors at boot. With
none connected it logs `ENUMERATED: 0 connected display(s)` and `not starting`, and WindowServer runs in software until the
next boot: solid Dock, no translucency, no desktop. A monitor that is disconnected (or switched to another input) while the
guest boots has the same effect. Use a dummy HDMI/DisplayPort plug, or keep the monitor connected and on the right input.
*VM-tested on Turing.*

## `PerfPowerServices` can use one vCPU all the time

Symptom: `/usr/libexec/PerfPowerServices` at 90-100% CPU from boot, and a load average above the vCPU count. A `sample` shows
its `PLSMCMetricsAgent` thread looping in `SMCGetKeyFromIndex` -> `SMCKextCall` -> `io_connect_method`, almost all of the
time inside the kernel call: it enumerates every SMC key again and again, and each lookup goes through QEMU's emulated I/O
ports. It is the same with VirtualSMC loaded and with only Apple's `AppleSMC` (VirtualSMC disabled in OpenCore, `isa-applesmc`
underneath). The daemon only does power logging, which means nothing in a VM. Disabling it frees the core:

```bash
sudo launchctl disable system/com.apple.PerfPowerServices     # persistent
sudo launchctl bootout system/com.apple.PerfPowerServices     # stop it now
# undo: sudo launchctl enable system/com.apple.PerfPowerServices
```

*VM-tested on Turing: the daemon's CPU use before and after. The effect on stream smoothness is not established.*

## "Unknown" CPU in About This Mac

The Proxmox UI said `host`, but the guest reported "Intel Core Processor (Skylake)". The QEMU command line had two `-cpu`
options, the one Proxmox generates and the one from the VM's `args:` line (`-cpu Skylake-Client,...`); the last one wins. The
label is cosmetic: in the guest the invariant TSC is present (`TSCI`), AVX2 and BMI1/2 are exposed, and a timestamp call costs
about 100 ns. The extra CPU flags in the Proxmox dialog (`md-clear`, `spec-ctrl`, `ssbd`, `pcid`, `nested-virt`) only change
the overridden option. *VM-tested on Turing.*

## Not established

- Whether the host is a bottleneck (vCPU contention, other VMs). Measuring it needs the Proxmox side (`/proc/pressure/cpu`,
  `top -H` on the VM's process).
