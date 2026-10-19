# Postcard

**A new place on your desktop every day.**

Every morning, Postcard sends your Mac a new photo of somewhere in the world: a canal in Venice,
a castle in Wales, autumn in Croatia. It's set as your wallpaper on every desktop and display,
including your iPad in Sidecar. Click the menu bar icon to read about the place, see it on a map,
or flip back through the past week's photos.

- **Every screen, every desktop.** Works across all your Spaces and displays, including an iPad in Sidecar.
- **The story behind the photo.** Each image comes with a short description of the place and the photographer's credit.
- **See it on the map.** One click opens the location in Apple Maps.
- **Look back.** Use ‹ › to browse the past week's photos, or jump back to today.
- **Stays out of your way.** It lives in the menu bar, with no Dock icon and no windows. Once the day's photo is set, it doesn't go online again until tomorrow.
- **Respects your choices.** If you set your own photo on a desktop, Postcard leaves it alone.

Postcard is lightweight and private: no accounts, no tracking, no data collected.

Under the hood it's a small Swift program (`postcard`) kept running by a per-user launchd
LaunchAgent. No app bundle, no sudo. It sits idle almost all the time and only wakes on the events
described below.

## Menu bar

Click the photo icon in the menu bar to see:

- what's in today's photo, its headline, the date and the photographer credit;
- a paragraph about the place;
- a row of buttons: **‹ ›** for the previous/next day (the menu stays open while you browse),
  **Today**, and **Show in Maps** (opens the photo's location in Apple Maps, when one is available).

On macOS 26 and later you can hide the icon in System Settings → Menu Bar; the wallpaper keeps
updating either way.

## Install

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
cd ~/Projects/Postcard
./install.sh
```

This builds the binary, applies today's image right away, and registers the agent.

## How it works

- **Schedule:** `postcard --watch` checks for a new photo at login, every hour, and on wake. The new
  photo arrives at a different time per region, so an hourly check picks it up within the hour.
- **Once a day:** after today's image is applied, it makes no more requests until the next
  day. Until then, each check is a single ~1 KB JSON request.
- **Every desktop and display:** macOS only sets the wallpaper of each display's *current* Space.
  So the agent watches for Space switches and display changes (an iPad in Sidecar, an external
  monitor) and applies the image wherever it isn't showing yet. This needs no network.
- **Idempotent:** state lives in `state.json`. If the photo hasn't changed, nothing is downloaded
  or applied.
- **Image:** one small request lists the last 8 days' photos. The region is chosen by your location
  unless you set one. It downloads UHD (3840×2160) and falls back to 1920×1080.
- **Safe writes:** images are validated (magic bytes + decode) and written atomically to a unique
  per-day filename, so macOS never serves a stale cached wallpaper and never shows a half-written file.
- **Wake/network:** waits for connectivity and retries with backoff (~5s/15s/45s) plus jitter.
- **Failures:** state is only saved after a successful apply, so a failed run is retried on the next run.
- **Manual choices respected:** a desktop showing an older Postcard photo or a stock macOS wallpaper
  gets today's photo. A desktop showing a picture of your own is left alone until the next new
  photo. `--force` overrides this.
- **Info and location:** once per new photo, it fetches the description and map location, saved
  in `images.json`. Details are only available for the last 7 days, and not every photo has a
  location.
- **History:** each new day it also downloads any of the last 8 days' photos that are missing, so
  `--prev`/`--next` work offline and instantly. A picked image stays on every desktop until the
  next new photo arrives (or `--today`).
- **Disk:** keeps the last 30 images (configurable). Logs rotate at 1 MB.

## Usage

```bash
postcard              # update now (no-op if today's image is already applied)
postcard --status     # current image, title, location, description, per-screen wallpaper
postcard --force      # re-download and re-apply to all screens
postcard --prev       # previous day's image (-p)
postcard --next       # next day's image (-n)
postcard --today      # back to today's image (-t)
postcard --mkt en-US  # one-off run with a specific region
```

Persistent settings:

```bash
defaults write com.durgesh.postcard market en-GB        # pin a region (default: by your location)
defaults write com.durgesh.postcard resolution 1920x1080 # default: UHD
defaults write com.durgesh.postcard keep -int 60         # images kept on disk
defaults delete com.durgesh.postcard market              # back to auto
```

Change the check interval with `POSTCARD_INTERVAL=1800 ./install.sh`.

## Multiple Spaces and Sidecar

macOS's wallpaper API only changes the current Space on each display. The agent fills each one in
the first time you switch to it each day, so you may see the old wallpaper for about half a second.
To avoid that flash, also turn on **System Settings → Wallpaper → Show on all Spaces**.

## Files

| What | Where |
|---|---|
| Binary | `~/Library/Application Support/Postcard/bin/postcard` |
| Images + state | `~/Library/Application Support/Postcard/` |
| LaunchAgent | `~/Library/LaunchAgents/com.durgesh.postcard.plist` |
| Logs | `~/Library/Logs/Postcard/postcard.log` |

## Uninstall

```bash
./uninstall.sh          # remove agent + binary, keep images
./uninstall.sh --purge  # also delete images, logs, settings
```

The photos belong to their photographers and are for personal wallpaper use only. Don't redistribute them.
