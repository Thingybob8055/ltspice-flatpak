# LTspice Flatpak (Wine wrapper)

Unofficial Flatpak that runs Analog Devices' LTspice on Linux through Wine.
LTspice itself is not bundled; it is downloaded from analog.com on first run.

- **Wine:** Flathub's `org.winehq.Wine` base app, branch `wow64-25.08` (Wine 11.0).
  LTspice 24+ is 64-bit only, so the pure-wow64 build avoids 32-bit GL driver
  extensions (a common source of breakage on NVIDIA / unusual distros).
- **First run:** choose to download + install the latest LTspice, use an
  existing install (other Wine prefixes, Bottles, a Windows partition — copied
  in or run in place), or install from a local `.msi`/`.exe`.
- **Updates:** once a day, the launcher compares the `Last-Modified` of the
  official `LTspice64.msi` with the installed release; it then asks, installs
  automatically, or stays quiet, depending on the setting.
- **Display:** X11 / XWayland by default (most mature); Wine's native Wayland
  driver can be selected in settings. HiDPI scaling (DPI) is configurable.

## Install from a release

Download `LTspice-x86_64.flatpak` from the
[latest release](https://github.com/Thingybob8055/ltspice-flatpak/releases/latest), then:

```sh
flatpak install --user LTspice-x86_64.flatpak
```

Wine is built into the bundle; the Freedesktop runtime and Wine Gecko are
fetched from Flathub automatically.
Only x86_64 is available. Flathub's Wine base app has no ARM build, and
LTspice is an x86-64 Windows program, so ARM would also need an emulator.

Every push to `main` builds a bundle (downloadable from the Actions run).
Pushing a `v*` tag also publishes it as a GitHub release:

```sh
git tag -a v1.1 -m "v1.1" && git push origin v1.1
```

## Build & install

```sh
flatpak install --user flathub org.flatpak.Builder
flatpak run --filesystem=$PWD org.flatpak.Builder --user --force-clean \
    --install-deps-from=flathub --repo=repo --install build-dir io.github.ltspice_wine.LTspice.yml
```

(or `make install`; `make bundle` produces a single-file `LTspice.flatpak`.)

## Usage

```
flatpak run io.github.ltspice_wine.LTspice [FILE...]
flatpak run io.github.ltspice_wine.LTspice --updates        # updates window: check now, ask/auto/off
flatpak run io.github.ltspice_wine.LTspice --settings       # DPI, backend, winecfg, reset, …
flatpak run io.github.ltspice_wine.LTspice --check-updates
flatpak run io.github.ltspice_wine.LTspice --info
```

The updates window also has its own "LTspice Updates" app-menu entry, and
both it and the settings are right-click actions on the LTspice icon. To bind
it to a key (e.g. Hyprland):
`bind = SUPER SHIFT, L, exec, flatpak run io.github.ltspice_wine.LTspice --updates` Logs: `~/.var/app/io.github.ltspice_wine.LTspice/cache/`.

## Uninstall

**1. Remove the app and all its data.** This includes the Wine prefix, the
LTspice installation inside it, the component libraries, the wrapper's
settings and its logs (everything under
`~/.var/app/io.github.ltspice_wine.LTspice`):

```sh
flatpak uninstall --user --delete-data io.github.ltspice_wine.LTspice
```

(Drop `--user` if you installed it system-wide.)

**2. Remove the Wine base app, Gecko and the runtimes it pulled in, if nothing
else uses them.** Flatpak lists what it will remove and asks before deleting:

```sh
flatpak uninstall --user --unused
```

**3. Optional: remove the build tooling and build output.** Only needed if you
built from source:

```sh
flatpak uninstall --user org.flatpak.Builder org.freedesktop.Sdk//25.08
flatpak uninstall --user --unused
rm -rf build-dir repo .flatpak-builder LTspice.flatpak   # in this project folder
```

**4. Optional: your own files.** LTspice saves schematics, keyboard-shortcut
backups and similar files to your real `~/Documents/LTspice`. The uninstall
steps above leave it alone. Delete it yourself if you don't want to keep it:

```sh
rm -rf ~/Documents/LTspice
```

Also remove any keybind or window rule you added to your desktop config (e.g.
the Hyprland `bind`/`windowrulev2` lines).

To start fresh **without** uninstalling, use *Settings ▸ Reset everything…*.
It deletes the Wine prefix and wrapper settings, and LTspice is set up again
on the next launch.

## Notes

- `--allow=multiarch` is required even with wow64 Wine: the LTspice MSI runs
  32-bit custom actions, and without it Flatpak's seccomp filter makes
  `msiexec` hang forever at `AI_IaLogPkgStarted`.
- Not affiliated with Analog Devices. LTspice is subject to its own license.
