#!/bin/sh
#
# FreeBSD Hyprland desktop installer — full run
# Run as: sudo sh install.sh [fast|full] [username]
#
# Picks up exactly where stage 1 left off (base FreeBSD 15.x, ZFS/GELI,
# a user created and in wheel/sudo). From there this single script:
#
#   1. builds the Hyprland desktop stack (compositor, bar, terminal,
#      toolchain, CLI tools, login manager) — mode-dependent, see below
#   2. writes dotfiles and wires up services/groups
#   3. hardens pf (aborts if the firewall config is broken)
#   4. installs the rest of the software stack via pkg, checking what's
#      already there and continuing past anything that fails
#
# TWO MODES, chosen interactively or as $1:
#   fast  pkg (binary packages) for the desktop stack — only Hyprland,
#         Hyprlock and Hypridle are actually compiled from ports, because
#         those move fast upstream and build options matter; everything
#         else (Mesa, Rust, Go, Firefox, Qt-heavy stuff...) is identical
#         either way and pkg saves hours. Realistically ~30-60 min.
#   full  compile the ENTIRE desktop stack from ports, as before.
#         Realistically an overnight build even on fast hardware.
#
# Part B (the big application list: Blender, LibreOffice, Chromium, ...)
# always uses pkg regardless of mode — compiling that from ports is not
# a reasonable trade-off in either mode.
#
# Rule enforced throughout:
#   security component fails (pf)      -> ABORT, fix it before continuing
#   optional application fails         -> log it, move on
#
# Logging: every run gets its own timestamped transcript under
# /var/log/installer/, plus one log file per port build / pkg install so
# you can find exactly what went wrong without re-running anything.
#
# Re-running is safe/idempotent — `make install clean` and `pkg install`
# both skip what's already there.

set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root: sudo sh install.sh [fast|full] [username]" >&2
    exit 1
fi

LOGDIR=/var/log/installer
mkdir -p "$LOGDIR"
MAINLOG="$LOGDIR/install-$(date +%Y%m%d-%H%M%S).log"
: > "$MAINLOG"
SCRIPT_START=$(date +%s)
FAILED=""
NOTES=""

log()  { printf '[%s] >>> %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$MAINLOG"; }
warn() { printf '[%s] !!! %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$MAINLOG" >&2; }
fail() { printf '[%s] XXX %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$MAINLOG" >&2; exit 1; }
note() { NOTES="$NOTES
- $*"; }

log "log transcript: $MAINLOG"

### 0. mode + primary user ------------------------------------------------

MODE=""
case "${1:-}" in
    fast|full) MODE="$1"; shift ;;
esac

if [ -z "$MODE" ]; then
    echo "Choose install mode:"
    echo "  [1] fast — pkg for the desktop stack, ports only for Hyprland/Hyprlock/Hypridle (~30-60 min)"
    echo "  [2] full — compile the entire desktop stack from ports (realistically overnight)"
    printf "Select [1/2] (default 1): "
    read choice
    case "$choice" in
        2) MODE=full ;;
        *) MODE=fast ;;
    esac
fi
log "install mode: $MODE"

TARGET_USER="${1:-${SUDO_USER:-}}"
if [ -z "$TARGET_USER" ]; then
    printf "Primary (desktop) username on this system: "
    read TARGET_USER
fi
if ! pw usershow "$TARGET_USER" >/dev/null 2>&1; then
    fail "user '$TARGET_USER' does not exist — create it first (stage 1's job)"
fi
TARGET_HOME=$(pw usershow "$TARGET_USER" | cut -d: -f9)

NPROC=$(sysctl -n hw.ncpu)
PORTSDIR=/usr/ports

log "target user: $TARGET_USER ($TARGET_HOME), building with ${NPROC} jobs, mode=$MODE"

################################################################################
# PART A — desktop stack
################################################################################

### A1. bootstrap pkg (always needed, both modes) ----------------------------

log "bootstrapping pkg"
env ASSUME_ALWAYS_YES=yes pkg bootstrap -y >/dev/null 2>&1 || true
pkg update -f || warn "pkg update failed — check network / pkg repo config"
pkg install -y git >/dev/null

### A2. ports tree (only actually needed for hyprland/lock/idle in fast mode,
### but cheap to have either way, and required for full mode) ---------------

if [ ! -d "$PORTSDIR/.git" ]; then
    log "cloning ports tree (~1-2GB, first run only)"
    rm -rf "$PORTSDIR"
    git clone --depth 1 https://git.FreeBSD.org/ports.git "$PORTSDIR"
else
    log "updating existing ports tree"
    (cd "$PORTSDIR" && git pull --ff-only)
fi

MAKE_CONF=/etc/make.conf
touch "$MAKE_CONF"
grep -q '^MAKE_JOBS_NUMBER' "$MAKE_CONF" || echo "MAKE_JOBS_NUMBER=${NPROC}"    >> "$MAKE_CONF"
grep -q '^WRKDIRPREFIX'     "$MAKE_CONF" || echo "WRKDIRPREFIX=/usr/obj/ports" >> "$MAKE_CONF"
grep -q '^OPTIONS_UNSET'    "$MAKE_CONF" || echo "OPTIONS_UNSET+=DOCS EXAMPLES" >> "$MAKE_CONF"
export BATCH=yes

### A3. helpers ----------------------------------------------------------------

build_port() {
    port="$1"
    dir="$PORTSDIR/$port"
    logfile="$LOGDIR/port_$(printf '%s' "$port" | tr '/' '_').log"
    if [ ! -d "$dir" ]; then
        warn "skip $port — not found in ports tree (category may have moved; check freshports.org)"
        FAILED="$FAILED $port(missing)"
        return 1
    fi
    log "building $port (ports)"
    t0=$(date +%s)
    if make -C "$dir" install clean BATCH=yes IGNORE_OSVERSION=yes >"$logfile" 2>&1; then
        log "built $port in $(( $(date +%s) - t0 ))s"
        return 0
    else
        warn "FAILED: $port — see $logfile"
        FAILED="$FAILED $port"
        return 1
    fi
}

ensure_pkg() {
    name="$1"
    logfile="$LOGDIR/pkg_$(printf '%s' "$name" | tr '/' '_').log"
    if pkg info -e "$name" >/dev/null 2>&1; then
        log "ok, already installed: $name"
        return 0
    fi
    log "installing $name (pkg)"
    t0=$(date +%s)
    if pkg install -y "$name" >"$logfile" 2>&1; then
        log "installed $name in $(( $(date +%s) - t0 ))s"
        return 0
    else
        warn "FAILED or not in repo: $name — see $logfile"
        FAILED="$FAILED $name"
        return 1
    fi
}

# ports where compiling is actually worth it even in fast mode: Hyprland
# and friends move quickly upstream and build options matter more than
# build time here.
ALWAYS_PORT="x11-wm/hyprland x11-wm/hyprlock x11-wm/hypridle"

is_always_port() {
    for p in $ALWAYS_PORT; do
        [ "$p" = "$1" ] && return 0
    done
    return 1
}

# unified installer: builds from ports in full mode, or when the port is
# in ALWAYS_PORT regardless of mode; otherwise installs the equivalent
# binary package (FreeBSD pkg names match the ports leaf name).
install_component() {
    port="$1"
    pkgname="${port##*/}"
    if [ "$MODE" = "full" ] || is_always_port "$port"; then
        build_port "$port"
    else
        ensure_pkg "$pkgname"
    fi
}

### A4. build/install the stack ------------------------------------------------
# NOTE: FreeBSD base already gives you clang/llvm/lld/lldb, bmake, OpenZFS,
# GELI, gpart, the loader, pf, WireGuard, OpenSSH, Capsicum, MAC, BSM audit,
# mtree, devd, dhclient, wpa_supplicant, and unbound (as local_unbound).
# None of that needs a port or package — this list is everything ELSE.

log "== toolchain =="
for p in devel/cmake devel/ninja devel/meson devel/pkgconf \
         lang/python311 lang/rust lang/go; do
    install_component "$p"
done

log "== seat / graphics / wayland core =="
for p in sysutils/seatd graphics/drm-kmod graphics/mesa-libs graphics/mesa-dri \
         graphics/vulkan-loader graphics/vulkan-tools x11/libinput \
         sysutils/dbus sysutils/polkit; do
    install_component "$p"
done

log "== compositor + desktop shell =="
for p in x11-wm/hyprland x11-wm/hyprlock x11-wm/hypridle x11/xwayland \
         x11/waybar x11/foot x11/ly x11/wl-clipboard x11/mako x11/wlogout \
         x11/nwg-look x11/py-nwg-displays x11/wofi x11/cliphist \
         graphics/grim x11/slurp graphics/swappy; do
    install_component "$p"
done

log "== audio =="
for p in multimedia/pipewire audio/wireplumber; do
    install_component "$p"
done

log "== shell / CLI tools =="
for p in shells/fish editors/neovim sysutils/tmux textproc/ripgrep \
         shells/fzf sysutils/btop ftp/curl ftp/wget net/rsync; do
    install_component "$p"
done

log "== security add-ons =="
for p in security/sudo security/sshguard net/wireguard-tools; do
    install_component "$p"
done

log "== browser =="
install_component www/firefox

### A5. services + groups -----------------------------------------------------

log "enabling services"
sysrc dbus_enable=YES          >/dev/null
sysrc seatd_enable=YES         >/dev/null
sysrc local_unbound_enable=YES >/dev/null
sysrc sshguard_enable=YES      >/dev/null

service dbus start          2>/dev/null || true
service seatd start         2>/dev/null || true
service sshguard start      2>/dev/null || true
service local_unbound setup 2>/dev/null || true
service local_unbound start 2>/dev/null || true

log "adding $TARGET_USER to video/seatd groups"
pw groupmod video -m "$TARGET_USER" 2>/dev/null || true
pw groupmod seatd -m "$TARGET_USER" 2>/dev/null || true

log "loading DRM KMS module — EDIT THIS for your actual GPU (i915kms/amdgpu/radeonkms)"
sysrc kld_list+="i915kms" >/dev/null
kldload i915kms 2>/dev/null || warn "kldload i915kms failed — load the right module for your GPU by hand"

### A6. ly as the login manager on ttyv0 --------------------------------------

log "wiring ly into ttyv0"
if [ -f /etc/ttys ]; then
    cp /etc/ttys /etc/ttys.bak
    sed -i '' 's;^ttyv0[[:space:]].*;ttyv0 "/usr/local/bin/ly" xterm on secure;' /etc/ttys
fi

### A7. dotfiles for the target user ------------------------------------------

CONF="$TARGET_HOME/.config"
mkdir -p "$CONF/hypr" "$CONF/waybar" "$CONF/foot"

log "writing hyprland.conf"
cat > "$CONF/hypr/hyprland.conf" <<'EOF'
# square, borderless, gapless tiling — generated by install.sh

$mod = SUPER
$terminal = foot
$fileManager = thunar
$menu = wofi --show drun

monitor = , preferred, auto, 1

exec-once = waybar
exec-once = mako
exec-once = wl-paste --type text --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store
exec-once = hypridle

env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24

general {
    gaps_in = 0
    gaps_out = 0
    border_size = 0
    layout = dwindle
}

decoration {
    rounding = 0
    active_opacity = 1.0
    inactive_opacity = 1.0
    drop_shadow = false
    blur {
        enabled = false
    }
}

animations {
    enabled = true
    bezier = snappy, 0.2, 0.9, 0.1, 1.0
    animation = windows, 1, 3, snappy
    animation = workspaces, 1, 3, snappy
    animation = border, 0
}

dwindle {
    preserve_split = true
}

input {
    kb_layout = us
    touchpad {
        natural_scroll = false
    }
}

misc {
    disable_hyprland_logo = true
    force_default_wallpaper = 0
}

bind = $mod, RETURN, exec, $terminal
bind = $mod, E, exec, $fileManager
bind = $mod, SPACE, exec, $menu
bind = $mod, B, exec, firefox
bind = $mod, Q, killactive,
bind = $mod, F, fullscreen, 0
bind = $mod, V, togglefloating,
bind = $mod, P, pseudo,
bind = $mod, G, pin,
bind = $mod, L, exec, hyprlock
bind = $mod, X, exec, wlogout

bind = $mod, left,  movefocus, l
bind = $mod, right, movefocus, r
bind = $mod, up,    movefocus, u
bind = $mod, down,  movefocus, d

bind = $mod SHIFT, left,  movewindow, l
bind = $mod SHIFT, right, movewindow, r
bind = $mod SHIFT, up,    movewindow, u
bind = $mod SHIFT, down,  movewindow, d

bind = $mod ALT, left,  resizeactive, -40 0
bind = $mod ALT, right, resizeactive, 40 0
bind = $mod ALT, up,    resizeactive, 0 -40
bind = $mod ALT, down,  resizeactive, 0 40

bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod, 6, workspace, 6
bind = $mod, 7, workspace, 7
bind = $mod, 8, workspace, 8
bind = $mod, 9, workspace, 9
bind = $mod, 0, workspace, 10

bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
bind = $mod SHIFT, 5, movetoworkspace, 5
bind = $mod SHIFT, 6, movetoworkspace, 6
bind = $mod SHIFT, 7, movetoworkspace, 7
bind = $mod SHIFT, 8, movetoworkspace, 8
bind = $mod SHIFT, 9, movetoworkspace, 9
bind = $mod SHIFT, 0, movetoworkspace, 10

bind = $mod, mouse_down, workspace, e+1
bind = $mod, mouse_up,   workspace, e-1

bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow

bind = , Print, exec, grim -g "$(slurp)" - | wl-copy
bind = SHIFT, Print, exec, grim - | wl-copy

bind = $mod, PERIOD, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy

bindel = , XF86AudioRaiseVolume,  exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume,  exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindel = , XF86AudioMute,         exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindel = , XF86AudioMicMute,      exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
EOF

log "writing waybar config"
cat > "$CONF/waybar/config.jsonc" <<'EOF'
{
    "layer": "top",
    "position": "top",
    "height": 28,
    "modules-left": ["hyprland/workspaces"],
    "modules-center": ["clock"],
    "modules-right": ["pulseaudio", "network", "battery", "tray"],
    "hyprland/workspaces": {
        "format": "{id}"
    },
    "clock": {
        "format": "{:%Y-%m-%d %H:%M}"
    },
    "battery": {
        "format": "{capacity}%"
    },
    "network": {
        "format-wifi": "{essid}",
        "format-ethernet": "eth"
    },
    "pulseaudio": {
        "format": "vol {volume}%"
    }
}
EOF

log "writing waybar style (square, borderless)"
cat > "$CONF/waybar/style.css" <<'EOF'
* {
    border: none;
    border-radius: 0;
    font-family: monospace;
    font-size: 13px;
}
window#waybar {
    background: #101010;
    color: #e0e0e0;
}
#workspaces button {
    padding: 0 8px;
    background: transparent;
    color: #808080;
}
#workspaces button.active {
    background: #202020;
    color: #ffffff;
}
#clock, #pulseaudio, #network, #battery, #tray {
    padding: 0 10px;
}
EOF

log "writing foot config"
cat > "$CONF/foot/foot.ini" <<'EOF'
[main]
font=monospace:size=11
pad=0x0

[colors]
alpha=1.0
EOF

chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config"

################################################################################
# PART B — pf hardening + application stack (always via pkg)
################################################################################

log "== pf firewall =="

EXT_IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [ -z "$EXT_IF" ]; then
    fail "could not determine the default-route interface — refusing to guess for a firewall config. Candidates: $(ifconfig -l 2>/dev/null). Set it manually and re-run."
fi
log "using external interface: $EXT_IF"

PF_CONF=/etc/pf.conf
if [ -f "$PF_CONF" ]; then
    cp "$PF_CONF" "${PF_CONF}.bak.$(date +%s)"
    log "existing pf.conf backed up"
fi

cat > "$PF_CONF" <<EOF
# pf.conf — generated by install.sh
# default-deny, stateful, ssh brute-force throttling via table + sshguard

ext_if = "$EXT_IF"

set skip on lo0
set block-policy drop
scrub in all fragment reassemble

table <bruteforce> persist
table <sshguard> persist

block in quick from <sshguard>
block in quick from <bruteforce>

block all

pass out quick keep state

pass in quick on \$ext_if proto tcp to port 22 keep state \\
    (max-src-conn 15, max-src-conn-rate 5/60, overload <bruteforce> flush global)

pass in quick on \$ext_if inet proto icmp icmp-type echoreq keep state
pass in quick on \$ext_if inet6 proto icmp6 icmp6-type echoreq keep state

# WireGuard, if you're running it — uncomment and set your port
# pass in quick on \$ext_if proto udp to port 51820 keep state
EOF

if ! pfctl -nf "$PF_CONF" >"$LOGDIR/pfctl_check.log" 2>&1; then
    fail "pf.conf failed syntax check — see $LOGDIR/pfctl_check.log — pf NOT enabled, fix the ruleset before re-running (hard stop, not a warning)"
fi
log "pf.conf syntax OK"
sysrc pf_enable=YES        >/dev/null
sysrc pf_rules="$PF_CONF"  >/dev/null
sysrc pflog_enable=YES     >/dev/null
sysrc pflog_logfile="/var/log/pflog" >/dev/null
service pf reload 2>/dev/null || service pf start 2>/dev/null || fail "pf.conf checked out OK but the pf service still won't start — check 'service pf start' manually"
service pflog start 2>/dev/null || true

service sshguard restart 2>/dev/null || service sshguard start 2>/dev/null || warn "sshguard didn't (re)start — pf's baseline rules still apply, but check this"

log "== linux compat layer =="
sysrc linux_enable=YES >/dev/null
kldload linux64 2>/dev/null || true
ensure_pkg linux-rl9 || ensure_pkg linux_base-c7
note "Linux compat installed for apps that ship only Linux binaries."

log "== bluetooth =="
sysrc hcsecd_enable=YES >/dev/null
sysrc sdpd_enable=YES   >/dev/null
service hcsecd start 2>/dev/null || true
service sdpd start 2>/dev/null || true
note "Bluetooth core (hcsecd/sdpd/hccontrol) is base-system; a USB dongle attaches via ng_ubt automatically. No polished GUI applet exists on FreeBSD — expect CLI tools, not a GNOME-style panel."

log "== printing =="
ensure_pkg cups
ensure_pkg cups-filters
sysrc cupsd_enable=YES >/dev/null
service cupsd start 2>/dev/null || true

# don't create the cups group ourselves — the package owns that
if pw groupshow cups >/dev/null 2>&1; then
    pw groupmod cups -m "$TARGET_USER" 2>/dev/null || true
    log "added $TARGET_USER to cups group"
else
    warn "cups group does not exist after package installation — check the cups package's post-install output"
fi
note "CUPS admin UI: http://localhost:631 once cupsd is running."

log "== creative / media =="
for p in blender kdenlive mpv pwvucontrol inkscape; do
    ensure_pkg "$p"
done

log "== office =="
for p in libreoffice thunderbird; do
    ensure_pkg "$p"
done
ensure_pkg onlyoffice || note "OnlyOffice has no reliable FreeBSD package — LibreOffice (installed above) is the realistic option."

log "== browsers =="
for p in chromium tor; do
    ensure_pkg "$p"
done
ensure_pkg torbrowser-launcher || note "Tor Browser's launcher targets Linux and generally doesn't work on FreeBSD. Tor itself (installed above) works fine — point Firefox at socks5://127.0.0.1:9050, or torify a command."
note "Zen Browser ships no FreeBSD build at all (Linux/macOS/Windows only) — Firefox from Part A is the closest native option."

log "== file manager =="
for p in thunar thunar-volman tumbler gvfs; do
    ensure_pkg "$p"
done

log "== dev / security tools =="
for p in wine-devel qemu tree atuin git openjdk21; do
    ensure_pkg "$p"
done
ensure_pkg vscodium || note "VSCodium isn't reliably packaged for FreeBSD. neovim (Part A) or editors/lapce (native, lightweight) are the realistic editor options."
note "Ghidra and Burp Suite have no FreeBSD packages, but both are plain Java apps — openjdk21 is installed above, just run: java -jar burpsuite.jar / ./ghidraRun after downloading the release."

log "== gaming =="
ensure_pkg prismlauncher || note "Prism Launcher may not be in the repo for this release — check 'pkg search prismlauncher' manually."
ensure_pkg linux-steam-utils || note "linux-steam-utils failed/unavailable — Steam uses the Linuxulator and is hardware- and game-dependent either way. Treat it as an optional compatibility component to test, not something to rely on."

log "== bitwarden =="
ensure_pkg bitwarden-cli || note "Bitwarden's desktop app isn't packaged for FreeBSD. The CLI (bitwarden-cli) or the Firefox/Chromium browser extension are the practical paths."

################################################################################
# summary
################################################################################

ELAPSED=$(( $(date +%s) - SCRIPT_START ))
log "done in $((ELAPSED / 60))m $((ELAPSED % 60))s (mode=$MODE)"
if [ -n "$FAILED" ]; then
    warn "the following failed, were skipped, or aren't in the repo:$FAILED"
    warn "port build logs: $LOGDIR/port_*.log — pkg logs: $LOGDIR/pkg_*.log"
fi
if [ -n "$NOTES" ]; then
    echo ""
    echo "=== things worth knowing ===$NOTES"
fi
echo ""
log "full transcript saved to: $MAINLOG"
log "next steps:"
log "  1. double-check kld_list in /etc/rc.conf matches your actual GPU"
log "  2. reboot — ly will greet you on ttyv0, log in as $TARGET_USER, pick hyprland"
log "  3. tune $CONF/hypr/hyprland.conf to taste"
