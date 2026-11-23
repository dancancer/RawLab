---
name: "RawLab"
description: "Photo-first dark native RAW editor design system across macOS, Windows, iOS / iPadOS, and Android."
colors:
  canvas-dark: "#1c1c1e"
  surface-low: "#212124"
  surface-base: "#272729"
  surface-high: "#303033"
  win-window-surface: "#181a1e"
  win-tree-surface: "#232326"
  win-selected-surface: "#34332d"
  accent-yellow: "#f2ce48"
  accent-ink: "#252110"
  accent-cyan: "#63cdd6"
  outline-subtle: "#444449"
  text-primary: "#eeeef2"
  text-secondary: "#b9b9c3"
  error-soft: "#ffb09b"
rounded:
  mac-thumbnail: "3pt"
  mac-control: "4pt"
  mac-film-selection: "6pt"
  mac-overlay: "8pt"
  win-tile: "3px"
  win-control: "5px"
  win-popup: "6px"
  win-banner: "8px"
  ios-film-artwork: "4pt"
  ios-film-selection: "6pt"
  ios-number-tile: "6pt"
  ios-overlay: "8pt"
  android-tile: "4dp"
  android-control: "6dp"
  android-overlay: "10dp"
spacing:
  ios-gap-compact: "4pt"
  ios-gap-standard: "8pt"
  ios-gap-controls: "12pt"
  ios-inset-controls: "16pt"
  mac-canvas-margin: "12pt"
  win-canvas-margin: "16px"
  android-grid-gap: "8dp"
components:
  mac-slider-thumb:
    size: "14pt"
  mac-hsl-swatch:
    size: "18pt"
  mac-histogram-plot:
    height: "68pt"
  win-slider-thumb:
    size: "14px"
  win-hsl-swatch:
    size: "20px"
  win-histogram-plot:
    height: "92px"
  ios-tool-grid-row:
    height: "52pt"
  ios-group-bar:
    height: "48pt"
  ios-draft-bar:
    height: "48pt"
  ios-hsl-swatch:
    size: "19pt"
  ios-histogram-header:
    height: "44pt"
  ios-film-artwork:
    rounded: "{rounded.ios-film-artwork}"
  ios-film-selection:
    rounded: "{rounded.ios-film-selection}"
  ios-status-container:
    rounded: "{rounded.ios-overlay}"
  android-touch-target:
    size: "48dp"
  android-hsl-swatch:
    size: "19dp"
  android-shutter-button:
    size: "68dp"
---

# Design System: RawLab

## Overview

**Creative North Star: "RawLab photo-first editor"**

RawLab is an Operate-mode native RAW and photo editor spanning four native clients: **macOS** (SwiftUI/AppKit), **Windows** (WPF), **iOS / iPadOS** (SwiftUI/UIKit), and **Android** (Jetpack Compose / Material 3). Across every screen size and operating system, the photograph leads: restrained dark neutral-gray surfaces eliminate viewing glare, functional yellow marks active controls and adjusted values without decorative competition, and native platform ergonomics shape each workspace while preserving shared color and parameter semantics.

RawLab targets **sighted photographers working at standard OS text sizes**; low-vision extreme large-text reflow and screen-reader-first (VoiceOver/TalkBack/UIA) flows are outside active design scope. Controls support Simplified Chinese, English, German, French, Japanese, and Spanish while preserving proper film simulation names.

Related interaction specifications and asset registries live in [compact controls](docs/design/editor-workspace/compact-controls.md), [dedicated mobile workspaces](docs/design/editor-workspace/mobile-workspaces.md), [mobile camera workspaces](docs/design/camera-transfer/android-camera-ui.md), [edited-photo previews](docs/design/editor-workspace/edited-photo-previews.md), and the [design asset registry](docs/design/README.md). Clickable design prototypes remain reference expressions and do not replace implemented source behavior or device acceptance.

**Key Characteristics:**
- A dark neutral photo workspace with functional yellow for active selection, modified values, and adjustment fills.
- Desktop three-column Edit / Select / Preview workspaces (macOS & Windows) paired with mobile two-level dedicated tool workspaces (iOS & Android).
- Native platform controls, monospaced/tabular numeric readouts, and explicit draft transactions without decorative card stacks.
- Cross-client HDR editing, monitoring, and luminance histograms alongside mobile wireless Sony camera import and tethering.

## Colors

Achromatic neutral-dark surfaces anchor color judgment so the photograph's own chroma and contrast remain uncontested, while functional yellow signals selection, edits, and progress.

### Primary
- **Functional Yellow** (`#F2CE48` on Windows & Android; `.yellow` / `NSColor.systemYellow` / `UIColor.systemYellow` on Apple platforms): Active tabs, selected tool outlines, modified parameter values and dots, ruler indicator needles, slider active fills, crop handles, and primary draft/export confirmations. Paired with `#252110` dark ink when used as a solid fill on Windows and Android.

### Secondary
- **Brand Cyan** (`#63CDD6`): Supporting secondary role in the dual-frame RawLab icon (yellow + cyan overlap) and Android secondary scheme token. Never used as competing editor chrome.

### Neutral
- **Canvas Dark** (`#1C1C1E` on Windows & Android; `NSColor(white: 0.12)` / `Color(white: 0.12)` on Apple platforms): Photo editing and contact-sheet background.
- **Layered Control Surfaces** (`#212124` low inputs/tiles, `#272729` inspector/dock surfaces, `#303033` raised bars/headers on Windows & Android; native `.windowBackgroundColor` / `.systemBackground` / `.secondarySystemBackground` on Apple platforms): Separate chrome from the photo canvas via quiet tonal steps and `1 px`/`1 pt` borders (`#444449` / `.separatorColor`).
- **Text & Semantic Error** (`#EEEEF2` primary, `#B9B9C3`/`#B1B1BC` secondary/muted, `#FFB09B`/`#FFAB92` soft error on mobile/Windows; `.primary`/`.secondary`/`.systemRed` on Apple platforms): Readable standard-contrast typography and non-glaring diagnostics.

### Shared Visualization & Artwork Semantics
- **Film Icons**: Square, flat front-label artwork inspired by documented Fujifilm packaging; preserve each reference's palette and typography without perspective boxes, sides, or generic all-green styling. Concepts without physical packaging use explicitly marked concept labels.
- **RGB Histogram**: 256 bins per channel, shared linear peak scaling, filled RGB/CMY/neutral-gray overlaps representing the current sRGB output.
- **HDR Luminance Histogram**: 256 `log1p`-scaled luminance bins spanning `-8…+8 EV`, with a solid white `0 EV` reference-white marker (0.5 position) and a dashed yellow current display-headroom marker (both backed with black contrast strokes).
- **Clipping & HDR False Color**: Highlight clipping red `RGBA(255, 0, 0, 160)` and shadow clipping blue `RGBA(0, 130, 255, 160)`. HDR False Color maps linear luminance `y` to magenta-red `(1.0, 0.0, 0.35)` when `y > headroom`, amber `(1.0, 0.6, 0.0)` when `1.0 < y <= headroom`, deep blue `(0.02, 0.15, 0.7)` when `y <= 0.01`, and neutral gray `(0.35, 0.35, 0.35)` for SDR midtones.
- **HSL Swatches**: Eight named channels (Red `#E65C5A`, Orange `#E8A04F`, Yellow `#DFCE51`, Green `#7BBA64`, Aqua `#68C8C7`, Blue `#5C89DF`, Purple `#A075D2`, Magenta `#CB6EAF` on mobile; matching named WPF colors on Windows and system swatches on macOS).

### macOS
- Editor, Batch Selection, and Batch Export windows force `.preferredColorScheme(.dark)`; utility windows (About, Software Update, LUT/DCP import dialogs, Preset/Transfer sheets) inherit parent or system appearance.
- Numeric fields use `NSColor(calibratedWhite: 0.13, alpha: 1)` fill with `.systemYellow` border when active/stepping and `.systemRed` when invalid. Active workspace-mode toolbar pills use neutral `Color.primary.opacity(0.14)`, while subtle yellow washes (`0.08–0.18` opacity) mark selected folders, tiles, film cards, grading zones, and curve points. Drag-and-drop drop targets highlight with system `Color.accentColor`.
- Canvas badges and overlays use `.black.opacity(0.65–0.72)` or `.regularMaterial`.

### Windows
- Explicit dark WPF palette applied dynamically across 33 brushes: `WindowSurface #181A1E`, `CanvasSurface #1C1C1E`, `InputSurface #212124`, `TreeSurface #232326`, `OverlayPaper #24272D`, `Surface #272729`, `PopupSurface #292C32`, `RaisedSurface #303033`, `HoverSurface #41454D`, `PressedSurface #515662`, `SelectedSurface #34332D`, `Outline #444449`, `Foreground #EEEEF2`, `Muted #B1B1BC`, `Accent/Indicator #F2CE48`, `AccentText #252110`, `OverlayAccent #F2D259`, `ErrorForeground #FFAB92`, and `OverlaySurface #D923252A`. Disabled controls use `0.4` opacity.

### iOS / iPadOS
- The editor and camera workspace deliberately enforce `.preferredColorScheme(.dark)` even under light system appearance.
- Photo canvas uses `Color(white: 0.12)`; semantic `Color(.systemBackground)`, `Color(.secondarySystemBackground)`, and `Color(.tertiarySystemBackground)` carry docks, parameter controls, and compact number tiles; `Color(.tertiarySystemFill)` backs Recent thumbnail slots.
- Camera workspace uses `Color(white: 0.10–0.17)` neutral surfaces; live viewfinder focus frames use `#34D759`-equivalent green (`rgb(0.20, 0.84, 0.35)`) when locked vs. `.white.opacity(0.92)` while searching, backed by `.black.opacity(0.45)`.

### Android
- Static dark-only Material 3 `darkColorScheme` (`background #1C1C1E`, `surfaceContainerLow #212124`, `surface #272729`, `surfaceContainerHigh #303033`, `primary #F2CE48`, `onPrimary #252110`, `primaryContainer/secondaryContainer #3D351C`, `secondary #63CDD6`, `onSurface #EEEEF2`, `onSurfaceVariant #B9B9C3`, `outline #85858E`, `outlineVariant #444449`, `error #FFB09B`); no light theme and no Material You dynamic color.
- Pure `#000000` backs camera viewfinder, tether fullscreen review, HSL 3× loupe, and RGB histogram plots; `#34D759` indicates locked focus frames. `NumericControl` modified readouts, ruler needles, and active bars use `colorScheme.primary` (`#F2CE48`), paired with neutral `onSurfaceVariant` baseline markers.

**The Functional Yellow Rule.** Yellow signals active selection, modified state, and adjustment progress — never decorative chrome. Pair tint with a visible dot, outline, or label.

## Typography

Use each operating system's native UI font stack with monospaced or tabular numerals for parameter readouts at standard OS text sizes. Do not add decorative display fonts or shrink labels to force fixed containers.

### macOS
- System font (`SF Pro`) without display fonts or window-width scaling.
- `13 pt` semibold sidebar/inspector section headers (`文件夹`, `照片`, `调整栏`) and parameter labels; right-aligned `NSFont.monospacedDigitSystemFont` numeric fields.
- `12 pt` toolbar workspace tabs (semibold when active), folder tree rows, group tabs (`medium`), and collapsible accordion headers (`semibold`).
- `11 pt` film names (wrapped in a two-line `29 pt` slot; `10 pt` when a compatibility notice appears), master recipe titles, status bar text, comparison labels, and secondary captions.
- `10 pt` sidebar thumbnail filenames and master recipe subtitles; `14 pt` semibold + `12 pt` photo info overlay; `.caption2.monospacedDigit()` histogram stats and Highlights tick marks.

### Windows
- `Segoe UI, Microsoft YaHei UI` with `TextOptions.TextFormattingMode="Display"` and `UseLayoutRounding="True"`.
- `13 px` body (`Window.FontSize`, photo info overlay, canvas labels); `11 px` captions (inspector tools, film/recipe labels, tile filenames, histogram stats, lens metadata); `24 px` empty-state welcome heading; `22 px` semibold and `16 px` semibold headings in batch and picker windows.
- `ParameterNumberBox` enforces `FontNumeralAlignment.Tabular` (`CultureInfo`-aware formatting with max 2 decimals) rather than a monospace family.

### iOS / iPadOS
- SwiftUI system text styles and `UIFont.preferredFont(forTextStyle:)` (`SF Pro`): `.subheadline` parameter names, semibold `.body.monospacedDigit()` complete tappable values inside a reserved width slot, `.caption` tool grid captions / film two-line slots / reference bounds, `.headline` value-wheel title, `.body.monospacedDigit()` temporary wheel readout and picker rows, and `16 pt` monospaced tether parameter bar readouts.

### Android
- Compose Material 3 default `Typography` on system `sans` (`bodySmall`, `labelSmall`, `titleMedium`, `bodyMedium`, `labelMedium`, `titleSmall`, `titleLarge`, `labelLarge`, `headlineSmall`).
- `16 sp` readouts in the camera tether parameter strip (`Shutter / Aperture / ISO / EV`).
- `NumericControl` stabilizes numeric jitter using `FontFamily.Monospace` inside fixed-width boxes (`104 dp` standard, `56 dp` / `68 dp` inline) rather than `tnum`, using fixed-decimal signed formatting (`formatAdjustmentReadout`).

**The Stable Readout Rule.** Numeric readouts reserve stable width with monospaced or tabular digits so sign and precision changes never shift adjacent sliders or controls.

## Layout

### macOS
- Minimum content size `950×620 pt` (default `1320×850 pt`), with three workspace modes (`Edit`, `Select`, `Preview`) in a flat center toolbar; `Escape` restores the previous mode from Preview.
- In `Edit`, the left browser defaults to `232 pt` (`200–288 pt`) and the right inspector defaults to `304 pt` (`280–360 pt`), persisting widths across launches. Below `1180 pt` window width, the browser opens as a `264 pt` leading overlay drawer (dismissed via `Escape`, opening a photo, or widening past `1180 pt`) and the inspector locks to `280 pt`.
- The left browser strictly separates folders (`min(height × 0.34, 220 pt)` in Edit, full height in Select, with Collapse All above the tree) and thumbnails (2-column sidebar in Edit; adaptive `132–208 pt` contact sheet + bottom batch bar in Select; per-folder scroll memory, breadcrumbs, Up button, and retry on directory error).
- The central photo canvas spans full height between the toolbar and `30 pt` bottom status bar, sharing zoom and pan across comparisons (`12 pt` default canvas margin, toggleable; Fit vs. 1:1 actual pixels quantized in `64 px` render steps; upper-left `360 pt` max-width photo info overlay; in-bounds comparison labels).
- The right inspector places the collapsible `68 pt` RGB/HDR histogram at the top (also accessible in a `286 pt` toolbar `ellipsis.circle` popover when hidden), followed by **6 adjustment groups in SDR / 7 in HDR** (`Looks`, `Light`, `Color`, `Effects`, `Detail`, `Geometry & Lens`, plus `HDR Rendition`), Look Strength pinned above SDR Looks (replaced by `HDRLookControls` + `QuickPresetView` in HDR), and independently scrolling accordion tools. When a Geometry/Lens draft is active, fixed Cancel/Apply draft actions occupy the footer; otherwise the footer displays `"当前外观"` + active look name and opens the **`320 pt` Processing Settings popover** (HDR toggle, HDR monitoring, HDR rendition controls, HDR RAW camera development, processing version, automatic migration progress & confirmed rollback, X3F mode, and exposure baseline).

### Windows
- Minimum window `1000×680 px` (default `1440×920 px`) in a 4-row shell: Menu (`28 px`), Toolbar (`48 px`), WorkspaceBody (`*`), Status Bar (`40 px`).
- Uses the same `Editing` / `Selection` / `Preview` modes and `1180 px` compact threshold (`264 px` slide-over `LibraryOverlay` drawer; inspector locked to `280 px` with splitter hidden). Resizable widths persist (`200–288 px` default `232 px` library; `280–360 px` default `304 px` inspector via `5 px` `GridSplitter`).
- Strictly separates virtualized folder `TreeView` (`min(220, height × 0.34)` in Editing, full height in Selection) and thumbnail gallery (2-col `108 px` rows in Editing; adaptive `144 px` rows in Selection with bottom action bar) with per-folder `Gallery.Anchors` scroll memory and debounced filesystem watch.
- Right inspector hosts the collapsible `92 px` histogram (reparents to `280 px` toolbar `HistogramPopup` when hidden or body height `< 400 px`), 6 SDR / 7 HDR group wrap panel, SDR Look Strength row, scrolling tool buttons with `ToolBody` inserted directly below the active tool, fixed Geometry/Lens `DraftActions` when editing geometry/lens, and a footer with active look name + `330 px` `ProcessingPopup` (processing version, migration status & rollback, X3F mode, exposure baseline).

### iOS / iPadOS
- `NavigationStack` workspace with **0 pt default photo canvas margin** (optional `16 pt` toggle); photos scale proportionally to fill at least one edge without default cropping. Empty state shows RawLab heading, guidance copy, photo import, Recently Opened, file import, and camera import; no adjustment dock appears until a photo is open.
- **Two-level dedicated tool workspaces**:
  - **Overview**: photo canvas with floating dark translucent `workspaceActions` capsules (`.black.opacity(0.62)` + `1 pt` `.white.opacity(0.14)` stroke; leading Undo/Redo/Reset, trailing Compare) above a 4-column tool `LazyVGrid` (`52 pt` min row height, `4 pt` spacing, adaptive `60 pt` 1-row / `116 pt` 2-row height; Looks includes `My Presets`) and `48 pt` single-line horizontal group bar (**6 SDR groups / 7 HDR groups**). Overview top toolbar holds Back/Import, Camera, Export/Cancel, and sectioned More.
  - **Active Tool Workspace**: top navigation bar hides cleanly to maximize photo height; parameter panel scrolls independently above a fixed `48×48 pt` `Cancel / Title / Apply` footer (highlighting `Apply` in `.yellow` when modified); canvas `workspaceActions` adds `editor.tool.more` overflow menu (`Fine` toggle, HSL Target toggle, My Presets, Compare modes, Histogram, Photo Info, Pure Preview, Processing Settings) and displays a tappable yellow `Fine` capsule (`editor.fine.badge`) between capsules when `Fine` is active. Left-edge `UIScreenEdgePanGestureRecognizer` exits via dirty-draft confirmation.
- Side-by-side composition activates when `availableWidth >= 600 pt && width > height` (`sidePanelWidth = min(336 pt, width × 0.48)`); narrower or portrait windows stack vertically with measured parameter height (`240 pt` fallback, `52%` height cap, **`140 pt` photo reservation**).
- Native Value Wheel explicitly presents as a sheet on iPhone (including regular-width landscape) and an anchored popover on iPad (`280–480 pt`, ideal `360 pt`, height `min(440 pt, availableHeight - safeArea - 40)`), adapting to a sheet in compact contexts; when sheet content is `width > 480 && height < 400`, title/value/range context sits at `44%` width beside the `200–220 pt` picker without auto-scrolling away.
- Camera Tether adapts between a `108 pt` bottom shutter bar (portrait) and `96 pt` right rail (landscape).

### Android
- Edge-to-edge dark system bars with `Scaffold`, `statusBarsPadding`, `navigationBarsPadding`, and `imePadding`. State-driven root router (`Camera` / `BatchExport` / `BatchSelection` / `Album` / `Editor`) preserves Album and Editor state.
- Editor uses the same **two-level dedicated tool workspaces** and **0 dp default photo margin** (optional `8 dp` toggle): `48 dp` overview top bar (Back, Camera, Export, sectioned More; hidden in tool workspaces and Pure Preview); adaptive home dock (`108 dp` 1-row / `164 dp` 2-row height) with 6 SDR / 7 HDR `EditorGroupStrip` + 4-column `EditorTool` grid (`52 dp` min row height; Looks includes `My Presets`; disabled tools dim and explain via snackbar on tap); active tool workspace with floating dark translucent `workspaceActions` capsules (`CircleShape`, `Black 0.62`, `1 dp` `White 0.14` stroke, focus fade, plus tappable yellow `Fine` pill between capsules when active), scrollable parameter body (`min(332 dp, availableHeight - 96 dp)`), and fixed `48 dp` `Close / Title / Check` Apply/Cancel footer (`Check` in `#F2CE48` when dirty). Per-photo HDR controls live inside Processing Settings rather than Editor Settings.
- Side dock activates at `maxWidth >= 600 dp && maxWidth > maxHeight` (`336 dp` fixed width); otherwise bottom dock.
- Album supports Square or Original-ratio Staggered grids (`1–6` columns, default `3`). Camera Tether adapts between a `108 dp` bottom shutter bar (portrait) and `96 dp` right rail (landscape).

**The Photo Budget Rule.** Keep the photograph visible and unobstructed at center stage; scroll complex parameters within bounded panels or drawers rather than squeezing controls over the image.

## Elevation & Depth

All four clients rely on flat tonal layering and hairline dividers rather than decorative drop shadows or card stacks.

- **macOS**: Continuous window surfaces separated by `1 pt` `.separatorColor` lines (`6 pt` split drag target); only the compact narrow-window browser drawer uses a structural drop shadow (`.black.opacity(0.35), radius: 12, x: 4`). Transient canvas overlays use `.black.opacity(0.65–0.72)` or `.regularMaterial`.
- **Windows**: Pure tonal step hierarchy (`#181A1E` → `#232326` → `#272729` → `#292C32` → `#303033`) with `1 px` `Outline` strokes (`#444449`) and **zero `DropShadowEffect`**. Canvas overlays use translucent `OverlaySurface` (`#D923252A`).
- **iOS / iPadOS**: Continuous semantic backgrounds and dividers; system sheets/popovers for secondary flows; `.regularMaterial` capsules/bars pinned near photo edges without obscuring the image center; floating RGB/HDR histogram uses `.black.opacity(0.65)` with a `1 pt` `.white.opacity(0.12)` border.
- **Android**: Flat Material 3 tonal hierarchy (`#1C1C1E` → `#212124` → `#272729` → `#303033`) with `HorizontalDivider` / `VerticalDivider` and dark scrims (`.56–.80` black alpha); only `RgbHistogramOverlay`'s popup uses an explicit `shadowElevation` (`6 dp`).

**The Flat-By-Default Rule.** Separate regions through tonal steps and hairline dividers; reserve translucency or structural elevation for transient overlays, drawers, and popups.

## Shapes

- **App Icon**: Abstract flat mark featuring two offset yellow and cyan photographic frames on a charcoal tile (rounded-square on desktop; full-bleed opaque square with OS mask on iOS; `#242426` adaptive background on Android). No aperture blades, film perforations, text, bevels, or 3D camera illustrations.
- **macOS**: **No circular tool buttons or circular progress rings in active UI.** Group tabs and accordion sections use `4 pt` pills with `3×3 pt` / `4×4 pt` yellow modified dots. Main workspace photo tiles (`WorkspacePhotoTile`) and `46×46 pt` film/recipe artwork use **`3 pt`** corner radius; film selection cards use `6 pt` radius with `1 pt` yellow stroke; `RoundParameterSlider` uses a `14×14 pt` circular thumb and `3 pt` track; HSL swatches are `18×18 pt` circles; histogram plots use `3 pt` radius; crop handle targets are `40×40 pt` with `18 pt` L-corners.
- **Windows**: Crisp small radii — `3 px` photo tiles/badges/menu items/scroll thumbs, `4 px` combo boxes/labels, `5 px` buttons/popups/info overlay, `6 px` histogram & processing popups, `8 px` HSL banner & update lock card; `14×14 px` circular slider thumb; `20×20 px` circular HSL swatches; compact `18×18 px` `AdjustmentRing` draws a `4 px` yellow modified dot beside `16×16 px` `EditorIcon` glyphs (`24×24` grid, `1.6 px` stroke).
- **iOS / iPadOS**: **No 48 pt tool circles, 270° progress arcs, or circle scalar badges in active UI.** Flat tool grid tiles pair `21 pt` SF Symbols with a `3×3 pt` yellow dot; action buttons target `>= 44×44 pt` (`48×48 pt` draft Apply/Cancel); HSL swatches are `19 pt` circles (`2 pt` `.primary` selected ring + `4×4 pt` yellow dot); film artwork uses `4 pt`, film selection & compact number tiles use `6 pt`, overlays use `8 pt`; compact inline sliders use `14×14 pt` circular thumbs; HSL target loupe is `88×88 pt` circular (`3×` zoom); camera tether shutter is `68×68 pt` circular; crop marks are `12×12 pt` inside `44×44 pt` targets.
- **Android**: Material 3 standard corner scales (`4 / 8 / 12 / 16 dp`) plus `3 dp` status notices, `4 dp` edited pencil badge & camera tiles, `6 dp` camera controls & export rows, `10 dp` progress pills, `24 dp` cancel-focus pill, and `CircleShape` for `3 dp` modified dots, `19 dp` HSL swatches (`3 dp` selected ring), `32 dp` wipe handle, `48 dp` canvas buttons, `68 dp` shutter, and `88 dp` HSL loupe. Enforces `48×48 dp` minimum touch targets (`HslControls` cells `48 dp` tall, `>= 44 dp` wide) and a local 64-icon `AppIcons` vector set.

## Components

### Shared Cross-Platform Semantics
- **Edited-Photo Markers & Thumbnails**: All four browsers render saved non-default edits into thumbnails (on-demand viewport loading) with a passive lower-right pencil badge on a dark translucent backdrop (`4 pt`/`3 px`/`4 dp` radius) independent of current-photo borders and selection checkmarks.
- **Adjustment Transfer, Quick & My Presets, History**: Copy/Paste/Sync (All / Modified / Custom scope with live value summaries), Quick Presets inline drawer, My Presets modal library, session transaction Undo/Redo, and individual quarantine/deletion of unreadable edit records, presets, looks, or batch journals.
- **Processing Migration & X3F**: Automatic background fitting to processing version 3 for eligible legacy SDR edits with persistent confirmed rollback (`回到迁移前`) inside desktop Processing Settings popovers and mobile Processing Settings sheets; Normal vs. Legacy X3F switcher.
- **Single & Batch Export**: Native resolution or explicit long-edge ceiling (presets `2048`/`3000`/`4096` + custom), separated from preview quality, never overwriting source files. Uniform frozen batch tasks and per-target frozen collection exports (`BatchSelection` → `BatchExport`) preserve target states and report per-item results.

### Desktop (`macOS` & `Windows`)
- **Workspace Shell & File Browser**: Flat `Edit / Select / Preview` toolbar switcher; trailing actions for Compare (Side-by-Side, Wipe with keyboard/mouse divider, hold-canvas or hold-`\` Before view), Photo Info (`I` cycles hidden/file/capture), Clipping overlay, Zoom menu (`Fit`, `100%`, `±25%`, canvas margin toggle), Inspector toggle, and Export menu. Left browser keeps Collapse All, breadcrumbs, Up, retry on error, per-folder scroll memory, and thumbnail context action `"应用当前设置"`.
- **Sliders & Numeric Fields**: `RoundParameterSlider` (`macOS`) and `ParameterSlider` + `ParameterRow` (`Windows`) feature `3 pt/px` tracks, `14 pt/px` circular thumbs, baseline origin marks, yellow fill from default to current value, double-click reset, arrow/Shift-fine keys, and scroll-wheel stepping on numeric inputs.
- **Adjustment Inspector Modules**:
  - *Looks*: Shared SDR Look Strength (`0–200%`), 3-column Film chooser (`Neutral` + bundled + imported `.cube`/`.vlt`/`.rlook`/`.dcp` with `LUTCompatibilityDialog` & `DCPImportOptionsDialog`, categories, accent-insensitive live search, Recent max 12, unreadable cleanup), 3-column Master Recipes, Quick & My Presets, and HDR Looks (`HDR Silver`, `HDR Silver Master`, `.cube`).
  - *Light*: Exposure (`±5 EV` SDR / `±4 EV` HDR) + Auto Exposure, Contrast, Highlights/Shadows (`-100…+100`), White/Black Points, and S-Curve / Multi-point **master Tone Curve** (`164 pt/px` canvas, up to 33 points, `-8…+8 EV` in HDR). *(Desktop UI currently edits only the master RGB curve while preserving and rendering stored R/G/B channel curves.)*
  - *Color*: White Balance (reciprocal Kelvin `2000–50000 K`, Tint `-150…+150`; Relative WB in HDR), Saturation, Vibrance, 8-swatch HSL (`0.1` precision on macOS) + canvas Target Adjustment, and 3-zone Color Grading wheel (`138–156 pt/px`).
  - *Effects & Detail*: Clarity, Dehaze, Vignette (Amount + expandable Midpoint/Roundness/Feather/Highlights + Reset), Grain (Amount/Size/Roughness + Reset), Sharpening (`0–200%`), Wavelet Denoise (`Detail`/`Clean`/`Custom` presets) + desktop GPU AI Denoise (`Core ML` on Apple Silicon macOS; `DirectML` on Windows) with progress, cancel, retry, and diagnostics export.
  - *Geometry & Lens*: Explicit draft transaction with fixed Cancel/Apply footer and dirty-departure guard; crop overlay with aspect lock/swap, 90° rotation, H/V flip, thirds grid, Straighten (`±45°`), numeric `%` Position & Size, Perspective H/V. **SDR Lens** on macOS and Windows enforces RAW-only visibility and exposes Distortion, TCA, and Auto-Crop **without a Vignetting toggle**; **Bayer HDR RAW Camera Development** (inside macOS popover / Windows `HDR RAW…` dialog) exposes Distortion, TCA, **Vignetting**, Auto-Crop, FBDD (`0–2`), WB, exposure reference, and `.dcp`/`.rlook` camera profiles.
  - *HDR & Updates*: 7th `HDR Rendition` group + Processing Settings HDR controls (Metal EDR on macOS / D3D11 FP16 scRGB `HwndHost` on Windows, Auto HDR vs. SDR Compatible toggle, HDR False Color, HDR Luminance Histogram). Desktop updates use Sparkle (`macOS`) and Velopack (`Windows`) with non-blocking lock banners when installing.

### Mobile (`iOS / iPadOS` & `Android`)
- **Two-Level Dedicated Tool Workspaces & Local Drafts**: Every adjustment tool opens a dedicated workspace backed by a scoped local draft (up to `100` undo/redo steps), floating canvas `workspaceActions` bar (Undo, Redo, context-aware Reset menu, Compare, and More menu), fixed `48 pt/dp` bottom `Cancel / Title / Apply` bar returning to the overview tool grid, and a 3-way dirty-exit confirmation (`Apply / Discard / Continue`) triggered by back navigation, iOS left-edge swipe back, or Android predictive Back.
- **Dual-Mode Adjustment Controls**:
  - *Full-Width Scalar Ruler*: Used on single-parameter tools. iOS `AdjustmentRulerView` moves a `13/22 → 28 pt` responsive tick tape beneath a fixed center yellow indicator (`24 pt` excitation radius, `180 ms` quadratic decay, `120 ms` release settle, `100/160/180 ms` focus fade at `0.08` phone / `0.42` iPad opacity, `125 ms` gated haptics). Android `AdjustmentRuler` uses a fixed `48 dp`-tall track with `21` ticks, `+4 dp` proximity pulse, `24 dp` edge-back gesture guard, and `125 ms` gated haptics.
  - *Compact Inline Row*: Used on multi-parameter tools (WB, HSL, Vignette, Grain, Denoise, Film Strength, Color Grading, Geometry) — single-row `Label + 14 pt/dp-thumb Track + Value`.
  - *Fine & Direct Numeric Entry*: `Fine` (`0.25×` drag sensitivity) lives inside the workspace More menu and surfaces a tappable yellow canvas `Fine` pill (`editor.fine.badge` / `adjustment-fine-badge`) while active; tapping any numeric readout opens iOS single-column `NativeValueWheel` (with `SizingPickerView` width-change re-centering and `PickerContainerView` vertical centering) or Android's validated Material numeric `AlertDialog`.
- **Rich Mobile Tool Workspaces**:
  - **RGB Tone Curves**: Full `RGB / Red / Green / Blue` channel tabs (`194 pt/dp` canvas, up to 33 points, point coordinate editor, `-8…+8 EV` axis in HDR).
  - **8-Channel HSL & Loupe Sampling**: `19 pt/dp` swatches + canvas Target Adjustment with `88 pt/dp` `3×` circular magnification loupe.
  - **Color Grading**: 3 zone tabs (`Shadows` / `Midtones` / `Highlights`) + `130 pt/dp` wheel + inline Hue/Saturation controls.
  - **RAW + JPEG Lens Correction**: Enabled for both RAW and JPEG/raster sources (disabled on normal X3F and HDR mode), exposing **Distortion, TCA, Vignetting, Auto-Crop**, searchable Lensfun profile chooser, and manual focal-length / crop-factor entry with JPEG in-camera correction guidance.
  - **HDR Editing & Cancellable Export**: Full HDR toolset + 7th `HDR Rendition` group (`Peak Limit`, `SDR Exposure`, `SDR Contrast`, `SDR Saturation`), top-edge HDR monitoring card (Auto HDR / SDR Compatible, False Color, EV luminance histogram), Metal EDR (`iOS`) / API 34+ FP16 (`Android`), and cancellable HDR JPEG / HDR HEIF (iOS) export progress banners.
- **1:1 Viewport ROI Tiled Zoom & Mobile Libraries**: Double-tap Fit ↔ `100%`, progressive `1024 px` multi-level tile pyramid above `1.05×` base scale (hysteresis `0.85×`) synchronized across before/after comparisons. Browsers expose `All / Edited / Unedited` filters (`RecentPhotosView` up to 100 photos / ~2 GiB on iOS; Square/Staggered `AlbumScreen` + System Open With private copy cleanup on Android).
- **Sony Wireless Camera Import & Tether Workspace**: Dedicated `.fullScreenCover` / root route from editor top bar; model-agnostic BLE/Wi-Fi connect + manual Wi-Fi + Connection Help + Save Location. Supports Manual selection (3-col grid, format/date/selected filters, preview) and One-tap Resumable Incremental Import (RAW / JPEG / RAW+JPEG, local JPEG resize/recompress), plus still-photo Tether live view (`68 pt/dp` shutter, 4-slot live parameter strip, Shooting Params sheet with Focus Area `0xD22C`, aspect-fit `640×480` tap-to-focus, live focus/face/tracking frames with `#34D759` green lock state and Cancel Focus pill). *(Verified on Android with Sony α7C II fw 2.00; iOS camera workflow remains an unverified hardware preview.)*

## Do's and Don'ts

### Do:
- **Do** keep the photograph central and unobstructed; keep default mobile photo margin at 0 and desktop full-height canvas between toolbar and status bar.
- **Do** preserve dark neutral surfaces, functional yellow for active/modified states, native system controls, and monospaced/tabular readouts.
- **Do** enforce explicit scoped draft Apply/Cancel and export/import guards; never export an active draft or present an unfinished preview as current.
- **Do** preserve shared color, HDR, v3 migration/rollback, and RAW/raster compatibility semantics across all four clients; keep camera-only controls honest per source type.
- **Do** design and evaluate layouts at standard OS text sizes for sighted photographers, keeping all 6 localized languages crisp and untruncated.

### Don't:
- **Don't** introduce decorative drop shadows, nested card stacks, custom display fonts, or non-functional accent color washes.
- **Don't** invent aggregate badges for multi-parameter tools, reintroduce retired circular tool progress rings, or obscure the photo center with processing spinners.
- **Don't** optimize layouts, inflate controls, or file review issues around low-vision Accessibility Dynamic Type / large-text modes or VoiceOver / TalkBack screen-reader flows.
- **Don't** claim Simulator/Emulator screenshots prove physical haptics, physical HDR peak brightness, iOS camera hardware compatibility, or RAW export numerical accuracy.
