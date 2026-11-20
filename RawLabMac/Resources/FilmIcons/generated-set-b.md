# Film Icon Generation Set B

Generated on 2026-09-27 with the built-in `image_gen__imagegen` tool. The five final assets are unified full-bleed, square, front-facing packaging artwork: no physical box perspective, side/top faces, shadows, or outer transparent margin. Each final file is 1254 x 1254 PNG artwork covering the complete canvas. The three real-product references are `eterna.png` (Fujicolor ETERNA cinema label), `classic-neg.png` (FUJICOLOR SUPERIA X-TRA 400), and the historical SUPERIA REALA design used by the `reala-ace.png` concept. `eterna-bb.png`, `classic-chrome.png`, and `reala-ace.png` are explicitly labeled `FILM SIMULATION` concepts and must not be represented as real retail film stocks.

## Provenance

| Asset | Project file | Final generated source | Initial source (when reframed) | Source URL(s) | Viewed local reference(s) | Concept marker |
| --- | --- | --- | --- | --- | --- | --- |
| ETERNA cinema label | `RawLabMac/Resources/FilmIcons/eterna.png` | `01a0e1e6-551e-7861-9d86-8e6f72867d0c/exec-0dc36316-a801-46c4-94db-459f81d527da.png` | `01a0e1e6-551e-7861-9d86-8e6f72867d0c/exec-a5cbbede-9634-4ca4-83d9-96f847b7fff5.png` | `https://asset.fujifilm.com/www/jp/files/2019-10/a2b78141b856eedf5ba0bb0c403c69fc/rd_report_ff_rd051_all.pdf`; `https://www.davidelkins.com/download/download_files/fuji/fujifilm_motion_picture_film_manual.pdf` | `/tmp/rawtools-filmrefs/eterna-manual-hi/page-05.png`; `/tmp/rawtools-filmrefs/eterna-fig1.png` | No, real ETERNA cinema-film label reference |
| ETERNA BLEACH BYPASS | `RawLabMac/Resources/FilmIcons/eterna-bb.png` | `01a0e1e6-551e-7861-9d86-8e6f72867d0c/exec-7cfe513b-a76a-4059-9cbf-f6a664a26685.png` | - | `https://digitalcamera-support-en.fujifilm.com/digitalcameraengmobiledetail?aid=000008291&sfdcIFrameOrigin=null`; `https://asset.fujifilm.com/www/jp/files/2019-10/a2b78141b856eedf5ba0bb0c403c69fc/rd_report_ff_rd051_all.pdf` | `RawLabMac/Resources/FilmIcons/eterna.png` | Yes, exact `FILM SIMULATION` and `BLEACH BYPASS` labels |
| CLASSIC CHROME | `RawLabMac/Resources/FilmIcons/classic-chrome.png` | `01a0e1e6-551e-7861-9d86-8e6f72867d0c/exec-39bacb08-2e43-4f7c-a437-0647c79ffb0c.png` | - | `https://digitalcamera-support-en.fujifilm.com/digitalcameraengmobiledetail?aid=000008291&sfdcIFrameOrigin=null` | - | Yes, exact `FILM SIMULATION` label; invented gray-silver/deep-blue concept |
| REALA ACE | `RawLabMac/Resources/FilmIcons/reala-ace.png` | `01a0e1e6-551e-7861-9d86-8e6f72867d0c/exec-43529cf6-bc02-445f-a735-85edac21f947.png` | `01a0e1e6-551e-7861-9d86-8e6f72867d0c/exec-9de63bba-b47f-4bcf-8af0-cb5f3be93ecc.png` | `https://www.fujifilm.com.hk/products/consumer_film/color_negativefilms_35mm/superia_reala/index.html`; `https://www.adorama.com/images/large/FJCS36.JPG`; `https://digitalcamera-support-en.fujifilm.com/digitalcameraengmobiledetail?aid=000008291&sfdcIFrameOrigin=null` | `/tmp/rawtools-filmrefs/reala-official.jpg`; `/tmp/rawtools-filmrefs/reala-adorama.jpg` | Yes, exact `FILM SIMULATION` label; historical SUPERIA REALA-inspired concept |
| CLASSIC Neg. | `RawLabMac/Resources/FilmIcons/classic-neg.png` | `01a0e1e6-551e-7861-9d86-8e6f72867d0c/exec-e374f3cd-b4f7-4412-a41f-0cc5701b283a.png` | `01a0e1e6-551e-7861-9d86-8e6f72867d0c/exec-ccd22267-893a-410e-9701-3dabd15ee305.png` | `https://www.fujifilm.com.hk/products/consumer_film/color_negativefilms_35mm/superia_xtra400/index.html`; `https://www.fujifilm.com.hk/products/consumer_film/color_negativefilms_35mm/superia_xtra400/img/pic_01.png`; `https://digitalcamera-support-en.fujifilm.com/digitalcameraengmobiledetail?aid=000008291&sfdcIFrameOrigin=null` | `/tmp/rawtools-filmrefs/superia-xtra400-official.png` | No, real SUPERIA X-TRA 400 label reference |

## Exact Final Prompts

The prompt embedded in each final PNG is the exact prompt used for its final generation or framing edit. The initial source-generation prompts are represented by the source/reference URLs and generated source paths in the table above; final reframing edits preserved the artwork and only removed the old outer margins.

### `eterna.png`

```text
Edit only the canvas framing of the supplied flat ETERNA front-label artwork. Preserve the existing FUJIFILM, FUJICOLOR NEGATIVE FILM, ETERNA, 500, 35mm, TYPE 8573, 3200K, and E.I.500 lettering, colors, black/gold/orange-red geometric layout, paper grain, and straight-on flat packaging-art style exactly. Uniformly scale and reframe the existing square label until the artwork reaches every edge of the 1254 x 1254 square canvas: remove all transparent outer margins and any black/transparent canvas border. The final image must be full-bleed edge-to-edge square art, with no perspective, no side/top face, no shadows, no new objects, no redrawing, no new wording, and no changed proportions except the uniform scale needed to fill the canvas. Keep all existing text inside the canvas and legible.
```

### `eterna-bb.png`

```text
Use case: product-mockup
Asset type: square app film-simulation icon, full-bleed flat front packaging artwork
Primary request: Create a single full-bleed square front packaging label artwork for the ETERNA BLEACH BYPASS Film Simulation concept, derived from the authentic ETERNA cinema-film label artwork in the supplied reference. This is an invented digital Film Simulation concept, not a real retail film product and not a physical box.
Input images: Image 1 is the regenerated flat ETERNA front-label artwork; use its square composition, typography hierarchy, black/gold/orange-red label language, and FUJIFILM branding as the starting point, but redesign the stock name for this concept.
Scene/backdrop: the square artwork must cover every pixel edge to edge; no transparent outer margin, no black canvas border, no floor, table, surface, cast shadow, or atmospheric backdrop.
Subject: exactly one flat square printed front label, straight-on and centered, with no physical depth. Treat the entire canvas as a square piece of packaging graphic design.
Style/medium: crisp high-resolution printed packaging artwork, clean geometric panels, subtle matte ink grain, precise edges, highly legible type, no 3D render.
Composition/framing: full-bleed square canvas, perfectly front-facing and orthographic, no perspective, no visible side or top, no physical product silhouette.
Lighting/mood: uniform flat color, no lighting gradients, no highlights, no shadow.
Color palette: ETERNA-inspired near-black and charcoal field, muted brown-gold information panel, restrained desaturated orange-red accent wedge, cream and gold type; strong contrast but low saturation to evoke bleach bypass.
Materials/textures: flat matte printed label, subtle paper grain only, no bevels, folded seams, or box corners.
Text (verbatim): "FUJIFILM"; "FUJICOLOR"; "ETERNA"; "BLEACH BYPASS"; "FILM SIMULATION"; "HIGH CONTRAST"; "LOW SATURATION".
Constraints: This is a concept package and must visibly include the exact words "FILM SIMULATION". Do not present it as an authentic stock and do not invent ISO, exposure, format, or retail claims. Use only one flat square label; fill the whole image.
Avoid: cardboard box, canister, reel, roll, physical product photography, perspective, side face, top face, rounded 3D corners, shadows, hands, props, scenery, watermark, collage, extra labels, fake retail specifications, transparent margin, black border, and any non-square layout.
```

### `classic-chrome.png`

```text
Use case: product-mockup
Asset type: square app film-simulation icon, full-bleed flat front packaging artwork
Primary request: Create a single full-bleed square front packaging label artwork for the CLASSIC CHROME Film Simulation concept. This is an invented concept graphic, not a real retail film product and not a physical box.
Scene/backdrop: the square artwork must cover every pixel edge to edge; no transparent outer margin, no black canvas border, no floor, table, surface, cast shadow, or backdrop.
Subject: exactly one flat square printed front label, straight-on and centered, with no physical depth. Treat the entire canvas as a square piece of packaging graphic design.
Style/medium: crisp high-resolution printed packaging artwork, clean geometric panels, subtle matte ink grain, precise edges, highly legible type, no 3D render.
Composition/framing: full-bleed square canvas, perfectly front-facing and orthographic, no perspective, no visible side or top, no physical product silhouette.
Lighting/mood: uniform flat color, no lighting gradients, no highlights, no shadow.
Color palette: low-saturation gray-silver and deep navy blue, charcoal black typography panels, restrained cream-white type, tiny muted red Fujifilm mark accent. Do not use bright green, rainbow colors, or orange-dominant packaging.
Materials/textures: flat matte printed label, subtle paper grain only, no bevels, folded seams, or box corners.
Text (verbatim): "FUJIFILM"; "CLASSIC CHROME"; "FILM SIMULATION"; "LOW SATURATION"; "DOCUMENTARY".
Constraints: This is a concept package and must visibly include the exact words "FILM SIMULATION". Do not imply an authentic retail film stock and do not invent ISO, exposure, or format specifications. Use only one flat square label; fill the whole image.
Avoid: cardboard box, canister, reel, roll, physical product photography, perspective, side face, top face, rounded 3D corners, shadows, hands, props, scenery, watermark, collage, extra labels, fake retail specifications, transparent margin, black border, and any non-square layout.
```

### `reala-ace.png`

```text
Edit only the canvas framing of the supplied flat REALA ACE front-label artwork. Preserve the existing FUJIFILM mark, FUJICOLOR, SUPERIA, REALA ACE, FILM SIMULATION lettering, historical green/white/gold/red layout, paper grain, and straight-on flat packaging-art style exactly. Uniformly scale and reframe the existing square label until the artwork reaches every edge of the 1254 x 1254 square canvas: remove all transparent outer margins and any black/transparent canvas border. The final image must be full-bleed edge-to-edge square art, with no perspective, no side/top face, no shadows, no new objects, no redrawing, no new wording, and no changed proportions except the uniform scale needed to fill the canvas. Keep all existing text inside the canvas and legible.
```

### `classic-neg.png`

```text
Edit only the canvas framing of the supplied flat SUPERIA X-TRA 400 front-label artwork. Preserve the existing FUJIFILM, FUJICOLOR, SUPERIA, X-TRA 400, COLOR NEGATIVE FILM, 400, and 36 lettering, green/blue/gold/rainbow colors, geometric layout, paper grain, and straight-on flat packaging-art style exactly. Uniformly scale and reframe the existing square label until the artwork reaches every edge of the 1254 x 1254 square canvas: remove all transparent outer margins and any black/transparent canvas border. The final image must be full-bleed edge-to-edge square art, with no perspective, no side/top face, no shadows, no new objects, no redrawing, no new wording, and no changed proportions except the uniform scale needed to fill the canvas. Keep all existing text inside the canvas and legible.
```

## Checksums

```text
d8ccb3f06f3e79f2b704d25c548e9f63377dd680c558f84af318c9be73a7e77a  eterna.png
edc9959c71782138b1bee21397e15b931bad83380e5ccb896ea1c82ade8c524d  eterna-bb.png
9cde82639c98fd47ab636a2ab67be58fc82c47072b0e5a1726d558c81f2c90e7  classic-chrome.png
7b48f8e69cb098589abc9695fd4f3d827e1906d185ec7ee6d0ef4a974f552253  reala-ace.png
a6420c6a847383e274d7ef55272b90281870ba96e2cb809638f2a3e2331230a3  classic-neg.png
```
