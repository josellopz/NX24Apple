# NX24Apple

NX24Apple is josellopz's fork of [LNPANDY/NX2Apple](https://github.com/LNPANDY/NX2Apple), powered by [seedds/nxnative](https://github.com/seedds/nxnative). The original MIT license and copyright notices remain in `LICENSE`.

## Spanish interface

The `frontend/l10n/es.json` catalog covers all 1,174 current interface keys, including build errors, extracted Switch 2 folders, controls, launch options, saves and first-run setup. Spanish is detected for system languages such as `es-CL`, `es-ES`, `es-MX` and `es-419`. To select it manually, use Settings > Language > Español. The same catalog is read by the Qt launcher and generates the iOS shell catalogs.

Engine subprocess output and game code are not translated. Changing the interface language does not change the game's language, which has its own launch option when the profile supports it.

## Branding and compatibility

The window, header, app settings row and bundle display name use NX24Apple. The Swift targets, executable name, bundle identifier and Application Support paths retain their original values to keep the installed library, preferences and saves accessible. The launcher still credits nxnative. App release checks point to `josellopz/NX2Apple`.

## Local package

The downloadable experimental package includes the release launcher binary, the engine pin plus the patch series, language files, the iOS shell sources, Python and the bundled build tools. The app always selects its included engine, even when the installed app left the experimental channel selected. Upstream engine update controls are replaced with an explanation of the included engine. The companion launch script also disables app updates for that run and refuses a second launcher process. Close another NX2Apple or NX24Apple instance before using it.

The build is signed ad hoc and is not Apple notarized. This fork does not distribute the upstream owner's signed update manifest. Use the fork's release page to download a new package. Build provenance and a SHA-256 checksum accompany the download. There are no games, keys, dumps or generated game apps in the package.

Extracted Switch 2 builds remain experimental and require an existing engine profile. See [SWITCH2-EXPERIMENT.md](SWITCH2-EXPERIMENT.md) for the supported layout, requirements and limitations.
