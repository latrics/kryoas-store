---
name: kryoas-release
description: Ship a Kryoas Control Station update (V1 or V2) to the Kryoas store with one command, so phones get the in-app update popup. Load for any Kryoas store release, publish, version bump, APK signing, or "push an update" request, and when an in-app update does not show up on a phone.
---

# Kryoas release (one command)

```bash
kryoas-release v2 "What changed, in words the pilots understand"
kryoas-release v1 "..."                  # Kryoas-V1 (no MAVLink signing)
kryoas-release v2 "..." --mandatory      # users cannot press "Later"
kryoas-release v2 "..." --dry-run        # build + package + verify only
kryoas-release v2 "..." --skip-build     # repackage the already built .so
kryoas-release v2 "..." --code 664401020 # pick the versionCode yourself
```

Run it in **Git Bash** on the build PC. `kryoas-release` is `~/bin/kryoas-release`, which runs
`~/.claude/skills/kryoas-release/scripts/kryoas-release.sh`.

## What it does (stops at the first problem)
1. **Version.** Reads the channel's highest versionCode from the live `apps.json` and the
   manifest's versionCode. Takes the larger, adds 1, and derives the name from it
   (664401018 → `4.4.1-18`).
2. **Build.** Runs `mingw32-make -j8` in `<repo>/build/android-release-64`. It first re-runs
   qmake if a `.pro`/`.pri` is newer than the Makefile, because qmake doesn't re-run by itself.
3. **Package.** Writes the version into `android/AndroidManifest.xml` after the build, because
   the post-link `update_android_version.sh` overwrites it. Copies the fresh `.so` into
   `android-build/libs/arm64-v8a`, because `make install` from Git Bash writes to
   `C:\C\Users\...`. Then runs `androiddeployqt --release --gradle`.
4. **Check the APK.** It checks:
   - versionCode and package name;
   - the updater permission;
   - the channel meta-data (`kryoas-v1`/`kryoas-v2`);
   - that it is not debuggable;
   - that the `.so` inside the APK equals the freshly built one.
5. **Sign.** Opens a separate WSL window: zipalign, then `apksigner` with the store keystore
   `~/keystores/kryoas-release.keystore`. The user types the password there, with 3 attempts.
   The password never enters the transcript or any log. The script then checks the
   certificate is the store key `9be7fdc0…`.
6. **Publish.** Pulls `~/kryoas-store`, then runs `publish.sh` (v2) or
   `publish-app.sh kryoas-v1 <name>` (v1). These write `versionCode`, `sha256`, `size` (and
   `minVersionCode` with `--mandatory`), commit and push. If the push stalls, it retries with
   HTTP/1.1 and a long low-speed timeout.
7. **Check live.** Polls `raw.githubusercontent.com/.../apps.json` until the new versionCode
   shows, then checks the live APK's SHA-256 matches the signed file.

Outputs are kept in `C:\Users\pc\kryoas-releases\<channel>-<name>\`: unsigned and signed APK,
make/deploy logs, `sign.status`.

## When Claude runs it
- Run it in the background, because the build takes 10–40 min. Tell the user that a WSL
  window will ask for the keystore password. Never ask for the password in chat.
- A `--dry-run` first is cheap insurance after big merges.
- Afterwards, the manifest in the repo holds the released version. Remind the user to commit
  it; don't commit without being asked.
- An FCM nudge is optional. Send a data message `{"type":"APP_UPDATE"}` to topic
  `app-update-<channel>` to make phones check right away instead of within 6 h.

## Rules
- **Never publish a Play build.** Play builds use `KRYOAS_PLAY_BUILD=1`, which strips the
  updater; the script unsets that variable. Never re-sign a Qt Creator Play APK for the store.
- **Every store APK must be signed with the store key** (`9be7fdc0…`). Another key means
  phones refuse the update. Never tell users to uninstall to get past that: uninstalling
  erases their data.
- **versionCode must only go up.** `publish*.sh` refuses otherwise (`ALLOW_SAME_CODE=1`
  overrides; only use it to replace a broken upload nobody installed).
- **All variants share the package** `com.kryoas.controlstation`. The channel meta-data is
  what keeps V1 phones on V1 and V2 phones on V2.
- **Repos:** v1 = `C:\Users\pc\Kryoas-V1`, v2 = `C:\Users\pc\qgroundcontrol-v4.4.1`. V3 is
  not wired up: there is no repo/build dir known to the tool.

## Troubleshooting
- **"Update available" not showing right after a publish:** GitHub's raw CDN caches
  `apps.json` for about 5 min. Use Profile → Check for updates after that.
- **A phone with a debug-signed or V1-debug app** can't take a store update. It needs a
  one-time uninstall and reinstall. Back up first with
  `adb exec-out "run-as com.kryoas.controlstation tar -cf - ." > backup.tar`, which only
  works for debug builds.
- **"keystore password was incorrect"** in the window: it's a typo. You get 3 tries per run.
- **Build fails with `undefined reference` to a class that exists:** stale Makefile. Run
  `mingw32-make qmake` with `ANDROID_NDK_ROOT` set; the script does this when a
  `.pro` changes.
- **Push HTTP 408:** the script retries once. If it still fails, the commit is in
  `~/kryoas-store`; run `git push` there later.

## Installing on the build PC
This folder is the backed-up copy. The working copy lives in
`C:\Users\pc\.claude\skills\kryoas-release\` (the Claude Code skill), with
`kryoas-release` copied to `C:\Users\pc\bin\` (on Git Bash's PATH). After
changing the script, update both copies.

To set it up on a fresh PC:
1. Copy `kryoas-release.sh` and `sign-window.sh` to `~/.claude/skills/kryoas-release/scripts/`
   and `README.md` there as `SKILL.md`.
2. Copy `kryoas-release` to `~/bin/`.
3. Check the paths at the top of `kryoas-release.sh` (repos, Android SDK/NDK, Qt), and that
   WSL has `zipalign`, `apksigner` and `~/keystores/kryoas-release.keystore`.
