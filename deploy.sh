#!/usr/bin/env bash
# Push builds to the device and pull results back over SSH, without touching the SD card
# by hand. On muOS, turn on SSH under Configuration > Web Services (user root).
#
#   DEVICE=root@192.168.1.50 ./deploy.sh <command>...
#
# Commands (run several in one go, e.g. "./deploy.sh mod perfenv SLAYPERF_SPINE_HZ=15"):
#   mod        build + push the SlayPerf DLL/manifest (~30 KB). Keeps the device's slayperf.cfg.
#   cfg        push perfmod/slayperf.cfg over the device copy
#   lowres     push the slaylowres texture mod (~430 MB, skipped if unchanged)
#   lowres-off / lowres-on   park or restore slaylowres on the device (just a move, no re-upload)
#   install    fresh install: game files + default conf (conf only if the device has none)
#   game       push sts2 + sts2.pck + data dir (~1.7 GB, skipped per file if unchanged)
#   launcher   push "Slay the Spire 2.sh" to $REMOTE_LAUNCHER_DIR
#   perfenv K=V...   write perf.env on the device with the given SLAYPERF_*/SLAY_* settings
#                    (no args = delete perf.env, i.e. back to defaults)
#   shot       screenshot the handheld into ./device-logs/shots/
#   pull       fetch log.txt and perf CSVs into ./device-logs/
#
# Env: DEVICE (required), REMOTE_GAMEDIR (default /mnt/sdcard/ports/slaythespire2),
#      REMOTE_LAUNCHER_DIR (needed for "launcher"), SSH_OPTS (extra ssh args)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_GAMEDIR="$ROOT/slaythespire2/slaythespire2"
DEVICE="${DEVICE:?set DEVICE=root@<device-ip>}"
REMOTE_GAMEDIR="${REMOTE_GAMEDIR:-/mnt/sdcard/ports/slaythespire2}"
read -r -a SSH_ARGS <<< "${SSH_OPTS:-}"

rsh() { ssh "${SSH_ARGS[@]}" "$DEVICE" "$@"; }

# push_tar <local base> <relative paths...>  -> extracted under $REMOTE_GAMEDIR
push_tar() {
    local base="$1"; shift
    tar --format=ustar -C "$base" -cf - "$@" | rsh "mkdir -p '$REMOTE_GAMEDIR' && tar -C '$REMOTE_GAMEDIR' -xf -"
}

# push_big <relative path>: skip if the device already has an identical file.
push_big() {
    local rel="$1" local_sum remote_sum
    local_sum=$(md5sum "$LOCAL_GAMEDIR/$rel" | cut -d' ' -f1)
    remote_sum=$(rsh "md5sum '$REMOTE_GAMEDIR/$rel' 2>/dev/null | cut -d' ' -f1" || true)
    if [[ "$local_sum" == "$remote_sum" ]]; then
        echo "  $rel unchanged, skipping"
    else
        echo "  pushing $rel ($(du -h "$LOCAL_GAMEDIR/$rel" | cut -f1))"
        push_tar "$LOCAL_GAMEDIR" "$rel"
    fi
}

while [[ $# -gt 0 ]]; do
    cmd="$1"; shift
    case "$cmd" in
        mod)
            "$ROOT/perfmod/build.sh" >/dev/null
            echo "pushing slayperf"
            push_tar "$LOCAL_GAMEDIR" mods/slayperf/slayperf.dll mods/slayperf/slayperf.json
            rsh "[ -f '$REMOTE_GAMEDIR/mods/slayperf/slayperf.cfg' ]" \
                || push_tar "$ROOT/perfmod" --transform 's|^|mods/slayperf/|' slayperf.cfg
            ;;
        cfg)
            echo "pushing slayperf.cfg"
            push_tar "$ROOT/perfmod" --transform 's|^|mods/slayperf/|' slayperf.cfg
            ;;
        lowres)
            [[ -f "$LOCAL_GAMEDIR/mods/slaylowres/slaylowres.pck" ]] || { echo "build it first: tools/make-lowres.sh"; exit 1; }
            echo "slaylowres:"
            push_tar "$LOCAL_GAMEDIR" mods/slaylowres/slaylowres.json
            push_big mods/slaylowres/slaylowres.pck
            ;;
        lowres-off)
            # Park it outside mods/ so the game ignores it; no SD writes, instant to undo.
            echo "disabling slaylowres"
            rsh "cd '$REMOTE_GAMEDIR' && mkdir -p mods-disabled && { [ ! -d mods/slaylowres ] || mv mods/slaylowres mods-disabled/; }"
            ;;
        lowres-on)
            echo "enabling slaylowres"
            rsh "cd '$REMOTE_GAMEDIR' && mkdir -p mods && { [ ! -d mods-disabled/slaylowres ] || mv mods-disabled/slaylowres mods/; }"
            ;;
        install)
            # Fresh install: game files plus the default config (only if the device has none).
            set -- game "$@"
            rsh "[ -d '$REMOTE_GAMEDIR/conf' ]" || { echo "pushing default conf"; push_tar "$LOCAL_GAMEDIR" conf; }
            ;;
        game)
            echo "game files:"
            push_big sts2
            push_big sts2.pck
            for f in "$LOCAL_GAMEDIR"/*.so; do push_big "$(basename "$f")"; done
            push_tar "$LOCAL_GAMEDIR" data_sts2_linuxbsd_arm64
            ;;
        launcher)
            : "${REMOTE_LAUNCHER_DIR:?set REMOTE_LAUNCHER_DIR to the ports roms folder on the device}"
            echo "pushing launcher"
            tar --format=ustar -C "$ROOT/slaythespire2" -cf - "Slay the Spire 2.sh" \
                | rsh "mkdir -p '$REMOTE_LAUNCHER_DIR' && tar -C '$REMOTE_LAUNCHER_DIR' -xf -"
            ;;
        perfenv)
            kv=()
            while [[ $# -gt 0 && "$1" == *=* ]]; do kv+=("$1"); shift; done
            if [[ ${#kv[@]} -eq 0 ]]; then
                echo "removing perf.env (defaults)"
                rsh "rm -f '$REMOTE_GAMEDIR/perf.env'"
            else
                echo "perf.env: ${kv[*]}"
                printf '%s\n' "${kv[@]}" | rsh "cat > '$REMOTE_GAMEDIR/perf.env'"
            fi
            ;;
        shot)
            # Grab the visible framebuffer (works while the game is running).
            dest="$ROOT/device-logs/shots"; mkdir -p "$dest"
            name="shot-$(date +%Y%m%d-%H%M%S)"
            rsh "cat /sys/class/graphics/fb0/pan; cat /dev/fb0" > "$dest/$name.raw"
            python3 -I "$ROOT/tools/fb2png.py" "$dest/$name.raw" "$dest/$name.png" >/dev/null && rm "$dest/$name.raw"
            echo "$dest/$name.png"
            ;;
        pull)
            dest="$ROOT/device-logs"
            mkdir -p "$dest"
            rsh "cd '$REMOTE_GAMEDIR' && tar -cf - log.txt mods/slayperf/logs 2>/dev/null" | tar -C "$dest" -xf - || true
            echo "logs in $dest:"
            ls -t "$dest"/mods/slayperf/logs/*.csv 2>/dev/null | head -5 || true
            ;;
        *)
            sed -n '2,24p' "$0"; exit 1 ;;
    esac
done
