---
name: kryoas-release
description: Ship a Kryoas Control Station update (Internal / Internal · UIN / Client / Client · UIN builds) to the Kryoas store with one command, so phones get the in-app update popup. Load for any Kryoas store release, publish, version bump, APK signing, or "push an update" request, and when an in-app update does not show up on a phone.
---

# Kryoas release (one command)

Read `VERSIONING.md` in the repo first. It explains versions (`1.4.0`, `1.5.0-test.2`) and the 4 builds.

```bash
kryoas-release all-internal "notes" --test   # 1.5.0-test.N to internal + internal-uin
kryoas-release all-internal "notes"          # 1.5.0 to internal + internal-uin
kryoas-release all-client "notes"            # 1.5.0 to client + client-uin
kryoas-release client-uin "notes"            # just one build
kryoas-release internal,client "notes"       # any comma-separated list
kryoas-release all-internal "..." --dry-run  # build + package + check only
kryoas-release all-client "..." --mandatory  # users cannot press "Later"
```

- **Builds:** `internal`, `internal-uin`, `client`, `client-uin`. Each name is also its store channel.
- **Repo:** one repo, `C:\Users\pc\qgroundcontrol-v4.4.1`. The `KRYOAS_REPO` environment variable overrides it.
- **Version:** `kryoas-version.txt` in the repo. Bump it by editing and committing; the tool never edits it.
- **Where to run it:** Git Bash on the build PC. `kryoas-release` is `~/bin/kryoas-release`, which runs `scripts/kryoas-release.sh`.

## What it does (stops at the first problem)
1. **Source tree.** Client releases need a clean tree and warn when not on `main`. Internal releases may have uncommitted changes, and the app then shows `+changes`.
2. **Version.** Reads `kryoas-version.txt` and the live `apps.json`. The build number is the highest one already used for this version on any channel, plus 1. All builds in this run share that number:
   - versionCode = `1 MM mm pp BBB`;
   - the name is `X.Y.Z`, or `X.Y.Z-test.BBB` with `--test`.
3. **Refuses when:**
   - `--test` is used on a client build;
   - a channel already has this exact version, so it needs a PATCH bump;
   - a channel already has a newer version;
   - the channel doesn't exist in `apps.json`;
   - a client release's version was never on `internal`/`internal-uin` (override with `--no-internal-first`).
4. **Builds each one.** Sets `KRYOAS_TRACK` / `KRYOAS_UIN` / `KRYOAS_BUILD` / `KRYOAS_TEST`, then:
   - always runs `mingw32-make qmake`, then `mingw32-make -j8` in `build/android-release-64`;
   - only `KryoasBuildInfo.cc` recompiles between builds;
   - copies the `.so` by hand, then `androiddeployqt --release --gradle`.
5. **Checks each APK.** Package, versionCode and versionName, label (`Kryoas` or `Kryoas Internal`), channel meta-data, updater permission, not debuggable, and that the `.so` in the APK is the fresh build.
6. **Signs all of them in one WSL window.** The password is typed once there; it never reaches this transcript or a log. Then checks every certificate is the store key `9be7fdc0…`.
7. **Publishes.** Runs `~/kryoas-store/publish-app.sh <channel> <name> <apk> <notes>` per build, retrying the push on a slow link.
8. **Checks live.** Polls the raw `apps.json` for the new versionCode on every channel and compares SHA-256 with the signed APK.
9. **Tags locally** `kryoas-<name>`. Push the tag only when the user asks.

Outputs are kept in `C:\Users\pc\kryoas-releases\kryoas-<name>\`: unsigned and signed APKs, and per-build qmake/make/deploy logs.

## When Claude runs it
- Run it in the background. A first build takes 10–40 min; later builds in the same run take a few minutes each.
- Tell the user a WSL window will ask for the keystore password. Never ask for it in chat.
- Offer `--dry-run` first after big merges. It doesn't need the store channels to exist.
- An FCM nudge is optional: send the data message `{"type":"APP_UPDATE"}` to topic `app-update-<channel>`.

## Rules
- **Never publish a Play build.** The script unsets `KRYOAS_PLAY_BUILD`.
- **Every store APK is signed with the store key** (`9be7fdc0…`). Never tell users to uninstall to get past a signer mismatch: uninstalling erases their data.
- **versionCode only goes up.** A released version is never reused: fixes are a PATCH bump.
- **UIN and non-UIN builds of a track share a package.** Only the channel keeps a phone on its build. To switch a phone between UIN and non-UIN, install the other APK by hand.
- **Internal and Client are separate packages.** They install side by side; a phone can't move between them by update.

## Old channels (before 1.0.0)
- **`kryoas-v2`** holds the old V2 client phones on 4.4.1-x. The first client release uses `--bridge` (`kryoas-release client-uin "…" --bridge --no-internal-first` if needed), which also publishes the Client · UIN APK there. After installing it, those phones follow `client-uin`.
- **`kryoas-v1`** held the internal phones. Internal is now its own package, so those phones get Kryoas Internal installed by hand once; then the channel is retired.
- **`kryoas-v3`** is experiments and is not wired into this tool yet.

## Troubleshooting
- **"Update available" not showing right after a publish:** GitHub's raw CDN caches `apps.json` for about 5 min.
- **gradle: "No matching client found for package name com.kryoas.controlstation.internal":** the Internal app isn't in `android/google-services.json`. It must be registered in Firebase project `age-krayos` and the file updated.
- **gradle: "kryoas-build.properties is missing":** qmake hasn't run in that build folder. Run `mingw32-make qmake`.
- **"keystore password was incorrect":** a typo. You get 3 tries.
- **Push HTTP 408:** the script retries once. Otherwise the commit is in `~/kryoas-store`; run `git push` there later.

## Backup copy
A copy of this skill (the scripts, plus this file as README.md) is in the kryoas-store repo under `tools/kryoas-release/`. After changing the script here, copy it there too and push.
