# 2026-10-04: AMD dGPU hang on resume (not caused by Omabar)

**Outcome:** after a lid close and reopen, the screen locked up and the Mac had to be restarted. The Touch Bar was blank afterwards only because everything was. The cause was the **AMD Radeon (Navi 14) dGPU failing to resume**. Omabar and tiny-dfr were ruled out. This report is here so the next time it happens, nobody spends an afternoon blaming the Touch Bar.

## System

| | |
|---|---|
| Model | MacBookPro16,1 (16-inch 2019, Intel T2) |
| dGPU | `03:00.0` AMD Navi 14 [Radeon RX 5500M / Pro 5500M] and `03:00.1` its HDMI audio |
| Kernel | `linux-t2` 7.2.7 (`7.2.7-arch1-Watanare-T2-2-t2`), with `amdgpu.ppfeaturemask=0xfff7bffd` (the existing boot-hang workaround) |
| Mesa | 26.2.2 |
| Display | The internal panel (`eDP-1`) was driven by **amdgpu** (`card3`), so every resume depends on the dGPU waking up |
| Omabar | 0.1.0, about 10 minutes after replacing the `jonathan.touchbar-layouts` prototype |

## Timeline (the boot that ended in the hang)

That boot had been up since 15:41 and went through **five** suspend/resume cycles.

| Time | Event |
|---|---|
| 16:35, 16:52, 17:09 | Resumes 1–3 (prototype's resume service). Clean: no amdgpu warnings. |
| 17:30 | Cutover to Omabar. |
| 17:33:55 | Resume 4 (Omabar's `omabar-resume.service`). Touch Bar back and fine. **First warning sign:** `snd_hda_intel 0000:03:00.1: Refused to change power state from D0 to D3hot`. |
| 17:39:52 | Resume 5: lid opened. While `systemd-sleep` resumes devices, the kernel logs **17×** `WARNING: drivers/gpu/drm/amd/amdgpu/amdgpu_irq.c:670 at amdgpu_irq_put` and **3×** more D3hot refusals on `03:00.1`. tiny-dfr crashes as it does on every T2 resume (Touch Bar re-attaches; see AGENTS.md §10). |
| 17:39:55 | `amdgpu 0000:03:00.0: ring sdma0 timeout, signaled seq=30151, emitted seq=30155`, repeating every ~2 s. |
| 17:39:58 | `amdgpu: [drm] device wedged, but no recovery needed` |
| 17:40:08 | `amdgpu: [drm] *ERROR* amdgpu_vm_validate() failed.` |
| 17:40:24 | `Ring sdma0 reset succeeded`, amdgpu device coredump created (`/sys/class/drm/card3/device/devcoredump/data`). |
| 17:40:25 | `quickshell` (omarchy-shell, PID 94186) **aborts with SIGABRT inside Mesa** (`libgallium-26.2.2` → `abort`). The desktop is unusable and the user restarts the Mac. |

The next boot starts after the restart. Its first journal timestamps (17:39:53) look *earlier* than boot −1's last entry because the clock is corrected after boot; the order is real, the overlap isn't. Resume 6 (17:44:20, boot 0) is clean: no amdgpu warnings, and Omabar's resume service restarts tiny-dfr 2 s after wake as designed.

## Why it isn't Omabar or the Touch Bar

1. **Different hardware.** The Touch Bar is a USB display (`appletbdrm`, its own DRM card) on the T2 bridge. Omabar and tiny-dfr never open the AMD GPU.
2. **Same Omabar behaviour, different outcomes.** `omabar-resume.service` (sleep 2 s, restart tiny-dfr) ran identically at 17:33 (fine), 17:39 (hang) and 17:44 (fine). The prototype's equivalent ran at 16:52 and 17:09 (fine).
3. **The first failure is in the dGPU's own power management,** during device resume (`systemd-sleep` context), before any user-space Omabar code runs. The audio function `03:00.1` refusing D3hot was already visible on the resume before.
4. **Pattern:** the failure arrived on the 5th suspend of a 2-hour boot, after a warning on the 4th. That points at accumulated dGPU/driver state across suspends.

## How to recognise it next time

```bash
journalctl --list-boots | tail -3                                   # an unexpected new boot?
B=-1   # the boot that ended badly
journalctl -b $B -k | grep -c 'amdgpu_irq.c:670'                    # irq warnings during resume
journalctl -b $B -k | grep -E 'Refused to change power state'       # 03:00.1 refusing D3hot (early sign)
journalctl -b $B -k | grep -E 'ring .* timeout|device wedged'       # the hang
journalctl -b $B | grep -E 'quickshell.*(terminated|dumped core)'   # shell crash in libgallium
journalctl -b $B --grep 'PM: suspend exit'                          # how many resumes that boot had
```

If those match and `bin/omabar doctor` is clean after the restart, it's this issue, not Omabar.

## Possible follow-ups (not done)

- **Drive the internal panel from the Intel iGPU** (gmux switch, e.g. the t2linux `apple-gmux`/`gpu-switch` approach) so the dGPU can stay powered off. That removes it from every suspend/resume.
- Try other `amdgpu` options for runtime PM and resume, or a newer kernel or Mesa, if hangs recur.
- Reboot periodically if long uptimes with many suspends turn out to be the trigger.
- The amdgpu devcoredump (`/sys/class/drm/card3/device/devcoredump/data`) only lasts until reboot. Save it next time if reporting upstream (drm/amd).
