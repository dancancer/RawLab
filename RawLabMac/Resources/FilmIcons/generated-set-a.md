# Film Icon Generation Set A

Generated on 2026-09-27 with the built-in `image_gen__imagegen` tool. This revision follows the approved direction: square, opaque, full-bleed front packaging label artwork; strict straight-on layout; no physical carton, perspective, side/top planes, cast shadow, or loose film. Each asset was generated in its own image-generation call, copied into the project, visually inspected, verified as 1254 x 1254 RGB PNG, and annotated with its exact prompt using `impeccable embed-prompt` in PNG `tEXt` metadata.

## Reference Evidence

The official reference canvas dimensions and the observed packaging variant are recorded below. These are image dimensions, not invented physical measurements of the packages.

| Asset | Project file | Generated source | Official reference URL | Local reference | Observed reference |
| --- | --- | --- | --- | --- | --- |
| PROVIA 100F | `RawLabMac/Resources/FilmIcons/provia.png` | `01a0e1e5-adf6-75a0-965a-6d693dc94f1e/exec-a4fccd87-a1d5-420b-96fb-41268281cb25.png` | `https://asset.fujifilm.com/www/us/files/2020-04/2f58d86dc2b5c2f5b064b6e657108637/provia-100f.png` | `/tmp/rawtools-filmrefs/provia-100f.png` | 529 x 458 PNG. Official composite shows the small 135 single-roll box at lower right and larger 120/multipack boxes; selected 135 artwork is a wide front panel with green upper field, deep blue-purple lower field, and gold PROVIA 100F type. |
| Velvia 50 | `RawLabMac/Resources/FilmIcons/velvia.png` | `01a0e1e5-adf6-75a0-965a-6d693dc94f1e/exec-907859f9-eb3e-41ef-b33b-bdff49ac274f.png` | `https://asset.fujifilm.com/www/us/files/2020-04/cb1931fd6c4c8f5907bb5449891868c3/film-velvia50.png` | `/tmp/rawtools-filmrefs/film-velvia50.png` | 590 x 400 PNG. Official composite shows the small 135-36 box at lower right and larger 120 boxes; selected 135 artwork is a wide front panel with green header, blue lower field, black band, and cream-gold Velvia 50 type. |
| ASTIA 100F | `RawLabMac/Resources/FilmIcons/astia.png` | `01a0e1e5-adf6-75a0-965a-6d693dc94f1e/exec-c45114c6-f80e-4b7b-990d-596e32e52a95.png` | `https://www.fujifilm.com.hk/products/professional_films/color_reversalfilms/astia_100f/img/pic_01.png` | `/tmp/rawtools-filmrefs/astia-pic-01.png` | 241 x 241 RGBA PNG. Official image is a single 35mm package; the visible front design uses green FUJICHROME, yellow ASTIA, and deep blue/purple 100F areas. |
| NEOPAN 100 ACROS II | `RawLabMac/Resources/FilmIcons/acros.png` | `01a0e1e5-adf6-75a0-965a-6d693dc94f1e/exec-20a855d3-46e1-4373-9b6c-2a3e0d826927.png` | `https://asset.fujifilm.com/www/ca/files/2020-04/74c0cafcd8abccb3498ad334f5182806/acros-100II-36.jpg` | `/tmp/rawtools-filmrefs/acros-100II-36.jpg` | 1791 x 1500 JPEG. Official image is a single 135-36 package; the front design is dominated by black/charcoal with a forest-green NEOPAN band, white FUJIFILM strip, and cool light-gray ACROS 100 II type. |
| FUJICOLOR PRO 160 NS | `RawLabMac/Resources/FilmIcons/pro-neg-std.png` | `01a0e1e5-adf6-75a0-965a-6d693dc94f1e/exec-a587cbfb-ed5f-4da0-b5c4-e127c02b2f20.png` | `https://asset.fujifilm.com/www/jp/files/2024-04/6b75b1c1cb4253623fb2cd7a56ff7443/datasheet_pro160ns_01.pdf` (official packaging page 4) | `/tmp/rawtools-filmrefs/pro160ns-page-4.png` (rendered from `/tmp/rawtools-filmrefs/pro160ns-datasheet.pdf`) | 1323 x 1872 PNG render of the official PDF page. The page shows the PRO 160 NS 120 box and other format packages; the selected label preserves the package's black field, green FUJICOLOR Professional band, maroon NS block, and gold/white type. |

The 135/120 distinction is taken from the official package views and Fujifilm datasheet format listings. The square artwork is an intentional flat-label adaptation, not a claim that the original physical cartons were square.

## Exact Prompts

### `provia.png`

```text
Use case: product-mockup
Asset type: square app film-stock icon as a flat front packaging label
Input image: Image 1 is the official Fujifilm PROVIA 100F packaging reference. Use the small 135 single-roll package shown in the reference, not the larger 120 multipack and not the other packages.
Primary request: Create a square, opaque, full-bleed flat print design that faithfully adapts the front face of a Fujifilm FUJICHROME PROVIA 100F 135-36 retail film package. This is printed label artwork, not a photograph of a box.
Composition/framing: strict straight-on orthographic front view, square canvas filled edge to edge by the flat package artwork. No perspective, no visible depth, no side panel, no top face, no carton silhouette, no white margin, no cast shadow, no background outside the print.
Design: use the recognizable official 135 PROVIA 100F front design from the reference: a vivid Fujifilm green upper area, a deep navy/royal-purple lower field, a narrow blue-violet transition band, cream-gold PROVIA 100F lettering, the white FUJIFILM/FUJICHROME branding, and small daylight/135-36 technical marks. Keep the green as an accent and let the deep blue-purple lower area clearly distinguish PROVIA from the all-green 120 multipack.
Style/medium: precise high-resolution packaging artwork, crisp flat ink, realistic tiny paper-print grain only, clean geometric borders and typography, no 3D rendering, no product photography.
Text (verbatim): "FUJIFILM", "FUJICHROME", "Professional", "PROVIA 100F", "DAYLIGHT", "135 36", "COLOR REVERSAL FILM". Render the product name accurately and legibly.
Constraints: preserve the actual Fujifilm PROVIA 100F 135 package identity and color hierarchy; one label design only; opaque square full bleed; no extra objects.
Avoid: physical box, 3D carton, perspective, side/top planes, shadows, highlights that imply depth, loose film, camera, hand, table, multipack, 120, Velvia, ASTIA, PRO Neg, invented logos, misspelled FUJIFILM, misspelled PROVIA, and generic green square art.
```

### `velvia.png`

```text
Use case: product-mockup
Asset type: square app film-stock icon as a flat front packaging label
Input image: Image 1 is the official Fujifilm FUJICHROME Velvia 50 packaging reference. Use the small 135-36 single-roll package shown at lower right as the source, not the larger 120 five-roll multipack.
Primary request: Create a square, opaque, full-bleed flat print design that faithfully adapts the front face of a Fujifilm FUJICHROME Velvia 50 135-36 retail film package. This is printed label artwork, not a photograph of a box.
Composition/framing: strict straight-on orthographic front view, square canvas filled edge to edge by the flat package artwork. No perspective, no visible depth, no side panel, no top face, no carton silhouette, no white margin, no cast shadow, no background outside the print.
Design: preserve the recognizable official Velvia 50 135 front hierarchy from the reference: vivid Fujifilm green header/frame, saturated blue lower field, a black band, cream-gold Velvia lettering and 50 badge, white FUJIFILM/FUJICHROME branding, and small daylight/135-36 technical marks. The blue lower area must be prominent; do not turn this into an all-green label or a generic blue poster.
Style/medium: precise high-resolution packaging artwork, crisp flat ink, realistic tiny paper-print grain only, clean geometric borders and typography, no 3D rendering, no product photography.
Text (verbatim): "FUJIFILM", "FUJICHROME", "Professional", "Velvia", "50", "DAYLIGHT", "135 36", "COLOR REVERSAL FILM". Render the product name accurately and legibly.
Constraints: preserve the actual Fujifilm Velvia 50 package identity and green/blue/black/gold color hierarchy; one label design only; opaque square full bleed; no extra objects.
Avoid: physical box, 3D carton, perspective, side/top planes, shadows, highlights that imply depth, loose film, camera, hand, table, multipack, 120, PROVIA, ASTIA, PRO Neg, invented logos, misspelled FUJIFILM, misspelled Velvia, and generic green square art.
```

### `astia.png`

```text
Use case: product-mockup
Asset type: square app film-stock icon as a flat front packaging label
Input image: Image 1 is the official Fujifilm FUJICHROME ASTIA 100F packaging reference. Use this single 35mm retail package as the source for the flat front design.
Primary request: Create a square, opaque, full-bleed flat print design that faithfully adapts the front face of a Fujifilm FUJICHROME ASTIA 100F 135-36 retail film package. This is printed label artwork, not a photograph of a box.
Composition/framing: strict straight-on orthographic front view, square canvas filled edge to edge by the flat package artwork. No perspective, no visible depth, no side panel, no top face, no carton silhouette, no white margin, no cast shadow, no background outside the print.
Design: preserve the recognizable official ASTIA front hierarchy from the reference: Fujifilm white brand panel, vivid green FUJICHROME field, warm yellow/gold ASTIA panel, deep royal blue/purple 100F and lower field, clean white Professional and daylight details. Keep the green, gold, and blue areas distinct; do not make an all-green label.
Style/medium: precise high-resolution packaging artwork, crisp flat ink, realistic tiny paper-print grain only, clean geometric borders and typography, no 3D rendering, no product photography.
Text (verbatim): "FUJIFILM", "FUJICHROME", "Professional", "ASTIA", "100F", "DAYLIGHT", "135 36", "COLOR REVERSAL FILM". Render the product name accurately and legibly.
Constraints: preserve the actual Fujifilm ASTIA 100F package identity and green/gold/blue color hierarchy; one label design only; opaque square full bleed; no extra objects.
Avoid: physical box, 3D carton, perspective, side/top planes, shadows, highlights that imply depth, loose film, camera, hand, table, multipack, 120, PROVIA, Velvia, PRO Neg, invented logos, misspelled FUJIFILM, misspelled ASTIA, and generic green square art.
```

### `acros.png`

```text
Use case: product-mockup
Asset type: square app film-stock icon as a flat front packaging label
Input image: Image 1 is the official Fujifilm NEOPAN 100 ACROS II 135-36 packaging reference. Use the front-face typography and color hierarchy from the real 35mm single-roll package.
Primary request: Create a square, opaque, full-bleed flat print design that faithfully adapts the front face of a Fujifilm NEOPAN 100 ACROS II 135-36 retail film package. This is printed label artwork, not a photograph of a box.
Composition/framing: strict straight-on orthographic front view, square canvas filled edge to edge by the flat package artwork. No perspective, no visible depth, no side panel, no top face, no carton silhouette, no white margin, no cast shadow, no background outside the print.
Design: preserve the official ACROS II hierarchy: a restrained white Fujifilm brand strip near the top, a saturated deep forest-green NEOPAN Professional band, and a dominant near-black/charcoal lower field with a crisp outlined black label and cool light-gray ACROS 100 II lettering. Include small white technical copy for black-and-white prints and 135 36, but keep the actual product name dominant. Green must be an upper accent, while black/charcoal is the main lower field.
Style/medium: precise high-resolution packaging artwork, crisp flat ink, realistic tiny paper-print grain only, clean geometric borders and typography, no 3D rendering, no product photography.
Text (verbatim): "FUJIFILM", "NEOPAN", "Professional", "ACROS 100 II", "FILM FOR BLACK & WHITE PRINTS", "135 36". Render the product name accurately and legibly.
Constraints: preserve the actual Fujifilm NEOPAN 100 ACROS II package identity; one label design only; opaque square full bleed; no extra objects; black-and-white film identity must be obvious.
Avoid: physical box, 3D carton, perspective, side/top planes, shadows, highlights that imply depth, loose film, camera, hand, table, multipack, 120, PROVIA, Velvia, ASTIA, PRO Neg, invented logos, misspelled FUJIFILM, misspelled ACROS, and generic green square art.
```

### `pro-neg-std.png`

```text
Use case: product-mockup
Asset type: square app film-stock icon as a flat front packaging label
Input image: Image 1 is the official Fujifilm PRO 160 NS packaging reference from the Fujifilm product information bulletin. Use the real PRO 160 NS package hierarchy shown there; the film-simulation icon must represent the actual product PRO 160 NS, not a fictional package.
Primary request: Create a square, opaque, full-bleed flat print design that faithfully adapts the front face of a Fujifilm FUJICOLOR Professional PRO 160 NS retail film package. This is printed label artwork, not a photograph of a box. The icon may adapt the real 120 package artwork to a square front label, but must retain the real product name PRO 160 NS.
Composition/framing: strict straight-on orthographic front view, square canvas filled edge to edge by the flat package artwork. No perspective, no visible depth, no side panel, no top face, no carton silhouette, no white margin, no cast shadow, no background outside the print.
Design: use the authentic Fujicolor Professional PRO 160 NS hierarchy: saturated Fujifilm green upper band, dominant black lower field, clean white FUJIFILM and FUJICOLOR Professional branding, a restrained deep maroon/rose accent block behind the large 160 NS marking, thin gold rules, and small white technical copy. Make the black and maroon areas prominent enough that it is not an all-green label. The design should look like a real professional color-negative package front.
Style/medium: precise high-resolution packaging artwork, crisp flat ink, realistic tiny paper-print grain only, clean geometric borders and typography, no 3D rendering, no product photography.
Text (verbatim): "FUJIFILM", "FUJICOLOR", "Professional", "PRO 160", "NS", "DAYLIGHT / FOR COLOR PRINTS", "EASY END-SEAL", "PROFESSIONAL PACK", "ISO 160". Render the actual product name accurately and legibly.
Constraints: preserve the real PRO 160 NS package identity and green/black/maroon/white/gold color hierarchy; one label design only; opaque square full bleed; do not write or imply "PRO Neg.Std" on the package.
Avoid: physical box, 3D carton, perspective, side/top planes, shadows, highlights that imply depth, loose film, camera, hand, table, multipack, fictional 135 branding, PROVIA, Velvia, ASTIA, ACROS, invented logos, misspelled FUJIFILM, misspelled FUJICOLOR, misspelled PRO 160 NS, and any text that says PRO Neg.Std.
```
