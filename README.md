MGE XE lighting for OpenMW
======

A fork of [OpenMW](https://openmw.org) 0.51.0 that brings MGE XE's lighting
and distant-land rendering to the OpenMW engine: atmospheric scattering,
the MGE fog model (exponential, height-aware, weather-driven), the sky
blended into the scattered haze, water reflecting the real sky, proper
night darkening, and MGE-style pre-generated distant land for smooth
performance at large view distances. A ported MGE/MGG/STEP post-processing
chain and a companion app complete the package.

Every engine change against stock 0.51.0 is reviewable in one diff:
**[base-0.51.0...mge-edition](https://github.com/Merch-Lis/openmw/compare/base-0.51.0...mge-edition)**

Installing
------

Grab the drop-in package from
**[Releases](https://github.com/Merch-Lis/openmw/releases)** and follow the
5-step README.txt inside. It overlays an existing OpenMW 0.51.0 install
(engine + shaders + the OpenMW Graphics Extender app); your data files and
configuration stay untouched.

What's inside
------

- **MGE XE fog & scattering** — the XE `fogColourScatter`/`fogColour`
  model ported into the compatibility shaders (`files/shaders/compatibility/
  mge_fog.glsl`), driven by live weather, sun and time-of-day uniforms fed
  from the engine.
- **Distant land** — MGE XE-style pre-generated distant statics in three
  size classes with residency rings (`apps/openmw/mwrender/objectpaging.cpp`,
  `apps/distantlandtool`), generated per load order by the
  [OpenMW Graphics Extender](https://github.com/Merch-Lis/openmw-graphics-extender).
- **Underwater** — MGE's from-below water rendering: exponential murk,
  medium-correct reflections/refraction, god rays.
- **Post chain** — 13 ported MGE/MGG/STEP shaders (SSAO, sunshafts, bloom,
  eye adaptation, tonemapping, DoF and more), resolution-normalized.
- **Performance** — integrates kartoffels'
  [experimental optimizations](https://github.com/kartoffels-ci/openmw)
  (software occlusion culling, shadow-map reuse), plus an optional 16-bit
  post chain (`hdr chain`, off by default for stock parity).

Building (Windows/MSVC)
------

Standard OpenMW build process. One quirk: `renderingmanager.obj`'s debug
info trips `LNK1103` on Release links; the fork pins `/DEBUG:NONE` for the
Release link in `apps/openmw/CMakeLists.txt`.

Credits
------

- [OpenMW](https://gitlab.com/OpenMW/openmw) — the engine this fork builds on.
- [MGE XE](https://github.com/Hrnchamd/MGE-XE) (Hrnchamd) — the reference
  implementation of the fog, scattering, water and distant-land model.
- [kartoffels-ci/openmw](https://github.com/kartoffels-ci/openmw) — the
  integrated occlusion-culling and shadow-reuse optimizations.
- Original post-process shader authors: Knu, Hrnchamd, peachykeen, phal,
  vtastek, shadeMe, Apel, haasn/JPulowski, Jukka Korhonen & Avery Lee,
  and DassiD (MGG/STEP compilations).

License: GPL-3.0, same as upstream OpenMW.
