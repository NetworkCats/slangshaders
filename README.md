# slangshaders

My collection of shaders written in [Slang](https://shader-slang.org/).

## Shaders

- `anime_meadow.slang` — a Shinkai-style anime summer meadow: volumetric cumulus clouds, wind-swept grass, a small railway scene with hand-painted-style shading, and a 35 mm film lens/grain post pass.

## Building

Requires `slangc` and, for the offline renderer, macOS with Swift and Metal.

```sh
./build.sh [time] [out.png] [width] [height]   # e.g. ./build.sh 30 build/frame.png 1920 1080
```

`build.sh` compiles the shader to Metal and renders a frame with `tools/render.swift`. Output goes to `build/`.
