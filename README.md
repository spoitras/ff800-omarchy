# RME Fireface 800 on Omarchy / Arch Linux

Low-latency audio from an **RME Fireface 800** (FireWire) on **Omarchy** (Arch +
Hyprland/Wayland), using **`jackd` with the FFADO backend**, with PipeWire attached
as a JACK client so ordinary desktop audio keeps working.

Verified on hardware: **48000 Hz / 128 frames, 40 hardware ports, 0 xruns**, stable
across repeated play/disconnect cycles and a cold boot.

> **Read [Why not `pipewire-ffado`](#why-not-pipewire-ffado) before you start.**
> The obvious approach — PipeWire's own FFADO driver — crashes. This guide exists
> because that path fails in ways that take *all* system audio down with it.

---

## Contents

- [Tested on](#tested-on)
- [Architecture](#architecture)
- [Why not `pipewire-ffado`](#why-not-pipewire-ffado)
- [Install](#install)
- [Configure](#configure)
- [Daily use](#daily-use)
- [The clock-mode trap](#the-clock-mode-trap)
- [Troubleshooting](#troubleshooting)
- [DAW setup](#daw-setup)
- [Hyprland notes](#hyprland-notes)
- [What survives updates](#what-survives-updates)
- [Known-bad paths](#known-bad-paths)

---

## Tested on

| | |
|---|---|
| Interface | RME Fireface 800 (GUID `0x000a35005b685205`) |
| Controller | TI XIO2213A/B IEEE-1394b OHCI |
| OS | Omarchy 4.0.2-1 (Arch), kernel 7.1.9-arch1-2 |
| Compositor | Hyprland (Wayland) |
| `jack2` | 1.9.22-2 |
| `libffado` | 2.5.0-1 |
| `pipewire` / `wireplumber` | 1:1.6.8-1 / 0.5.15-1 |

Other FFADO-supported RME interfaces should work with the same shape; the GUID in
the config and the clock-mode fix are FF800-specific.

---

## Architecture

```
FF800 ──FireWire──► jackd (FFADO backend)
                      │   owns the device, holds the stream open for its lifetime
                      ├──────────────► Bitwig / REAPER      (native JACK clients)
                      └──────────────► PipeWire             (module-jack-tunnel)
                                          └── browser, notifications, desktop audio
```

Two properties matter:

1. **jackd holds the hardware stream open** for the whole life of the server. It
   does not open and close it per client.
2. **JACK failures cannot take down desktop audio.** jackd is a separate process;
   if it dies or never starts, PipeWire keeps running on your onboard card.

Both are the direct consequence of the failure described next.

---

## Why not `pipewire-ffado`

PipeWire ships `libpipewire-module-ffado-driver`, which looks like the natural
choice. It is not usable here. Three distinct crashes, all upstream:

**1. It segfaults instead of failing.** When it cannot open the device — interface
powered off, wrong clock mode, missing realtime privileges — it crashes the whole
`pipewire` process rather than returning an error. `flags = [ nofail ]` does **not**
help; nothing catches a segfault. systemd then trips `start-limit-hit` and the
machine has no audio at all until you run `systemctl --user reset-failed`.

**2. It has a use-after-free on client disconnect.** This is the fatal one:

```
data-loop.0 thread:                        concurrently, another thread:
 #0 StreamProcessor::getTimeAtPeriod()      #4 IsoHandlerManager::~IsoHandlerManager()
 #1 StreamProcessorManager::waitForPeriod() #5 Ieee1394Service::~Ieee1394Service()
 #2 DeviceManager::waitForPeriod()          #6 DeviceManager::~DeviceManager()
 #3 ffado_streaming_wait                    #7 ffado_streaming_finish
 #4 module-ffado-driver.so                 #12 pw_impl_node_set_state
                                           #13 module-client-node.so
```

**PipeWire closes the hardware stream every time the last client disconnects — by
design.** libffado cannot survive that teardown: the device is destroyed while the
data loop is still inside `ffado_streaming_wait`. In practice, *play anything, let
it finish, and PipeWire dies a few seconds later.*

**3. Throughput tests do not catch it.** `pw-top` reports a clean `ERR 0` right up
until the client disconnects. If you benchmark this driver you will conclude it
works. **Test by letting a client finish and disconnect, then waiting.**

`jackd` avoids all three: it keeps the stream open, so the teardown path is never
taken.

---

## Install

```sh
# 1. Blacklist the in-kernel driver BEFORE first power-on (see note)
echo "blacklist snd_fireface" | sudo tee /etc/modprobe.d/blacklist-snd-fireface.conf

# 2. Packages
sudo pacman -S jack2 pipewire-jack-client libffado realtime-privileges \
               jack-example-tools python-pyqt5

# 3. Realtime privileges, then LOG FULLY OUT AND BACK IN
sudo gpasswd -a "$USER" realtime
```

Verify after re-login — this must print `98`, not `0`:

```sh
ulimit -r
```

### Why each piece

| Package | Why |
|---|---|
| `jack2` | The JACK server, and `/usr/lib/jack/jack_firewire.so`, the FFADO backend |
| `pipewire-jack-client` | `module-jack-tunnel` — PipeWire as a *client of* real JACK. **Not** `pipewire-jack`, which is the opposite: PipeWire *impersonating* JACK. They conflict; you want this one. |
| `libffado` | The userspace FireWire audio driver itself |
| `realtime-privileges` | Creates the `realtime` group and the rtprio/memlock limits |
| `jack-example-tools` | `jack_lsp`, `jack_connect` for inspecting and patching |
| `python-pyqt5` | Required by `ffado-mixer`; an *optional* dep of `libffado`, so it is not pulled in automatically |

`pacman -S jack2 pipewire-jack-client` will prompt to **remove `pipewire-jack`**.
That is correct. Packages depending on `jack`/`libjack.so` (ffmpeg, mpv, obs, …) are
satisfied by `jack2`'s `provides`; nothing else is uninstalled.

### The blacklist is not optional

`snd-fireface.ko` ships with the kernel and carries a modalias for this device
(`ieee1394:ven00000A35mo00101800sp00000A35ver*`, `0x0A35` = RME). udev matches it the
instant the FF800 is powered on and autoloads the driver, which then claims the
device and locks FFADO out. Write the blacklist **before** first power-on. No reboot
needed — modprobe re-reads `/etc/modprobe.d/` on every load attempt.

### Realtime privileges are a hard prerequisite

Not a tuning step. libffado requests a FIFO thread at **priority 98** during device
*open*. At the default `rtprio 0` that returns `EPERM` and the open aborts:

```
Error (PosixThread.cpp)[161] Start: Cannot create realtime thread (1: Operation not permitted)
firewire ERR: FFADO: Error creating virtual device
```

Lowering the period size does not work around it.

### Permissions: no group change needed

`libffado` ships `/usr/lib/udev/rules.d/60-ffado.rules` setting `GROUP="audio"`, but
access does not depend on it. systemd's `70-uaccess.rules` also matches any FireWire
unit with `IEEE1394_UNIT_FUNCTION_AUDIO=1` — which the FF800 sets — and grants the
active seat user a direct ACL:

```sh
getfacl /dev/fw1     # -> user:<you>:rw-
```

You do **not** need to join `audio`. (The ACL follows the active local session, so
it is reapplied on login and replug but not granted to a remote session.)

---

## Configure

### 1. systemd user unit — `~/.config/systemd/user/jackd-ff800.service`

```ini
[Unit]
Description=JACK server for RME Fireface 800 (FFADO backend)
Documentation=man:jackd(1) man:ffado-test(1)

[Service]
Type=simple
ExecStart=/usr/bin/jackd -R -P 93 -d firewire -r 48000 -p 128 -n 3
# systemd user services do NOT inherit PAM limits from /etc/security/limits.d,
# so realtime limits must be set explicitly here. libffado internally requests
# priority 98 -- higher than jackd's own -P 93 -- so this cap must exceed 98
# or the device open fails with EPERM.
LimitRTPRIO=99
LimitMEMLOCK=infinity
# Never auto-restart: if the interface is off, retry loops just hammer the bus.
Restart=no

[Install]
WantedBy=default.target
```

Then `systemctl --user daemon-reload`. Do **not** `enable` it — see
[Daily use](#daily-use).

> **The `LimitRTPRIO` value is the single easiest thing to get wrong.** A cap of 95
> looks generous and still fails, because the number that matters is libffado's
> internal 98, not the 93 you pass to `jackd`.

### 2. PipeWire bridge — `~/.config/pipewire/ffado-available/30-jack-tunnel.conf`

Kept outside `pipewire.conf.d/` and symlinked in by the helper, so it is only
active while jackd is running.

**Replace the GUID** with yours from `ffado-test ListDevices`.

```
context.modules = [
    {   name = libpipewire-module-jack-tunnel
        flags = [ ifexists nofail ]
        args = {
            jack.client-name = "PipeWire"
            tunnel.mode      = duplex
            jack.connect     = true
            audio.channels   = 2
            audio.position   = [ FL FR ]
            jack.connect-audio = [
                "firewire_pcm:000a35005b685205_pbk_analog-1_out"
                "firewire_pcm:000a35005b685205_pbk_analog-2_out"
            ]
            sink.props   = { node.description = "Fireface 800 (JACK) Output" }
            source.props = { node.description = "Fireface 800 (JACK) Input"  }
        }
    }
]
```

Those two port names route stereo desktop audio to analog outputs 1/2. Change them
to send it elsewhere.

### 3. The helper — `~/.local/bin/ff800`

Provided in this repo as [`ff800`](ff800). Install it:

```sh
install -Dm755 ff800 ~/.local/bin/ff800
```

It handles the ordering and the clock-mode trap. Ensure `~/.local/bin` is on `PATH`.

---

## Daily use

```sh
ff800 on        # force clock to master, start jackd, attach the PipeWire bridge
ff800 off       # detach bridge, stop jackd gracefully
ff800 status    # device / jackd / rate+buffer+ports / bridge / pipewire
ff800 reset     # recover a wedged device
```

Healthy output:

```
device  : present on bus
jackd   : active
jack    : 48000 Hz / 128 frames / 46 ports
bridge  : enabled
pipewire: active
          40. Fireface 800 (JACK) Output
          41. Fireface 800 (JACK) Input
```

46 = 40 hardware ports + 6 from the bridge client.

**Nothing is enabled at boot, deliberately.** A cold boot always comes up with
working audio whether the interface is on or not, and `ff800 off` is always one
command back to plain onboard audio.

### Two rules the helper encodes

- **Never `pkill jackd`.** An unclean exit leaves isochronous handlers allocated on
  the controller; the next open then fails with `Enable requested on enabled stream
  'Receive'`, or segfaults in `jackctl_server_open`. `ff800 off` stops the unit so
  jackd gets SIGTERM and tears down cleanly.
- **Bound every `jack_client_open`.** It never returns against a server hung in the
  device open, which is a real failure mode here. Every JACK query in the helper
  runs under `timeout`.

---

## The clock-mode trap

**The FF800 does not retain its clock mode across a power cycle.** It returns in
slave/AutoSync mode, and with no external clock connected it then refuses to set its
sample rate:

```
Error (rme_avdevice.cpp)[572] setSamplingFrequency: slave clock mode active but no valid external clock present
Fatal (devicemanager.cpp)[802] initStreaming: Could not set sampling frequency to 48000
```

jackd reports only the unhelpful `FFADO: Error creating virtual device`. **Always
diagnose with libffado directly**, which prints the real cause:

```sh
timeout 20 ffado-test-streaming -p 128 -n 3 -r 48000 -P 93 -v 2
# exit 124 = streamed until killed (healthy);  255 = init failure;  139 = segfault
```

`ff800 on` fixes this automatically every start. To do it by hand: start
`ffado-dbus-server`, set `Control/Clock_mode` to `0`, and **stop the daemon again**.

```python
import dbus
base = '/org/ffado/Control/DeviceManager/<GUID>/Control/'
o = dbus.SessionBus().get_object('org.ffado.Control', base + 'Clock_mode')
dbus.Interface(o, 'org.ffado.Control.Element.Discrete').setValue(0)  # 0=master, 1=slave
```

Confirm it took: `sysclock_freq` flips from `0` to `48000`.

> `Generic/ClockSelect` is a red herring — it reports `Internal, Valid: 1, Active: 1,
> Locked 1` even while `Control/Clock_mode` is `1`. The register that matters is
> `Control/Clock_mode`.

---

## Troubleshooting

### First move, always

```sh
ff800 off        # restores plain desktop audio immediately
ff800 status
```

### Symptom table

| Symptom | Cause | Fix |
|---|---|---|
| `FFADO: Error creating virtual device` | Clock mode reverted to slave | `ff800 on` (handles it), or set `Clock_mode=0` |
| `Cannot create realtime thread ... priority: 98` | RT limits missing or cap too low | `realtime-privileges` + re-login; unit needs `LimitRTPRIO=99` |
| `timeout waiting for device not busy` | Device wedged by an unclean exit | `ff800 reset` |
| `Enable requested on enabled stream 'Receive'` | Stale isochronous handlers | `ff800 reset` |
| jackd segfaults in `jackctl_server_open` | Stale handlers from a `SIGKILL` | `ff800 reset` |
| Red **HOST** light on the FF800 | Lost host sync after an unclean teardown | `ff800 reset` |
| `No FireWire adapters (ports) found` | Device dropped off the bus | Power-cycle the interface — a bus reset cannot recover a device that is not there |
| JACK nodes vanish from `wpctl status` | Another process took the device | `pgrep -f 'ffado-dbus-serve[r]'`, stop it, `ff800 on` |
| Status-bar audio icon x-ed out | Bar lost its PipeWire connection on restart | `omarchy restart shell` |

### Recovering a wedged device

```sh
ff800 reset      # stops jackd, bus-resets, confirms the device reappears
ff800 on
```

If `reset` says the device is still not visible, power-cycle the interface.

### Verifying properly

Throughput proves nothing. Test the **disconnect** path:

```sh
before=$(coredumpctl list --no-pager | wc -l)
pw-play --target <sink-id> some.wav      # let it run to completion
sleep 20
systemctl --user is-active pipewire jackd-ff800.service   # both active
echo "new coredumps: $(( $(coredumpctl list --no-pager | wc -l) - before ))"   # 0
```

---

## DAW setup

Start the server first with `ff800 on`, then set the DAW's audio driver to **JACK**.

- **Bitwig Studio** — Preferences → Audio → Driver = **JACK**. Bitwig also has a
  native PipeWire backend, but that only reaches the FF800 through
  `pipewire-ffado`, the broken path. Use JACK.
- **REAPER** — Preferences → Audio → Device = **JACK**. No `pw-jack` wrapper: this
  is a real JACK server.

Ports appear individually and by name, e.g.
`firewire_pcm:<GUID>_cap_analog-1_in` … `analog-8`, plus ADAT and SPDIF — rather
than the anonymous 20-channel block `pipewire-ffado` exposes.

> **Not yet verified:** the author's machine had neither DAW installed at the time
> of writing. The stack is confirmed; the in-DAW steps are not.

### Routing without a GUI

```sh
jack_lsp -c                       # list ports and current connections
jack_connect   <source> <dest>
jack_disconnect <source> <dest>
```

Most routing belongs in the DAW, which re-establishes its own connections on
launch. For inter-application patching, `aj-snapshot` saves and restores a whole
graph.

### Onboard DSP mixer

```sh
ffado-mixer &
```

Input trims, hi-Z instrument input, zero-latency hardware monitoring, headphone
routing — all *before* the signal reaches software.

**`ffado-mixer` and jackd coexist.** Verified: the mixer runs with jackd streaming,
46 ports still up, and jackd survives the mixer closing. Mixer access is
control-register traffic, not streaming, so it does not contend for the isochronous
channels. Only two *streaming* clients conflict.

---

## Hyprland notes

Omarchy drives Hyprland from **Lua**, not a flat `hyprland.conf`. The old
`windowrulev2 = float, class:^(...)$` syntax does not apply. Use `o.window()` in
`~/.config/hypr/looknfeel.lua` (or your own override file):

```lua
-- ffado-mixer tiles by default; class verified with `hyprctl clients`
o.window("ffado-mixer", { float = true })
```

**Always confirm the class yourself** — `hyprctl clients -j` while the window is
open. `ffado-mixer` is verified. DAW plugin windows run under XWayland and may also
need floating, but those classes are unverified here; check before adding a rule.

Other reported Hyprland/DAW issues worth knowing about:

- Bitwig knob/fader click-drag not registering under Hyprland
  ([hyprwm/Hyprland#2034](https://github.com/hyprwm/Hyprland/issues/2034)) — check
  current status; Ctrl+click and scroll wheel were reported as working.
- Nvidia cursor artifacts in XWayland windows — try `WLR_NO_HARDWARE_CURSORS=1`.

---

## What survives updates

Checked against Omarchy 4.0.2:

- **`omarchy update` does not reinstall packages from any manifest.** It runs
  `pacman -Syu`, migrations, AUR updates and orphan pruning. It will not drag
  `pipewire-jack` back.
- **`pipewire-jack` appears only in `omarchy-other.packages`, which no script
  reads.** The manifest that *is* read (`omarchy-base.packages`, used by
  `omarchy-reinstall-pkgs`) does not contain it.
- **Orphan pruning cannot touch these.** `omarchy-update-orphan-pkgs` removes
  `pacman -Qtdq` output — orphaned *dependencies*. Keep all of these marked
  **explicitly installed** and they never appear there.

Everything else is user-owned and outside pacman's reach: `~/.local/bin/ff800`,
`~/.config/systemd/user/`, `~/.config/pipewire/`, and
`/etc/modprobe.d/blacklist-snd-fireface.conf`.

**Still worth watching:** a PipeWire major bump can change module option names and
config syntax — if audio breaks right after an update, check
`journalctl --user -u pipewire | grep -i jack-tunnel` first.

---

## Known-bad paths

Do not spend time on these.

### `pipewire-ffado`

Uninstall it. See [Why not `pipewire-ffado`](#why-not-pipewire-ffado). Keep
`libffado` — that is what `jack_firewire.so` links against.

### `jack2-dbus` / `jackdbus`

**Does not work with the FFADO backend.** Tested twice, once on a pristine device
seconds after a clean power-on: it opens the device (all `FW_*` libffado threads
spawn) but the server start never completes — 0 ports, log frozen at
`Starting jack server...`, D-Bus caller times out with `NoReply`.

It then **ignores SIGTERM**, being blocked uninterruptibly in the device open, so
clearing it requires SIGKILL — which knocks the interface off the bus entirely and
costs a power cycle.

This is a real loss: `libpipewire-module-jackdbus-detect` would have created and
destroyed the tunnel live, with no PipeWire restart and so no dropped clients. It is
not available here.

**If installed, treat it as a hazard.** `org.jackaudio.service` is D-Bus-activatable,
so anything probing for a JACK server — `jack_control`, qjackctl, a JACK-aware app —
spawns the hanging server and costs a power cycle:

```sh
sudo pacman -Rns jack2-dbus
```

### `snd-fireface` (in-kernel ALSA driver)

Mutually exclusive with FFADO. Its ALSA mixer controls do not give working access to
the FF800's onboard DSP mixer, which is the main reason to use FFADO at all. If you
do not need the onboard mixer, `snd-fireface` + plain ALSA-in-PipeWire is a
genuinely different approach worth considering — PipeWire has shipped latency
improvements specific to that path — but none of this guide applies to it.

---

## Open items

- Bitwig and REAPER were not installed when this was written; the DAW steps are
  unverified.
- `ff800 on`/`off` restart PipeWire, which drops connected clients and can x-out the
  status-bar audio icon (`omarchy restart shell`). Loading the tunnel into the
  running daemon with `pw-cli load-module` would avoid this — untested.
- Suspend/resume across a FireWire bus reset is unreliable on Linux generally. Do
  not suspend mid-session; if the device vanishes after resume, replug and
  `ff800 reset`.

---

## References

- [libpipewire-module-jack-tunnel(7)](https://man.archlinux.org/man/libpipewire-module-jack-tunnel.7.en)
- [libpipewire-module-ffado-driver(7)](https://man.archlinux.org/man/libpipewire-module-ffado-driver.7.en)
- [PipeWire FFADO driver docs](https://docs.pipewire.org/page_module_ffado_driver.html)
- [jack2 — Arch package](https://archlinux.org/packages/extra/x86_64/jack2/)
- [pipewire-jack-client — Arch package](https://archlinux.org/packages/extra/x86_64/pipewire-jack-client/)
- [FFADO + PipeWire issues — Ardour forum](https://discourse.ardour.org/t/ffado-and-pipewire-issues-fireface-profire-40/110124)
- [PipeWire's FFADO driver continues to be unstable](https://interfacinglinux.com/community/linuxaudiosofware/pipewires-ffado-driver-continues-to-be-unstable-for-me/)
- [PipeWire — ArchWiki](https://wiki.archlinux.org/title/PipeWire)
- [JACK — ArchWiki](https://wiki.archlinux.org/title/JACK_Audio_Connection_Kit)
