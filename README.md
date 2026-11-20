# Kryoas store

This repo is where Kryoas Control Station APKs are published.

- **Phones update from it automatically.** The app's built-in updater reads `apps.json` from here.
- **People download from it.** The download page is <https://latrics.github.io/kryoas-store/>.

No Google Play is involved.

The app's version and build scheme is described in `VERSIONING.md` in
[KryoasControlStation](https://github.com/latrics/KryoasControlStation). In short:

- **Version** = how new the code is: `1.4.0`. Internal test builds are `1.5.0-test.2`.
- **Build** = who the app is for and whether UIN (MAVLink signing) is on.
- **Each build has its own channel** in this store, and a phone only ever updates from the channel of the build it has installed.

## Channels

| Channel | App on the phone | Package | For | UIN |
|---|---|---|---|---|
| `internal` | Kryoas Internal | `com.kryoas.controlstation.internal` | our own flying and testing | off |
| `internal-uin` | Kryoas Internal | `com.kryoas.controlstation.internal` | our own testing of UIN drones | on |
| `client` | Kryoas | `com.kryoas.controlstation` | clients | off |
| `client-uin` | Kryoas | `com.kryoas.controlstation` | clients with UIN drones | on |
| `kryoas-v1` | (old) | `com.kryoas.controlstation` | old internal app, 4.4.1. Retired | off |
| `kryoas-v2` | (old) | `com.kryoas.controlstation` | old client app, 4.4.1. Its phones move to `client-uin` | on |
| `kryoas-v3` | (old) | `com.kryoas.controlstation` | experiments. Not part of the 1.0 system yet | — |

Internal and Client are separate apps: they can sit side by side on one phone. A build with UIN and the
same build without UIN are the same app (same package), so a phone switches between them only by
installing the other APK by hand.

## What is in this repo

| Path | What it is |
|---|---|
| `apps.json` | **The catalogue.** The download page and every phone's updater read it. One entry per channel. |
| `apps/<channel>/<version>/<file>.apk` | The published APKs, e.g. `apps/client-uin/1.0.0/kryoas-client-uin-1.0.0.apk`. |
| `icons/` | Channel icons for the download page. |
| `index.html` | The download page. It groups channels by their `section` (current builds, experiments, old apps). |
| `publish-app.sh` | Adds one signed APK to one channel. It updates `apps.json`, then commits and pushes. |
| `tools/kryoas-release/` | Backup copy of the one-command release tool (the live copy is in the build PC's Claude skills). |
| `publish.sh`, `fdroid/` | **Retired** pre-1.0 F-Droid flow for the old V2 app. Kept online as it is so nothing breaks; `publish.sh` refuses to run unless `KRYOAS_LEGACY_FDROID=1`. |

### `apps.json` entries

```json
{
  "id": "client-uin",                       // channel = the app's com.kryoas.update.channel
  "name": "Kryoas Client · UIN",
  "tagline": "For clients with UIN drones · MAVLink signing on",
  "section": "Kryoas 1.0 and later",        // heading on the download page
  "icon": "icons/client-uin.svg",
  "minVersionCode": 1010100004,              // optional: below this, the update can't be postponed
  "versions": [                              // newest first
    {
      "version": "1.1.0",
      "versionCode": 1010100004,
      "file": "apps/client-uin/1.1.0/kryoas-client-uin-1.1.0.apk",
      "sha256": "…", "size": 67271985,
      "description": "What changed, in words the pilots understand",
      "date": "2026-12-01"
    }
  ]
}
```

`publish-app.sh` writes these fields; nobody should need to edit them by hand. The updater only acts
on `versions[0]`, and only if it has `versionCode` and `sha256`.

## How a phone gets an update

1. **When it checks:** at launch, when the user returns to the app (at most every 30 min), every 6 h
   in the background, and from Profile → *Check for updates*. It reads
   `raw.githubusercontent.com/latrics/kryoas-store/main/apps.json`.
2. **What it offers:** the newest version of its own channel, if that `versionCode` is higher than
   the installed one.
3. **What the user sees:** a notification and a popup. The popup never appears while a vehicle is
   armed. "Later" is hidden when the update is mandatory.
4. **Checks before installing:** the download resumes if the connection drops. The SHA-256, package
   name, versionCode and signing key are all checked before Android's install screen opens.
5. **What the update keeps:** it is an in-place update, so plans, logs, settings, activation and the
   upload queue all stay.

Every APK must be signed with the store key (certificate SHA-256 `9be7fdc0…`). Never tell a user to
uninstall to get past a signing problem: uninstalling erases their data.

## How to release

On the build PC, in Git Bash:

```bash
# 1. bump kryoas-version.txt in KryoasControlStation and commit (e.g. 1.1.0)
kryoas-release all-internal "notes" --test   # 1.1.0-test.N → internal + internal-uin
kryoas-release all-internal "notes"          # 1.1.0 → internal + internal-uin
kryoas-release all-client   "notes"          # 1.1.0 → client + client-uin
```

The tool:
1. builds each APK;
2. checks the package, version, channel, label and native library;
3. signs every APK in one WSL window, where you type the keystore password once;
4. runs `publish-app.sh` for each channel;
5. waits until `apps.json` on GitHub shows the new version;
6. tags the commit `kryoas-<version>`.

| Option | What it does |
|---|---|
| `--dry-run` | Builds and checks only. Nothing is signed or published. |
| `--mandatory` | Users can't press "Later". |
| `--bridge` | Also publishes Client · UIN to the old `kryoas-v2` channel. |
| `--no-internal-first` | Allows a client release of a version the internal channels never had. |

It refuses a client release that hasn't been on an internal channel first, unless you pass `--no-internal-first`.

**By hand** (only if the tool can't be used), with an APK already signed with the store key:

```bash
cd ~/kryoas-store && git pull --rebase
./publish-app.sh client-uin 1.1.0 /path/kryoas-client-uin-1.1.0.apk "notes"   # MANDATORY=1 in front to force
```

**Refusals:** `publish-app.sh` refuses a channel that isn't in `apps.json`, and a versionCode that isn't
higher than the channel's newest. `ALLOW_SAME_CODE=1` overrides the versionCode check; use it only to
replace a broken upload nobody installed.

**Nudge phones right away (optional):** send an FCM data message `{"type": "APP_UPDATE"}` to topic
`app-update-<channel>`, e.g. `app-update-client-uin`. Otherwise phones find the update within 6 h.

## Moving existing phones onto 1.0

- **Old V2 client phones** (`kryoas-v2`): make the first client release with `--bridge`:

  ```bash
  kryoas-release client-uin "…" --bridge --no-internal-first
  ```

  The phones get Kryoas Client · UIN 1.0.0 as a normal in-app update, keeping all their data. After
  that they follow `client-uin`.
- **Old V1 internal phones** (`kryoas-v1`): Kryoas Internal is a different app, so install it by
  hand once.
  - **Activate it:** the old app then goes drain-only, finishes its uploads and can be uninstalled.
  - **Plans and projects:** Kryoas Internal keeps them in `KryoasInternal/` on the phone, not
    `KryoasControlStation/`.

## Adding a channel

1. Add an entry to `apps.json` with `id`, `name`, `tagline`, `section`, `icon` and `"versions": []`.
2. Add an icon in `icons/`.
3. Commit and push.

The app side must set the same channel name. In KryoasControlStation that happens in `QGCCommon.pri` and
`android/build.gradle`. An empty channel shows as "Coming soon".

## Troubleshooting

- **The update isn't offered right after publishing:** GitHub's raw cache can take about 5 minutes.
  Check `raw.githubusercontent.com/latrics/kryoas-store/main/apps.json`, then use Profile →
  *Check for updates*.
- **`git push` times out (HTTP 408) on an APK:** the commit is already local
  (`git log origin/main..HEAD`). Retry the push:

  ```bash
  git -c http.version=HTTP/1.1 -c http.lowSpeedTime=600 push origin main
  ```

  `kryoas-release` does this retry once by itself.
- **The download page looks stale:** GitHub Pages lags a few minutes behind `main`. Hard-refresh the page.
