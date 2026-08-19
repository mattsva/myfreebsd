#!/bin/sh
#
# FreeBSD unattended base-system installer — run from the LIVE SHELL
# (boot the install media, at the Welcome screen pick "Shell", then run
# this). Replaces bsdinstall entirely for a scripted, repeatable install:
# disk partitioning, ZFS, GELI encryption, hardening, wheel/sudo user —
# then hands off to install.sh (the desktop-stack script) automatically
# on first real boot, using the choices you make here.
#
# SAFETY: this WILL destroy all data on the disk you select. It asks you
# to type the exact device name twice before touching anything. There is
# no "are you sure" theater beyond that — read the disk list carefully.
#
# This script drives bsdinstall's own scripted-install mechanism
# (`bsdinstall script`) rather than reimplementing gpart/zpool/geli by
# hand — that's the same code path pfSense/OPNsense-style unattended
# installs use, so disk/ZFS/GELI setup itself is FreeBSD's own tested
# logic, not mine.
#
# IMPORTANT: the exact ZFSBOOT_* variable names below match FreeBSD
# 15.1's bsdinstall as of when this was written. Before running on
# real hardware, verify them yourself against your actual boot media:
#   grep -oE 'ZFSBOOT_[A-Z_]+' /usr/libexec/bsdinstall/zfsboot | sort -u
# If they've drifted, fix the installerconfig this script generates
# before you let it touch a disk.

set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root in the live shell." >&2
    exit 1
fi

echo "=== FreeBSD unattended install — base system + desktop handoff ==="
echo ""

### 1. disk selection — the dangerous part, so it gets the most friction ---

echo "Available disks:"
geom disk list | grep -E '^Geom name' | sed 's/Geom name: /  /'
echo ""
printf "Disk device to install to (e.g. nvd0, ada0, da0), WITHOUT /dev/: "
read DISK1
printf "Type it again to confirm you mean to WIPE %s completely: " "$DISK1"
read DISK2
if [ "$DISK1" != "$DISK2" ] || [ -z "$DISK1" ]; then
    echo "Disk names didn't match (or were empty) — aborting, nothing was touched." >&2
    exit 1
fi
if [ ! -e "/dev/$DISK1" ]; then
    echo "/dev/$DISK1 does not exist — aborting." >&2
    exit 1
fi
DISK="$DISK1"
echo "Will install to: /dev/$DISK — everything on it will be destroyed."
printf "Type exactly: yes wipe %s   to proceed: " "$DISK"
read confirm
if [ "$confirm" != "yes wipe $DISK" ]; then
    echo "Confirmation text didn't match — aborting, nothing was touched." >&2
    exit 1
fi

### 2. base system questions ------------------------------------------------

printf "Hostname: "
read HOSTNAME
printf "Keyboard layout (e.g. us, de): "
read KEYLAYOUT
printf "Timezone (e.g. Europe/Berlin) — 'list' to browse: "
read TIMEZONE
if [ "$TIMEZONE" = "list" ]; then
    tzsetup -s 2>/dev/null | less
    printf "Timezone: "
    read TIMEZONE
fi

printf "Primary username: "
read NEWUSER
printf "Password for %s (visible, live shell only): " "$NEWUSER"
read USERPASS
printf "Root password (visible, live shell only): "
read ROOTPASS

printf "GELI disk-encryption passphrase: "
read -s GELIPASS
echo ""
printf "confirm passphrase: "
read -s GELIPASS2
echo ""
if [ "$GELIPASS" != "$GELIPASS2" ]; then
    echo "passphrases didn't match — aborting." >&2
    exit 1
fi

### 3. desktop-stack choices, pre-seeded for install.sh on first boot -------
# Same questions install.sh normally asks interactively — answered once,
# here, so first boot can run it completely unattended.

echo ""
echo "Desktop-stack install mode:"
echo "  [1] fast   — everything via pkg, including Hyprland itself"
echo "  [2] medium — pkg for most things, ports for Hyprland/Hyprlock/Hypridle/Waybar/foot/fish/neovim"
echo "  [3] full   — compile the entire desktop stack from ports"
printf "Select [1/2/3] (default 1): "
read mchoice
case "$mchoice" in 2) MODE=medium ;; 3) MODE=full ;; *) MODE=fast ;; esac

echo "GPU driver — leave blank to auto-detect on first boot (recommended, since"
echo "this live shell's hardware view may not match the installed system's):"
printf "intel/amd/nvidia/none/blank: "
read GPU_DRIVER

printf "Install Linux compat layer (Steam etc.)? [y/N]: "
read a; case "$a" in y|Y|yes) WITH_LINUX_COMPAT=yes ;; *) WITH_LINUX_COMPAT=no ;; esac
printf "Install Wine? [y/N]: "
read a; case "$a" in y|Y|yes) WITH_WINE=yes ;; *) WITH_WINE=no ;; esac
printf "Try Steam (linux-steam-utils)? [y/N]: "
read a; case "$a" in y|Y|yes) WITH_STEAM=yes ;; *) WITH_STEAM=no ;; esac
printf "Try building OpenDeck for an AJAZZ stream deck (experimental)? [y/N]: "
read a; case "$a" in y|Y|yes) WITH_STREAMDECK=yes ;; *) WITH_STREAMDECK=no ;; esac

echo ""
echo "=== summary ==="
echo "disk=$DISK host=$HOSTNAME user=$NEWUSER keymap=$KEYLAYOUT tz=$TIMEZONE"
echo "mode=$MODE gpu=${GPU_DRIVER:-auto-detect} linux_compat=$WITH_LINUX_COMPAT wine=$WITH_WINE steam=$WITH_STEAM streamdeck=$WITH_STREAMDECK"
printf "Proceed with base install now? [y/N]: "
read go
[ "$go" = "y" ] || [ "$go" = "Y" ] || { echo "aborted, nothing was touched."; exit 1; }

### 4. build the bsdinstall scripted config ----------------------------------

CONF=/tmp/installerconfig
cat > "$CONF" <<EOF
export ZFSBOOT_DISKS="$DISK"
export ZFSBOOT_POOL_NAME="zroot"
export ZFSBOOT_VDEV_TYPE="stripe"
export ZFSBOOT_GELI_ENCRYPTION="YES"
export ZFSBOOT_GELI_KEY_LENGTH="256"
export ZFSBOOT_GELI_PASSPHRASE="$GELIPASS"
export ZFSBOOT_SWAP_SIZE="8g"
export DISTRIBUTIONS="base.txz kernel.txz"
export BSDINSTALL_DISTSITE="\${BSDINSTALL_DISTSITE:-}"
export nonInteractive="YES"

#!/bin/sh
# --- everything below runs chrooted into the freshly extracted system ---
set -e

sysrc hostname="$HOSTNAME"
echo "keymap=\"$KEYLAYOUT\"" >> /etc/rc.conf
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime

pw useradd "$NEWUSER" -m -G wheel -s /bin/sh
echo "$USERPASS" | pw usermod "$NEWUSER" -h 0
echo "$ROOTPASS" | pw usermod root -h 0

pkg install -y sudo
echo "%wheel ALL=(ALL) ALL" >> /usr/local/etc/sudoers

# hardening — same set as the bsdinstall hardening screen
cat >> /etc/sysctl.conf <<HARDENING
security.bsd.see_other_uids=0
security.bsd.see_other_gids=0
security.bsd.see_jail_proc=0
security.bsd.unprivileged_read_msgbuf=0
security.bsd.unprivileged_proc_debug=0
kern.randompid=1
HARDENING
sysrc clear_tmp_enable=YES
sysrc syslogd_flags="-ss"
sysrc sendmail_enable=NONE
sysrc sendmail_submit_enable=NO
sysrc sendmail_outbound_enable=NO
sysrc sendmail_msp_queue_enable=NO
echo "console=\"/boot/loader.conf console\"" > /dev/null
echo 'kern.securelevel_enable="YES"' >> /etc/rc.conf

# firstboot hook: run install.sh once, unattended, with the choices
# gathered during bootstrap — then disable itself
mkdir -p /root/desktop-setup
cat > /usr/local/etc/rc.d/firstboot_desktopsetup <<'FIRSTBOOT'
#!/bin/sh
# PROVIDE: firstboot_desktopsetup
# REQUIRE: NETWORKING
# KEYWORD: firstboot
. /etc/rc.subr
name="firstboot_desktopsetup"
start_cmd="firstboot_desktopsetup_run"
firstboot_desktopsetup_run() {
    export MODE TARGET_USER GPU_DRIVER WITH_LINUX_COMPAT WITH_WINE WITH_STEAM WITH_STREAMDECK FW_FALLBACK
    sh /root/desktop-setup/install.sh "\$MODE" "\$TARGET_USER" "\$GPU_DRIVER" \
        > /root/desktop-setup/firstboot.log 2>&1
    sysrc firstboot_desktopsetup_enable=NO
}
load_rc_config \$name
run_rc_command "\$1"
FIRSTBOOT
chmod +x /usr/local/etc/rc.d/firstboot_desktopsetup
sysrc firstboot_desktopsetup_enable=YES
sysrc firstboot_enable=YES

cat >> /etc/rc.conf <<ENVVARS
MODE=$MODE
TARGET_USER=$NEWUSER
GPU_DRIVER=$GPU_DRIVER
WITH_LINUX_COMPAT=$WITH_LINUX_COMPAT
WITH_WINE=$WITH_WINE
WITH_STEAM=$WITH_STEAM
WITH_STREAMDECK=$WITH_STREAMDECK
FW_FALLBACK=ipfw
ENVVARS
EOF

echo ""
echo "Generated $CONF — review it now if you want (esp. the ZFSBOOT_* vars"
echo "against your actual bsdinstall version). Press enter to run bsdinstall,"
echo "Ctrl-C to bail out and edit first."
read _

### 5. hand off to bsdinstall's own scripted installer -----------------------

bsdinstall script "$CONF"

### 6. copy install.sh into the new system for firstboot to run -------------

NEWROOT=/mnt
if [ -d "$NEWROOT/root" ]; then
    if [ -f ./install.sh ]; then
        mkdir -p "$NEWROOT/root/desktop-setup"
        cp ./install.sh "$NEWROOT/root/desktop-setup/install.sh"
        chmod +x "$NEWROOT/root/desktop-setup/install.sh"
        echo "install.sh staged for firstboot."
    else
        echo "!!! install.sh not found next to bootstrap.sh — copy it to"
        echo "!!! $NEWROOT/root/desktop-setup/install.sh yourself before rebooting,"
        echo "!!! or firstboot will fail with nothing to run."
    fi
fi

echo ""
echo "Base install done. Review $NEWROOT if you want, then reboot."
echo "On first real boot it will automatically run install.sh with:"
echo "  mode=$MODE gpu=${GPU_DRIVER:-auto} user=$NEWUSER"
