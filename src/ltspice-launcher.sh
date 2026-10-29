#!/usr/bin/env bash
# LTspice launcher for the Flatpak Wine wrapper.
#
# Handles first-run setup (download / existing install / local installer),
# Wine prefix maintenance, update checks against the official installer and
# finally launches LTspice with any files passed on the command line.

set -uo pipefail

APP_ID="${FLATPAK_ID:-io.github.ltspice_wine.LTspice}"
APP_NAME="LTspice"
MSI_URL="${LTSPICE_MSI_URL:-https://ltspice.analog.com/software/LTspice64.msi}"
UPDATE_INTERVAL="${LTSPICE_UPDATE_INTERVAL:-86400}"   # seconds between automatic checks

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
CONF="$CONFIG_DIR/ltspice-wrapper.conf"
LOG="$CACHE_DIR/ltspice-wrapper.log"
mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$CACHE_DIR"

export WINEPREFIX="$DATA_DIR/wine"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
# No host menu entries from inside the sandbox, and LTspice does not need .NET.
export WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree=d${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"

MANAGED_DIR="$WINEPREFIX/drive_c/Program Files/ADI/LTspice"
MANAGED_EXE="$MANAGED_DIR/LTspice.exe"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Keep the launcher lock (fd 9) out of Wine: wineserver outlives the launcher
# and would otherwise hold the lock, blocking every later launch.
wine()       { command wine "$@" 9>&-; }
wineboot()   { command wineboot "$@" 9>&-; }
wineserver() { command wineserver "$@" 9>&-; }

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

conf_get() {
    [[ -f $CONF ]] || return 0
    sed -n "s/^$1=//p" "$CONF" | tail -n1
}

conf_set() {
    local tmp
    tmp=$(mktemp "$CONF.XXXXXX")
    [[ -f $CONF ]] && grep -v "^$1=" "$CONF" >"$tmp"
    printf '%s=%s\n' "$1" "${2//$'\n'/ }" >>"$tmp"
    mv -f "$tmp" "$CONF"
}

has_gui() { [[ -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} ]]; }

z() {
    if ! has_gui; then
        echo "$APP_NAME: no display available for dialog" >&2
        return 1
    fi
    zenity --title="$APP_NAME" --window-icon="$APP_ID" "$@" 2>/dev/null
}

info()  { z --info --width=420 --text="$1"; }
error() { log "ERROR: $1"; z --error --width=420 --text="$1" || echo "Error: $1" >&2; }
ask()   { z --question --width=420 --text="$1"; }

# Wait for all Wine processes of the prefix to exit, without hanging forever.
wine_wait() {
    timeout 60 wineserver -w 9>&- || command wineserver -k 9>&-
}

# Run a command while showing a pulsating progress dialog with elapsed time.
# Gives up after PROGRESS_TIMEOUT seconds (default 15 min) and returns 124.
with_progress() {
    local text=$1 rc start limit=${PROGRESS_TIMEOUT:-900} timed_out="$CACHE_DIR/.timed-out"
    shift
    rm -f "$timed_out"
    "$@" >>"$LOG" 2>&1 &
    local pid=$!
    start=$(date +%s)
    # Ignore SIGPIPE so closing the dialog does not stop the timeout watchdog.
    { trap '' PIPE; while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(($(date +%s) - start))
        if ((elapsed >= limit)); then
            log "Timed out after ${elapsed}s: $*"
            touch "$timed_out"
            kill "$pid" 2>/dev/null
            command wineserver -k 9>&- 2>/dev/null
            break
        fi
        printf '# %s  (%d:%02d)\n' "$text" $((elapsed / 60)) $((elapsed % 60)) 2>/dev/null
        sleep 0.5
    done; } | if has_gui; then
        z --progress --pulsate --auto-close --no-cancel --width=460 --text="$text"
    else
        cat >/dev/null
    fi
    wait "$pid" 2>/dev/null; rc=$?
    if [[ -e $timed_out ]]; then
        rm -f "$timed_out"
        rc=124
    fi
    return $rc
}

last_header() { # file header-name
    [[ -f $1 ]] || return 0
    tr -d '\r' <"$1" | grep -i "^$2:" | tail -n1 | cut -d' ' -f2-
}

# Last-Modified of the official installer; this is what identifies a release.
remote_release() {
    curl -fsSIL --max-time "${1:-10}" "$MSI_URL" 2>>"$LOG" |
        tr -d '\r' | grep -i '^last-modified:' | tail -n1 | cut -d' ' -f2-
}

pretty_date() { date -d "$1" '+%B %-d, %Y' 2>/dev/null || echo "$1"; }

ltspice_running() { pgrep -fi 'ltspice[^/]*\.exe|XVIIx64\.exe' >/dev/null; }

wait_for_ltspice_to_close() {
    while ltspice_running; do
        z --question --width=420 --ok-label="Retry" --cancel-label="Cancel" \
            --text="LTspice is currently running.\n\nPlease close all LTspice windows, then press Retry." || return 1
    done
    wineserver -k 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Wine prefix
# ---------------------------------------------------------------------------

apply_wine_settings() {
    local reg dpi
    reg=$(mktemp "$CACHE_DIR/settings.XXXXXX.reg")
    dpi=$(conf_get DPI)
    {
        echo 'Windows Registry Editor Version 5.00'
        echo
        echo '[HKEY_CURRENT_USER\Control Panel\Desktop]'
        # Subpixel font smoothing makes schematic text much more readable.
        echo '"FontSmoothing"="2"'
        echo '"FontSmoothingType"=dword:00000002'
        echo '"FontSmoothingGamma"=dword:00000578'
        echo '"FontSmoothingOrientation"=dword:00000001'
        if [[ $dpi =~ ^[0-9]+$ ]]; then
            printf '"LogPixels"=dword:%08x\n' "$dpi"
        fi
        echo
        echo '[HKEY_CURRENT_USER\Software\Wine\DllOverrides]'
        echo '"winemenubuilder.exe"=""'
    } >"$reg"
    wine regedit /S "$(winepath -w "$reg")" >>"$LOG" 2>&1
    rm -f "$reg"

    # Wine's built-in UI fonts lack glyphs such as → (U+2192), which LTspice
    # uses in its menus and messages. Link them to fonts shipped in the
    # Flatpak runtime so missing glyphs fall back instead of showing boxes.
    local links='DejaVuSans.ttf,DejaVu Sans\0LiberationSans-Regular.ttf,Liberation Sans\0FreeSans.ttf,FreeSans' face
    for face in "Tahoma" "Tahoma Bold" "MS Shell Dlg" "MS Shell Dlg 2" "Microsoft Sans Serif" \
        "Segoe UI" "Arial" "Courier New" "Lucida Console"; do
        wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink' \
            /v "$face" /t REG_MULTI_SZ /d "$links" /f >>"$LOG" 2>&1
    done
}

# Bump when apply_wine_settings changes so existing prefixes pick it up.
SETTINGS_REV=2

ensure_prefix() {
    local wine_version
    wine_version=$(wine --version 2>/dev/null)
    if [[ -f $WINEPREFIX/system.reg && $(conf_get WINE_VERSION) == "$wine_version" ]]; then
        if [[ $(conf_get SETTINGS_REV) != "$SETTINGS_REV" ]]; then
            apply_wine_settings
            conf_set SETTINGS_REV "$SETTINGS_REV"
        fi
        return 0
    fi
    log "Preparing prefix for $wine_version"
    if ! with_progress "Preparing the Wine environment ($wine_version)…" wineboot -u; then
        error "Failed to initialise the Wine environment.\n\nSee the log at:\n$LOG"
        return 1
    fi
    wine_wait
    apply_wine_settings
    conf_set WINE_VERSION "$wine_version"
    conf_set SETTINGS_REV "$SETTINGS_REV"
}

# ---------------------------------------------------------------------------
# Installing LTspice
# ---------------------------------------------------------------------------

# Download the official installer with a progress dialog.
# Sets DOWNLOAD_RELEASE to the server's Last-Modified header.
download_installer() {
    local dest=$1 hdr="$1.headers" part="$1.part" pid rc ui_rc=0
    DOWNLOAD_RELEASE=""
    rm -f "$part" "$hdr"
    log "Downloading $MSI_URL"
    curl -fL --retry 3 --connect-timeout 20 -D "$hdr" -o "$part" "$MSI_URL" 2>>"$LOG" &
    pid=$!

    if has_gui; then
        while kill -0 "$pid" 2>/dev/null; do
            local total size
            total=$(last_header "$hdr" content-length)
            size=$(stat -c %s "$part" 2>/dev/null || echo 0)
            if [[ $total =~ ^[0-9]+$ && $total -gt 0 ]]; then
                echo $((size * 99 / total))
                echo "# Downloading LTspice from Analog Devices…  $((size / 1048576)) of $((total / 1048576)) MiB"
            else
                echo "# Downloading LTspice from Analog Devices…  $((size / 1048576)) MiB"
            fi
            sleep 0.5
        done | z --progress --auto-close --width=460 --percentage=0 \
            --text="Connecting to ltspice.analog.com…"
        ui_rc=${PIPESTATUS[1]}
    fi

    if [[ $ui_rc -ne 0 ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -f "$part" "$hdr"
        log "Download cancelled"
        return 1
    fi
    wait "$pid"; rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$part" "$hdr"
        error "Downloading LTspice failed (curl error $rc).\n\nCheck your internet connection and try again."
        return 1
    fi
    DOWNLOAD_RELEASE=$(last_header "$hdr" last-modified)
    mv -f "$part" "$dest"
    rm -f "$hdr"
}

# Read the installed version from the uninstall registry entries.
detect_installed_version() {
    wine reg query 'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall' /s 2>/dev/null |
        tr -d '\r' | awk '
            /^HKEY_/ { name = ""; ver = "" }
            /DisplayName/ && /LTspice/ { name = 1 }
            /DisplayVersion/ { ver = $NF }
            name && ver { print ver; exit }'
}

run_installer() { # path-to-msi-or-exe
    local installer=$1 win_installer rc
    win_installer=$(winepath -w "$installer")
    log "Running installer $installer"
    case ${installer,,} in
        *.msi)
            # '/l*v' must stay quoted, otherwise bash globs it (e.g. to /lib /lib64).
            with_progress "Installing LTspice… (usually under a minute)" \
                wine msiexec /i "$win_installer" /qn '/l*v' "$(winepath -w "$CACHE_DIR/msi-install.log")"
            ;;
        *)
            # Unknown installer type: run it interactively.
            wine "$win_installer" >>"$LOG" 2>&1
            ;;
    esac
    rc=$?
    wine_wait
    log "Installer exited with $rc"
    case $rc in
        0 | 3010) ;;
        124)
            error "The LTspice installer did not finish within 15 minutes and was stopped.\n\nInstaller log:\n$CACHE_DIR/msi-install.log"
            return 1
            ;;
        1602) log "Installation cancelled"; return 1 ;;
        *)
            error "The LTspice installer failed (code $rc).\n\nInstaller log:\n$CACHE_DIR/msi-install.log"
            return 1
            ;;
    esac

    if [[ -f $MANAGED_EXE ]]; then
        conf_set INSTALL_MODE managed
        conf_set LTSPICE_EXE "$MANAGED_EXE"
    else
        local found
        found=$(find "$WINEPREFIX/drive_c/Program Files" "$WINEPREFIX/drive_c/Program Files (x86)" \
            -maxdepth 3 -iname 'LTspice*.exe' -o -maxdepth 3 -iname 'XVIIx64.exe' 2>/dev/null |
            grep -viE 'uninst|setup' | head -n1)
        if [[ -z $found ]]; then
            error "The installer finished but LTspice.exe could not be found.\n\nSee the logs in:\n$CACHE_DIR"
            return 1
        fi
        conf_set INSTALL_MODE managed
        conf_set LTSPICE_EXE "$found"
    fi
    conf_set INSTALLED_VERSION "$(detect_installed_version)"
}

install_latest() {
    local msi="$CACHE_DIR/LTspice64.msi"
    wait_for_ltspice_to_close || return 1
    download_installer "$msi" || return 1
    if run_installer "$msi"; then
        conf_set INSTALLED_RELEASE "$DOWNLOAD_RELEASE"
        conf_set SKIPPED_RELEASE ""
        conf_set LAST_CHECK "$(date +%s)"
        rm -f "$msi"
        return 0
    fi
    return 1
}

install_from_file() {
    local file
    file=$(z --file-selection --title="Select the LTspice installer" \
        --file-filter="LTspice installer | *.msi *.MSI *.exe *.EXE" \
        --file-filter="All files | *") || return 1
    wait_for_ltspice_to_close || return 1
    run_installer "$file" || return 1
    # The release of a local installer is unknown; the next update check
    # will offer the latest official release (which can be skipped).
    conf_set INSTALLED_RELEASE ""
}

# Look for LTspice installs in the usual places (other Wine prefixes,
# Bottles, mounted Windows partitions).
find_existing_installs() {
    local roots=(
        "$HOME/.wine/drive_c"
        "$HOME"/.local/share/wineprefixes/*/drive_c
        "$HOME"/.local/share/bottles/bottles/*/drive_c
        "$HOME"/.var/app/com.usebottles.bottles/data/bottles/bottles/*/drive_c
        "$HOME"/Games/*/drive_c
        "$HOME"/.PlayOnLinux/wineprefix/*/drive_c
        /run/media/*/* /media/*/* /media/* /mnt/*
    )
    local root
    for root in "${roots[@]}"; do
        [[ -d $root && $root != "$WINEPREFIX/drive_c" ]] || continue
        for exe in "$root/Program Files/ADI/LTspice/LTspice.exe" \
            "$root/Program Files/LTC/LTspiceXVII/XVIIx64.exe" \
            "$root/Program Files/LTC/LTspiceIV/scad3.exe"; do
            [[ -f $exe ]] && echo "$exe"
        done
    done 2>/dev/null | sort -u
}

# Copy library/settings from the prefix an existing install came from.
import_user_data() { # exe
    local exe=$1 src_root user_dir src
    [[ $exe == */drive_c/* ]] || return 0
    src_root="${exe%%/drive_c/*}/drive_c/users"
    user_dir="$WINEPREFIX/drive_c/users/${USER:-$(id -un)}"
    for src in "$src_root"/*/AppData/Local/LTspice "$src_root"/*/"Local Settings/Application Data/LTspice"; do
        if [[ -d $src && ! -e $user_dir/AppData/Local/LTspice ]]; then
            mkdir -p "$user_dir/AppData/Local"
            cp -a "$src" "$user_dir/AppData/Local/LTspice" && log "Imported $src"
        fi
    done
    for src in "$src_root"/*/AppData/Roaming/LTspice.ini; do
        if [[ -f $src && ! -e $user_dir/AppData/Roaming/LTspice.ini ]]; then
            mkdir -p "$user_dir/AppData/Roaming"
            cp -a "$src" "$user_dir/AppData/Roaming/" && log "Imported $src"
        fi
    done
}

use_existing_install() {
    local exe candidates=() args=() c
    mapfile -t candidates < <(find_existing_installs)
    if [[ ${#candidates[@]} -gt 0 ]]; then
        for c in "${candidates[@]}"; do args+=(FALSE "$c"); done
        args[0]=TRUE
        exe=$(z --list --radiolist --width=720 --height=340 \
            --text="Found these LTspice installations. Pick one, or choose Browse to select another." \
            --column="" --column="LTspice executable" "${args[@]}" \
            --extra-button="Browse…") || exe=""
    fi
    if [[ -z ${exe:-} || $exe == "Browse…" ]]; then
        exe=$(z --file-selection --title="Select LTspice.exe (or XVIIx64.exe)" \
            --file-filter="LTspice executable | *.exe *.EXE") || return 1
    fi
    if [[ ! -f $exe ]]; then
        error "File not found:\n$exe"
        return 1
    fi

    local how
    how=$(z --list --radiolist --width=640 --height=260 \
        --text="How should this installation be used?" \
        --column="" --column=id --column="Option" --hide-column=2 --print-column=2 \
        TRUE copy "Copy it into the app (recommended — self-contained, receives updates)" \
        FALSE inplace "Run it from its current location (updates are left to you)") || return 1

    wait_for_ltspice_to_close || return 1
    import_user_data "$exe"
    if [[ $how == copy ]]; then
        local src_dir
        src_dir=$(dirname "$exe")
        rm -rf "$MANAGED_DIR"
        mkdir -p "$(dirname "$MANAGED_DIR")"
        if ! with_progress "Copying LTspice…" cp -a "$src_dir" "$MANAGED_DIR"; then
            error "Copying $src_dir failed."
            return 1
        fi
        conf_set INSTALL_MODE copied
        conf_set LTSPICE_EXE "$MANAGED_DIR/$(basename "$exe")"
    else
        conf_set INSTALL_MODE external
        conf_set LTSPICE_EXE "$exe"
    fi
    conf_set INSTALLED_RELEASE ""
    conf_set INSTALLED_VERSION ""
}

setup() {
    local choice
    choice=$(z --list --radiolist --width=680 --height=300 \
        --text="<b>Welcome!</b> LTspice runs here through Wine. How would you like to set it up?" \
        --column="" --column=id --column="Option" --hide-column=2 --print-column=2 \
        TRUE download "Download and install the latest LTspice from Analog Devices (recommended)" \
        FALSE existing "Use an existing LTspice installation (Wine prefix, Bottles, Windows drive…)" \
        FALSE file "Install from an installer I already downloaded (.msi / .exe)") || return 1

    case $choice in
        download) install_latest ;;
        existing) use_existing_install ;;
        file) install_from_file ;;
        *) return 1 ;;
    esac || return 1
}

# ---------------------------------------------------------------------------
# Updates
# ---------------------------------------------------------------------------

# ask (default) | auto | off
update_policy() {
    local p
    p=$(conf_get UPDATE_POLICY)
    case $p in
        auto | off) echo "$p" ;;
        *) echo ask ;;
    esac
}

check_updates() { # interactive: 1 = user asked, 0 = automatic
    local interactive=${1:-0} mode remote installed skipped policy choice
    mode=$(conf_get INSTALL_MODE)
    remote=$(remote_release "$([[ $interactive == 1 ]] && echo 15 || echo 6)")
    if [[ -z $remote ]]; then
        log "Update check failed"
        [[ $interactive == 1 ]] && error "Could not reach ltspice.analog.com to check for updates."
        return 1
    fi
    conf_set LAST_CHECK "$(date +%s)"
    installed=$(conf_get INSTALLED_RELEASE)
    skipped=$(conf_get SKIPPED_RELEASE)
    policy=$(update_policy)
    log "Update check: remote='$remote' installed='$installed' skipped='$skipped'"

    if [[ $remote == "$installed" ]]; then
        [[ $interactive == 1 ]] && info "LTspice is up to date.\n\nInstalled release: $(pretty_date "$installed")"
        return 0
    fi
    [[ $interactive == 0 && $remote == "$skipped" ]] && return 0

    if [[ $mode == external ]]; then
        conf_set SKIPPED_RELEASE "$remote"
        info "A new LTspice release ($(pretty_date "$remote")) is available.\n\nYou are running an existing installation in place, so it is not updated automatically. Use <i>Help ▸ Check for Updates</i> inside LTspice, or switch to an app-managed installation in the wrapper settings."
        return 0
    fi

    if [[ $interactive == 0 && $policy == auto ]]; then
        install_latest
        return
    fi

    local text="A new LTspice release is available.\n\nLatest release: <b>$(pretty_date "$remote")</b>"
    if [[ -n $installed ]]; then
        text+="\nInstalled release: $(pretty_date "$installed")"
    else
        text+="\nInstalled release: unknown (installed from an existing copy or local installer)"
    fi
    choice=$(z --question --width=460 --text="$text\n\nInstall it now?" \
        --ok-label="Update now" --cancel-label="Later" --extra-button="Skip this release")
    case $? in
        0) install_latest && [[ $interactive == 1 ]] && info "LTspice was updated successfully." ;;
        *) [[ $choice == "Skip this release" ]] && conf_set SKIPPED_RELEASE "$remote" ;;
    esac
    return 0
}

maybe_check_updates() {
    local last now
    [[ $(update_policy) == off ]] && return 0
    last=$(conf_get LAST_CHECK)
    now=$(date +%s)
    if [[ ! $last =~ ^[0-9]+$ ]] || ((now - last >= UPDATE_INTERVAL)); then
        check_updates 0
    fi
}

updates_menu() {
    local choice policy installed version last checked current
    while true; do
        policy=$(update_policy)
        installed=$(conf_get INSTALLED_RELEASE)
        version=$(conf_get INSTALLED_VERSION)
        last=$(conf_get LAST_CHECK)
        current=${version:+version $version}
        if [[ -n $installed ]]; then
            current+="${current:+, }released $(pretty_date "$installed")"
        fi
        if [[ $last =~ ^[0-9]+$ ]]; then
            checked=$(date -d "@$last" '+%B %-d, %Y at %H:%M')
        else
            checked=never
        fi
        choice=$(z --list --width=580 --height=400 \
            --text="<b>LTspice updates</b>\n\nInstalled: ${current:-unknown}\nLast checked: $checked\n\nChoose what happens when a new release is published:" \
            --column=id --column="" --column="" --hide-column=1 --print-column=1 --hide-header \
            ask "$([[ $policy == ask ]] && echo ✔)" "Ask before installing (default)" \
            auto "$([[ $policy == auto ]] && echo ✔)" "Install automatically when LTspice starts" \
            off "$([[ $policy == off ]] && echo ✔)" "Never check automatically" \
            --ok-label="Select" --cancel-label="Close" \
            --extra-button="Check now" --extra-button="Reinstall latest")
        case $choice in
            ask | auto | off)
                conf_set UPDATE_POLICY "$choice"
                log "Update policy set to $choice"
                ;;
            "Check now") check_updates 1 ;;
            "Reinstall latest")
                ask "Download the latest LTspice and install it again?\n\nYour libraries and settings are kept." &&
                    install_latest && info "LTspice was installed successfully."
                ;;
            "") return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

settings_menu() {
    local choice exe mode version policy dpi graphics
    while true; do
        exe=$(conf_get LTSPICE_EXE)
        mode=$(conf_get INSTALL_MODE)
        version=$(conf_get INSTALLED_VERSION)
        policy=$(update_policy)
        dpi=$(conf_get DPI)
        graphics=$(conf_get GRAPHICS)
        choice=$(z --list --width=700 --height=460 \
            --text="<b>LTspice wrapper settings</b>\nInstallation: ${mode:-not set up} ${version:+(version $version)}\n<small>${exe:-}</small>" \
            --column=id --column="Action" --column="Current" --hide-column=1 --print-column=1 \
            updates "Updates…"                                 "$policy" \
            change  "Change installation source…"              "" \
            dpi     "Display scaling (DPI)"                    "${dpi:-96 (default)}" \
            graphics "Display backend"                          "${graphics:-auto}" \
            winecfg "Open Wine configuration"                  "" \
            winetricks "Open Winetricks"                       "" \
            folder  "Open the Wine prefix folder"              "" \
            log     "Show wrapper log"                         "" \
            reset   "Reset everything…"                        "" \
            --ok-label="Open" --cancel-label="Close") || return 0

        case $choice in
            updates) updates_menu ;;
            change) setup ;;
            dpi)
                local d
                d=$(z --list --radiolist --width=420 --height=360 --text="Choose the scaling for LTspice windows.\nIncrease this on HiDPI screens if text looks tiny." \
                    --column="" --column=dpi --column="Scale" --hide-column=2 --print-column=2 \
                    TRUE 96 "100 %" FALSE 120 "125 %" FALSE 144 "150 %" FALSE 168 "175 %" \
                    FALSE 192 "200 %" FALSE 240 "250 %" FALSE 288 "300 %") || continue
                wait_for_ltspice_to_close || continue
                conf_set DPI "$d"
                apply_wine_settings
                ;;
            graphics)
                local g
                g=$(z --list --radiolist --width=600 --height=300 --text="How LTspice windows are displayed:" \
                    --column="" --column=id --column="Backend" --hide-column=2 --print-column=2 \
                    TRUE auto "Automatic — X11 / XWayland when available (recommended)" \
                    FALSE x11 "Always X11 / XWayland" \
                    FALSE wayland "Native Wayland (experimental Wine driver)") || continue
                wait_for_ltspice_to_close || continue
                conf_set GRAPHICS "$g"
                ;;
            winecfg) setup_display_env; wine winecfg >>"$LOG" 2>&1 ;;
            winetricks) setup_display_env; winetricks >>"$LOG" 2>&1 ;;
            folder) xdg-open "$WINEPREFIX/drive_c" >/dev/null 2>&1 ;;
            log) z --text-info --width=800 --height=500 --filename="$LOG" ;;
            reset)
                if z --question --width=460 --default-cancel --ok-label="Reset" \
                    --text="Delete the Wine environment and all wrapper settings?\n\nThis removes the LTspice installation inside the app and its libraries/settings. Your schematics in your home folder are <b>not</b> touched."; then
                    wait_for_ltspice_to_close || continue
                    rm -rf "$WINEPREFIX" "$CONF"
                    info "Everything was reset. LTspice will be set up again on next launch."
                    return 0
                fi
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

# Pick X11 (XWayland) or Wine's native Wayland driver. Wine tries X11 first
# and falls back to Wayland when no X display is reachable.
setup_display_env() {
    case $(conf_get GRAPHICS) in
        wayland) [[ -n ${WAYLAND_DISPLAY:-} ]] && unset DISPLAY ;;
        x11 | auto | "") ;;
    esac
}

launch() {
    local exe args=() f
    exe=$(conf_get LTSPICE_EXE)
    if [[ -z $exe || ! -f $exe ]]; then
        error "LTspice could not be found at:\n${exe:-<not set>}\n\nIt will be set up again."
        setup || exit 1
        exe=$(conf_get LTSPICE_EXE)
    fi
    for f in "$@"; do
        [[ $f == file://* ]] &&
            f=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(urllib.parse.urlparse(sys.argv[1]).path))' "$f")
        if [[ -e $f ]]; then
            args+=("$(winepath -w "$(realpath "$f")")")
        else
            args+=("$f")
        fi
    done
    setup_display_env
    log "Launching $exe ${args[*]}"
    cd "$(dirname "$exe")" || exit 1
    exec wine "$exe" "${args[@]}"
}

usage() {
    cat <<EOF
Usage: ltspice [OPTION] [FILE...]

Runs LTspice through Wine. Without options, LTspice is started (and set up on
first run). Files given are opened in LTspice.

Options:
  --setup           Run the first-run setup again (change installation)
  --settings        Open the wrapper settings dialog
  --updates         Open the updates window (check now, ask/auto/off)
  --check-updates   Check for a new LTspice release now
  --update          Download and install the latest LTspice release
  --winecfg         Open Wine configuration for the LTspice prefix
  --wine ARGS...    Run an arbitrary Wine command in the LTspice prefix
  --kill            Terminate LTspice and all Wine processes of the app
  --info            Print installation information
  --help            Show this help

Environment:
  LTSPICE_MSI_URL          Override the installer download URL
  LTSPICE_UPDATE_INTERVAL  Seconds between automatic update checks (default 86400)
  WINEDEBUG                Wine debug channels (default -all)
EOF
}

main() {
    log "Started: $*"
    case ${1:-} in
        --help | -h) usage; exit 0 ;;
        --kill) wineserver -k; exit $? ;;
        --info)
            echo "Wine:         $(wine --version)"
            echo "Prefix:       $WINEPREFIX"
            echo "Config:       $CONF"
            echo "Log:          $LOG"
            echo "Mode:         $(conf_get INSTALL_MODE)"
            echo "Executable:   $(conf_get LTSPICE_EXE)"
            echo "Version:      $(conf_get INSTALLED_VERSION)"
            echo "Release date: $(conf_get INSTALLED_RELEASE)"
            echo "Update mode:  $(update_policy)"
            exit 0
            ;;
    esac

    # Serialise setup/update work between concurrent launches.
    exec 9>"$CACHE_DIR/launcher.lock"
    flock 9

    ensure_prefix || exit 1

    case ${1:-} in
        --setup) setup; exit $? ;;
        --settings) settings_menu; exit 0 ;;
        --updates) updates_menu; exit 0 ;;
        --check-updates) check_updates 1; exit $? ;;
        --update) install_latest; exit $? ;;
        --winecfg) setup_display_env; exec 9>&-; exec wine winecfg ;;
        --wine) shift; setup_display_env; exec 9>&-; exec wine "$@" ;;
        --*) usage >&2; exit 2 ;;
    esac

    if [[ -z $(conf_get LTSPICE_EXE) ]]; then
        setup || exit 1
    elif ! ltspice_running; then
        maybe_check_updates
    fi

    exec 9>&-
    launch "$@"
}

main "$@"
