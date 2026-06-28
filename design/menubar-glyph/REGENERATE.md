# Regenerating the menu-bar glyph imagesets

The `MenuLemon*` template imagesets in `app/Lemon/Assets.xcassets/` are rasterized
from the SVGs in `assets/`. **Use `rsvg-convert` (transparent background), NOT
`qlmanage`** — qlmanage's SVG thumbnailer bakes an opaque white background, which a
*template* image then tints into a solid dark box in the menu bar.

```sh
brew install librsvg   # provides rsvg-convert
A=design/menubar-glyph/assets
for pair in idle:MenuLemonIdle working:MenuLemonWorking waiting:MenuLemonWaiting \
            done:MenuLemonDone error:MenuLemonError disabled:MenuLemonDisabled; do
  s=${pair%%:*}; n=${pair##*:}; d=app/Lemon/Assets.xcassets/$n.imageset
  rsvg-convert -w 18 -h 18 "$A/lemon-$s.svg" -o "$d/glyph.png"
  rsvg-convert -w 36 -h 36 "$A/lemon-$s.svg" -o "$d/glyph@2x.png"
  rsvg-convert -w 54 -h 54 "$A/lemon-$s.svg" -o "$d/glyph@3x.png"
done
```

Verify transparency by compositing a glyph over a bright color (e.g. magenta) — the
color must show *through* around the lemon; only the ink should be opaque.
