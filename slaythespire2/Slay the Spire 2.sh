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
# Settings menu (LÖVE, bundled with PortMaster), shown on every launch. Same pattern as the
# PortMaster "Binding of Isaac: Rebirth" port. It writes conf/love/sts2launcher/settings.cfg,
# which is turned into SLAY_*/SLAYPERF_* settings below. Set SLAY_SKIP_MENU=1 (in perf.env
# or the environment) to go straight to the game with the saved settings.
# ---------------------------------------------------------------------------------------
[ -f "$GAMEDIR/perf.env" ] && grep -q '^SLAY_SKIP_MENU=1' "$GAMEDIR/perf.env" && SLAY_SKIP_MENU=1
if [ -d "$GAMEDIR/mods/slaylowres" ] || [ -d "$GAMEDIR/mods-disabled/slaylowres" ]; then
  export SLAY_LOWRES_AVAILABLE=1
else
  export SLAY_LOWRES_AVAILABLE=0
fi
love_txt="$controlfolder/runtimes/love_11.5/love.txt"
if [ "${SLAY_SKIP_MENU:-0}" != "1" ] && [ -f "$love_txt" ]; then
  source "$love_txt"
  $GPTOKEYB "$LOVE_GPTK" -c "$GAMEDIR/launcher.gptk" &
  XDG_DATA_HOME=$CONFDIR $LOVE_RUN "$GAMEDIR/launcher"
  menu_status=$?
  $ESUDO pkill -f "gptokeyb.*$LOVE_GPTK"
  if [ "$menu_status" -ne 0 ]; then
    echo "Settings menu closed without launching (status $menu_status)"
    [[ "$PM_CAN_MOUNT" != "N" ]] && $ESUDO umount "${weston_dir}"
    pm_finish
    exit 0
  fi
fi

# Apply the menu's settings. Parsed rather than sourced, and only known keys are accepted.
SETTINGS_CFG="$CONFDIR/love/sts2launcher/settings.cfg"
if [ -f "$SETTINGS_CFG" ]; then
  while IFS='=' read -r key value; do
    [[ "$value" =~ ^[A-Za-z0-9_]+$ ]] || continue
    case "$key" in
      lowres)    SLAY_LOWRES=$value ;;
      spine_hz)  SLAYPERF_SPINE_HZ=$value ;;
      particles) SLAYPERF_PARTICLES=$value ;;
      gc)        SLAY_DOTNET_TWEAKS=$value ;;
      cpu_max)   [ "$value" = "1" ] && SLAY_GOVERNOR=performance || SLAY_GOVERNOR= ;;
      hud)       [ "$value" = "1" ] && SLAYPERF_HUD=true || SLAYPERF_HUD=false ;;
    esac
  done < "$SETTINGS_CFG"
  echo "Menu settings: $(tr '\n' ' ' < "$SETTINGS_CFG")"
fi

# ---------------------------------------------------------------------------------------
# Performance experiments. Everything here is optional; see README "Performance work".
# perf.env is applied after the menu settings, so it overrides them.
#   SLAY_MODS=0             run with --nomods (true vanilla baseline)
#   SLAY_GOVERNOR=performance   pin the CPU governor for the session (restored on exit)
#   SLAY_DOTNET_TWEAKS=1    cheaper .NET JIT/GC settings for slow CPUs
#   SLAYPERF_<KEY>=value    override any key in mods/slayperf/slayperf.cfg,
#                           e.g. SLAYPERF_PARTICLES=off SLAYPERF_SPINE_HZ=15
# You can also put these in $GAMEDIR/perf.env so you don't have to edit this script.
# ---------------------------------------------------------------------------------------
[ -f "$GAMEDIR/perf.env" ] && . "$GAMEDIR/perf.env"

# Low-res textures: SLAY_LOWRES=1/0 moves the mod in or out of mods/ (a rename, no copying).
if [ "${SLAY_LOWRES:-}" = "1" ] && [ -d "$GAMEDIR/mods-disabled/slaylowres" ]; then
  mkdir -p "$GAMEDIR/mods" && mv "$GAMEDIR/mods-disabled/slaylowres" "$GAMEDIR/mods/"
elif [ "${SLAY_LOWRES:-}" = "0" ] && [ -d "$GAMEDIR/mods/slaylowres" ]; then
  mkdir -p "$GAMEDIR/mods-disabled" && mv "$GAMEDIR/mods/slaylowres" "$GAMEDIR/mods-disabled/"
fi

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

# -x: xbox360 controller emulation (the game reads input from this virtual pad).
# -X: exit on the hotkey (Select+Start).
$GPTOKEYB2 "$godot_executable" -x -X &
gptokeyb_pid=$!

# westonwrap only checks gptokeyb at startup, so after the hotkey nothing stops the game:
# it keeps running with no input device and looks frozen. Watch gptokeyb ourselves and send
# the game SIGTERM when it exits. SlayPerf turns that into a clean, saving quit (the game
# alone ignores SIGTERM), so escalate to SIGKILL if it's still around after 10 s.
signal_game() {
  for p in /proc/[0-9]*; do
    [ "$(cat "$p/comm" 2>/dev/null)" = "$godot_executable" ] && $ESUDO kill "-$1" "${p#/proc/}" 2>/dev/null
  done
}
(
  while kill -0 "$gptokeyb_pid" 2>/dev/null; do sleep 1; done
  echo "gptokeyb exited (quit hotkey), stopping $godot_executable"
  signal_game TERM
  sleep 10
  signal_game KILL
) &
quit_watcher_pid=$!

# Start Westonpack and Godot
# Note: don't pass "--force-sentry off". The game only checks whether the flag is present,
# so any value forces Sentry ON in debug mode, which logs and uploads every warning.
$ESUDO env CRUSTY_BLOCK_INPUT=1 $weston_dir/westonwrap.sh headless noop kiosk crusty_x11egl \
XDG_DATA_HOME=$CONFDIR $game_env $GAMEDIR/$godot_executable \
--resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} -f \
--rendering-driver opengl3_es --audio-driver ALSA --main-pack "$GAMEDIR/$pck_filename" \
--force-steam off $extra_args

# Game is gone: stop the watcher (it would otherwise fire when gptokeyb is torn down).
kill "$quit_watcher_pid" 2>/dev/null
kill "$gptokeyb_pid" 2>/dev/null

[ -n "${old_governor:-}" ] && echo "$old_governor" | $ESUDO tee "$GOV" >/dev/null

$ESUDO $weston_dir/westonwrap.sh cleanup
if [[ "$PM_CAN_MOUNT" != "N" ]]; then
    $ESUDO umount "${weston_dir}"
fi
pm_finish
