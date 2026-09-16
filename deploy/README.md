# Deploy — rebuilding on a fresh Raspberry Pi

Everything needed to reproduce the working setup: RPiPlay (AirPlay mirroring)
plus a Bluetooth A2DP speaker, both mixed through PipeWire onto an InnoMaker
DAC Mini HiHat (PCM5122) HAT. Verified end-to-end on a Raspberry Pi Zero W
v1.1 running Raspberry Pi OS Trixie (32-bit armhf, kernel 6.18.50+rpt-rpi-v6).

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
the rpiplay build, the boot config (DAC overlay), the patched kernel module,
all systemd services, and user lingering. Phone pairing needs the Bluetooth
settings screen open on the phone; the Pi auto-accepts (NoInputNoOutput
agent) and the script leaves the Pi permanently discoverable.

## The final audio topology (verified working)

```
Phone (Bluetooth A2DP) -> BlueZ -> bluealsa -> bluealsa-aplay
                                                   | (ALSA "default" PCM)
iPhone (AirPlay) -> rpiplay -> ALSA "pipewire" PCM |
                                                   v
                                    PipeWire -> BossDAC card (PCM5122)
                                                   v
                                          RCA out / 3.5mm jack
```

* `bluealsa` + `bluealsa-aplay` provide the A2DP **sink** endpoints. Without
  them bluetoothd has no endpoints, and the phone's "connect for media audio"
  silently does nothing.
* `bluealsa-aplay` writes the decoded PCM to the ALSA `default` device, which
  routes into PipeWire (via `pipewire-alsa`), so Bluetooth and AirPlay mix on
  the same DAC. Its systemd unit needs `Environment=XDG_RUNTIME_DIR=/run/user/1000`
  to find the user's PipeWire socket (same fix as rpiplay's unit).

## Why the patched pcm512x module + the allo-boss overlay exist

On Raspberry Pi OS kernels ≥ 6.12 (verified on 6.18.x), opening a PCM512x
sound card bound through the `hifiberry-dacplus*` overlays fails permanently:

```
ASoC error (-22): at snd_soc_pcm_component_pm_runtime_get() on pcm512x.1-004d
```

The codec's runtime resume (`pcm512x_resume`) fails in
`regulator_bulk_enable()`/`regcache_sync()`, the runtime-PM core stores that
error, and every subsequent open re-fails with -22. Worse, a resume whose
`regcache_sync` fails leaves the chip with reset-default registers while the
driver's cache still believes the old values are applied — the DAC ended up
with **volume at the reset default (−79.5 dB) and an unconfigured DAC clock
source (DAC_REF = 0x00)**, producing open/close clicks with no audio.

The patches (applied by the scripts in `pcm512x-fix/`):
1. `patch_pcm512x.py` — `pcm512x_resume` logs-and-continues on the
   regulator/cache failures; `hw_params` reconfigures format/clocks anyway.
2. `patch_pcm512x_retry.py` — the boot probe retries the codec reset for
   ~60 s: some HATs clock-stretch the I2C bus while their LDOs settle and the
   bcm2835 I2C controller cannot handle clock stretching (errata).
3. `patch_pcm512x_dacref.py` — in slave (Pi-as-clock-master) mode, explicitly
   selects SCK as the DAC conversion clock (`DAC_REF = SDAC_SCK`) and disables
   the stale PLL. Without this: clicks, no audio.

**Use the `allo-boss-dac-pcm512x-audio` overlay** (not `hifiberry-dacplus*`):
the Allo Boss DAC machine driver binds the same PCM5122 at I2C 0x4D, its
overlay references no supplies (kernel dummy regulators → clean runtime-PM),
and its master path runs the PCM5122 in codec-master mode with the HAT's
onboard oscillators — matching the InnoMaker's hardware design. The card
registers as `BossDAC`.

If the Pi runs a different kernel than the prebuilt module in `modules/`,
provision.sh rebuilds it from `pcm512x-fix/` (the kernel headers must match
the running kernel — some images prepopulate `/usr/src` without the dpkg
package, provision.sh handles both).

## Hardware lessons from this build

* **Keep the HDMI cable unplugged** on the Zero: the connector shell sits
  next to the header and shorted HAT pins under contact (a power LED died
  when the HAT was pressed; unplugging HDMI restored it).
* **Intermittent power LEDs / I2C stretching / the sinks vanishing under
  load / the Pi dropping off the LAN** all traced to marginal 3V3 power
  delivery through the hand-soldered header joints. Continuity tests pass
  on resistive joints — only a loaded **voltage** measurement reveals them.
  Reflow pins 1, 2, 17 (3V3) and the GND return (6) with fresh solder.
* WiFi power-save: brcmfmac power-save caused repeated LAN drops. It was
  disabled via NetworkManager, then re-enabled to reduce draw on the
  marginal rail — revisit after the power path is fixed.

## Files

| File | Purpose |
|---|---|
| `provision.sh` | One-shot provisioning script (run on the Pi) |
| `boot-config-reference.txt` | Working `config.txt` snapshot (reference) |
| `etc-default-rpiplay` | `/etc/default/rpiplay` — rpiplay service arguments |
| `systemd/rpiplay.service.pi` | Pi-local rpiplay unit (`User=pi`, `EnvironmentFile`, `~/RPiPlay/build`) |
| `systemd/rpiplay-pipewire.conf` | Drop-in: `XDG_RUNTIME_DIR` so the ALSA `pipewire` PCM finds the user's PipeWire |
| `systemd/bt-agent.service` + `bt-agent.sh` | Persistent pairing agent: clears the rfkill soft-block (minimal images ship hci0 blocked without the `rfkill` tool), waits for bluetoothd, keeps the Pi powered/discoverable/pairable |
| `systemd/bluealsa-a2dp.conf` | bluealsa daemon override: A2DP sink profile |
| `systemd/bluealsa-aplay.service` | BT audio player → ALSA default (PipeWire) |
| `systemd/rpiplay-pipewire.conf` | rpiplay drop-in (see above) |
| `modules/snd-soc-pcm512x-6.18.39+rpt-rpi-v8.ko` | Prebuilt patched module (aarch64; provision.sh rebuilds for other kernels) |
| `pcm512x-fix/` | Patched `pcm512x` source + Makefile + the three patch scripts |

## Layout on the Pi

```
~/RPiPlay/                             source + build (service runs build/rpiplay)
/etc/systemd/system/rpiplay.service    (+ .d/pipewire.conf)
/etc/systemd/system/bt-agent.service   + /usr/local/sbin/bt-agent.sh
/etc/systemd/system/bluealsa-aplay.service (+ .d/ override for bluealsa)
/etc/systemd/system/bluealsa.service.d/a2dp.conf
/etc/wireplumber/wireplumber.conf.d/51-bluez-a2dp.conf
/etc/default/rpiplay                   service arguments (RPIPLAY_ARGS)
/etc/NetworkManager/conf.d/wifi-powersave-off.conf  (optional)
```

## Known trade-offs

* **AirPlay volume changes are ignored**: rpiplay renders through the ALSA
  `pipewire` PCM which has no mixer; volume is whatever PipeWire's sink is
  set to. Bluetooth volume works (AVRCP).
* The WirePlumber Bluetooth monitor on this image does not register A2DP
  endpoints (the `api.bluez5.enum.dbus` SPA handle never loads) — which is
  why BlueALSA provides the endpoints instead. If a future image fixes the
  SPA loading, the `bluez5.roles = [ a2dp_sink ]` settings in
  `51-bluez-a2dp.conf` become relevant again.
* `rpiplay -a analog` auto-detect matches card names containing
  "hifiberry"; the BossDAC card does not match, so use `-a pipewire` (as
  deployed) or an explicit device name.
