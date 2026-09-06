OpenMGE XE lighting
======

A fork of OpenMW 0.51.0 that adds a conduit letting OpenMW's compatibility shaders (the built-in shaders that draw terrain, objects, water, sky etc.) read live weather, sun and time of day. This enables MGE-style atmospheric scattering, with the distant haze getting its colour from light scattering through the air instead of fading to a flat tone, the sky blending into this haze, both being tinted by the sun, water reflecting the real sky, and nights properly darkening: previously this was only approximated via post-processing, preventing OpenMW and MGE XE parity when it came to lighting.

The fork also introduces MGE XE's sea as real 3D geometry (weather-dependent waves carrying XE's own wave pattern, foam on crests and shores, caustics, a depth- and weather-based underwater murk), an optional MGE XE-style pre-generated distant land mechanism to keep performance smooth at large view distances, underwater rendering matching MGE's (exponential murk, reflections and refraction fogged by the viewer's medium, god rays), a 16-bit post-processing chain, an NPC-only lighting clamp, and integrates Kartoffels' experimental graphics optimizations (occlusion culling, shadow reuse, soft shadows) to 0.51.0. A ported set of MGE XE, MGG and STEP post-processing shaders, XE Sky Variations, the water script and a companion app (OpenMW Graphics Extender) ship with the release package.

A second package, Redux Plus, brings the same shaders to an unmodified OpenMW 0.51.0: the weather is estimated from the fog palette, fog range and sun light, and one extra post-processing pass corrects the estimate. It changes no engine code, so it is not on this fork; it is distributed alongside the Full package.

Every change against stock 0.51.0 can be reviewed in one diff: [base-0.51.0...mge-edition](https://github.com/Merch-Lis/openmw/compare/base-0.51.0...mge-edition)

Install
------

Download the package from [Releases](https://github.com/Merch-Lis/openmw/releases) and follow the README.txt inside. It overlays an existing OpenMW 0.51.0 install; your data files stay untouched, and the README.txt lists the settings to merge.

Where the changes are located
------

- files/shaders/compatibility/mge_fog.glsl: the MGE XE fog and scattering model, driven by weather, sun and time-of-day uniforms fed from the engine.
- apps/openmw/mwrender/objectpaging.cpp and apps/distantlandtool: distant statics in three size classes with residency rings, generated per load order by the [OpenMW Graphics Extender](https://github.com/Merch-Lis/openmw-graphics-extender).
- files/shaders/compatibility/water.frag, water.vert, mge_water_data.glsl, mge_shore_data.glsl: the sea - displaced wave geometry on a camera-following radial mesh, XE's water normal volume, foam, caustics, the from-below underwater path.
- files/shaders/compatibility/sky.frag, fog.glsl: sky and fog integration.
- files/data: the settings-window layout with the Shadows tab and the NPC-only clamp, the underwater murk pass (MGE_Water_Murk.omwfx), and the two water textures.
- The post-processing shaders are not part of the engine tree; they ship as a data folder in the release package.

Credits
------

- OpenMW
- MGE XE (Hrnchamd): the reference implementation of the fog, scattering, water and distant-land model, the XE Sky Variations original, and the water normal volume shipped as files/data/textures/mge/water_nrm.dds (GPL v2, with MGE XE).
- [Kartoffels](https://github.com/kartoffels-ci/openmw): the integrated occlusion culling, shadow reuse and soft shadows.
- Water: the raymarched wave-height technique, the gradient noise field, and the water-type and foam groundwork come from Rafael's Enhanced Water for OpenMW; the weather-driven wave amplitude, caustics and murk follow NullCascade's Wonders of Water.
- Original shaders: Knu (SSAO, Depth of Field), Hrnchamd (Eye Adaptation, Bloom Fine, Underwater Effects, Sunshafts co-author), peachykeen (trueBloom, Depth of Field co-author), phal (Sunshafts), vtastek (gammavtdt), shadeMe (ColorMood), Apel (darker interiors), haasn/JPulowski (deband), Jukka Korhonen & Avery Lee (film), and DassiD (the MGG / STEP shader compilations).
- Anthropic for making this port doable by a complete coding layman.

License: GPL-3.0, same as upstream OpenMW.
