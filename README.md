MGE XE lighting for OpenMW
======

A fork of OpenMW 0.51.0 that adds a conduit letting OpenMW's compatibility shaders (the built-in shaders that draw terrain, objects, water, sky etc.) read live weather, sun and time of day. This enables MGE-style atmospheric scattering, with the distant haze getting its colour from light scattering through the air instead of fading to a flat tone, the sky blending into this haze, both being tinted by the sun, water reflecting the real sky, and nights properly darkening: previously this was only approximated via post-processing, preventing OpenMW and MGE XE parity when it came to lighting.

The fork also introduces MGE XE-style pre-generated distant land to keep performance smooth at large view distances, underwater rendering matching MGE's (exponential murk, reflections and refraction fogged by the viewer's medium, god rays), and integrates Kartoffels' experimental graphics optimizations (occlusion culling and shadow reuse) to 0.51.0. A ported set of MGE XE, MGG and STEP post-processing shaders and a companion app (OpenMW Graphics Extender) ship with the release package.

Every change against stock 0.51.0 can be reviewed in one diff: [base-0.51.0...mge-edition](https://github.com/Merch-Lis/openmw/compare/base-0.51.0...mge-edition)

Install
------

Download the package from [Releases](https://github.com/Merch-Lis/openmw/releases) and follow the README.txt inside. It overlays an existing OpenMW 0.51.0 install; your data files and configuration stay untouched.

Where the changes live
------

- files/shaders/compatibility/mge_fog.glsl: the MGE XE fog and scattering model, driven by weather, sun and time-of-day uniforms fed from the engine.
- apps/openmw/mwrender/objectpaging.cpp and apps/distantlandtool: distant statics in three size classes with residency rings, generated per load order by the [OpenMW Graphics Extender](https://github.com/Merch-Lis/openmw-graphics-extender).
- files/shaders/compatibility/water.frag, sky.frag, fog.glsl: water, sky and fog integration, including the from-below underwater path.
- The post-processing shaders are not part of the engine tree; they ship as a data folder in the release package.

Building (Windows/MSVC)
------

Standard OpenMW build process. One quirk: renderingmanager.obj's debug info trips LNK1103 on Release links, so the fork pins /DEBUG:NONE for the Release link in apps/openmw/CMakeLists.txt.

Credits
------

- OpenMW
- MGE XE (Hrnchamd): the reference implementation of the fog, scattering, water and distant-land model.
- [Kartoffels](https://github.com/kartoffels-ci/openmw): the integrated occlusion culling and shadow reuse.
- Original shaders: Knu (SSAO, Depth of Field), Hrnchamd (Eye Adaptation, Bloom Fine, Underwater Effects, Sunshafts co-author), peachykeen (trueBloom, Depth of Field co-author), phal (Sunshafts), vtastek (gammavtdt), shadeMe (ColorMood), Apel (darker interiors), haasn/JPulowski (deband), Jukka Korhonen & Avery Lee (film), and DassiD (the MGG / STEP shader compilations).
- Anthropic for making this port doable by a complete coding layman.

License: GPL-3.0, same as upstream OpenMW.
