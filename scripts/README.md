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
