# ASUS TUF Gaming A14 (2026, FA401EA): silent speakers and microphones on Linux, fixed

**Status: fixed on 2026-09-11.** Kernel 7.2.3, BIOS FA401EA.301. Internal speakers and the
SoundWire microphones work with the patched `snd-soc-rt721-sdca` module in this repository.
The fix is a small addition to the Realtek RT721 codec driver; nothing else in the audio stack
needed to change.

If you just want sound: jump to [Install](#install).

## The problem

On the TUF Gaming A14 FA401EA (Ryzen AI MAX+ 392 "Strix Halo") Linux creates the sound card
correctly and everything looks healthy, yet nothing comes out:

- `amd-soundwire` card present, PipeWire sink running, volume and OSD work, `aplay` and
  `speaker-test` run without errors, DAPM shows the whole speaker path powered.
- **No sound from the internal speakers.**
- **No sound from wired headphones, and plugging them in is not even detected.**
- **Microphone capture returns exact digital zeros** (`arecord -D hw:1,4` gives all-zero samples).
- Windows plays fine on the same laptop.

Reported by several owners on kernel bugzilla
[221310](https://bugzilla.kernel.org/show_bug.cgi?id=221310) and
[221958](https://bugzilla.kernel.org/show_bug.cgi?id=221958), the CachyOS issue
[#853](https://github.com/CachyOS/linux-cachyos/issues/853) and, for the ASUS Vivobook S16
M3607GA with the same codec, [thesofproject/linux #5868](https://github.com/thesofproject/linux/issues/5868).
BIOS .304 does not fix it. Some FA401EA units play with the stock driver, others do not; the
reason for that difference is still unknown.

### Hardware path

| | |
|---|---|
| Audio controller | AMD ACP 7.0, PCI `1022:15e2` rev 0x70, subsystem `1043:1724` (`0000:64:00.5`) |
| Codec | Realtek **RT721 SDCA** on SoundWire link 1 (`sdw:0:1:025d:0721:01`), the only codec on the board |
| Linux path | legacy `snd_pci_ps` + `amd_sdw_manager` + `snd_acp_sdw_legacy_mach` (machine entry `acp70_rt721_only`, selected through the FA401EA DMI override in `acp-config.c`); no SOF firmware exists for this path |
| Codec driver | `snd_soc_rt721_sdca` (`sound/soc/codecs/rt721-sdca*.c`) |

## Root cause

The RT721 has vendor registers that gate its analog blocks. The SDCA power-domain requests the
driver issues (PDE 41 for the amplifier, PDE 2A for the microphones) are acknowledged and reach
PS0, but on this board they do not switch those gates on. The mainline driver never writes them,
so every codec function is digitally alive and analog-dead: the amplifier is silent, the DMIC
engine emits zeros, the jack comparators never fire, and the codec's own `Clock_Valid` flag stays
0 no matter what the host does.

The vendor register space of a silent FA401EA reads, before and during playback:

| register (NID:reg) | name in `rt721-sdca.h` | value |
|---|---|---|
| 0x5f:0x00 | `MISC_POWER_CTL0` (codec-wide gates) | `0x0092` |
| 0x5f:0x20 | amplifier path gates | `0x01c2` |
| 0x5f:0x30 | microphone path gates | `0x01c2` |
| 0x01:0x0c / 0x0e / 0x11 / 0x13 | `ANA_POW_PART` | `0x0000` / `0x0002` / `0x8001` / `0x4020` |

These are exactly the "off" values that [stevedamnvan](https://github.com/stevedamnvan) found
on an **MSI Claw 8 EX AI+** (Intel Lunar Lake, SOF, same RT721 codec, same symptom: valid PCMs,
silent speakers, zero microphones). He recovered the power-up sequence the Windows driver uses
from the MSI audio package and published it in
[msi-claw-8-ex-linux](https://github.com/stevedamnvan/msi-claw-8-ex-linux). Applied to the
FA401EA, the same sequence brings the codec to life: the tone is audible and the microphones
deliver real samples. Every step reads back as written; 0x5f:0x00 goes from `0x0092` to `0xf69e`,
and the path registers from `0x01c2` to `0xfff7` while a stream is active.

Everything a host can verify had been checked before this and was correct: every SoundWire
command acknowledged, bus clock exactly 12 MHz (measured), driver presets and the BIOS's own SDCA
initialization tables, power domains, mutes and volumes, data-port programming, and the SoundWire
transport itself (proven in both directions with the bus's port test modes). The block was inside
the codec, and this is what it was.

## The fix

`0001-ASoC-rt721-sdca-power-up-the-vendor-analog-gates.patch` adds to `rt721-sdca.c`:

1. **Codec-wide power-up**, run after the three vendor presets in `rt721_sdca_io_init()` (so it is
   repeated whenever the codec is re-enumerated, which on this platform happens after every idle
   period because ACPI power-gates the ACP) and again on resume. Its inverse runs on runtime
   suspend. Steps, one read-modify-write each, in this order:

   | step | NID:reg | bit |
   |---|---|---|
   | 1 to 4 | 0x5f:0x00 | set 15, 14, 13, 12 |
   | 5 | 0x01:0x11 | set 15 |
   | 6 | 0x01:0x0c | set 15 |
   | 7, 8 | 0x5f:0x00 | set 3, 10 |
   | 9 | 0x01:0x13 | set 6 |
   | 10 | 0x01:0x0e | set 3 |
   | 11, 12 | 0x5f:0x00 | set 2, 9 |
   | 13, 14 | 0x61:0x1a (`UMP_HID_CTRL3`) | set 15, then clear 15 |

2. **Per-path power-up** around the existing PDE requests: 0x5f:0x20 at amplifier power-up
   (PDE 41) and 0x5f:0x30 at microphone power-up (PDE 2A), bits 11, 10, 5, 0, 9, 4, 2, 12, 13,
   14, 15 set one at a time; cleared in reverse order at power-down.

3. A DMI gate (ASUS board `FA401EA`, MSI board `MS-1T91`) and a module parameter
   `vendor_power_seq` (`-1` auto, `0` off, `1` force on) so owners of other RT721 boards with the
   same symptom can try it without rebuilding:

   ```
   # /etc/modprobe.d/rt721.conf
   options snd_soc_rt721_sdca vendor_power_seq=1
   ```

4. The touched registers are added to the MBQ regmap's readable and volatile tables so the
   read-modify-writes see real hardware state.

The module in `rt721-fix/` is the kernel v7.2.3 driver plus Realtek's two September 2026 fixes
("Adjust latency control to fix no-sound issue", upstream `a20afec40ea1`, and "fix uninitialized
stream_config->type") plus this patch. The patch applies on top of those two.

## Install

Requirements: `linux-headers` matching the running kernel, `dkms`. Secure Boot must be off (or
you must sign the module yourself).

```bash
sudo pacman -S --needed dkms linux-headers        # Arch; use your distro's equivalents
git clone <this repository> && cd <this repository>
sudo dkms add  ./rt721-fix
sudo dkms install snd-soc-rt721-sdca-fa401ea/1.0
modinfo -n snd_soc_rt721_sdca                     # must print .../updates/dkms/snd-soc-rt721-sdca.ko*
sudo reboot
```

`depmod` searches `updates/` before the in-tree `kernel/` directory, so the DKMS module replaces
the stock one at boot, and DKMS rebuilds it on kernel updates. Remove with
`sudo dkms remove snd-soc-rt721-sdca-fa401ea/1.0 --all`. Drop it once a mainline kernel carries an
equivalent fix.

### Try it without rebooting

`rt721-swap.sh` swaps the codec module on a running system (it also reloads the machine driver
and `snd_soc_sdw_utils`, which is required, see "Notes" below), plays `tone.wav`, records three
seconds from the microphones and classifies the capture:

```bash
make -C rt721-fix
sudo KO=$PWD/rt721-fix/snd-soc-rt721-sdca.ko bash rt721-swap.sh test
sudo bash rt721-swap.sh restore      # back to the in-tree module (a reboot does the same)
```

Nothing is installed by the script; it only `insmod`s the built module for the current boot.

### Verify

- You hear the tone / any playback through the speakers.
- `arecord -D hw:1,4 -f S16_LE -r 48000 -c 2 -d 3 t.wav` produces non-zero samples
  (`rt721 FU1E Capture Switch` must be on; alsa-ucm-conf 1.2.16.1 ships it off).
- `dmesg | grep rt721` shows `enabling vendor analog power sequence` once per codec init.

## Test status

| | |
|---|---|
| Speaker playback | works (module swap on a running system, 2026-09-11) |
| DMIC capture | works; channel 0 clean, channel 1 clipped at full scale in the first test, to be investigated |
| Clean reboot with the DKMS module | not yet verified at the time of writing |
| Headphone jack detection and playback | not yet verified |
| Suspend / resume, audio after idle | not yet verified |
| Idle power impact of the gates | unknown; the module clears them on runtime suspend |

Please open an issue with `dmesg | grep -i 'rt721\|soundwire'` and your BIOS version if your
result differs.

## Notes and caveats

- The bit sequence was recovered from MSI's Windows package, not ASUS's. It works on the FA401EA,
  but Realtek has not confirmed it is the generic RT721 power-up recipe. The FA401EA Windows
  package (Realtek 10.0.305.1) keeps its per-board presets in an encrypted blob
  (`RTKDAT_1043.dat`), so the ASUS recipe cannot be read directly.
- Some FA401EA units reportedly play with the stock driver on the same kernels. Different codec
  trim or OTP defaults for these gates is the natural guess; a vendor register dump from such a
  unit would settle it.
- The "TX Air" FA401EA variant with TAS2783 speaker amplifiers (RT721 for jack and mics only) has
  not been tested.
- Reloading only the codec module on a running system leaves the card without its speaker and
  DMIC parts: the `snd_soc_sdw_utils` module keeps per-DAI `rtd_init_done` flags that a partial
  re-probe does not clear (kernel 7.2, `asoc_sdw_mc_dailink_exit_loop()` breaks after the first
  matching DAI). `rt721-swap.sh` reloads `snd_soc_sdw_utils` together with the machine driver to
  avoid this. A reboot always restores a complete card.
- Not related to, and not fixed by: BIOS .304, the FA401EA DMI override in `acp-config.c`
  (`27d090f3ccd4`), the `acp70_rt721_only` machine entry (`d2dcd85f9e09`), Realtek's
  `0x2f5d` latency fix alone, the BIOS SDCA initialization tables, a SoundWire ForceReset, or any
  bus-clock setting. All were tested.

## How it was found

1. A kprobe trace of every SoundWire command during playback showed all of them acknowledged.
2. Direct ALSA capture from the DMICs returned exact digital zeros, so the codec produced nothing
   in either direction while the whole control plane was fine.
3. The SoundWire port test modes (PRBS and static patterns, applied to the AMD manager and the
   codec ports through a patched driver) passed in both directions, proving the transport and
   pointing at the codec's audio functions.
4. Realtek's driver presets, the BIOS SDCA init tables (FA401EA's and those of a working Vivobook
   18), calibration retriggers, every bus-clock declaration, a ForceReset and extra power domains
   all changed nothing; the codec's `Clock_Valid` stayed 0.
5. A dump of the Realtek vendor register space was taken as a baseline.
6. A search for prior art turned up the MSI Claw 8 EX fix. Its "dead" register values matched the
   FA401EA dump bit for bit; applying its sequence produced sound on the first try.

## Credits and references

- **stevedamnvan**, [msi-claw-8-ex-linux](https://github.com/stevedamnvan/msi-claw-8-ex-linux):
  recovered the RT721 vendor power sequence and wrote the original in-driver quirk for the MSI
  Claw 8 EX AI+. This fix is that sequence applied to the ASUS board.
- Realtek (Jack Yu, Shuming Fan, Oder Chiou) for the September 2026 rt721 patches on alsa-devel,
  and the merged rt712/rt722 reset fixes that documented how the codec keeps state across reboots.
- AMD (Vijendar Mukunda) for the FA401EA DMI override and the `acp70_rt721_only` machine entry
  that make the card exist at all.
- Owners who reported and tested on bugzilla 221310 / 221958, CachyOS #853 and alsa-devel
  (berlogue, shivanshs9, horskiilya, Cristian Timohi, Joakim Andersson Lee and others).
- Kernel bugzilla [221310](https://bugzilla.kernel.org/show_bug.cgi?id=221310),
  [221958](https://bugzilla.kernel.org/show_bug.cgi?id=221958),
  [221282](https://bugzilla.kernel.org/show_bug.cgi?id=221282) (Vivobook 18 M1807GA, working
  reference), [CachyOS #853](https://github.com/CachyOS/linux-cachyos/issues/853),
  [thesofproject/linux #5868](https://github.com/thesofproject/linux/issues/5868).

## Repository layout

| path | what |
|---|---|
| `0001-ASoC-rt721-sdca-power-up-the-vendor-analog-gates.patch` | the fix as a kernel patch (against v7.2.3 + Realtek's two fixes; apply with `-p1` in a kernel tree) |
| `rt721-fix/` | out-of-tree module sources with `dkms.conf`, `Kbuild`, `Makefile` |
| `rt721-swap.sh`, `tone.wav` | no-reboot test: swap the codec module, play a tone, capture the microphones |

## License

The driver sources and the patch are derived from the Linux kernel and are GPL-2.0-only, like the
original `sound/soc/codecs/rt721-sdca*.c`. The scripts and this document may be used freely.
