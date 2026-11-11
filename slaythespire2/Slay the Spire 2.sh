#!/bin/bash

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
elif [ -d "/mnt/mmc/MUOS/PortMaster/" ]; then
  controlfolder="/mnt/mmc/MUOS/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi
source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

GAMEDIR=/$directory/ports/slaythespire2
godot_executable="sts2"
pck_filename="sts2.pck"

> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1

CONFDIR="$GAMEDIR/conf/"
$ESUDO mkdir -p "${CONFDIR}"

weston_dir=/tmp/weston
$ESUDO mkdir -p "${weston_dir}"
weston_runtime="weston_pkg_0.2"
if [ ! -f "$controlfolder/libs/${weston_runtime}.squashfs" ]; then
  if [ ! -f "$controlfolder/harbourmaster" ]; then
    pm_message "This port requires the latest PortMaster to run, please go to https://portmaster.games/ for more info."
    sleep 5
    exit 1
  fi
  $ESUDO $controlfolder/harbourmaster --quiet --no-check runtime_check "${weston_runtime}.squashfs"
fi
if [[ "$PM_CAN_MOUNT" != "N" ]]; then
    $ESUDO umount "${weston_dir}"
fi
$ESUDO mount "$controlfolder/libs/${weston_runtime}.squashfs" "${weston_dir}"

cd $GAMEDIR

# ---------------------------------------------------------------------------------------
# Performance experiments. Everything here is optional; see README "Performance work".
#   SLAY_MODS=0             run with --nomods (true vanilla baseline)
#   SLAY_GOVERNOR=performance   pin the CPU governor for the session (restored on exit)
#   SLAY_DOTNET_TWEAKS=1    cheaper .NET JIT/GC settings for slow CPUs
#   SLAYPERF_<KEY>=value    override any key in mods/slayperf/slayperf.cfg,
#                           e.g. SLAYPERF_PARTICLES=off SLAYPERF_SPINE_HZ=15
# You can also put these in $GAMEDIR/perf.env so you don't have to edit this script.
# ---------------------------------------------------------------------------------------
[ -f "$GAMEDIR/perf.env" ] && . "$GAMEDIR/perf.env"

# The game only loads mods after the player accepts the mod warning. Pre-accept it so the
# perf mods load on a fresh install.
SETTINGS="$CONFDIR/SlayTheSpire2/default/1/settings.save"
if [ -f "$SETTINGS" ] && grep -q '"mod_settings": null' "$SETTINGS"; then
  sed -i 's/"mod_settings": null/"mod_settings": {"mods_enabled": true}/' "$SETTINGS"
fi

extra_args=""
[ "${SLAY_MODS:-1}" = "0" ] && extra_args="$extra_args --nomods"

game_env="GODOT_SILENCE_ROOT_WARNING=1"
# Values can't contain spaces (they're passed through westonwrap as VAR=value words).
for v in $(compgen -v SLAYPERF_); do
  game_env="$game_env $v=${!v}"
done
if [ "${SLAY_DOTNET_TWEAKS:-0}" = "1" ]; then
  # No PGO instrumentation tier; bigger gen0 budget means fewer GCs. 0x2000000 = 32MB.
  game_env="$game_env DOTNET_TieredPGO=0 DOTNET_GCgen0size=0x2000000"
fi

GOV=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
if [ -n "${SLAY_GOVERNOR:-}" ] && [ -w "$GOV" -o -n "$ESUDO" ]; then
  old_governor=$(cat "$GOV")
  echo "$SLAY_GOVERNOR" | $ESUDO tee "$GOV" >/dev/null
fi

# -x: xbox360 controller emulation. -X: quit via kill. The game ignores SIGTERM, so the
# default (polite) quit on the hotkey combo does nothing.
$GPTOKEYB2 "$godot_executable" -x -X &

# Start Westonpack and Godot
# Note: don't pass "--force-sentry off". The game only checks whether the flag is present,
# so any value forces Sentry ON in debug mode, which logs and uploads every warning.
$ESUDO env CRUSTY_BLOCK_INPUT=1 $weston_dir/westonwrap.sh headless noop kiosk crusty_x11egl \
XDG_DATA_HOME=$CONFDIR $game_env $GAMEDIR/$godot_executable \
--resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} -f \
--rendering-driver opengl3_es --audio-driver ALSA --main-pack "$GAMEDIR/$pck_filename" \
--force-steam off $extra_args

[ -n "${old_governor:-}" ] && echo "$old_governor" | $ESUDO tee "$GOV" >/dev/null

$ESUDO $weston_dir/westonwrap.sh cleanup
if [[ "$PM_CAN_MOUNT" != "N" ]]; then
    $ESUDO umount "${weston_dir}"
fi
pm_finish
