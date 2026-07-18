# scripts/

## icon-to-base64.sh

Converts an image, an SF Symbol, or an emoji into a base64 PNG string for use in an MTMR `items.json` `"image": { "base64": "..." }` field. Always re-encodes to a clean 8-bit RGBA PNG — MTMR crashes (SIGILL) on 8-bit indexed/palette PNGs, so this avoids that entirely regardless of the source format. Copies the result to your clipboard and prints it to stdout.

```sh
# From an existing image file (logo, downloaded icon, screenshot, etc.)
./scripts/icon-to-base64.sh --image ~/Downloads/some-icon.png [--size 22]

# From an SF Symbol (system icon set) with a chosen tint color
./scripts/icon-to-base64.sh --sf-symbol "wrench.and.screwdriver" --color white [--size 22] [--point-size 16]
# --color accepts: white, black, red, orange, yellow, green, blue, purple, gray, or a "#RRGGBB" hex string
# (defaults to white — SF Symbols render in black by default, invisible against the Touch Bar's black background
# unless explicitly tinted)

# From a literal emoji character
./scripts/icon-to-base64.sh --emoji "🔥" [--size 22]
```

Browse available SF Symbol names at [developer.apple.com/sf-symbols](https://developer.apple.com/sf-symbols/) or the SF Symbols Mac app.

**Gotcha:** if you redirect the output to a file, do NOT merge stderr into it (`> out.txt 2>&1`) — the diagnostic line ("N chars, copied to clipboard...") is intentionally printed to stderr so it doesn't pollute the base64, but merging streams defeats that and corrupts the file. Just use plain `> out.txt` (stderr will still print to your terminal).

## button-template.json

A reusable template for Touch Bar buttons that match macOS's own native style — borderless, no background fill, icon-only, blends into the black Touch Bar (like the system's brightness/volume buttons). A colored-pill/CTA-style variant (`background` + `bordered`) was tried first and rejected — too wide, too loud, didn't fit the system aesthetic. Stick with minimal/transparent going forward. Copy the object into `items.json`'s array, then:
1. Generate an icon with `icon-to-base64.sh` and paste the result into `image.base64`
2. Set (or remove) `matchAppId` to scope it to a specific app
3. Keep `bordered: false` and don't set `background` — that's what keeps it flat/native instead of a filled pill
4. Fill in `actions` for whatever triggers you need (`singleTap`, `doubleTap`, `tripleTap`, `longTap` are all supported per-button)
