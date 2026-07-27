# Ctrl-Say Icon Source

`CtrlSay/AppIcon.icon` is the production Icon Composer document and the source of truth for the shipped app icon.

## Construction

- The Icon Composer canvas is the keycap. There is no separate key graphic, backdrop, container, or nested border.
- The keycap uses one continuous neutral monochrome material and one system-rendered outer edge.
- Default uses the neutral silver monochrome treatment. Dark has an explicit charcoal-to-black glass treatment while retaining the same white backlit legends. Mono remains available for the system's clear and tinted rendering.
- `Ctrl-Say` and the listening mark each have their own Icon Composer group, so either can be moved or scaled independently.
- Each group contains a crisp 1024-point vector face and a subtle raster backlight generated from the exact same path.
- Both face layers remain flat, solid, monochrome artwork with Icon Composer's raised glass effect disabled.
- No bevel, embossing, indentation, outline, border, or shadow is baked into the SVG artwork.
- The listening mark uses a short rounded emitter followed by three closed vector outlines generated from true circular arcs. It never uses stroked SVG paths or hand-shaped Bézier chevrons.

## Editing

Open `CtrlSay/AppIcon.icon` in Icon Composer.

- Select either legend group to change its X position, Y position, or scale while keeping its backlight aligned.
- Edit the constants at the top of `generate_layers.swift` when changing the exact font size, baseline, text, or listening-mark geometry.
- Run `swift Design/AppIcon/generate_layers.swift` to regenerate the production SVGs, then replace the corresponding image layer in Icon Composer.

The text is converted to vector outlines, following Apple's Icon Composer guidance. This keeps the shipped icon independent of a font file while preserving the macOS system-font geometry used by the generator.
