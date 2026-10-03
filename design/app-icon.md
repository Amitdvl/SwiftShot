# SwiftShot — Captured Instant

## Reference study

Studied popular app identities in Mobbin’s public featured-app collection:
https://mobbin.com/
The signed-out library redirects to the landing page; the study uses the
actual visible icon collection there, not a claimed popularity ranking.

- Wise: a forceful silhouette and tightly limited palette.
- Headspace: one uncomplicated shape with generous surrounding space.
- Cosmos: deliberate spacing is as important as the positive shapes.
- Loom: repetition creates a recognizable mass at small sizes.

These are composition observations, not assets to reproduce.

## Original concept

Two opposing sweeps suggest an S and the movement of a shutter around a
captured opening. Broad outer curves balance crisp diagonal inner cuts.
The mark uses two solid orange sweeps on a charcoal background. No camera,
cursor, window stack, stock viewfinder, or baked-in gradient is used.

The initial concept was explored with the built-in image-generation tool,
then rebuilt as precise SVG contours for native rendering.

## Production

Editable source: `SwiftShot.icon`. Source paths: `icon-layers/Sweep-Upper.svg`
and `icon-layers/Sweep-Lower.svg`. Icon Composer supplies native specular
highlights, 15% translucency and 18% neutral shadow, plus dark/mono appearances.
The charcoal treatment is the primary appearance and was visually checked in Icon Composer.

`SwiftShot-orange-dark.png` is the final 1024px color export from Icon Composer.
`SwiftShot-native.png` is its current master alias. The asset catalog provides
raster fallbacks; Xcode compiles the layered `.icon` source directly.

The rejected pane/cursor design is retained under `explorations/pane-icon`.
