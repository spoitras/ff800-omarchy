# RME Fireface 800 on Arch / Omarchy

Low-latency audio from an RME Fireface 800 (FireWire) using **`jackd` + FFADO**,
with PipeWire attached as a JACK client so desktop audio keeps working.

Tested at **48000 Hz / 128 frames, 40 ports, 0 xruns** on Omarchy 4.0.2, kernel
7.1.9, `jack2` 1.9.22, `libffado` 2.5.0, PipeWire 1.6.8.

> **Don't use `pipewire-ffado`.** PipeWire closes the hardware stream whenever the
> last client disconnects, and libffado can't survive that teardown — play anything
> to completion and `pipewire` segfaults, taking all system audio with it. `jackd`
> holds the stream open, so it never happens.

```
FF800 ──FireWire──► jackd (FFADO) ──┬──► Bitwig / REAPER   (JACK clients)
                                    └──► PipeWire          (desktop audio)
```

---

## 1. Blacklist the kernel driver

Do this **before** first powering on the interface — udev autoloads `snd_fireface`
on contact and it locks FFADO out.

```sh
echo "blacklist snd_fireface" | sudo tee /etc/modprobe.d/blacklist-snd-fireface.conf
```

No reboot needed.

## 2. Install

```sh
sudo pacman -S jack2 pipewire-jack-client libffado realtime-privileges \
               jack-example-tools python-pyqt5
```

This removes `pipewire-jack` — that's correct. You want **`pipewire-jack-client`**
(PipeWire *as a client of* JACK), not `pipewire-jack` (PipeWire *pretending to be*
JACK). Confusingly similar names, opposite meanings.

## 3. Realtime privileges

```sh
sudo gpasswd -a "$USER" realtime
```

**Log fully out and back in**, then verify — this must print `98`:

```sh
ulimit -r
```

Without it, libffado can't create its RT thread and the device open fails outright.
No group membership beyond `realtime` is needed; systemd's `uaccess` already grants
you an ACL on `/dev/fw*`.

## 4. Install the files

```sh
install -Dm755 ff800               ~/.local/bin/ff800
install -Dm644 jackd-ff800.service ~/.config/systemd/user/jackd-ff800.service
install -Dm644 30-jack-tunnel.conf ~/.config/pipewire/ffado-available/30-jack-tunnel.conf
systemctl --user daemon-reload
```

Ensure `~/.local/bin` is on your `PATH`. Don't `enable` the service — `ff800` starts
it on demand.

## 5. Set your device GUID

```sh
ffado-test ListDevices     # -> 0x000a35005b685205
```

Put it in both `~/.config/pipewire/ffado-available/30-jack-tunnel.conf` (the four
`firewire_pcm:<GUID>_…` port names) and `~/.local/bin/ff800` (the `GUID=` line).

## 6. Store master clock mode in the device flash — once

The FF800 powers on with the settings in its flash, and libffado reloads those
into the device on the first open after a power cycle. If the flash says
slave/AutoSync, that first open fails (see [the gotcha](#first-start) for the
mechanism). Fix it at the source, one time, with the interface on and jackd
stopped:

```sh
ff800 off
python3 - <<'PY'
import dbus
base = '/org/ffado/Control/DeviceManager/000a35005b685205/Control/'   # your GUID
bus = dbus.SessionBus()
ctl = lambda n: dbus.Interface(bus.get_object('org.ffado.Control', base + n),
                               'org.ffado.Control.Element.Discrete')
ctl('Clock_mode').setValue(0)       # 0 = master
ctl('Flash_control').setValue(1)    # 1 = save control settings to flash (~1 s)
ctl('Flash_control').setValue(0)    # 0 = reload from flash, to verify
print('flash clock mode:', int(ctl('Clock_mode').getValue()), '(0 = master)')
PY
pkill -f 'ffado-dbus-serve[r]'
```

The D-Bus call activates `ffado-dbus-server` by itself. Same thing in
`ffado-mixer`: set the clock to Master, then **Save control** in the *Flash*
box. It stores the current sample rate and input/output levels too; that is
what the interface will boot with from now on.

## 7. Go

```sh
ff800 on
```

```
device  : present on bus
jackd   : active
jack    : 48000 Hz / 128 frames / 46 ports
bridge  : enabled
pipewire: active
```

---

## Usage

```sh
ff800 on             # start jackd + attach PipeWire
ff800 off            # stop cleanly
ff800 status
ff800 status --json  # same, machine-readable (what the bar plugin polls)
ff800 reset          # recover a wedged device
ff800 clock          # check/force clock master without starting anything
ff800 log [n]        # what the last starts actually did
```

`ff800 on` mirrors every decision it makes to the journal under the `ff800` tag,
with timings. That matters because the bar plugin collects the command's stdout
into a QML string and drops it on success — so a start that failed and recovered
through the plugin used to leave no record of why anywhere. `ff800 log` reads it
back.

`status` also reports the xrun count for the current jackd session, counted from
the unit's journal and reset by every `ff800 on`.

Nothing starts at boot, so a cold boot always has working audio whether the
interface is on or not. `ff800 off` is always the way back.

**Never `pkill jackd`** — an unclean exit wedges the controller and the next start
fails. Use `ff800 off`.

## Bar plugin

This repo doubles as an Omarchy shell plugin: a bar widget that turns the stack
on and off and shows what jackd is doing.

```
󰥛  ← bright when the stack is up, dimmed when it's down, red on a failed start
```

Clicking it opens a panel with the on/off switch, the numbers worth watching
while tracking, and the three recovery actions from the troubleshooting table.

```
Fireface 800                    1 xrun   [ ●]
48 KHZ · 128 FRAMES

Device                          present on bus
jackd                                   active
Clock                               48000 Hz
Buffer                     128 frames · 2.7 ms
Ports                                       46
DSP load                                 0.4 %
Xruns                                        1
PipeWire bridge                        enabled
PipeWire                                active

ACTIONS
󰜉  Reset device     For a red HOST light or a wedged stream
󰙪  Onboard mixer    Trims, hi-Z, zero-latency monitoring
󰦛  Restart shell    Restores the bar's audio icon
```

The plugin never reimplements any of the logic above — it shells out to
`ff800`, so the bar and the terminal can't disagree about what "on" means.

### Install

`ff800` itself must be installed first (steps 1–6). Then:

```sh
omarchy plugin add https://github.com/spoitras/ff800-omarchy.git
omarchy plugin enable spoitras.ff800 --section right
```

Plugins land disabled so you can read the code before enabling — it runs
unsandboxed inside `omarchy-shell`.

Already have the repo checked out? Point the plugin directory at it instead:

```sh
ln -sfn "$PWD" ~/.config/omarchy/plugins/spoitras.ff800
omarchy-shell shell rescanPlugins
omarchy plugin enable spoitras.ff800 --section right
```

Note that the shell's file watcher doesn't follow that symlink, so edits need
`omarchy restart shell` rather than hot-reloading.

### Controls

| Where | Action |
|---|---|
| Bar icon, left click | Open/close the panel |
| Bar icon, right click | Refresh now |
| Panel switch | `ff800 on` / `ff800 off` |
| `↑` `↓` `Enter` | Move and activate the panel cursor |
| `p` `r` `x` `m` | Power toggle · refresh · reset · mixer |

Turning it on takes ~4 seconds. With slave clock in the device flash (before
step 6) the first start after a power cycle took ~9, spending a failed attempt,
a clock fix and a retry; `ff800 on` still does that whenever the first open
fails. Both measured. Nothing is lost when it takes the slow path, but
`ff800 log` is the only place it's recorded.
The switch throws immediately and the panel says `Starting…` until the poll
catches up. There is deliberately no power toggle on right-click — too easy to
hit by accident for something that restarts PipeWire.

### Settings

Per-widget, on the plugin's entry in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | `15` | Status poll interval. One poll costs ~45 ms |
| `command` | `ff800` | Looked up with `~/.local/bin` prepended to `PATH` |
| `whenAbsent` | `Show` | `Hide` drops the widget from the bar while the FF800 is powered off |

### IPC

```sh
omarchy-shell ff800 toggle      # panel
omarchy-shell ff800 power       # on/off
omarchy-shell ff800 powerOn
omarchy-shell ff800 powerOff
omarchy-shell ff800 reset
omarchy-shell ff800 refresh
omarchy-shell ff800 state       # on | partial | off | absent | failed
```

Which makes a keybinding a one-liner in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + A", "Fireface 800", "omarchy-shell ff800 toggle")
```

`partial` means jackd is up but PipeWire isn't bridged to it: JACK clients have
audio and the desktop doesn't.

## DAWs

Run `ff800 on` first, then set the audio driver to **JACK**:

- **Bitwig** — Preferences → Audio → Driver = JACK. (Its native PipeWire backend
  only reaches the FF800 via the broken `pipewire-ffado` path.)
- **REAPER** — Preferences → Audio → Device = JACK. No `pw-jack` needed.

Ports appear by name (`firewire_pcm:<GUID>_cap_analog-1_in` …), so you can assign
inputs individually.

*Not yet verified — neither DAW was installed when this was written.*

## Onboard mixer

```sh
ffado-mixer &
```

Input trims, hi-Z instrument input, zero-latency monitoring. Runs fine alongside
jackd — mixer access and streaming don't conflict.

## Routing

Mostly unnecessary; DAWs handle their own. Otherwise:

```sh
jack_lsp -c
jack_connect <source> <dest>
```

---

## Troubleshooting

Start with `ff800 off` — that restores normal desktop audio immediately.

| Symptom | Fix |
|---|---|
| `FFADO: Error creating virtual device` | On the first open after a power cycle: the flash says slave clock — step 6. `ff800 on` retries once with the clock fixed and the second attempt works. Twice in a row means a wedged device — `ff800 reset` |
| `Cannot create realtime thread ... priority: 98` | Missing RT privileges — step 3, and re-login |
| `timeout waiting for device not busy` | `ff800 reset` |
| `Enable requested on enabled stream` | `ff800 reset` |
| jackd segfaults on start | `ff800 reset` |
| Red **HOST** light | `ff800 reset` |
| `No FireWire adapters (ports) found` | Device dropped off the bus — power-cycle it |
| JACK nodes vanish | Something else took the device: `pgrep -f 'ffado-dbus-serve[r]'` |
| Status-bar audio icon x-ed out | `omarchy restart shell` (PipeWire restart drops the bar's connection), or the plugin's **Restart shell** action |

**Diagnose with libffado directly** — jackd's errors are vague, libffado's are not:

```sh
timeout 20 ffado-test-streaming -p 128 -n 3 -r 48000 -P 93 -v 2
# 124 = healthy   255 = init failure   139 = segfault
```

**Test stability by letting playback finish and disconnect**, not by watching
throughput. A clean `pw-top` says nothing about the teardown path.

---

## Gotchas worth knowing

<a name="first-start"></a>
**The FF800's registers are write-only, so libffado keeps a shadow of the
device state in shared memory.** It lives at `/dev/shm/ffado:rme_shm-<GUID>`,
reference-counted, unlinked when the last user closes it. Everything below
follows from three facts in the libffado 2.5.0 RME driver (`src/rme/`):

- Every D-Bus read, `Clock_mode` included, returns the shadow, not the device.
  A "read back" proves only that the write reached shared memory.
- A process that *creates* the segment initialises it from the device flash and
  writes those flash settings back into the device (`init_hardware`). A process
  that *attaches* to an existing segment does neither.
- When streaming init fails, `ffado_streaming_init` returns without destroying
  the device object, so the failed process never releases its reference. The
  segment leaks and outlives it.

**Why the first start after a power cycle failed, and why the retry worked.**
With slave/AutoSync in the flash and no external clock connected:

```
20:00:37  jackd open failed after 0s -- FFADO: Error creating virtual device
20:00:37  first open failed (expected after a power cycle) -- fixing clock, retrying
20:00:37  clock mode was slave -> set to master
20:00:38  clock was slave -> master; letting it relock (3s)
20:00:43  jackd up after 2s
20:00:45  on -- jack 48000 Hz / 128 frames / 46 ports
```

1. `ff800 on` opens first. jackd creates a fresh segment, reloads slave from
   the flash into the device, and libffado refuses the sample rate: "slave clock
   mode active but no valid external clock present". jackd exits — and leaks
   the segment.
2. The clock check attaches to that leaked segment, reads slave, writes master
   to shadow and device. Stopping the D-Bus daemon drops *its* reference; the
   leaked one keeps the segment alive.
3. The retry attaches to the same segment. `settings_valid` is already set, so
   the flash is not consulted, the clock stays master, and the open succeeds.

So the clock write *is* what fixes the start. It only ever needed a segment
that survives until jackd opens, and the failure in step 1 is what accidentally
provided one. This also explains the experiment that seemed to prove the
opposite — master written and "read back", a 12 s settle, and a failed open
regardless: the daemon was the segment's only user, so stopping it unlinked the
segment and discarded the write; jackd then created a fresh one and reloaded
slave from the flash. The read-back was the shadow. Confirmed on the live
system after the run above: the segment's birth time was the second of the
failed open, and its reference count read 3 with two live users.

**The permanent fix is master in the flash (step 6).** A fresh segment then
loads master, and the first open should succeed cold with no D-Bus round trip.
`ff800 on` keeps the retry as a fallback. The settle after the clock write has
no role in this mechanism; it stays overridable (`FF800_CLOCK_SETTLE=0 ff800 on`)
and is a candidate for removal.

*Not yet verified cold on this machine.* The leaked segment from the last
failed open survives until a host reboot, and while it exists jackd never
reads the flash. To test: `ff800 off`, make sure no `ffado-dbus-server` is
running, remove `/dev/shm/ffado:rme_shm-<GUID>`, power-cycle the interface,
`ff800 on`.

**Restarts within the same power cycle are cheap** because the leaked segment
keeps master alive, not because the device remembers anything. A clean `ff800
off` releases jackd's reference, the leaked one stays, and the next `ff800 on`
attaches and opens first time — **3.8 s measured**, no D-Bus at all.

**Two consequences worth knowing.** Power-cycling the *interface* without
rebooting the host leaves the shadow saying master while the device has
reloaded its flash; with slave in the flash, the clock check then reports
"already master" and repairs nothing — one more reason to fix the flash. And
after an unclean jackd exit the leaked shadow keeps `is_streaming = 1`, which
makes libffado skip the stream-start register on the next open; a stale segment
is a plausible part of what `ff800 reset` is recovering from. Removing it, with
jackd and `ffado-dbus-server` both stopped, is safe — the next process recreates
it from the flash.

**`ffado-dbus-server` is D-Bus activatable.** `/usr/share/dbus-1/services/
org.ffado.Control.service` means any client that talks to `org.ffado.Control` —
including `ff800`'s own clock check — starts the daemon. So `ff800` no longer
spawns it by hand behind a blind `sleep 8`; it just makes the call, polls until
the control object appears (~1 s, versus 11 s before), and stops the daemon
again *only if it wasn't already running*. Mixer access and streaming don't
conflict — an incidentally activated daemon has run alongside jackd here without
effect — so this is tidiness, not necessity. Note the flip side: if that daemon
is the shared-memory segment's only user, stopping it also discards the shadow,
clock write included. See above.

**`LimitRTPRIO` in the service must exceed 98.** libffado internally requests
priority 98 — higher than the 93 passed to `jackd` — so a cap of 95 looks generous
and still fails with `EPERM`. systemd user units don't inherit PAM limits, which is
why it's set in the unit at all.

**Don't install `jack2-dbus`.** It hangs with the FFADO backend, ignores SIGTERM,
and clearing it costs a power cycle. It's also D-Bus-activatable, so anything
probing for a JACK server triggers it.

**Don't suspend mid-session.** FireWire bus reset across suspend is unreliable; if
the device vanishes, replug and `ff800 reset`.

**Hyprland window rules** on Omarchy use Lua, not `windowrulev2`:

```lua
o.window("ffado-mixer", { float = true })
```

Confirm any class with `hyprctl clients -j` before adding a rule.

---

## References

- [libpipewire-module-jack-tunnel(7)](https://man.archlinux.org/man/libpipewire-module-jack-tunnel.7.en)
- [jack2](https://archlinux.org/packages/extra/x86_64/jack2/) · [pipewire-jack-client](https://archlinux.org/packages/extra/x86_64/pipewire-jack-client/)
- [FFADO + PipeWire issues — Ardour forum](https://discourse.ardour.org/t/ffado-and-pipewire-issues-fireface-profire-40/110124)
- [PipeWire](https://wiki.archlinux.org/title/PipeWire) · [JACK](https://wiki.archlinux.org/title/JACK_Audio_Connection_Kit) — ArchWiki

---

## License

[MIT](LICENSE)
