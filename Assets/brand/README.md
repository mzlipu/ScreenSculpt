# Brand assets

`AppIcon.icns` and `MenuBarIcon*.png` are **generated**, not hand-edited. Run
`make icon` after changing `scripts/make-appicon.swift`, and commit the result —
committing the output means a build needs no image tooling.

`AppIcon.iconset/` is an intermediate and is not committed.

## Why the icon is drawn in code

The icon is needed at 16 points and at 1024, and no single raster serves both:
a detailed render turned down to menu bar size becomes a smudge, and a small one
scaled up is worse. Drawing it means the geometry is re-evaluated at each size —
the iris simplifies to a plain disc below 48 points, where its blades could not
resolve anyway.

It also has to satisfy three things a exported PNG usually does not:

- **Transparency outside the tile.** macOS composites the icon over whatever is
  behind it. An opaque image shows as a square.
- **No baked shadow.** The system draws its own; a second one underneath it
  looks like a mistake.
- **A squircle, not a rounded rectangle.** Apple's shape is a superellipse.
  Circular corners read as visibly pillowed next to system icons.

## reference/

The original artwork this design follows, kept for provenance. Those files are
opaque RGB with a background plate and a baked drop shadow, and the largest is
512px, so they could not be used directly — but the palette, the marquee
brackets and the aperture all come from them.
