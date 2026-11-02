# Experimental Switch 2 folder builds on macOS

This branch connects the Mac launcher's build page to nxnative's existing extracted-game pipeline. It does not add a console runtime or new game profiles. Switch 1 package selection, keys, updates, DLC, Mac builds and iPhone builds keep their existing path.

## Use the launcher

1. Open **Build game** and change **Game source** to **Switch 2 · extracted folders (experimental)**.
2. Choose the game root shown below. Selecting `base`, `updates`, an `updates/<version>` folder, or their `exefs`/`romfs` child also works. Dropping one extracted root onto the build page selects this mode too.
3. Choose **Save to** if you want the cache and app on another local drive.
4. Install any missing dependencies in Settings, then choose **Build game**.

```text
MyGame/
  base/
    exefs/                   main, main.npdm, sdk, rtld, any subsdk modules
    romfs/                   extracted game data, optional when a complete update is present
  updates/                   optional
    458752/                  decimal title version, not a display version like 1.2.0
      exefs/
      romfs/                 complete patched tree, not a BKTR patch
  dlc/                       optional
    040074A01BF13001/         DLC title ID belonging to this base game
      0/
        romfs/
```

Keep NSP, XCI, NSZ and XCZ files outside the extracted root. The engine gives packages priority when both exist, so the launcher rejects mixed roots. ExeFS and RomFS names must match the lower-case layout above. Arbitrary separate ExeFS/RomFS locations are not combined or copied by the launcher.

The launcher reads the title ID from `main.npdm`, checks bounded META/ACI0 headers and the main executable's NSO0 header, and validates base/update identities, decimal update versions and DLC layout. It rechecks the inputs immediately before every build. These checks detect malformed layout and basic header damage, not the completeness or authenticity of a game's data. Keep all modules required by the profile, not only `main`.

The engine chooses the newest update. A dump may omit `base/romfs` when `base/exefs` identifies the game and at least one complete update provides its own ExeFS and RomFS. The launcher checks the known base and update locations without walking the asset tree. An update is always packed with its own code and data. The engine does not advertise v0 when the base RomFS is absent, so profiles needing v0 shaders fall back to deriving from the available update rather than mixing versions. Its RomFS must already include the base and update's changes, including removed files. This UI does not extract or decrypt packages and does not apply update patches. No `prod.keys` argument is supplied for an extracted build.

## Requirements

- An Apple silicon Mac. The launcher itself targets macOS 13 or later. The pinned NVN toolchain requires Xcode 27.2 and the corresponding macOS version (upstream documents macOS 26.6 or later), plus the Metal toolchain component.
- Python 3.12 or newer and the engine's dependencies. Released NX2Apple bundles Python and most tools. A source checkout needs the setup described in [BUILDING.md](BUILDING.md). The dependency checker remains responsible for the required tools, including .NET 10.
- A synced engine with `scripts/pack_dump.py` and the dump path in `scripts/build_ipa_from_nsp.py`.
- An existing engine profile at `dm/games/<NPDM title ID>/game.tsv`. The engine cannot survey an unknown extracted game into a provisional profile because that survey reads NSPs.
- Enough local disk space for complete RomFS images, intermediate files and shader caches. The engine performs its disk and compiler checks. Keep output outside cloud folders.
- Your own already extracted game files. No game data or keys are included in this branch or its tests.

The selected Mac has an M3 Pro and Xcode 27.2 was detected during development. This does not establish game compatibility or performance on that chip.

## Build behavior

The folder root is passed directly to the existing build script with `--platform mac-app --progress json`. No NSP staging, key argument, iPhone framework step or extra RomFS archive step is used. The cache is `<Save to>/<NPDM title ID>_build` and the output is `<Save to>/<NPDM title ID>.app`. With no Save to choice, both go under the game root. The generated app is recorded in the existing library and the extracted source is remembered for rebuilds. Switching input modes preserves the current package selection.

Build progress, logs, Stop and engine errors use the existing process-group pipeline. The launcher reports missing folders, unreadable files, malformed headers, invalid versions and title mismatches before launch. An older engine or missing profile gets an actionable message before compilation. An engine failure still appears with its log and exit status. A successful script must leave the expected app for the launcher to mark the build done.

## Engine evidence and limits

Implementation was checked against NX2Apple `70a196ea497dab0e3ea59a40ee9d99666dc2e854` and its pinned nxnative `cd859c38a8f8890ddbb57a23d6f45e23ba9e6651`, with the repository's existing patch queue. Relevant code is `scripts/pack_dump.py`, `dump_folder`, `scan_dump`, `extract_dump` and the dump branch of `main` in `scripts/build_ipa_from_nsp.py`.

The folder contract already exists at that pin. A comparison with nxnative HEAD `65501fbbaf8526f7aab0a1edd028135888590f8e` found newer runtime, graphics and game-profile changes, including additional Switch 2 profiles. This branch keeps NX2Apple's engine pin. A small pending engine patch adds update-only RomFS discovery and preserves available version identities. A game documented on newer upstream may therefore have no profile in this checkout. Update the engine through the project's normal process to gain those changes.

The pinned tree includes Donkey Kong Bananza's `040074A01BF12000` profile. A profile's presence is not proof that every version works. The engine owns version/build matching, shader translation and runtime compatibility. Dump builds lack control data and can produce a blank app icon. Switch 2 iPhone/iPad builds are disabled in this experiment. M3 Pro gameplay, real-game compilation, rendering, controllers and performance remain unverified.

## Validation

Synthetic fixtures cover root/base normalization, NPDM-derived identity, truncated headers, invalid offsets, wrong base/update IDs, numeric version sorting, malformed/duplicate update versions, DLC ownership/layout and mixed package rejection. Store tests cover no-keys readiness, Mac-only enforcement, source removal before launch, direct folder input, output/cache paths, engine/profile gates and command construction. Existing package, library and install tests are run for regressions. Native captures show the input and target cards in English, Chinese and German.

The engine's existing `test_nsp_dump.py` suite packs synthetic RomFS trees and checks that a dump needs no keys. This is a pipeline contract test, not a commercial game build. No real game files were supplied or built during this work.

### Update-only RomFS follow-up

The original engine assumed `base/romfs` always exists. The carried patch accepts a complete update when it is absent and removes unavailable v0 from the versions offered to profile selection. Tests use synthetic directories with and without base data, preserve update numbers and verify that missing RomFS is a handled error. No game files are moved, copied or relabelled. This is an input-layout fix, not a new Pokopia profile. The patch is pending upstream submission and is included for review in this fork.
