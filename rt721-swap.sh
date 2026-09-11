#!/bin/bash
# Swap the RT721 codec driver at runtime, rebuild the card, play a tone.
#   sudo bash rt721-swap.sh           -> load the locally built module (BIOS tables after presets)
#   sudo BIOS_TABLES=2 bash rt721-swap.sh   -> BIOS tables instead of the driver presets
#   sudo BIOS_TABLES=0 bash rt721-swap.sh   -> driver presets only (Realtek patches + DIAG)
#   sudo BIOS_TABLES=3 bash rt721-swap.sh   -> the Vivobook 18 M1807GA BIOS tables (working machine) after presets
#   sudo PDE47=1 SAPU=1 bash rt721-swap.sh  -> also power the jack function's PDE 47/34, SAPU 29 Protection_Mode=1
#   sudo DCCAL=3 bash rt721-swap.sh         -> log + retrigger the Class-D/DC calibration (DCCAL=7 adds the rt722-style HP cal)
#   sudo CLAWPOWER=7 bash rt721-swap.sh     -> MSI-Claw RT721 vendor analog power sequence (1 codec, 2 amp, 4 mic, 8 jack path)
#   sudo VRESET=1 bash rt721-swap.sh        -> rt711/712/722-style vendor soft reset before the presets (2 = rt722 register)
#   sudo VDUMP=1 bash rt721-swap.sh         -> dump the whole Realtek vendor register space (kernel log) for comparison
#   sudo NOINIT=1 VDUMP=2 bash rt721-swap.sh -> after a warm reboot from Windows with the in-tree driver blacklisted:
#                                        dump the codec as Windows left it, do NOT run the presets, then play
#                                        (Realtek's three Sept-2026 fixes + DIAG prints)
#   sudo bash rt721-swap.sh restore   -> go back to the in-tree module (or just reboot)
#   sudo DATAMODE=3 bash rt721-swap.sh -> SoundWire port TEST MODE on manager+codec (1 PRBS, 2 static-0,
#                                        3 static-1): no audio, but the codec reports TestFail per port and
#                                        the DMIC capture shows the pattern if the codec->host path works
#   sudo CLKSWEEP=1 bash rt721-swap.sh -> 1.5 s into each stream sweep SCP_BusClock_Base 1..5 x Scale 1..3
#                                        and log the codec's Clock_Valid for each (listen for blips)
#   sudo CLKBASE=3 CLKSCALE=2 bash rt721-swap.sh -> force one base/scale pair for the whole run
# Every run is also archived under runs/<timestamp>-<tag>.log and runs/<timestamp>-<tag>-kernel.log
# The SoundWire manager and the ACP PCI device are pinned "on" during the swap so the
# codec is re-initialised on a running bus, then set back to auto.
SP=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
KO=${KO:-$SP/rt721-build/snd-soc-rt721-sdca.ko}
OUT=$SP/rt721-swap.log
STAMP=$(date +%Y%m%d-%H%M%S); TAG="${1:-patched}"; for v in BIOS_TABLES DUMP PDE18 PPU CLRFS CLKVALID RESET FACTION DATAMODE CLKSWEEP CLKBASE CLKSCALE PDE47 SAPU DCCAL VDUMP NOINIT CLAWPOWER VRESET; do [ -n "${!v}" ] && TAG="$TAG-$v=${!v}"; done
mkdir -p $SP/runs
U=${SUDO_USER:-wowzontle}; UIDN=$(id -u "$U")
CODEC=$(ls -d /sys/bus/soundwire/devices/sdw:*:025d:0721:* 2>/dev/null | head -1)
MGR=$(readlink -f "$CODEC/../.." 2>/dev/null); [ -d "$MGR/power" ] || MGR=$(ls -d /sys/bus/platform/devices/amd_sdw_manager.* | tail -1)
PCI=/sys/bus/pci/devices/$(lspci -D -d 1022:15e2 | awk '{print $1}' | head -1)
[ -n "$CODEC" ] && [ -d "$PCI" ] || { echo "!!! no RT721 on the SoundWire bus or no ACP PCI device"; exit 1; }
asuser() { sudo -u "$U" env XDG_RUNTIME_DIR=/run/user/$UIDN DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UIDN/bus "$@"; }
PW_UNITS="pipewire.socket pipewire-pulse.socket pipewire.service pipewire-pulse.service wireplumber.service"
MODE=${1:-patched}

exec > >(tee "$OUT") 2>&1
echo "### swap ($MODE) start $(date)  kernel $(uname -r)"
if [ "$MODE" = patched ]; then
  [ -f "$KO" ] || { echo "!!! $KO not built. Run:  make -C $SP/rt721-build"; exit 1; }
  modinfo -F vermagic "$KO" | grep -q "^$(uname -r) " || { echo "!!! vermagic mismatch: $(modinfo -F vermagic "$KO")"; exit 1; }
fi
MARK="RT721-SWAP-$$"; echo "$MARK begin" > /dev/kmsg
echo "module soundwire_amd +p" > /sys/kernel/debug/dynamic_debug/control

echo "pinning bus on"; echo on > $PCI/power/control; echo on > $MGR/power/control; echo on > $CODEC/power/control; sleep 1
echo "codec runtime: $(cat $CODEC/power/runtime_status)  manager: $(cat $MGR/power/runtime_status)"
echo "stopping PipeWire stack"; asuser systemctl --user stop $PW_UNITS; sleep 1
echo "unloading machine driver, sdw utils, rt721"
if ! modprobe -r snd_acp_sdw_legacy_mach snd_soc_sdw_utils snd_soc_rt721_sdca; then
  echo "!!! unload failed"; fuser -v /dev/snd/* 2>&1; lsmod | grep -E 'rt721|sdw_legacy|sdw_utils'
  asuser systemctl --user start $PW_UNITS; exit 1
fi
sleep 1
if [ "$MODE" = patched ]; then
  # modprobe -r above also removed the now-unused helper modules; insmod does not
  # resolve dependencies, so load them back explicitly first
  modprobe -a snd_soc_rt_sdw_common regmap_sdw regmap_sdw_mbq soundwire_bus snd_soc_core
  echo "loading patched module $KO"
  echo "bios_tables=${BIOS_TABLES:-1}  (0=off 1=FA401EA after presets 2=FA401EA instead 3=Vivobook18 after 4=FA401EA+Vivobook delta 5=Vivobook18 instead)"
  echo "diag_dump=${DUMP:-1} diag_pde18=${PDE18:-0} diag_ppu=${PPU:--1} diag_clrfs=${CLRFS:-0} diag_clkvalid=${CLKVALID:--1} diag_reset=${RESET:-0} diag_faction=${FACTION:--1} diag_datamode=${DATAMODE:--1} diag_clksweep=${CLKSWEEP:-0} diag_clkbase=${CLKBASE:--1} diag_clkscale=${CLKSCALE:--1} diag_pde47=${PDE47:-0} diag_sapu=${SAPU:--1} diag_dccal=${DCCAL:-1} diag_vdump=${VDUMP:-0} diag_noinit=${NOINIT:-0} diag_clawpower=${CLAWPOWER:-0} diag_vreset=${VRESET:-0}"
  [ "${DATAMODE:--1}" != -1 ] && echo "*** DATAMODE=$DATAMODE: SoundWire port test mode, the tone is replaced by a test pattern (silence expected)"
  if modinfo -F parm "$KO" 2>/dev/null | grep -q '^diag_dump:'; then INSMOD_ARGS="bios_tables=${BIOS_TABLES:-1} diag_dump=${DUMP:-1} diag_pde18=${PDE18:-0} diag_ppu=${PPU:--1} diag_clrfs=${CLRFS:-0} diag_clkvalid=${CLKVALID:--1} diag_reset=${RESET:-0} diag_faction=${FACTION:--1} diag_datamode=${DATAMODE:--1} diag_clksweep=${CLKSWEEP:-0} diag_clkbase=${CLKBASE:--1} diag_clkscale=${CLKSCALE:--1} diag_pde47=${PDE47:-0} diag_sapu=${SAPU:--1} diag_dccal=${DCCAL:-1} diag_vdump=${VDUMP:-0} diag_noinit=${NOINIT:-0} diag_clawpower=${CLAWPOWER:-0} diag_vreset=${VRESET:-0}"; else INSMOD_ARGS=""; echo "(module has no diag_* parameters: loading it plain)"; fi
  insmod "$KO" $INSMOD_ARGS || { echo "!!! insmod failed (see dmesg)"; modprobe snd_soc_rt721_sdca; }
else
  echo "loading in-tree module"; modprobe snd_soc_rt721_sdca
fi
echo "module snd_soc_rt721_sdca +p" > /sys/kernel/debug/dynamic_debug/control
sleep 2
modprobe snd_acp_sdw_legacy_mach
sleep 3
[ "${RESET:-0}" = 1 ] && { echo "waiting 6 s for the forced codec reset + re-enumeration"; sleep 6; }
echo; echo "### card"; grep -A1 amdsoundwire /proc/asound/cards; amixer -c1 info | grep Components
amixer -c1 controls | grep -q 'Speaker Switch' && echo "Speaker Switch present" || echo "!!! Speaker Switch missing"
echo "codec: $(cat $CODEC/status)  driver: $(basename "$(readlink $CODEC/driver)")  srcversion: $(cat /sys/module/snd_soc_rt721_sdca/srcversion 2>/dev/null)"
echo "starting PipeWire stack"; asuser systemctl --user start $PW_UNITS
for i in $(seq 1 25); do asuser wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -q 'amd_sdw.HiFi__Speaker__sink' && { echo "default sink: SoundWire speaker"; break; }; sleep 1; done
echo; echo "### playing tone - LISTEN"
asuser pw-play --volume 0.6 $SP/tone.wav & PP=$!; sleep 2.5
echo "pcm2p during play: $(head -1 /proc/asound/card1/pcm2p/sub0/status)"; wait $PP
sleep 2
echo; echo "### DMIC capture 3 s via ALSA (hw:1,4)"
amixer -q -c1 cset name='rt721 FU1E Capture Switch' on,on,on,on
asuser arecord -q -D hw:1,4 -f S16_LE -r 48000 -c 2 -d 3 $SP/dmic-patched.wav 2>&1 | head -3
cp -f $SP/dmic-patched.wav $SP/runs/$STAMP-$TAG-dmic.wav 2>/dev/null
amixer -q -c1 cset name='rt721 FU1E Capture Switch' off,off,off,off
python3 - $SP/dmic-patched.wav <<'PYEOF'
import wave, sys, array, math
try:
    w=wave.open(sys.argv[1]); n=w.getnframes(); ch=w.getnchannels(); d=array.array('h', w.readframes(n))
    for c in range(ch):
        s=d[c::ch]; rms=math.sqrt(sum(x*x for x in s)/len(s)); peak=max(abs(x) for x in s); nz=sum(1 for x in s if x)
        ones=sum(1 for x in s if x==-1); mn=min(s); mx=max(s); distinct=len(set(s[:20000]))
        kind="all zero" if nz==0 else ("all ones (0xFFFF static-1 pattern)" if ones==len(s) else ("pseudo-random (PRBS-like)" if distinct>1000 and rms>5000 else "signal"))
        print(f"  dmic ch{c}: frames={len(s)} rms={rms:.1f} peak={peak} min={mn} max={mx} nonzero={100*nz/len(s):.1f}% ones={100*ones/len(s):.1f}% distinct={distinct} -> {kind}")
except Exception as e: print("  dmic analysis failed:", e)
PYEOF
echo "unpinning bus"; echo auto > $CODEC/power/control; echo auto > $MGR/power/control; echo auto > $PCI/power/control
echo "$MARK end" > /dev/kmsg
echo "module soundwire_amd -p" > /sys/kernel/debug/dynamic_debug/control
echo; echo "### kernel log"
dmesg | sed -n "/$MARK begin/,/$MARK end/p" > $SP/rt721-swap-kernel.log
grep -vE 'val:0x0$|UFW BLOCK|p_params->num|Port=[0-9]|dir:[01] dai|pcm_hw_params|DIAG DUMP \[|command is ignored|callbacks suppressed' $SP/rt721-swap-kernel.log
echo "(full kernel log incl. DIAG DUMP -> $SP/rt721-swap-kernel.log, $(grep -c 'DIAG DUMP' $SP/rt721-swap-kernel.log) dump lines)"
if grep -qE 'Test fail|DIAG CLAW|DIAG VRESET|DIAG DP|DIAG CLK|DIAG SAPU|DIAG PDE47|BIOS init table|DIAG DCCAL|JD_PRODUCT_NUM' $SP/rt721-swap-kernel.log; then echo; echo "### port / clock test summary"; grep -E 'Test fail|DIAG CLAW|DIAG VRESET|DIAG DP|DIAG data mode|DIAG CLK|DIAG SAPU|DIAG PDE(47|34)|BIOS init table|DIAG DCCAL|JD_PRODUCT_NUM' $SP/rt721-swap-kernel.log | sed 's/.*0721:01: //'; fi
cp -f $SP/rt721-swap-kernel.log $SP/runs/$STAMP-$TAG-kernel.log; cp -f $OUT $SP/runs/$STAMP-$TAG.log
echo "archived: $SP/runs/$STAMP-$TAG.log (+ -kernel.log, -dmic.wav)"
echo "### swap end $(date) -> $OUT   (shell bar stale? run: omarchy-restart-shell)"
