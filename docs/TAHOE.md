# macOS 26 (Tahoe): what we did to make it work, and what may not work for you

Status: **one setup, VM-tested, 2026-10-19.** An RTX 2060 Super (Turing, TU106) passed through to a Proxmox/QEMU
virtual machine, macOS 26.7.1 (build 25G241), OpenCore 1.0.6, Lilu 1.6.8, WhateverGreen 1.6.7, driver package 2.3.7
plus this fork's plugin. The VM reports itself as `iMac19,1`. Nothing here has been run on real Mac hardware, on a
PC booting macOS natively, on other cards, or by anyone but us. Labels follow [CONTRIBUTING.md](../CONTRIBUTING.md):
*VM-tested* means we ran it on that one setup; *not tested* means we did not.

macOS 26 is the last macOS release for Intel Macs, which is why it matters: software vendors will target it, so it is
the version most likely to stay supported. It is also the version least likely to be simple to set up.

## What worked without any change to the driver

*VM-tested.* After an in-place upgrade from macOS 15.8.1 (done with Software Update; the 2.3.6 kexts were installed
before the upgrade) the NVIDIA kexts loaded on macOS 26 as they were: `NVRM`, `NVRMFB`, `NVRMAGDC` and `NVAccel`
(upstream builds a separate `NVAccel` for macOS 26; `package/install.sh` picks the build by `sw_vers`). The card showed up
as `Metal Support: Metal 3`, the display came up on the first boot, and WindowServer rendered through our Metal plugin
(its surfaces appear in the plugin log). A compute kernel and our Metal tests ran. The boot arguments and OpenCore settings
carried over unchanged.

## The steps, in order

1. Start from a working macOS 15 setup of this driver. Keep a way back: we took a snapshot of the VM before every step.
2. Upgrade macOS 15 to 26 with Software Update. Expect several restarts and a long time on the Apple logo; the progress
   bar sat at "8 more minutes" and "2 more minutes" for a while in ours, and it was well over half an hour in total.
3. Check the driver loaded (`kmutil showloaded --list-only | grep nullmoth` shows four kexts, `system_profiler
   SPDisplaysDataType` shows your card with Metal).
4. Install the matching driver package with its installer (`sudo ./install.sh`) and restart. Run `sudo CHECK=1 ./install.sh`
   first: it builds a test kernel collection and changes nothing. The installer backs up what was installed, installs a
   fallback that restores the old driver if the new one cannot bring the display up, and prints the undo command.
5. **Clear the icon caches, then restart.** See below. This was the single biggest fix for what we saw.
6. If you use Sunshine, see the streaming notes below.

## Stale icon caches (the fix for broken Dock icons)

*VM-tested.* After the upgrade, many Dock and Finder icons were missing their glyph layers: Finder had no face, Safari no
needle, the App Store no "A". Opening an app fixed some of them. We first suspected the driver (and one possible driver bug
is still open, see below), but the cause was **icon caches that macOS had generated while an earlier driver version
drew the Liquid Glass icon shaders wrongly**. Our first clears did not help because we missed some of the caches. Removing all
of these and restarting rebuilt every icon correctly:

```
/Library/Caches/com.apple.iconservices.store
/private/var/folders/*/*/C/com.apple.iconservices
/private/var/folders/*/*/C/com.apple.iconservicesagent
/private/var/folders/*/*/C/com.apple.dock.iconcache
/private/var/folders/*/*/0/com.apple.dock.launchpad      (resets the Launchpad layout)
/private/var/folders/*/*/T/com.apple.iconservicesagent
```

Removing them needs sudo; macOS rebuilds them on demand. A tool that clears them once per macOS build and driver version is planned.

The first boot after a clear is slow: the icon service rebuilds every icon, the system load went above 180
on a four-core VM for about four minutes, then settled. That is normal, once.

## What may not work for you, and why it will not always be easy

- **Your Mac may not be allowed to install macOS 26.** Apple supports only a short list of Intel Macs. Our VM reports
  `iMac19,1`, which is not on that list, and the installer still went through. We did not change the model for the upgrade
  and we do not know why it was accepted; do not assume yours will be. A PC booting macOS through OpenCore has to present a
  model macOS 26 accepts, and that is outside this driver.
- **OpenCore, SIP and boot arguments are yours.** Our values (README, "Wiring into an existing OpenCore setup") worked
  unchanged: `csr-active-config` `0x0A43`, `nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80
  ipc_control_port_options=0`, `SecureBootModel` `Disabled`. If your setup differs, kexts may be refused after the upgrade.
- **WhateverGreen.** The installer warns that with WhateverGreen loaded and no `gfxrst=4` boot argument the Mac may panic
  when the NVIDIA display first opens. Ours did not panic without it, but add `gfxrst=4` if you can.
- **A display must be attached when the card starts** (docs/VM-NOTES.md).
- **Black screen after the upgrade.** The installer's fallback restores the previous driver if the new one cannot start. If you
  have SSH, `sudo ./uninstall.sh <backup folder printed by the installer>` restores it. Do not delete the backup folder under
  `/Library/NullMoth/` until you are sure.
- **Each restart may stop at the OpenCore picker.** In a VM that boots OpenCore from a disk image the picker can need a key
  press; we sent it from Proxmox with `qm sendkey`.
- **The package's encoder libraries changed in 2.3.7.** This fork's Turing H.264/HEVC encode patches only accept the
  2.2.0/2.3.6-era stock libraries, not the ones in the 2.3.7 package. On our VM we kept the older patched libraries. Until
  the patch scripts are updated, a clean 2.3.7 install on Turing has no hardware encode from this fork.
- **Our plugin is a debug build in our test; release builds ignore `NVMTL_*` environment variables** and read
  `/Library/GPUBundles/nvmtl/nvrm610.conf` instead.

## Known problems on Tahoe in our setup

- **Red patches on the glass "A" of the App Store icon** in the Dock, and possibly other glass icons: a few dozen pixels per
  icon, polygon-shaped, in the composited display. The icon service's own bitmap of the same icon is clean, so the red is added
  while the Dock is drawn. *Not understood.* Framebuffer fetch for WindowServer (`NVMTL_FBFETCH_WS=1`) did not change it.
- **Buffer-backed textures at offsets that are multiples of 16 but not of 32 are refused** and return nil. Apple's code creates
  them. They did not occur during the final icon rebuild but could elsewhere. A fix is in progress.
- **First boot after a cache clear is slow** (see above).
- **Sunshine's first H.264 session fails once with -12902 and then succeeds**, about five seconds later, when Sunshine calls
  VideoToolbox before its first Metal call. HEVC worked in a real Moonlight stream at 1080p.
- **Games, the Metal test suite and codec tests were run on macOS 15 first; most are not yet re-run on 26.**

## Reporting

If you try this, tell us the card, how macOS booted (hardware, OpenCore, VM), the model it reports, what worked, and include `/tmp/nvmtl.log`, the output of `kmutil showloaded --list-only | grep nullmoth` and `system_profiler SPDisplaysDataType`, and look through them before sharing.
Label what you report as VM-tested, tested on hardware, or not tested.
