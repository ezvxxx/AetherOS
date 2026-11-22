# Image codec dependencies

AetherOS vendors a pinned Zig 0.17-compatible image decoding stack for BMP,
PNG, JPEG, and WebP (lossy and lossless):

- `z2dimg` at `f6037e4b8a65258ac06398082f91fd595f1be109`
- `z2d` at `95e6d0dd70d8161f40cd6600a26520c5719b30b5`
- `riff` at `95720d487115c285f5b890e5788499f3931a4d26`
- `vp8` at `940c92375d7b841a03aa76f5223480834ac03a8f`

License notices are retained in the adjacent `LICENSE-*.txt` files and
`LICENSES-*` directories. The SVG support in `graphics/svg.zig` is an AetherOS
implementation and is intentionally bounded to common vector shapes and a
small path subset; it is not a full SVG specification implementation.
