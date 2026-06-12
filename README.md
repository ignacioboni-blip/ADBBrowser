# ADB Browser

A native macOS (SwiftUI) file browser for Android devices over adb. Built for a
rooted Pixel 10, but works with any device that has USB debugging enabled —
root just unlocks more of the filesystem.

Commands run through a persistent `adb shell` per device (a persistent root
shell when su is available), so browsing doesn't pay process-spawn + USB
handshake + Magisk `su -c` fork on every operation. One-shot invocations remain
as the fallback path and for root probes.

## Features

- **Live device presence**: the sidebar shows your phone's actual screen
  (refreshed every 5 s), battery + charging state, and free storage.
- **Wallpaper-synced theming**: the app reads the phone's Material You seed
  color (`settings get secure theme_customization_overlay_packages`) and tints
  the whole UI with it — accents crossfade when the phone's theme changes.
- Finder-style browser: breadcrumb path pills (⇧⌘G to type a path directly),
  back/forward/up, sortable columns (name, size, modified, permissions, owner),
  filter field, hidden-files toggle.
- **Live transfer progress**: pulls and pushes show a per-file progress bar and
  MB/s in the status strip (local file growth for pulls, remote `stat` polling
  for pushes).
- **⌘K command palette**: fuzzy-jump to places, recent folders, and entries in
  the current folder; type a `/path` to go there directly; run actions; or
  search the device recursively (`find` under the current folder, root-aware).
- **Gallery view (⌘2)** with real photo thumbnails: images are pulled over adb
  (3 at a time, ≤25 MB), downsampled to 256 px, and cached in
  ~/Library/Caches/AdbBrowse keyed by path+size+mtime. The list view shows the
  same thumbnails at icon size.
- **Quick Look**: select files and hit Space (or ⌘Y / context menu) — files are
  pulled to a temp folder and previewed in the native Quick Look panel.
- **Zoom navigation**: opening a folder zooms in, going back zooms out
  (spring-animated transitions).
- **Storage map (⌘3)**: DaisyDisk-style sunburst of the current folder, built
  from one `du -a -k -d 3` pass. Wedge colors derive from the phone's accent;
  the chart sweeps in radially, hover shows name/size/%, click a wedge to dive
  in, click the center to go up. Results are cached per folder per session.
- **Transfer flight**: starting a pull sends a file icon arcing across the
  window into the sidebar phone (and out of it for pushes).
- **Root keyline**: browsing paths a plain adb shell can't reach (outside
  /sdcard and /storage) draws an amber keyline around the view and ignites the
  root badge — you always know when you're acting as superuser.
- **Drag out to Finder**: drag any file from the list or grid straight into
  Finder; it's pulled over adb when the drop lands.
- **Cancellable transfer queue**: batches queue up serially; the status strip
  shows progress, speed, an × to cancel, and how many batches are waiting.
- **Overwrite protection**: paste, upload, and download prompt with
  Replace / Keep Both / Skip when names collide (Keep Both auto-numbers
  Finder-style).
- **Get Info (⌘I)**: path, size (on-demand `du` for folders), modified time,
  symlink target, and editable owner/group + rwx permission checkboxes with an
  octal field. Note: chmod on /sdcard is a no-op — Android's emulated FUSE
  filesystem forces its own permissions there; it works on real filesystems
  like /data.
- **Hot-plug detection**: `adb track-devices` runs in the background, so
  plugging in or unplugging a phone updates the app within half a second.
- **Instant revisits**: listings are cached per folder — going back shows the
  cached list immediately while a silent refresh runs behind it.
- **Folders-first + natural sort**: directories group on top (toggleable in
  the ⋯ menu) and names sort Finder-style ("IMG_2" before "IMG_10").
- **Drop an APK to install**: dropping .apk files from Finder asks whether to
  install them (`adb install -r`, so updates work too) or just copy them like
  regular files. Mixed drops upload the non-APK files as usual.
- **Root auto-detection** per device, shown in the status bar:
  1. adbd already running as root → plain commands
  2. `su -c` available (Magisk/KernelSU) → every command wrapped in su
  3. neither → plain shell (you can still browse /sdcard)
- File operations on the device: new folder, rename, delete (with confirmation),
  and copy/cut/paste between folders (⇧⌘C / ⇧⌘X / ⇧⌘V or context menu).
- Transfers:
  - **Download to Mac…** from the context menu (multi-selection supported)
  - Double-click a file to pull it to a temp folder and open it
  - Drag files/folders from Finder onto the window to upload, or use
    "Upload Files Here…"
  - Root-only paths transparently stage through `/data/local/tmp` with su when
    adbd can't read/write them directly.
- Quick places menu (⋯): /sdcard, Download, DCIM, /data/data, /.
- Multiple devices supported via the toolbar picker.
- Settings (⌘,): adb binary path override, start folder.

## Build & run

```sh
swift run                  # debug run from the terminal
./scripts/make_app.sh      # builds build/AdbBrowse.app (release, ad-hoc signed, with icon)
open build/AdbBrowse.app
```

To make it launchable from Spotlight/Launchpad, copy `build/AdbBrowse.app` to
/Applications. The icon is generated by `swift scripts/make_icon.swift` →
`assets/AppIcon.icns` (already committed; re-run only to change the design).

The ⋯ menu has a Density picker (Comfortable/Compact) that tightens list rows
and grid cells.

Requires macOS 14+ and Xcode command line tools. adb is auto-detected from
`$ANDROID_HOME`, `~/Library/Android/sdk/platform-tools`, or Homebrew.

## Notes

- The first root detection on a fresh device may pop a Magisk "grant" dialog on
  the phone — approve it (the probe waits up to 45 s).
- `Delete` uses `rm -rf` on the device and cannot be undone.
- Paste-copy of very large trees runs `cp -a` on-device and may take a while;
  the status bar shows a spinner while any operation is running.

## Layout

| File | Purpose |
| --- | --- |
| `Sources/AdbBrowse/AdbClient.swift` | adb process wrapper, root detection, pull/push with su staging |
| `Sources/AdbBrowse/Models.swift` | device/file models and the toybox `ls -lA` parser |
| `Sources/AdbBrowse/BrowserViewModel.swift` | navigation history, selection, clipboard, async operations |
| `Sources/AdbBrowse/ContentView.swift` | table UI, toolbar, context menus, drag-and-drop, sheets |
| `Sources/AdbBrowse/SettingsView.swift` | adb path + start folder settings |
| `scripts/make_app.sh` | wraps the release binary into AdbBrowse.app |
