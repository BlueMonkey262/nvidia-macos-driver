# Game compatibility and observed failures

These are observations on one RTX 2060 Super (8 GB VRAM, 256 MB BAR1) with macOS 15.8.1 in a passthrough VM.
They do not qualify other cards or configurations. A successful launch is not a gameplay pass.

## No Man's Sky: fatal error during initial loading/rendering

**Status: known broken on the tested configuration.** The native Intel build (Steam build 25732212; executable
reports version 4.70) reaches the galaxy fly-through, spends roughly 17 minutes loading shaders, then displays
its fatal-error dialog before playable gameplay is verified. The inspected settings were 1920×1080, Low graphics,
MetalFX Spatial and a 30 fps limit. Observed 2026-10-18.

### Confirmed evidence

- While loading, the main thread was translating Metal shader entries through `libnvmtl_translate` and
  `metal2vulkan`. The writable SPIR-V cache gained about 9,100 new vertex/fragment stage entries during the run,
  with hundreds still arriving per minute. This establishes compilation progress, not completion of all shaders.
- Around the transition to the failure, the driver reported image allocations occupying about 6077 MB of VRAM
  and overall heap usage reaching its reported 7472 MB budget. Private-buffer allocations as small as 36 bytes
  were refused and fell back to system memory. Colour images also spilled, reaching a reported 521 MB in system
  memory. The kernel logged `NV_ERR_NO_MEMORY` from pool allocation. Other processes had BAR1 mapping failures
  too; those are separate from this game's CPU fault.
- A live sample taken while the fatal dialog was open captured this main-thread path:

  ```text
  cGcApplicationLocalLoadState::Render
    ... SetMaterialTextures / cTkGraphicsAPI::SetTexture
      -[NVMTLArgumentEncoder setTexture:atIndex:] +29
        address 0
          _sigtramp
            HandleSignal(int)
              cTkSystem::DoSystemMessageBox
                CFUserNotificationReceiveResponse
  ```

- Disassembly of the installed plugin places that return address immediately after the method's initial
  indirect `_objc_retain` call on the incoming texture. It is before argument-field lookup, `gpuResourceID`
  retrieval and the handle write into the argument buffer. That narrows the failure beyond the method name alone.
- The process remained alive at low CPU while its signal handler waited for the dialog response. No new native
  macOS `.ips` crash report was found during inspection. The game's text logs contained no useful failure details.
  The sampled stack and unified log are the available diagnostic evidence.

### Interpretation and unresolved cause

The immediate failure is a null-address CPU call during texture argument-buffer binding. GPU-memory exhaustion
preceded it, but the logs do not prove that exhaustion caused the null call. The original signal registers and
live import slot were not captured: the process exited before debugger attachment. An invalid or stale texture,
runtime dispatch or import-pointer corruption, and a resource failure propagating an invalid object remain
investigation paths. None is confirmed. There is no evidence here that Steam file verification fixes this driver
failure, or that every shader had finished when the dialog appeared.

### Next investigation and pass condition

Preserve the populated shader cache. On a controlled rerun, capture the original signal context, the texture
argument and the `_objc_retain` target. Check ownership and concurrent resource eviction around argument binding,
and trace GPU-memory accounting and fallback allocation failures. Compare lower texture pressure separately to
test whether memory pressure affects reproduction. Do not infer a fix merely because a reduced workload survives.

Pass requires reaching playable native gameplay without the fatal dialog, followed by a focused regression for
the identified binding or resource-lifetime bug. No fix has been implemented or tested for this failure.

## Other current observations

- **Factorio 2.0.77, Space Age:** startup fails creating a mipmap staging buffer. The driver reports
  `vkMapMemory -> -2` with 127,038 live buffers and 10.7 GB allocated. The later crash-upload error is secondary.
  Buffer lifetime and allocation pressure remain unresolved. Failure observed on Turing; logs inspected.
- **Kerbal Space Program 1.12.5:** atmospheric flight works with low FPS reported by the tester. The log confirms
  OpenGL 4.1, shader-cache permission failures and BC7 decompression warnings. Their contribution to frame time
  has not been measured. Gameplay observed on Turing; performance attribution pending.
