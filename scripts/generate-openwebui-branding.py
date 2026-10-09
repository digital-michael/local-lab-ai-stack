#!/usr/bin/env python3
"""Generate the Photon Datum branding set for Open WebUI's STATIC_DIR override.

Icons/name only (no colour reskin — Open WebUI's CSS is Tailwind v4 utility
classes with no small, stable brand-accent variable like Authentik's
--ak-accent, so a deep reskin isn't maintainable; see
docs/library/framework_components/openwebui/ for why).

Source: the Photon Datum ribbon mark (transparent PNG), produced by the
website repo's tools/logo/make_transparent.py. Sizes/names below match
Open WebUI v0.11.3's own static/ directory exactly, so dropping the result
in as STATIC_DIR just replaces the branded files; everything else (fonts,
swagger-ui, user.png, etc.) gets auto-populated by Open WebUI itself on
first boot with that STATIC_DIR (see config.py's frontend->static copy step)
and is left alone here.

Usage:
  python3 scripts/generate-openwebui-branding.py <mark-on-dark.png> <out-dir>
"""
import sys
from pathlib import Path
from PIL import Image


def square_pad(im: Image.Image, margin_frac: float = 0.12, bg=(0, 0, 0, 0)) -> Image.Image:
    w, h = im.size
    side = round(max(w, h) * (1 + margin_frac))
    canvas = Image.new("RGBA", (side, side), bg)
    canvas.paste(im, ((side - w) // 2, (side - h) // 2), im)
    return canvas


def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    src, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    mark = Image.open(src).convert("RGBA")
    transparent_square = square_pad(mark)
    # Apple's own convention: opaque background, no alpha (iOS renders
    # transparency as black). Light scheme bg from the site's active scheme.
    opaque_square = square_pad(mark, bg=(245, 248, 252, 255))

    sizes = {
        "favicon-96x96.png": (96, 96, transparent_square),
        "favicon.png": (512, 512, transparent_square),
        "apple-touch-icon.png": (180, 180, opaque_square),
        "logo.png": (500, 500, transparent_square),
        "splash.png": (500, 500, transparent_square),
        "splash-dark.png": (500, 500, transparent_square),
        "web-app-manifest-192x192.png": (192, 192, transparent_square),
        "web-app-manifest-512x512.png": (512, 512, transparent_square),
    }
    for name, (w, h, base) in sizes.items():
        base.resize((w, h), Image.LANCZOS).save(out_dir / name, optimize=True)
        print("wrote", out_dir / name, f"{w}x{h}")

    ico_sizes = [16, 32, 48]
    frames = [transparent_square.resize((s, s), Image.LANCZOS) for s in ico_sizes]
    frames[0].save(out_dir / "favicon.ico", format="ICO",
                    sizes=[(s, s) for s in ico_sizes], append_images=frames[1:])
    print("wrote", out_dir / "favicon.ico", ico_sizes)


if __name__ == "__main__":
    main()
