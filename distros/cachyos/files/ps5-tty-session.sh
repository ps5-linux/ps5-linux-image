# /etc/profile.d/ps5-tty-session.sh — tty1 autologin: Gamescope or Plasma (no SDDM).
# Sourced from /etc/profile (login shells) and from ~/.bashrc (agetty autologin
# usually starts a non-login shell). Idempotent guard avoids double-exec.

case ${PS5_TTY_SESSION_INIT-} in
1) return ;;
esac
PS5_TTY_SESSION_INIT=1
export PS5_TTY_SESSION_INIT

tty_path=$(tty 2>/dev/null) || tty_path=""
[ "$tty_path" = "/dev/tty1" ] || return 0
[ -z "${WAYLAND_DISPLAY-}" ] || return 0
[ -z "${DISPLAY-}" ] || return 0

SESSION_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/ps5-next-session"
mkdir -p "$(dirname "$SESSION_FILE")"
[ -f "$SESSION_FILE" ] || echo gamescope >"$SESSION_FILE"
read -r SESSION <"$SESSION_FILE" 2>/dev/null || SESSION=gamescope
SESSION=$(printf '%s' "$SESSION" | tr -d '\r\n\t ')

export LIBSEAT_BACKEND=logind

case "$SESSION" in
  desktop|plasma|plasma-wayland|plasmax11)
    # Do not `exec` Plasma: if startplasma-{wayland,x11} exits immediately the login
    # shell ends, getty respawns in a tight loop, and start-limit-hit fires. Default
    # is Plasma Wayland from VT (no SDDM greeter Xorg). The plasmax11 token is an
    # explicit X11 escape hatch via startx + startplasma-x11.
    LOG=/tmp/ps5-tty-session.log
    # KDE helper: wraps Plasma in a session bus only when one is not already provided
    # by systemd --user. Plain dbus-run-session would start an isolated bus and break
    # org.freedesktop.systemd1 activation, PipeWire sockets, and xdg-desktop-portal.
    PLASMA_DBUS_WRAP=""
    [ -x /usr/lib/plasma-dbus-run-session-if-needed ] && PLASMA_DBUS_WRAP=/usr/lib/plasma-dbus-run-session-if-needed
    _run_plasma_dbus() {
      if [ -n "${PLASMA_DBUS_WRAP}" ]; then
        "$PLASMA_DBUS_WRAP" "$@"
      elif [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ]; then
        "$@"
      else
        dbus-run-session -- "$@"
      fi
    }
    rv=0
    case "$SESSION" in
      plasmax11)
        if [ -x /usr/bin/startx ] && [ -x /usr/bin/startplasma-x11 ]; then
          _run_plasma_dbus startx /usr/bin/startplasma-x11 -- >>"$LOG" 2>&1 || rv=$?
        else
          echo "$(date) startx or startplasma-x11 missing — falling back to gamescope" >>"$LOG"
        fi
        ;;
      *)
        if [ -x /usr/bin/startplasma-wayland ]; then
          _run_plasma_dbus /usr/bin/startplasma-wayland >>"$LOG" 2>&1 || rv=$?
        else
          echo "$(date) startplasma-wayland missing — falling back to gamescope" >>"$LOG"
        fi
        ;;
    esac
    [ "$rv" = 0 ] || echo "$(date) plasma session exited rv=$rv" >>"$LOG"
    echo gamescope >"$SESSION_FILE"
    unset PS5_TTY_SESSION_INIT
    export WLR_LIBINPUT_NO_DEVICES=1
    exec /usr/bin/gamescope-session-ps5
    ;;
  gamescope|*)
    echo gamescope >"$SESSION_FILE"
    export WLR_LIBINPUT_NO_DEVICES=1
    exec /usr/bin/gamescope-session-ps5
    ;;
esac
