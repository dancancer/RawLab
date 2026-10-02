# iOS App Icon

The yellow/cyan dual-frame mark follows `RawLabMac/Resources/AppIcon.png`.
Adapted with the built-in image generation tool on 2026-09-30: extend the
charcoal background to the square canvas edges, remove the macOS transparent
margin and rounded tile boundary, and preserve the existing frame mark.
iOS supplies the corner mask. No additional branding or text was introduced.

The opaque 1024-pixel master is
`Assets.xcassets/AppIcon.appiconset/AppIcon-1024x1024@1x.png`.
The other catalog sizes were resized from the same generated image using `sips`.

Validate all catalog entries from the repository root:

```sh
swift RawLab/tests/AppIconTests.swift RawLab/RawLab/Resources/Assets.xcassets/AppIcon.appiconset
```
