#!/usr/bin/env python3
"""Listens on the system bus for Steam Big Picture's Switch-to-Desktop
dbus call (org.freedesktop.DisplayManager.Seat.SwitchToUser) and performs
the session swap directly — runs as root so no pkexec / polkit needed.

Flow:
  1. Steam UI's Power-Menu Switch-to-Desktop fires
        dbus-send --system --dest=org.freedesktop.DisplayManager \\
            /org/freedesktop/DisplayManager/Seat0 \\
            org.freedesktop.DisplayManager.Seat.SwitchToUser \\
            string:doorstop string:plasma
  2. This listener catches the call (BecomeMonitor mode on system bus)
  3. Writes /etc/sddm.conf.d/zzt-steamos-temp-login.conf for plasma
  4. Runs 'steam -shutdown' as the deck user — gamescope-session ends
     cleanly because Steam (gamescope's child) exits, DRM master is
     released the gentle way, sddm bounces and autologs into plasma.
  5. The zzt- conf is one-shot — sddm's ExecStartPre wipes it on the
     next sddm restart, so closing plasma drops back to gamescope.
"""
import dbus, dbus.mainloop.glib, subprocess, sys, traceback
from gi.repository import GLib

LOG = "[steam-session-switch-listener]"
# zzz- sorts AFTER zz-steamos-autologin.conf (so it overrides), AND it
# doesn't match the ExecStartPre rm pattern that only deletes 'zzt-...'
# — so the conf survives `systemctl restart sddm` cycles.
ZZT = "/etc/sddm.conf.d/zzz-session-override.conf"

SESSION_MAP = {
    "plasma": "plasma.desktop",
    "plasma-wayland": "plasma.desktop",
    "plasma-wayland-persistent": "plasma.desktop",
    "desktop": "plasma.desktop",
    "plasma-x11": "plasmax11.desktop",
    "plasma-x11-persistent": "plasmax11.desktop",
    "gamescope": "gamescope-wayland.desktop",
}

def handle_switch(session):
    target = SESSION_MAP.get(session, "gamescope-wayland.desktop")
    print(f"{LOG} writing zzt- conf -> {target}", flush=True)
    with open(ZZT, "w") as f:
        f.write(f"[Autologin]\nUser=deck\nSession={target}\nRelogin=true\n")

    # Restart sddm directly. Since we used zzz-session-override.conf,
    # the ExecStartPre that only kills zzt-... doesn't wipe it. sddm
    # restart reads the conf (zzz- sorts after zz-steamos-autologin.conf,
    # so it wins) and autologs into the requested session.
    print(f"{LOG} systemctl restart sddm", flush=True)
    subprocess.Popen(["systemctl", "restart", "sddm"], stdin=subprocess.DEVNULL)

def on_message(_bus, message):
    try:
        if message.get_interface() != "org.freedesktop.DisplayManager.Seat":
            return
        if message.get_member() != "SwitchToUser":
            return
        args = list(message.get_args_list())
        if len(args) < 2:
            return
        user, session = str(args[0]), str(args[1])
        print(f"{LOG} caught SwitchToUser({user!r}, {session!r})", flush=True)
        handle_switch(session)
    except Exception:
        # NEVER let an exception kill the monitor — log and continue
        traceback.print_exc()

def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    bus_obj = bus.get_object("org.freedesktop.DBus", "/org/freedesktop/DBus")
    monitoring = dbus.Interface(bus_obj, "org.freedesktop.DBus.Monitoring")
    monitoring.BecomeMonitor(
        ["type='method_call',"
         "interface='org.freedesktop.DisplayManager.Seat',"
         "member='SwitchToUser'"],
        dbus.UInt32(0),
    )
    bus.add_message_filter(on_message)
    print(f"{LOG} listening on system bus for SwitchToUser", flush=True)
    GLib.MainLoop().run()

if __name__ == "__main__":
    sys.exit(main())
