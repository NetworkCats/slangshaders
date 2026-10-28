#!/bin/sh
# Compile anime_meadow.slang to Metal and render a frame: ./build.sh [time] [out.png] [w] [h]
set -e
cd "$(dirname "$0")"
mkdir -p build
slangc anime_meadow.slang -entry computeMain -stage compute -entry postMain -stage compute -target metal -o build/anime_meadow.metal
[ tools/render -nt tools/render.swift ] || swiftc -O tools/render.swift -o tools/render
./tools/render build/anime_meadow.metal "${2:-build/frame.png}" "${3:-1280}" "${4:-720}" "${1:-10}" 1 0.1 2
