#!/bin/sh
#
# FreeBSD Hyprland desktop installer — full run
# Run as: sudo sh install.sh [fast|medium|full] [username] [gpu]
#   gpu is one of: intel amd nvidia none  (see GPU section below)
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
# THREE MODES, chosen interactively or as $1:
#   fast    everything via pkg (binary packages), including Hyprland
#           itself. Fastest possible, no compiling at all. ~10-15 min.
#   medium  pkg for everything EXCEPT the pieces where compiling from
#           ports genuinely matters at runtime — Hyprland, Hyprlock,
#           Hypridle, Waybar, foot, fish, neovim (fast-moving upstream,
#           build options you'd actually want). Realistically ~1-2h.
#   full    compile the ENTIRE desktop stack from ports. Realistically
#           an overnight build even on fast hardware.
#
# Part B (the big application list: Blender, LibreOffice, Chromium, ...)
# always uses pkg regardless of mode — compiling that from ports is not
# a reasonable trade-off in any of the three.
#
# Rule enforced throughout:
#   security component fails (pf)      -> ABORT, fix it before continuing
#   required bootstrap dep fails       -> ABORT (pkg itself, git)
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
    echo "Run this as root: sudo sh install.sh [fast|medium|full] [username] [gpu]" >&2
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

FREEBSD_VERSION="$(freebsd-version -u 2>/dev/null || echo unknown)"
FREEBSD_KERNEL="$(freebsd-version -k 2>/dev/null || echo unknown)"
log "FreeBSD userland: $FREEBSD_VERSION, kernel: $FREEBSD_KERNEL"
if [ "$FREEBSD_VERSION" != "$FREEBSD_KERNEL" ]; then
    warn "kernel/userland version MISMATCH: kernel=$FREEBSD_KERNEL userland=$FREEBSD_VERSION"
    warn "this alone can break netlink-dependent tools like pfctl (ABI drift between versions) — fix with 'freebsd-update install' + reboot before continuing if pf gives you netlink errors"
fi
case "$FREEBSD_VERSION" in
    15.*) : ;;
    *) warn "this script was written against FreeBSD 15.x, userland is $FREEBSD_VERSION — proceeding, but watch for port/ABI mismatches" ;;
esac

### 0. mode + primary user + GPU ------------------------------------------

MODE=""
case "${1:-}" in
    fast|medium|full) MODE="$1"; shift ;;
esac

if [ -z "$MODE" ]; then
    echo "Choose install mode:"
    echo "  [1] fast   — everything via pkg, including Hyprland itself (~10-15 min)"
    echo "  [2] medium — pkg for most things, ports for Hyprland/Hyprlock/Hypridle/Waybar/foot/fish/neovim (~1-2h)"
    echo "  [3] full   — compile the entire desktop stack from ports (realistically overnight)"
    printf "Select [1/2/3] (default 1): "
    read choice
    case "$choice" in
        2) MODE=medium ;;
        3) MODE=full ;;
        *) MODE=fast ;;
    esac
fi
log "install mode: $MODE"

TARGET_USER="${1:-${SUDO_USER:-}}"
[ -n "${1:-}" ] && shift
if [ -z "$TARGET_USER" ]; then
    printf "Primary (desktop) username on this system: "
    read TARGET_USER
fi
if ! pw usershow "$TARGET_USER" >/dev/null 2>&1; then
    fail "user '$TARGET_USER' does not exist — create it first (stage 1's job)"
fi
TARGET_HOME=$(pw usershow "$TARGET_USER" | cut -d: -f9)

GPU_DRIVER="${GPU_DRIVER:-${1:-}}"
[ -n "${1:-}" ] && shift

detect_gpu() {
    # class=0x03 is the PCI display-controller class; grab that line plus
    # the vendor/device lines pciconf prints right after it.
    info=$(pciconf -lv 2>/dev/null | awk '
        /class=0x03/ { grab=5 }
        grab>0 { print; grab-- }
    ')
    case "$info" in
        *"Intel"*)                                            echo intel ;;
        *"NVIDIA"*)                                            echo nvidia ;;
        *"Advanced Micro Devices"*|*"ATI"*)                    echo amd ;;
        *"VMware"*|*"QEMU"*|*"Red Hat, Inc."*|*"InnoTek"*|*"VirtualBox"*|*"Bochs"*|*"1234:1111"*) echo vm ;;
        *)                                                     echo unknown ;;
    esac
}

if [ -z "$GPU_DRIVER" ]; then
    DETECTED="$(detect_gpu)"
    case "$DETECTED" in
        intel|amd|nvidia)
            GPU_DRIVER="$DETECTED"
            log "auto-detected GPU: $GPU_DRIVER (override with GPU_DRIVER=... or a 3rd argument if this is wrong)"
            ;;
        vm)
            warn "detected a virtual-machine display adapter (QEMU/VirtualBox/VMware/Bochs), not real GPU hardware"
            warn "drm-kmod doesn't target these — Hyprland will likely need software rendering (llvmpipe) in a VM, expect it to be slow or not start"
            GPU_DRIVER=none
            ;;
        *)
            warn "could not confidently auto-detect a GPU vendor from pciconf output"
            echo "GPU driver to load:"
            pciconf -lv 2>/dev/null | grep -B3 "class=0x03" | sed 's/^/    /' || true
            echo "  [1] intel   -> i915kms"
            echo "  [2] amd     -> amdgpu"
            echo "  [3] nvidia  -> proprietary nvidia-driver (NOT drm-kmod)"
            echo "  [4] none    -> skip, I'll configure this myself"
            printf "Select [1-4] (default 4): "
            read gchoice
            case "$gchoice" in
                1) GPU_DRIVER=intel ;;
                2) GPU_DRIVER=amd ;;
                3) GPU_DRIVER=nvidia ;;
                *) GPU_DRIVER=none ;;
            esac
            ;;
    esac
fi
log "GPU driver selection: $GPU_DRIVER"

NPROC=$(sysctl -n hw.ncpu)
PORTSDIR=/usr/ports

log "target user: $TARGET_USER ($TARGET_HOME), building with ${NPROC} jobs, mode=$MODE, gpu=$GPU_DRIVER"

################################################################################
# PART A — desktop stack
################################################################################

### A1. bootstrap pkg — required, aborts the whole script if it fails --------

log "bootstrapping pkg"
if ! command -v pkg >/dev/null 2>&1; then
    env ASSUME_ALWAYS_YES=yes pkg bootstrap -y || fail "could not bootstrap pkg — nothing else in this script can work without it"
fi
pkg update -f || warn "pkg update failed — check network / pkg repo config"

if [ "$MODE" = "full" ] || [ "$MODE" = "medium" ]; then
    pkg install -y git || fail "could not install git — required to fetch the ports tree for mode=$MODE"

    ### A2. ports tree — refuse to touch anything that isn't ours to delete ---
    if [ -e "$PORTSDIR" ] && [ ! -d "$PORTSDIR/.git" ]; then
        fail "$PORTSDIR exists but is not a git checkout — refusing to delete it. Move it aside yourself and re-run if you want a fresh clone."
    fi
    if [ ! -d "$PORTSDIR/.git" ]; then
        log "cloning ports tree (~1-2GB, first run only)"
        git clone --depth 1 https://git.FreeBSD.org/ports.git "$PORTSDIR" || fail "ports tree clone failed"
    else
        log "updating existing ports tree"
        (cd "$PORTSDIR" && git pull --ff-only) || warn "ports tree update failed — continuing with whatever's on disk"
    fi
else
    log "mode=fast — skipping ports tree entirely, pkg only"
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
    if make -C "$dir" install clean BATCH=yes >"$logfile" 2>&1; then
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

# ports where compiling is actually worth it in medium mode: fast-moving
# upstream + build options that matter at runtime. Not used in fast mode
# (everything is pkg there) or full mode (everything is ports there).
MEDIUM_PORT="x11-wm/hyprland x11-wm/hyprlock x11-wm/hypridle x11/waybar x11/foot shells/fish editors/neovim"

is_medium_port() {
    for p in $MEDIUM_PORT; do
        [ "$p" = "$1" ] && return 0
    done
    return 1
}

# unified installer, three-tier:
#   fast   -> always pkg
#   medium -> ports for MEDIUM_PORT list, pkg for everything else
#   full   -> always ports
# (FreeBSD pkg names match the ports leaf name, e.g. x11/foot -> foot)
install_component() {
    port="$1"
    pkgname="${port##*/}"
    case "$MODE" in
        full)
            build_port "$port"
            ;;
        medium)
            if is_medium_port "$port"; then build_port "$port"; else ensure_pkg "$pkgname"; fi
            ;;
        *)
            ensure_pkg "$pkgname"
            ;;
    esac
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
for p in x11-wm/hyprland x11-wm/hyprlock x11-wm/hypridle x11-wm/hyprpaper \
         x11-wm/hyprpicker x11/xwayland \
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

log "GPU driver: $GPU_DRIVER"
case "$GPU_DRIVER" in
    intel)
        sysrc kld_list+="i915kms" >/dev/null
        kldload i915kms 2>/dev/null || warn "kldload i915kms failed"
        ;;
    amd)
        sysrc kld_list+="amdgpu" >/dev/null
        kldload amdgpu 2>/dev/null || warn "kldload amdgpu failed"
        ;;
    nvidia)
        ensure_pkg nvidia-driver
        sysrc kld_list+="nvidia-modeset" >/dev/null
        note "nvidia-driver installed — this is the proprietary driver, NOT drm-kmod. Reboot required before it's active."
        ;;
    none|*)
        warn "no GPU driver selected — configure graphics/drm-kmod (or nvidia-driver) manually before expecting Hyprland to start"
        ;;
esac

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
exec-once = hyprpaper
exec-once = /usr/local/libexec/polkit-gnome-authentication-agent-1
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
bind = $mod, K, exec, $terminal
bind = $mod, E, exec, $fileManager
bind = $mod, SPACE, exec, $menu
bind = $mod, B, exec, firefox
bind = $mod, Q, killactive,
bind = $mod, F, fullscreen, 0
bind = $mod, T, togglefloating,
bind = $mod, U, pseudo,
bind = $mod, G, pin,
bind = $mod, L, exec, hyprlock
bind = $mod, X, exec, wlogout
bind = $mod, W, exec, waypaper
bind = $mod, S, exec, nwg-look
bind = $mod, N, exec, networkmgr
bind = $mod, A, exec, pwvucontrol
bind = $mod, C, exec, hyprpicker -a

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
bind = $mod, P, exec, grim -g "$(slurp)" - | wl-copy

bind = $mod, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy
bind = $mod SHIFT, R, exec, pgrep wf-recorder >/dev/null && pkill -INT wf-recorder || wf-recorder -f ~/Videos/recording-$(date +%Y%m%d-%H%M%S).mp4

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

log "writing waybar style (square, borderless, wallust-themed)"
cat > "$CONF/waybar/style.css" <<'EOF'
@import "colors.css";

* {
    border: none;
    border-radius: 0;
    font-family: monospace;
    font-size: 13px;
}
window#waybar {
    background: @background;
    color: @foreground;
}
#workspaces button {
    padding: 0 8px;
    background: transparent;
    color: @color8;
}
#workspaces button.active {
    background: @color0;
    color: @foreground;
}
#clock, #pulseaudio, #network, #battery, #tray {
    padding: 0 10px;
}
EOF

# fallback colors.css so waybar has something to import before wallust
# ever runs the first time (SUPER+W / waypaper regenerates this)
cat > "$CONF/waybar/colors.css" <<'EOF'
@define-color background #101010;
@define-color foreground #e0e0e0;
@define-color color0 #202020;
@define-color color8 #808080;
EOF

log "writing foot config (wallust-themed)"
cat > "$CONF/foot/foot.ini" <<'EOF'
[main]
font=monospace:size=11
pad=0x0
include=~/.config/foot/colors.ini
EOF

# fallback colors.ini until wallust generates a real one
cat > "$CONF/foot/colors.ini" <<'EOF'
[colors]
background=101010
foreground=e0e0e0
alpha=1.0
EOF

chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config"

log "writing wallust config + templates"
mkdir -p "$CONF/wallust/templates" "$CONF/waypaper" "$CONF/hypr/scripts"

cat > "$CONF/wallust/wallust.toml" <<'EOF'
[templates]
waybar = { template = "waybar-colors.css", target = "~/.config/waybar/colors.css" }
foot   = { template = "foot-colors.ini",   target = "~/.config/foot/colors.ini" }
EOF

cat > "$CONF/wallust/templates/waybar-colors.css" <<'EOF'
@define-color background {{background}};
@define-color foreground {{foreground}};
@define-color color0 {{color0}};
@define-color color1 {{color1}};
@define-color color2 {{color2}};
@define-color color3 {{color3}};
@define-color color4 {{color4}};
@define-color color5 {{color5}};
@define-color color6 {{color6}};
@define-color color7 {{color7}};
@define-color color8 {{color8}};
EOF

cat > "$CONF/wallust/templates/foot-colors.ini" <<'EOF'
[colors]
background={{background.strip}}
foreground={{foreground.strip}}
regular0={{color0.strip}}
regular1={{color1.strip}}
regular2={{color2.strip}}
regular3={{color3.strip}}
regular4={{color4.strip}}
regular5={{color5.strip}}
regular6={{color6.strip}}
regular7={{color7.strip}}
alpha=1.0
EOF

cat > "$CONF/hypr/scripts/apply-theme.sh" <<'EOF'
#!/bin/sh
# Regenerates waybar/foot colors from the current wallpaper via wallust.
# Called automatically by waypaper's post_command after picking a wallpaper,
# or run it yourself any time: ~/.config/hypr/scripts/apply-theme.sh <image>
WALL="${1:-$(hyprctl hyprpaper listloaded 2>/dev/null | tail -1)}"
[ -z "$WALL" ] && exit 0
command -v wallust >/dev/null 2>&1 || exit 0
wallust run "$WALL" >/tmp/wallust.log 2>&1
pkill -SIGUSR2 waybar 2>/dev/null || true
EOF
chmod +x "$CONF/hypr/scripts/apply-theme.sh"

cat > "$CONF/waypaper/config.ini" <<EOF
[Settings]
folder = $TARGET_HOME/Pictures/Wallpapers
backend = hyprpaper
post_command = $TARGET_HOME/.config/hypr/scripts/apply-theme.sh
EOF

mkdir -p "$TARGET_HOME/Pictures/Wallpapers" "$TARGET_HOME/Videos"
chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config" "$TARGET_HOME/Pictures"

################################################################################
# PART B — pf hardening + application stack (always via pkg)
################################################################################

log "== desktop polish (fonts, portals, wallpaper, archive/pdf) =="
for p in nerd-fonts noto qt6-qtimageformats; do
    ensure_pkg "$p"
done
ensure_pkg polkit-gnome || note "polkit-gnome unavailable — try lxqt-policykit instead, some actions (printer setup, blueman prompts) will silently fail without a running polkit agent."
for p in xdg-desktop-portal xdg-desktop-portal-wlr xdg-user-dirs; do
    ensure_pkg "$p"
done
ensure_pkg waypaper || note "waypaper (SUPER+W) unavailable — hyprpaper itself still runs, set a wallpaper manually with: hyprctl hyprpaper wallpaper \",/path/to/image\""
ensure_pkg wallust || note "wallust unavailable — wallpaper-based theming (colors.css/colors.ini) won't auto-generate, edit waybar/foot colors by hand instead."
ensure_pkg networkmgr || note "networkmgr (SUPER+N) unavailable — fall back to CLI: 'service netif restart', wpa_supplicant.conf, or ifconfig by hand."
for p in unzip p7zip xarchiver thunar-archive-plugin; do
    ensure_pkg "$p"
done
for p in zathura zathura-pdf-poppler imv; do
    ensure_pkg "$p"
done
note "PipeWire ships its own PulseAudio-compatible server — after reboot, run 'pactl info' to confirm apps expecting PulseAudio (Chromium, Firefox) actually see it; if not, check that pipewire-pulse is running alongside pipewire/wireplumber."

log "== pf firewall =="

# pfctl/route depend on the netlink(4) kernel module since ~2023; it's
# usually autoloaded, but not reliably in minimal/VM kernels — load it
# explicitly and persist it, or pfctl fails with "Failed to open netlink"
sysrc kld_list+="netlink" >/dev/null
if ! kldload netlink 2>"$LOGDIR/kldload_netlink.log"; then
    if grep -qi "already loaded\|file exists" "$LOGDIR/kldload_netlink.log"; then
        log "netlink already loaded, fine"
    else
        warn "kldload netlink failed — check kernel/userland version match (see above), then check /boot/kernel/netlink.ko exists"
    fi
fi

EXT_IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [ -z "$EXT_IF" ]; then
    fail "could not determine the default-route interface — refusing to guess for a firewall config. Candidates: $(ifconfig -l 2>/dev/null). Set it manually and re-run."
fi
log "using external interface: $EXT_IF"

PF_CONF=/etc/pf.conf

write_pf_conf() {
    if [ -f "$PF_CONF" ]; then
        cp "$PF_CONF" "${PF_CONF}.bak.$(date +%s)"
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
}

# returns 0 on a confirmed-working pf, 1 otherwise — never calls fail()
# itself, so the caller can decide what to do next
pf_attempt() {
    write_pf_conf
    if ! pfctl -nf "$PF_CONF" >"$LOGDIR/pfctl_check.log" 2>&1; then
        warn "pf.conf failed syntax check — see $LOGDIR/pfctl_check.log"
        return 1
    fi
    log "pf.conf syntax OK"
    sysrc pf_enable=YES        >/dev/null
    sysrc pf_rules="$PF_CONF"  >/dev/null
    sysrc pflog_enable=YES     >/dev/null
    sysrc pflog_logfile="/var/log/pflog" >/dev/null
    if ! { service pf reload 2>>"$LOGDIR/pfctl_check.log" || service pf start 2>>"$LOGDIR/pfctl_check.log"; }; then
        warn "pf service failed to start — see $LOGDIR/pfctl_check.log"
        return 1
    fi
    service pflog start 2>/dev/null || true
    if ! pfctl -sr >/dev/null 2>>"$LOGDIR/pfctl_check.log"; then
        warn "pf started but no active ruleset detected — see $LOGDIR/pfctl_check.log"
        return 1
    fi
    log "pf confirmed active with a loaded ruleset"
    return 0
}

# ipfw fallback: equivalent default-deny policy, doesn't touch netlink at
# all, and points sshguard at its ipfw backend instead of pf's tables
setup_ipfw_fallback() {
    log "configuring ipfw as fallback firewall"
    cat > /etc/ipfw.rules <<EOF
#!/bin/sh
ipfw -q flush
oif="$EXT_IF"
ipfw -q add 100 check-state
ipfw -q add 200 allow all from any to any via lo0
ipfw -q add 210 deny all from any to 127.0.0.0/8
ipfw -q add 220 deny log all from any to any frag
ipfw -q add 300 allow tcp from any to any established
ipfw -q add 400 allow all from any to any out via \$oif keep-state
ipfw -q add 500 allow icmp from any to any icmptypes 0,8,11
ipfw -q add 600 allow tcp from any to any 22 in via \$oif setup limit src-addr 15
ipfw -q add 65000 deny log all from any to any
EOF
    chmod 755 /etc/ipfw.rules
    sysrc firewall_enable=YES        >/dev/null
    sysrc firewall_script=/etc/ipfw.rules >/dev/null
    sysrc firewall_logging=YES       >/dev/null
    if ! service ipfw start >"$LOGDIR/ipfw_start.log" 2>&1; then
        warn "ipfw failed to start too — see $LOGDIR/ipfw_start.log"
        return 1
    fi
    # sshguard ships pf/ipfw backends — point it at ipfw instead of pf's tables
    SSHG_CONF=/usr/local/etc/sshguard.conf
    if [ -f "$SSHG_CONF" ]; then
        cp "$SSHG_CONF" "${SSHG_CONF}.bak.$(date +%s)"
        if grep -q '^BACKEND=' "$SSHG_CONF"; then
            sed -i '' 's#^BACKEND=.*#BACKEND="/usr/local/libexec/sshguard/ipfw.sh"#' "$SSHG_CONF"
        else
            echo 'BACKEND="/usr/local/libexec/sshguard/ipfw.sh"' >> "$SSHG_CONF"
        fi
    fi
    service sshguard restart 2>/dev/null || service sshguard start 2>/dev/null || true
    note "Firewall is ipfw, not pf — pf.conf was written but never activated. sshguard is pointed at the ipfw backend."
    return 0
}

PF_OK=0
if pf_attempt; then
    PF_OK=1
fi

if [ "$PF_OK" -ne 1 ]; then
    FW_FALLBACK="${FW_FALLBACK:-}"
    if [ -z "$FW_FALLBACK" ]; then
        echo ""
        echo "pf did not come up. Diagnostics are in $LOGDIR/pfctl_check.log. Choose how to proceed:"
        echo "  [1] retry pf now (in case it was transient)"
        echo "  [2] fall back to ipfw with an equivalent default-deny ruleset"
        echo "  [3] continue WITHOUT any firewall (test/VM only, NOT recommended)"
        echo "  [4] abort here and fix pf manually"
        printf "Select [1-4] (default 4): "
        read fwchoice
        case "$fwchoice" in
            1) FW_FALLBACK=retry ;;
            2) FW_FALLBACK=ipfw ;;
            3) FW_FALLBACK=none ;;
            *) FW_FALLBACK=abort ;;
        esac
    fi

    if [ "$FW_FALLBACK" = "retry" ]; then
        if pf_attempt; then
            PF_OK=1
        else
            warn "retry failed too"
            FW_FALLBACK=abort
        fi
    fi

    if [ "$PF_OK" -ne 1 ]; then
        case "$FW_FALLBACK" in
            ipfw)
                if setup_ipfw_fallback; then
                    log "ipfw fallback active"
                else
                    fail "ipfw fallback also failed — see $LOGDIR/ipfw_start.log — refusing to continue with no firewall at all"
                fi
                ;;
            none)
                printf "Type exactly: yes I understand   to continue with NO firewall: "
                read confirm
                if [ "$confirm" = "yes I understand" ]; then
                    warn "continuing WITHOUT any firewall — this host is unprotected at the network layer"
                    note "No firewall active (pf failed, ipfw not chosen) — fix this before exposing the machine to any network. Diagnostics: $LOGDIR/pfctl_check.log"
                else
                    fail "confirmation not given — aborting rather than silently running unprotected"
                fi
                ;;
            *)
                fail "pf not working and no fallback chosen — see $LOGDIR/pfctl_check.log, or re-run with FW_FALLBACK=ipfw / FW_FALLBACK=none to skip this prompt"
                ;;
        esac
    fi
fi

if [ "$PF_OK" -eq 1 ]; then
    service sshguard restart 2>/dev/null || service sshguard start 2>/dev/null || warn "sshguard didn't (re)start — pf's baseline rules still apply, but check this"
fi

log "== linux compat layer (optional) =="
WITH_LINUX_COMPAT="${WITH_LINUX_COMPAT:-}"
if [ -z "$WITH_LINUX_COMPAT" ]; then
    printf "Install Linux compatibility layer? Needed for Steam/some binary-only apps [y/N]: "
    read ans
    case "$ans" in y|Y|yes) WITH_LINUX_COMPAT=yes ;; *) WITH_LINUX_COMPAT=no ;; esac
fi
if [ "$WITH_LINUX_COMPAT" = "yes" ]; then
    sysrc linux_enable=YES >/dev/null
    kldload linux64 2>/dev/null || true
    ensure_pkg linux-rl9 || ensure_pkg linux_base-c7
    note "Linux compat installed for apps that ship only Linux binaries."
else
    log "skipping Linux compat layer (WITH_LINUX_COMPAT=no)"
fi

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
for p in qemu tree atuin git openjdk21; do
    ensure_pkg "$p"
done
ensure_pkg vscodium || note "VSCodium isn't reliably packaged for FreeBSD. neovim (Part A) or editors/lapce (native, lightweight) are the realistic editor options."
note "Ghidra and Burp Suite have no FreeBSD packages, but both are plain Java apps — openjdk21 is installed above, just run: java -jar burpsuite.jar / ./ghidraRun after downloading the release."

WITH_WINE="${WITH_WINE:-}"
if [ -z "$WITH_WINE" ]; then
    printf "Install Wine (run some Windows apps natively, no Linux compat needed)? [y/N]: "
    read ans
    case "$ans" in y|Y|yes) WITH_WINE=yes ;; *) WITH_WINE=no ;; esac
fi
if [ "$WITH_WINE" = "yes" ]; then
    ensure_pkg wine-devel
else
    log "skipping Wine (WITH_WINE=no)"
fi

log "== streaming / recording =="
ensure_pkg obs-studio || note "obs-studio failed/unavailable — check 'pkg search obs' for the current package name on this release."
ensure_pkg wf-recorder || note "wf-recorder unavailable — OBS with the PipeWire screen-capture source (via xdg-desktop-portal-wlr) is the fallback for screen recording."

log "== stream deck (AJAZZ, via OpenDeck) — experimental =="
# OpenDeck has NO official FreeBSD support and there is no port. This is a
# best-effort source build using the Rust toolchain already installed —
# expect friction (Tauri needs webkit2gtk, the elgato-streamdeck/mirajazz
# crates use hidapi which needs a working devfs permission for the USB HID
# node). Treat this as an experiment, not a guaranteed feature.
WITH_STREAMDECK="${WITH_STREAMDECK:-}"
if [ -z "$WITH_STREAMDECK" ]; then
    printf "Try building OpenDeck for the AJAZZ stream deck from source? Experimental, no FreeBSD support upstream [y/N]: "
    read ans
    case "$ans" in y|Y|yes) WITH_STREAMDECK=yes ;; *) WITH_STREAMDECK=no ;; esac
fi
if [ "$WITH_STREAMDECK" = "yes" ]; then
    ensure_pkg webkit2-gtk4-2.0 || note "webkit2-gtk4-2.0 (Tauri's runtime dependency) failed — OpenDeck build will very likely fail without it."
    ensure_pkg node
    if command -v cargo >/dev/null 2>&1; then
        OD_SRC=/usr/local/src/opendeck-ajazz
        if [ ! -d "$OD_SRC" ]; then
            git clone https://github.com/mistweaverco/opendeck-ajazz "$OD_SRC" >"$LOGDIR/opendeck_clone.log" 2>&1 || warn "OpenDeck clone failed — see $LOGDIR/opendeck_clone.log"
        fi
        if [ -d "$OD_SRC" ]; then
            log "attempting OpenDeck build (this is genuinely experimental on FreeBSD, may just fail)"
            ( cd "$OD_SRC" && cargo build --release ) >"$LOGDIR/opendeck_build.log" 2>&1 \
                && log "OpenDeck build succeeded — binary under $OD_SRC/src-tauri/target/release/" \
                || warn "OpenDeck build failed — see $LOGDIR/opendeck_build.log. Not a script bug: there is no upstream FreeBSD support for this app."
        fi
    else
        warn "cargo not found — skipping OpenDeck build"
    fi
    # USB HID access for the target user without root: FreeBSD gates /dev/uhid*
    # via devfs, not udev — this is the equivalent grant.
    DEVFS_RULES=/etc/devfs.rules
    if ! grep -q "streamdeck_ruleset" "$DEVFS_RULES" 2>/dev/null; then
        cat >> "$DEVFS_RULES" <<'EOF'

[streamdeck_ruleset=15]
add path 'uhid*' mode 0660 group operator
add path 'usb/*' mode 0660 group operator
EOF
        sysrc devfs_system_ruleset=streamdeck_ruleset >/dev/null
        pw groupmod operator -m "$TARGET_USER" 2>/dev/null || true
        note "Added a devfs ruleset granting the operator group access to uhid/usb device nodes so OpenDeck doesn't need root. Reboot for devfs_system_ruleset to take effect."
    fi
else
    log "skipping stream deck support (WITH_STREAMDECK=no)"
fi

log "== gaming (optional) =="
ensure_pkg prismlauncher || note "Prism Launcher may not be in the repo for this release — check 'pkg search prismlauncher' manually."

WITH_STEAM="${WITH_STEAM:-}"
if [ -z "$WITH_STEAM" ]; then
    printf "Try Steam via linux-steam-utils? Hardware/game-dependent, needs Linux compat [y/N]: "
    read ans
    case "$ans" in y|Y|yes) WITH_STEAM=yes ;; *) WITH_STEAM=no ;; esac
fi
if [ "$WITH_STEAM" = "yes" ]; then
    if [ "$WITH_LINUX_COMPAT" != "yes" ]; then
        warn "Steam requested but Linux compat layer wasn't installed earlier — linux-steam-utils will likely be useless without it"
    fi
    ensure_pkg linux-steam-utils || note "linux-steam-utils failed/unavailable — Steam is hardware- and game-dependent either way, treat it as an experiment, not something to rely on."
else
    log "skipping Steam (WITH_STEAM=no)"
fi

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
log "  3. tune $CONF/hypr/hyprland.conf to taste"#!/bin/sh
#
# FreeBSD Hyprland desktop installer — full run
# Run as: sudo sh install.sh [fast|medium|full] [username] [gpu]
#   gpu is one of: intel amd nvidia none  (see GPU section below)
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
# THREE MODES, chosen interactively or as $1:
#   fast    everything via pkg (binary packages), including Hyprland
#           itself. Fastest possible, no compiling at all. ~10-15 min.
#   medium  pkg for everything EXCEPT the pieces where compiling from
#           ports genuinely matters at runtime — Hyprland, Hyprlock,
#           Hypridle, Waybar, foot, fish, neovim (fast-moving upstream,
#           build options you'd actually want). Realistically ~1-2h.
#   full    compile the ENTIRE desktop stack from ports. Realistically
#           an overnight build even on fast hardware.
#
# Part B (the big application list: Blender, LibreOffice, Chromium, ...)
# always uses pkg regardless of mode — compiling that from ports is not
# a reasonable trade-off in any of the three.
#
# Rule enforced throughout:
#   security component fails (pf)      -> ABORT, fix it before continuing
#   required bootstrap dep fails       -> ABORT (pkg itself, git)
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
    echo "Run this as root: sudo sh install.sh [fast|medium|full] [username] [gpu]" >&2
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

FREEBSD_VERSION="$(freebsd-version -u 2>/dev/null || echo unknown)"
FREEBSD_KERNEL="$(freebsd-version -k 2>/dev/null || echo unknown)"
log "FreeBSD userland: $FREEBSD_VERSION, kernel: $FREEBSD_KERNEL"
if [ "$FREEBSD_VERSION" != "$FREEBSD_KERNEL" ]; then
    warn "kernel/userland version MISMATCH: kernel=$FREEBSD_KERNEL userland=$FREEBSD_VERSION"
    warn "this alone can break netlink-dependent tools like pfctl (ABI drift between versions) — fix with 'freebsd-update install' + reboot before continuing if pf gives you netlink errors"
fi
case "$FREEBSD_VERSION" in
    15.*) : ;;
    *) warn "this script was written against FreeBSD 15.x, userland is $FREEBSD_VERSION — proceeding, but watch for port/ABI mismatches" ;;
esac

### 0. mode + primary user + GPU ------------------------------------------

MODE=""
case "${1:-}" in
    fast|medium|full) MODE="$1"; shift ;;
esac

if [ -z "$MODE" ]; then
    echo "Choose install mode:"
    echo "  [1] fast   — everything via pkg, including Hyprland itself (~10-15 min)"
    echo "  [2] medium — pkg for most things, ports for Hyprland/Hyprlock/Hypridle/Waybar/foot/fish/neovim (~1-2h)"
    echo "  [3] full   — compile the entire desktop stack from ports (realistically overnight)"
    printf "Select [1/2/3] (default 1): "
    read choice
    case "$choice" in
        2) MODE=medium ;;
        3) MODE=full ;;
        *) MODE=fast ;;
    esac
fi
log "install mode: $MODE"

TARGET_USER="${1:-${SUDO_USER:-}}"
[ -n "${1:-}" ] && shift
if [ -z "$TARGET_USER" ]; then
    printf "Primary (desktop) username on this system: "
    read TARGET_USER
fi
if ! pw usershow "$TARGET_USER" >/dev/null 2>&1; then
    fail "user '$TARGET_USER' does not exist — create it first (stage 1's job)"
fi
TARGET_HOME=$(pw usershow "$TARGET_USER" | cut -d: -f9)

GPU_DRIVER="${GPU_DRIVER:-${1:-}}"
[ -n "${1:-}" ] && shift

detect_gpu() {
    # class=0x03 is the PCI display-controller class; grab that line plus
    # the vendor/device lines pciconf prints right after it.
    info=$(pciconf -lv 2>/dev/null | awk '
        /class=0x03/ { grab=5 }
        grab>0 { print; grab-- }
    ')
    case "$info" in
        *"Intel"*)                                            echo intel ;;
        *"NVIDIA"*)                                            echo nvidia ;;
        *"Advanced Micro Devices"*|*"ATI"*)                    echo amd ;;
        *"VMware"*|*"QEMU"*|*"Red Hat, Inc."*|*"InnoTek"*|*"VirtualBox"*|*"Bochs"*|*"1234:1111"*) echo vm ;;
        *)                                                     echo unknown ;;
    esac
}

if [ -z "$GPU_DRIVER" ]; then
    DETECTED="$(detect_gpu)"
    case "$DETECTED" in
        intel|amd|nvidia)
            GPU_DRIVER="$DETECTED"
            log "auto-detected GPU: $GPU_DRIVER (override with GPU_DRIVER=... or a 3rd argument if this is wrong)"
            ;;
        vm)
            warn "detected a virtual-machine display adapter (QEMU/VirtualBox/VMware/Bochs), not real GPU hardware"
            warn "drm-kmod doesn't target these — Hyprland will likely need software rendering (llvmpipe) in a VM, expect it to be slow or not start"
            GPU_DRIVER=none
            ;;
        *)
            warn "could not confidently auto-detect a GPU vendor from pciconf output"
            echo "GPU driver to load:"
            pciconf -lv 2>/dev/null | grep -B3 "class=0x03" | sed 's/^/    /' || true
            echo "  [1] intel   -> i915kms"
            echo "  [2] amd     -> amdgpu"
            echo "  [3] nvidia  -> proprietary nvidia-driver (NOT drm-kmod)"
            echo "  [4] none    -> skip, I'll configure this myself"
            printf "Select [1-4] (default 4): "
            read gchoice
            case "$gchoice" in
                1) GPU_DRIVER=intel ;;
                2) GPU_DRIVER=amd ;;
                3) GPU_DRIVER=nvidia ;;
                *) GPU_DRIVER=none ;;
            esac
            ;;
    esac
fi
log "GPU driver selection: $GPU_DRIVER"

NPROC=$(sysctl -n hw.ncpu)
PORTSDIR=/usr/ports

log "target user: $TARGET_USER ($TARGET_HOME), building with ${NPROC} jobs, mode=$MODE, gpu=$GPU_DRIVER"

################################################################################
# PART A — desktop stack
################################################################################

### A1. bootstrap pkg — required, aborts the whole script if it fails --------

log "bootstrapping pkg"
if ! command -v pkg >/dev/null 2>&1; then
    env ASSUME_ALWAYS_YES=yes pkg bootstrap -y || fail "could not bootstrap pkg — nothing else in this script can work without it"
fi
pkg update -f || warn "pkg update failed — check network / pkg repo config"

if [ "$MODE" = "full" ] || [ "$MODE" = "medium" ]; then
    pkg install -y git || fail "could not install git — required to fetch the ports tree for mode=$MODE"

    ### A2. ports tree — refuse to touch anything that isn't ours to delete ---
    if [ -e "$PORTSDIR" ] && [ ! -d "$PORTSDIR/.git" ]; then
        fail "$PORTSDIR exists but is not a git checkout — refusing to delete it. Move it aside yourself and re-run if you want a fresh clone."
    fi
    if [ ! -d "$PORTSDIR/.git" ]; then
        log "cloning ports tree (~1-2GB, first run only)"
        git clone --depth 1 https://git.FreeBSD.org/ports.git "$PORTSDIR" || fail "ports tree clone failed"
    else
        log "updating existing ports tree"
        (cd "$PORTSDIR" && git pull --ff-only) || warn "ports tree update failed — continuing with whatever's on disk"
    fi
else
    log "mode=fast — skipping ports tree entirely, pkg only"
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
    if make -C "$dir" install clean BATCH=yes >"$logfile" 2>&1; then
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

# ports where compiling is actually worth it in medium mode: fast-moving
# upstream + build options that matter at runtime. Not used in fast mode
# (everything is pkg there) or full mode (everything is ports there).
MEDIUM_PORT="x11-wm/hyprland x11-wm/hyprlock x11-wm/hypridle x11/waybar x11/foot shells/fish editors/neovim"

is_medium_port() {
    for p in $MEDIUM_PORT; do
        [ "$p" = "$1" ] && return 0
    done
    return 1
}

# unified installer, three-tier:
#   fast   -> always pkg
#   medium -> ports for MEDIUM_PORT list, pkg for everything else
#   full   -> always ports
# (FreeBSD pkg names match the ports leaf name, e.g. x11/foot -> foot)
install_component() {
    port="$1"
    pkgname="${port##*/}"
    case "$MODE" in
        full)
            build_port "$port"
            ;;
        medium)
            if is_medium_port "$port"; then build_port "$port"; else ensure_pkg "$pkgname"; fi
            ;;
        *)
            ensure_pkg "$pkgname"
            ;;
    esac
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
for p in x11-wm/hyprland x11-wm/hyprlock x11-wm/hypridle x11-wm/hyprpaper \
         x11-wm/hyprpicker x11/xwayland \
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

log "GPU driver: $GPU_DRIVER"
case "$GPU_DRIVER" in
    intel)
        sysrc kld_list+="i915kms" >/dev/null
        kldload i915kms 2>/dev/null || warn "kldload i915kms failed"
        ;;
    amd)
        sysrc kld_list+="amdgpu" >/dev/null
        kldload amdgpu 2>/dev/null || warn "kldload amdgpu failed"
        ;;
    nvidia)
        ensure_pkg nvidia-driver
        sysrc kld_list+="nvidia-modeset" >/dev/null
        note "nvidia-driver installed — this is the proprietary driver, NOT drm-kmod. Reboot required before it's active."
        ;;
    none|*)
        warn "no GPU driver selected — configure graphics/drm-kmod (or nvidia-driver) manually before expecting Hyprland to start"
        ;;
esac

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
exec-once = hyprpaper
exec-once = /usr/local/libexec/polkit-gnome-authentication-agent-1
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
bind = $mod, K, exec, $terminal
bind = $mod, E, exec, $fileManager
bind = $mod, SPACE, exec, $menu
bind = $mod, B, exec, firefox
bind = $mod, Q, killactive,
bind = $mod, F, fullscreen, 0
bind = $mod, T, togglefloating,
bind = $mod, U, pseudo,
bind = $mod, G, pin,
bind = $mod, L, exec, hyprlock
bind = $mod, X, exec, wlogout
bind = $mod, W, exec, waypaper
bind = $mod, S, exec, nwg-look
bind = $mod, N, exec, networkmgr
bind = $mod, A, exec, pwvucontrol
bind = $mod, C, exec, hyprpicker -a

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
bind = $mod, P, exec, grim -g "$(slurp)" - | wl-copy

bind = $mod, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy

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

log "writing waybar style (square, borderless, wallust-themed)"
cat > "$CONF/waybar/style.css" <<'EOF'
@import "colors.css";

* {
    border: none;
    border-radius: 0;
    font-family: monospace;
    font-size: 13px;
}
window#waybar {
    background: @background;
    color: @foreground;
}
#workspaces button {
    padding: 0 8px;
    background: transparent;
    color: @color8;
}
#workspaces button.active {
    background: @color0;
    color: @foreground;
}
#clock, #pulseaudio, #network, #battery, #tray {
    padding: 0 10px;
}
EOF

# fallback colors.css so waybar has something to import before wallust
# ever runs the first time (SUPER+W / waypaper regenerates this)
cat > "$CONF/waybar/colors.css" <<'EOF'
@define-color background #101010;
@define-color foreground #e0e0e0;
@define-color color0 #202020;
@define-color color8 #808080;
EOF

log "writing foot config (wallust-themed)"
cat > "$CONF/foot/foot.ini" <<'EOF'
[main]
font=monospace:size=11
pad=0x0
include=~/.config/foot/colors.ini
EOF

# fallback colors.ini until wallust generates a real one
cat > "$CONF/foot/colors.ini" <<'EOF'
[colors]
background=101010
foreground=e0e0e0
alpha=1.0
EOF

chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config"

log "writing wallust config + templates"
mkdir -p "$CONF/wallust/templates" "$CONF/waypaper" "$CONF/hypr/scripts"

cat > "$CONF/wallust/wallust.toml" <<'EOF'
[templates]
waybar = { template = "waybar-colors.css", target = "~/.config/waybar/colors.css" }
foot   = { template = "foot-colors.ini",   target = "~/.config/foot/colors.ini" }
EOF

cat > "$CONF/wallust/templates/waybar-colors.css" <<'EOF'
@define-color background {{background}};
@define-color foreground {{foreground}};
@define-color color0 {{color0}};
@define-color color1 {{color1}};
@define-color color2 {{color2}};
@define-color color3 {{color3}};
@define-color color4 {{color4}};
@define-color color5 {{color5}};
@define-color color6 {{color6}};
@define-color color7 {{color7}};
@define-color color8 {{color8}};
EOF

cat > "$CONF/wallust/templates/foot-colors.ini" <<'EOF'
[colors]
background={{background.strip}}
foreground={{foreground.strip}}
regular0={{color0.strip}}
regular1={{color1.strip}}
regular2={{color2.strip}}
regular3={{color3.strip}}
regular4={{color4.strip}}
regular5={{color5.strip}}
regular6={{color6.strip}}
regular7={{color7.strip}}
alpha=1.0
EOF

cat > "$CONF/hypr/scripts/apply-theme.sh" <<'EOF'
#!/bin/sh
# Regenerates waybar/foot colors from the current wallpaper via wallust.
# Called automatically by waypaper's post_command after picking a wallpaper,
# or run it yourself any time: ~/.config/hypr/scripts/apply-theme.sh <image>
WALL="${1:-$(hyprctl hyprpaper listloaded 2>/dev/null | tail -1)}"
[ -z "$WALL" ] && exit 0
command -v wallust >/dev/null 2>&1 || exit 0
wallust run "$WALL" >/tmp/wallust.log 2>&1
pkill -SIGUSR2 waybar 2>/dev/null || true
EOF
chmod +x "$CONF/hypr/scripts/apply-theme.sh"

cat > "$CONF/waypaper/config.ini" <<EOF
[Settings]
folder = $TARGET_HOME/Pictures/Wallpapers
backend = hyprpaper
post_command = $TARGET_HOME/.config/hypr/scripts/apply-theme.sh
EOF

mkdir -p "$TARGET_HOME/Pictures/Wallpapers"
chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/.config" "$TARGET_HOME/Pictures"

################################################################################
# PART B — pf hardening + application stack (always via pkg)
################################################################################

log "== desktop polish (fonts, portals, wallpaper, archive/pdf) =="
for p in nerd-fonts noto qt6-qtimageformats; do
    ensure_pkg "$p"
done
ensure_pkg polkit-gnome || note "polkit-gnome unavailable — try lxqt-policykit instead, some actions (printer setup, blueman prompts) will silently fail without a running polkit agent."
for p in xdg-desktop-portal xdg-desktop-portal-wlr xdg-user-dirs; do
    ensure_pkg "$p"
done
ensure_pkg waypaper || note "waypaper (SUPER+W) unavailable — hyprpaper itself still runs, set a wallpaper manually with: hyprctl hyprpaper wallpaper \",/path/to/image\""
ensure_pkg wallust || note "wallust unavailable — wallpaper-based theming (colors.css/colors.ini) won't auto-generate, edit waybar/foot colors by hand instead."
ensure_pkg networkmgr || note "networkmgr (SUPER+N) unavailable — fall back to CLI: 'service netif restart', wpa_supplicant.conf, or ifconfig by hand."
for p in unzip p7zip xarchiver thunar-archive-plugin; do
    ensure_pkg "$p"
done
for p in zathura zathura-pdf-poppler imv; do
    ensure_pkg "$p"
done
note "PipeWire ships its own PulseAudio-compatible server — after reboot, run 'pactl info' to confirm apps expecting PulseAudio (Chromium, Firefox) actually see it; if not, check that pipewire-pulse is running alongside pipewire/wireplumber."

log "== pf firewall =="

# pfctl/route depend on the netlink(4) kernel module since ~2023; it's
# usually autoloaded, but not reliably in minimal/VM kernels — load it
# explicitly and persist it, or pfctl fails with "Failed to open netlink"
sysrc kld_list+="netlink" >/dev/null
if ! kldload netlink 2>"$LOGDIR/kldload_netlink.log"; then
    if grep -qi "already loaded\|file exists" "$LOGDIR/kldload_netlink.log"; then
        log "netlink already loaded, fine"
    else
        warn "kldload netlink failed — check kernel/userland version match (see above), then check /boot/kernel/netlink.ko exists"
    fi
fi

EXT_IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [ -z "$EXT_IF" ]; then
    fail "could not determine the default-route interface — refusing to guess for a firewall config. Candidates: $(ifconfig -l 2>/dev/null). Set it manually and re-run."
fi
log "using external interface: $EXT_IF"

PF_CONF=/etc/pf.conf

write_pf_conf() {
    if [ -f "$PF_CONF" ]; then
        cp "$PF_CONF" "${PF_CONF}.bak.$(date +%s)"
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
}

# returns 0 on a confirmed-working pf, 1 otherwise — never calls fail()
# itself, so the caller can decide what to do next
pf_attempt() {
    write_pf_conf
    if ! pfctl -nf "$PF_CONF" >"$LOGDIR/pfctl_check.log" 2>&1; then
        warn "pf.conf failed syntax check — see $LOGDIR/pfctl_check.log"
        return 1
    fi
    log "pf.conf syntax OK"
    sysrc pf_enable=YES        >/dev/null
    sysrc pf_rules="$PF_CONF"  >/dev/null
    sysrc pflog_enable=YES     >/dev/null
    sysrc pflog_logfile="/var/log/pflog" >/dev/null
    if ! { service pf reload 2>>"$LOGDIR/pfctl_check.log" || service pf start 2>>"$LOGDIR/pfctl_check.log"; }; then
        warn "pf service failed to start — see $LOGDIR/pfctl_check.log"
        return 1
    fi
    service pflog start 2>/dev/null || true
    if ! pfctl -sr >/dev/null 2>>"$LOGDIR/pfctl_check.log"; then
        warn "pf started but no active ruleset detected — see $LOGDIR/pfctl_check.log"
        return 1
    fi
    log "pf confirmed active with a loaded ruleset"
    return 0
}

# ipfw fallback: equivalent default-deny policy, doesn't touch netlink at
# all, and points sshguard at its ipfw backend instead of pf's tables
setup_ipfw_fallback() {
    log "configuring ipfw as fallback firewall"
    cat > /etc/ipfw.rules <<EOF
#!/bin/sh
ipfw -q flush
oif="$EXT_IF"
ipfw -q add 100 check-state
ipfw -q add 200 allow all from any to any via lo0
ipfw -q add 210 deny all from any to 127.0.0.0/8
ipfw -q add 220 deny log all from any to any frag
ipfw -q add 300 allow tcp from any to any established
ipfw -q add 400 allow all from any to any out via \$oif keep-state
ipfw -q add 500 allow icmp from any to any icmptypes 0,8,11
ipfw -q add 600 allow tcp from any to any 22 in via \$oif setup limit src-addr 15
ipfw -q add 65000 deny log all from any to any
EOF
    chmod 755 /etc/ipfw.rules
    sysrc firewall_enable=YES        >/dev/null
    sysrc firewall_script=/etc/ipfw.rules >/dev/null
    sysrc firewall_logging=YES       >/dev/null
    if ! service ipfw start >"$LOGDIR/ipfw_start.log" 2>&1; then
        warn "ipfw failed to start too — see $LOGDIR/ipfw_start.log"
        return 1
    fi
    # sshguard ships pf/ipfw backends — point it at ipfw instead of pf's tables
    SSHG_CONF=/usr/local/etc/sshguard.conf
    if [ -f "$SSHG_CONF" ]; then
        cp "$SSHG_CONF" "${SSHG_CONF}.bak.$(date +%s)"
        if grep -q '^BACKEND=' "$SSHG_CONF"; then
            sed -i '' 's#^BACKEND=.*#BACKEND="/usr/local/libexec/sshguard/ipfw.sh"#' "$SSHG_CONF"
        else
            echo 'BACKEND="/usr/local/libexec/sshguard/ipfw.sh"' >> "$SSHG_CONF"
        fi
    fi
    service sshguard restart 2>/dev/null || service sshguard start 2>/dev/null || true
    note "Firewall is ipfw, not pf — pf.conf was written but never activated. sshguard is pointed at the ipfw backend."
    return 0
}

PF_OK=0
if pf_attempt; then
    PF_OK=1
fi

if [ "$PF_OK" -ne 1 ]; then
    FW_FALLBACK="${FW_FALLBACK:-}"
    if [ -z "$FW_FALLBACK" ]; then
        echo ""
        echo "pf did not come up. Diagnostics are in $LOGDIR/pfctl_check.log. Choose how to proceed:"
        echo "  [1] retry pf now (in case it was transient)"
        echo "  [2] fall back to ipfw with an equivalent default-deny ruleset"
        echo "  [3] continue WITHOUT any firewall (test/VM only, NOT recommended)"
        echo "  [4] abort here and fix pf manually"
        printf "Select [1-4] (default 4): "
        read fwchoice
        case "$fwchoice" in
            1) FW_FALLBACK=retry ;;
            2) FW_FALLBACK=ipfw ;;
            3) FW_FALLBACK=none ;;
            *) FW_FALLBACK=abort ;;
        esac
    fi

    if [ "$FW_FALLBACK" = "retry" ]; then
        if pf_attempt; then
            PF_OK=1
        else
            warn "retry failed too"
            FW_FALLBACK=abort
        fi
    fi

    if [ "$PF_OK" -ne 1 ]; then
        case "$FW_FALLBACK" in
            ipfw)
                if setup_ipfw_fallback; then
                    log "ipfw fallback active"
                else
                    fail "ipfw fallback also failed — see $LOGDIR/ipfw_start.log — refusing to continue with no firewall at all"
                fi
                ;;
            none)
                printf "Type exactly: yes I understand   to continue with NO firewall: "
                read confirm
                if [ "$confirm" = "yes I understand" ]; then
                    warn "continuing WITHOUT any firewall — this host is unprotected at the network layer"
                    note "No firewall active (pf failed, ipfw not chosen) — fix this before exposing the machine to any network. Diagnostics: $LOGDIR/pfctl_check.log"
                else
                    fail "confirmation not given — aborting rather than silently running unprotected"
                fi
                ;;
            *)
                fail "pf not working and no fallback chosen — see $LOGDIR/pfctl_check.log, or re-run with FW_FALLBACK=ipfw / FW_FALLBACK=none to skip this prompt"
                ;;
        esac
    fi
fi

if [ "$PF_OK" -eq 1 ]; then
    service sshguard restart 2>/dev/null || service sshguard start 2>/dev/null || warn "sshguard didn't (re)start — pf's baseline rules still apply, but check this"
fi

log "== linux compat layer (optional) =="
WITH_LINUX_COMPAT="${WITH_LINUX_COMPAT:-}"
if [ -z "$WITH_LINUX_COMPAT" ]; then
    printf "Install Linux compatibility layer? Needed for Steam/some binary-only apps [y/N]: "
    read ans
    case "$ans" in y|Y|yes) WITH_LINUX_COMPAT=yes ;; *) WITH_LINUX_COMPAT=no ;; esac
fi
if [ "$WITH_LINUX_COMPAT" = "yes" ]; then
    sysrc linux_enable=YES >/dev/null
    kldload linux64 2>/dev/null || true
    ensure_pkg linux-rl9 || ensure_pkg linux_base-c7
    note "Linux compat installed for apps that ship only Linux binaries."
else
    log "skipping Linux compat layer (WITH_LINUX_COMPAT=no)"
fi

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
for p in qemu tree atuin git openjdk21; do
    ensure_pkg "$p"
done
ensure_pkg vscodium || note "VSCodium isn't reliably packaged for FreeBSD. neovim (Part A) or editors/lapce (native, lightweight) are the realistic editor options."
note "Ghidra and Burp Suite have no FreeBSD packages, but both are plain Java apps — openjdk21 is installed above, just run: java -jar burpsuite.jar / ./ghidraRun after downloading the release."

WITH_WINE="${WITH_WINE:-}"
if [ -z "$WITH_WINE" ]; then
    printf "Install Wine (run some Windows apps natively, no Linux compat needed)? [y/N]: "
    read ans
    case "$ans" in y|Y|yes) WITH_WINE=yes ;; *) WITH_WINE=no ;; esac
fi
if [ "$WITH_WINE" = "yes" ]; then
    ensure_pkg wine-devel
else
    log "skipping Wine (WITH_WINE=no)"
fi

log "== gaming (optional) =="
ensure_pkg prismlauncher || note "Prism Launcher may not be in the repo for this release — check 'pkg search prismlauncher' manually."

WITH_STEAM="${WITH_STEAM:-}"
if [ -z "$WITH_STEAM" ]; then
    printf "Try Steam via linux-steam-utils? Hardware/game-dependent, needs Linux compat [y/N]: "
    read ans
    case "$ans" in y|Y|yes) WITH_STEAM=yes ;; *) WITH_STEAM=no ;; esac
fi
if [ "$WITH_STEAM" = "yes" ]; then
    if [ "$WITH_LINUX_COMPAT" != "yes" ]; then
        warn "Steam requested but Linux compat layer wasn't installed earlier — linux-steam-utils will likely be useless without it"
    fi
    ensure_pkg linux-steam-utils || note "linux-steam-utils failed/unavailable — Steam is hardware- and game-dependent either way, treat it as an experiment, not something to rely on."
else
    log "skipping Steam (WITH_STEAM=no)"
fi

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
