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

Put it in both `~/.config/pipewire/ffado-available/30-jack-tunnel.conf` (the two
`firewire_pcm:<GUID>_pbk_analog-*_out` port names) and `~/.local/bin/ff800` (the
`GUID=` line).

## 6. Go

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
ff800 on        # start jackd + attach PipeWire
ff800 off       # stop cleanly
ff800 status
ff800 reset     # recover a wedged device
```

Nothing starts at boot, so a cold boot always has working audio whether the
interface is on or not. `ff800 off` is always the way back.

**Never `pkill jackd`** — an unclean exit wedges the controller and the next start
fails. Use `ff800 off`.

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
| `FFADO: Error creating virtual device` | Clock mode reverted to slave. `ff800 on` fixes it automatically |
| `Cannot create realtime thread ... priority: 98` | Missing RT privileges — step 3, and re-login |
| `timeout waiting for device not busy` | `ff800 reset` |
| `Enable requested on enabled stream` | `ff800 reset` |
| jackd segfaults on start | `ff800 reset` |
| Red **HOST** light | `ff800 reset` |
| `No FireWire adapters (ports) found` | Device dropped off the bus — power-cycle it |
| JACK nodes vanish | Something else took the device: `pgrep -f 'ffado-dbus-serve[r]'` |
| Status-bar audio icon x-ed out | `omarchy restart shell` (PipeWire restart drops the bar's connection) |

**Diagnose with libffado directly** — jackd's errors are vague, libffado's are not:

```sh
timeout 20 ffado-test-streaming -p 128 -n 3 -r 48000 -P 93 -v 2
# 124 = healthy   255 = init failure   139 = segfault
```

**Test stability by letting playback finish and disconnect**, not by watching
throughput. A clean `pw-top` says nothing about the teardown path.

---

## Gotchas worth knowing

**The FF800 forgets its clock mode on every power cycle.** It comes back in slave
mode and refuses to set its sample rate. `ff800 on` forces it back to master each
start; if you're doing it by hand, set `Control/Clock_mode` to `0` over
`ffado-dbus-server` and stop the daemon afterwards.

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
