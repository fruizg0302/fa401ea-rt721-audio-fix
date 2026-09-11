# RT721 vendor analog power sequence — ASUS TUF Gaming A14 FA401EA

Replacement `snd-soc-rt721-sdca` module = kernel v7.2.3 sources + Realtek's two merged
September-2026 fixes (`0x2f5d=1` latency control, stream_config->type init) + the vendor
analog power sequence (see `../0001-ASoC-rt721-sdca-power-up-the-vendor-analog-gates.patch` (repo root)).
Without it the codec is fully configured but analog-dead on this board (silent speakers,
DMICs = digital zero, no jack detection). Sequence credit: stevedamnvan,
https://github.com/stevedamnvan/msi-claw-8-ex-linux (MSI Claw 8 EX AI+, same symptom).

Module parameter: `vendor_power_seq` = -1 auto (DMI: ASUS board FA401EA, MSI MS-1T91), 0 off, 1 on.

## Test without installing (swap script, root)

    make                                            # needs linux-headers for the running kernel
    sudo KO=$PWD/snd-soc-rt721-sdca.ko bash ../rt721-swap.sh clean

## Install persistently with DKMS (survives kernel updates as long as linux-headers is installed)

    sudo pacman -S --needed dkms linux-headers
    sudo dkms add  /path/to/this/repo/rt721-fix
    sudo dkms install snd-soc-rt721-sdca-fa401ea/1.0
    modinfo -n snd_soc_rt721_sdca      # must print .../updates/dkms/snd-soc-rt721-sdca.ko.zst

`depmod` searches `updates` before the in-tree `kernel/` directory (/usr/lib/depmod.d/search.conf),
so the DKMS module replaces the stock one at boot. Remove with
`sudo dkms remove snd-soc-rt721-sdca-fa401ea/1.0 --all`.

When a mainline kernel ships an equivalent fix, remove the DKMS module.
