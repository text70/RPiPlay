# Deploy — rebuilding on a fresh Raspberry Pi

Everything needed to reproduce the working setup (RPiPlay + InnoMaker DAC Mini
HiHat / PCM5122, Bluetooth A2DP, PipeWire mixing) on a fresh Raspberry Pi OS
64-bit install. This directory was extracted from the dead Pi's SD card.

## Quick start

```bash
# copy this repo to the new Pi (e.g. from the workstation):
rsync -a --exclude build --exclude .git ./ pi@<new-pi>:RPiPlay/
# on the Pi:
cd ~/RPiPlay/deploy && ./provision.sh
sudo reboot
# then pair the phone (see output of provision.sh)
```

`provision.sh` runs on the Pi as user `pi` and handles: system packages,
rpiplay build, boot config (InnoMaker overlay), the patched kernel module,
systemd services, and user lingering.

## Files

| File | Purpose |
|---|---|
| `provision.sh` | One-shot provisioning script (run on the Pi) |
| `boot-config-reference.txt` | Working `config.txt` extracted from the old SD card (reference only; provision.sh appends the needed lines itself) |
| `etc-default-rpiplay` | `/etc/default/rpiplay` — rpiplay service arguments |
| `systemd/rpiplay.service.pi` | Pi-local unit (`User=pi`, `EnvironmentFile`, points at `~/RPiPlay/build`) |
| `systemd/rpiplay-pipewire.conf` | Drop-in giving the service `XDG_RUNTIME_DIR` so the ALSA `pipewire` PCM finds the user's PipeWire socket |
| `systemd/bt-agent.service` + `bt-agent.sh` | Persistent NoInputNoOutput Bluetooth pairing agent |
| `modules/snd-soc-pcm512x-6.18.39+rpt-rpi-v8.ko` | Prebuilt patched module (only loads on that exact kernel) |
| `pcm512x-fix/` | Patched `pcm512x` source + Makefile + the two patch scripts |

## Why the patched pcm512x module + the allo-boss overlay exist

On Raspberry Pi OS kernels ≥ 6.12 (verified broken on 6.18.x), opening a
PCM512x-based sound card bound through the `hifiberry-dacplus*` overlays
fails permanently with:

```
ASoC error (-22): at snd_soc_pcm_component_pm_runtime_get() on pcm512x.1-004d
```

The codec's runtime resume (`pcm512x_resume` in `sound/soc/codecs/pcm512x.c`)
fails in `regulator_bulk_enable()`/`regcache_sync()`, and the runtime-PM core
stores that error, so every subsequent `pm_runtime_get_sync` re-returns -22.

The patches:
1. `patch_pcm512x.py` — `pcm512x_resume` logs-and-continues on those failures
   (`snd_soc_dai` `hw_params` writes all critical registers anyway).
2. `patch_pcm512x_retry.py` — the boot probe retries the codec reset for ~60 s,
   because some boards clock-stretch the I2C bus while their LDOs settle, and
   the bcm2835 I2C controller cannot handle clock stretching (errata).

**Use the `allo-boss-dac-pcm512x-audio` overlay** (not `hifiberry-dacplus*`):
the Allo Boss DAC machine driver binds the same PCM5122 at I2C 0x4D but its
overlay references no supplies (kernel dummy regulators → clean runtime-PM)
and its master path runs the PCM5122 in codec-master mode with the HAT's
onboard oscillators — correct for the InnoMaker's hardware design. The
resulting card is named `BossDAC`.

Two additional caveats found during bring-up:
* **Keep the HDMI cable unplugged** on the Zero: the connector shell sits
  next to the header and shorted HAT pins under contact (a power LED went
  dark when pressing the HAT; unplugging HDMI restored it).
* After boot the PipeWire sink can appear before the card finishes probing;
  if the sink list is empty or playback fails with EIO,
  `systemctl --user restart wireplumber` re-detects the card.

The patched module also restores the **hardware mixer** ("Digital" control on
the PCM5122), so phone volume works — which the `hifiberry-dac` stub-driver
fallback cannot do.

If the new Pi runs a different kernel, provision.sh rebuilds the module from
`pcm512x-fix/` (needs `raspberrypi-kernel-headers`, installed by the script).

## Layout on the Pi

```
~/RPiPlay/                       source + build (service runs build/rpiplay)
/etc/systemd/system/rpiplay.service (+ .d/pipewire.conf)
/etc/systemd/system/bt-agent.service
/etc/default/rpiplay             service arguments (RPIPLAY_ARGS)
/usr/local/sbin/bt-agent.sh      BT pairing agent loop
```

Audio topology: `rpiplay (AirPlay, ALSA "pipewire" PCM)` and `Bluetooth A2DP`
both terminate in the user's PipeWire, which mixes them onto the DAC card.
Trade-off: AirPlay volume changes are ignored by the ALSA renderer on the
"pipewire" PCM (no mixer there); Bluetooth volume works via AVRCP.
