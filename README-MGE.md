# OpenMW MGE Edition — engine patch

## What this is

A patch series on top of the official [OpenMW 0.51.0](https://gitlab.com/OpenMW/openmw)
release that recreates the classic MGE XE / Morrowind Graphics Extender
visual experience natively in OpenMW: MGE-style distant land, the MGE
fog and atmospheric-scattering model, MGE water, and engine support for
the classic post-process shader pack (SSAO, sun shafts, bloom, eye
adaptation, depth of field, underwater effects), ported to omwfx.

Everything is opt-in: with no settings changed, the engine behaves like
stock 0.51.0. The single `mge-edition` commit against the
`official-0.51.0` tag contains the complete diff — the compare view
shows exactly what changed and where.

## Feature map (where to look)

| Feature | Key files |
|---|---|
| Distant land (resident distant statics, three-class size/distance model, disk-cached generation, save-state refresh) | `apps/openmw/mwrender/objectpaging.*`, `apps/distantlandtool/` |
| Software occlusion culling (Masked Occlusion Culling; terrain + building occluders) — based on kartoffels' work | `components/sceneutil/occlusionculling.*`, `extern/masked-occlusion-culling/` |
| MGE fog + atmospheric scattering (XE Common.fx model, weather-transition derived-space blending) | `files/shaders/compatibility/mge_fog.glsl`, `fog.glsl`, `sky.frag`, `apps/openmw/mwworld/weather.cpp` |
| XE Sky Variations (daily scattering via Lua) | `apps/openmw/mwlua/weatherbindings.cpp`, `apps/openmw/mwrender/renderingmanager.*` |
| MGE water (XE fresnel above/below, underwater refraction fade) | `files/shaders/compatibility/water.frag`, `apps/openmw/mwrender/water.cpp` |
| Shader-pack support (MGE parity uniforms: weather identity, sun, sky colour) | `apps/openmw/mwrender/renderingmanager.cpp`, `skyutil.cpp`, `components/fx/` |
| FP16 post-processing chain (`hdr chain` setting; kills repeated 8-bit quantization banding) | `apps/openmw/mwrender/postprocessor.cpp`, `components/settings/categories/postprocessing.hpp` |

New settings are declared in `files/settings-default.cfg` (search for
`occlusion`, `mge fog`, `distant statics`, `hdr chain`) — every one
documented in place, all defaulting to stock behaviour.

## Building

Identical to upstream OpenMW 0.51.0 — see the [official build
instructions](https://wiki.openmw.org/index.php?title=Development_Environment_Setup).
No new dependencies beyond the vendored `extern/masked-occlusion-culling`.

Note: this fork concentrates the distant-land code in
`apps/openmw/mwrender/renderingmanager.cpp`, which makes that translation
unit large. On some MSVC toolsets the linker may reject its debug info with
`LNK1103: debugging information corrupt`. If you hit it, build the Release
target without linker debug info (`GenerateDebugInformation=false` /
`/DEBUG:NONE`) — a distributed Release binary needs no PDB — or use a stable
VS 2022 toolchain.

## Companion downloads (not in this repo)

- The **shader pack** (omwfx ports of the MGE-era shaders, with the MGE
  `water_NRM.dds` animation volume) and the **OpenMW Graphics Extender**
  app (distant-land generation + settings UI) ship in the player
  package alongside this patch.

## Credits & licence

GPLv3, as OpenMW. Original visual design and reference implementations:
MGE XE (Hrnchamd and contributors). Occlusion culling based on
kartoffels' OpenMW fork. Classic shaders by Knu, Hrnchamd, peachykeen,
phal, vtastek, shadeMe, Apel, haasn/JPulowski, Jukka Korhonen & Avery
Lee (ported to omwfx in the shader pack).
