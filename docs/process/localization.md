# Localization

The macOS, iOS, Android and Windows clients support `zh-Hans`, `en`, `de`,
`fr`, `ja` and `es`. The default follows the system language. Unsupported
languages fall back to English. Language selection is persistent and separate
from photo adjustments and batch jobs.

## Language Selection

- macOS: the application menu's Language submenu, or the About window.
- iOS: the globe menu in the editor toolbar.
- Android: the language menu in About; Android 13+ also exposes the supported
  languages in the system's per-app language settings.
- Windows: the language picker in About.

Changing language refreshes the interface without replacing photo settings.
Historical error details and user-created look names retain their original
contents. Film names, RAW filenames, diagnostic details from the native engine,
CLI output and existing documentation are not translated.

Master recipe names and IDs remain unchanged. Recipe subtitles and descriptive
summaries, the shared eight-channel HSL mixer, and photo-effect controls are
localized at their display sites. Batch summaries use the selected recipe name
rather than treating every neutral LUT as an unmodified image.

## Resources

The four clients' native localization catalogs are generated from the single
source in [`Shared/strings`](../../Shared/strings/README.md). Edit that source, not
the generated tables, then run `python3 scripts/localization/generate.py`.
`python3 scripts/localization/generate.py --check` compares all output bytes and
rejects unowned catalogs; the Contracts and CI policy job runs this check on Linux.
Platform-specific terms live in the platform sources with an explicit reason.
iOS `InfoPlist.strings` remains outside this generator's scope.

Apple clients share `Shared/Localization.swift` and use their own six
`Resources/<language>.lproj/Localizable.strings` tables. iOS additionally has
localized `InfoPlist.strings` photo-permission descriptions. Chinese source
phrases are table keys; existing enum raw values remain stable and are localized
only for display. Keep format placeholders, escaped percent signs and newlines
consistent across languages.

On macOS and iOS, localized native Pickers use a locale identity on the control
itself to refresh AppKit/UIKit's cached options. Do not apply this identity to
the editor or its model. iOS denoise presets have a separate row so longer
translations do not compete with the enable switch and reset button.
Preset and export-size labels sit above their controls to leave full width for
long option names. macOS batch output uses an icon-only folder action with a
localized tooltip and accessibility name.
Localized secondary windows also use a dynamic navigation title.

Android uses an English default `values/strings.xml`, `values-b+zh+Hans` for
Simplified Chinese and the `values-de/fr/ja/es` resource qualifiers. Use
`stringResource` in Compose and `AppStrings` for model-generated messages.

Windows embeds `Resources/Localization/<language>.json`. `Loc` merges English
fallbacks with the selected table and supplies `DynamicResource` values to WPF.
Persisted `ParameterSpec.Group` and `BatchJob.LookName` values must not be
translated; localize them only at display sites.

## Focused Checks

```bash
python3 -m unittest discover -s tests -p test_localization.py
bash RawLabMac/tests/localization.sh
build/tools/dotnet/dotnet run --project RawLabWindows/tests/localization/LocalizationChecks.csproj -c Release
```

On Windows, the focused native WPF regression does not require a RAW fixture or
the processing DLL:

```powershell
dotnet run --project RawLabWindows/tests/localization-ui/LocalizationUiChecks.csproj -c Release
```

It exercises application resource refresh, tool and HSL accessibility labels,
preference persistence, and the actual editor settings across all six languages.
The Windows test uses a private language file and private window persistence,
without backing up or rewriting the user's language preference. It refuses an
existing default batch journal before startup; use an exclusive test account
without a concurrently running product process. The real App startup/resource
subscriptions and StartupUri window creation run; a test Loaded class handler
installs private state before the window's Loaded instance handler. This is not
a physical desktop or real-profile restart test.
The standalone `--default-isolation <output>` mode checks journal/staging
preservation and is also included in `RawLabWindows/tests/run-v08.ps1`.

Android has `LanguageChoiceTest` for resolution and `LanguageResourcesTest` for
actual resource selection. iOS has `EditorUITests.testLanguageSelectionPersists`
for live switching, restart persistence and return to the system language.
`testSixLanguageNativePickerAndBatchWalkthrough` checks native exposure,
white-balance, denoise and export-size options, keeps an exposure edit across
six live language changes, and exports one batch to Photos. It requires the
seeded DJI DNG used by the existing editor UI tests and an isolated simulator;
its final Done action clears the test batch task, not the exported photo.
Legacy UI tests pin Simplified Chinese independently of the host language.

When devices are shared with other tasks, build Android test APKs with
`assembleDebugAndroidTest` and install/run them with an explicit `adb -s SERIAL`.
Do not use a connected Gradle task that would enumerate other tasks' devices.

Translations are an initial version. Resource completeness and placeholders are
tested; native-speaker copy review remains outstanding.
