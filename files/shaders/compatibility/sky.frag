#version 120

#if @useUBO
    #extension GL_ARB_uniform_buffer_object : require
#endif

#if @useGPUShader4
    #extension GL_EXT_gpu_shader4: require
#endif

#include "lib/sky/passes.glsl"

// MGE XE fog port: the sky dome shares the fog scattering equation at
// fogdist=1 so the horizon is seamless (XE Main.fx SkyPS).
#include "lib/light/lighting_util.glsl"
#include "mge_fog.glsl"

uniform int pass;
uniform sampler2D diffuseMap;
uniform sampler2D maskMap;      // PASS_MOON
uniform float opacity;          // PASS_CLOUDS, PASS_ATMOSPHERE_NIGHT
uniform vec4 moonBlend;         // PASS_MOON
uniform vec4 atmosphereFade;    // PASS_MOON

varying vec2 diffuseMapUV;
varying vec4 passColor;
varying vec3 passViewPos;

vec3 skyWorldDir()
{
    return normalize((osg_ViewMatrixInverse * vec4(normalize(passViewPos), 0.0)).xyz);
}

void paintAtmosphere(inout vec4 color)
{
    color = gl_FrontMaterial.emission;
    // MGE XE: replace the dome colour with the scattering equation + dither
    color.xyz = mgeFogColourSky(skyWorldDir(), gl_FrontMaterial.emission.xyz, gl_FrontMaterial.emission.xyz)
              + vec3(mgeSkyDither(gl_FragCoord.xy));
    // Vanilla fades the dome rim to transparency (vertex alpha) so the
    // CLEAR COLOUR (= raw palette fog) shows through as the sky-fog blend.
    // MGE instead re-colours the engine fog to scatter every frame
    // (distantland.cpp "Simplified version of scattering"); our dome already
    // carries the correct colour at every direction, so render it opaque —
    // the palette colour must never show through in nice weather (under a
    // dark-fog palette like MGG it reads as a blue band above the horizon).
    color.a = 1.0;
}

void paintAtmosphereNight(inout vec4 color)
{
    color = texture2D(diffuseMap, diffuseMapUV);
    color.a *= passColor.a * opacity;
}

void paintClouds(inout vec4 color)
{
    color = texture2D(diffuseMap, diffuseMapUV);
    color.a *= passColor.a * opacity;
    color.xyz = clamp(color.xyz * gl_FrontMaterial.emission.xyz, 0.0, 1.0);

    // ease transition between clear color and atmosphere/clouds.
    // DELIBERATE deviation from both stock and MGE: stock fades clouds to
    // gl_Fog.color because ITS scene fog converges there — ours converges to
    // the scatter colour, and a dark palette fog (e.g. MGG Clear deep blue)
    // otherwise paints a fog-coloured band across the horizon sky. MGE
    // needs no fade at all only because its cloud rim sits against the
    // scatter dome. Fade to the dome colour at this direction instead:
    // nice weather -> scatter, bad weather -> palette fog (= stock).
    vec3 horizonCol = mgeFogColourSky(skyWorldDir(), gl_Fog.color.xyz, gl_FrontMaterial.emission.xyz);

    // Dense-weather raised sky-fog band: clouds fade
    // into the band wherever it covers the dome, so fog visually wraps
    // tall massifs instead of dark clouds cutting in right above them.
    // mgeSkyFogH is raise-aware and ff-gated: in Clear/Cloudy the band is
    // the stock XE rim and this mix is a no-op above it.
    float wDenseCloud = mgeDerivedFog().wDense;
    float band = (1.0 - mgeSkyFogH(skyWorldDir().z)) * wDenseCloud;
    color.xyz = mix(color.xyz, horizonCol, band);

    color = mix(vec4(horizonCol, color.a), color, passColor.a);
}

void paintMoon(inout vec4 color)
{
    vec4 phase = texture2D(diffuseMap, diffuseMapUV);
    vec4 mask = texture2D(maskMap, diffuseMapUV);

    // Morrowind does this in two passes

    // First pass: moon shadow, normal blending (src alpha, 1 - src alpha)
    // dst.rgb = mask.rgb * mask.a + dst.rgb * (1 - mask.a)
    // Second pass: moon phase, additive blending (src alpha, 1)
    // dst.rgb += phase.rgb * phase.a

    // The same is doable in a single pass through premultiplied alpha blending
    // color.rgb = mask.rgb * mask.a + phase.rgb * phase.a
    // color.a = mask.a
    // dst.rgb = color.rgb + dst.rgb * (1 - color.a)

    vec3 maskTinted = mask.rgb * atmosphereFade.rgb;
    float maskAlpha = mask.a * atmosphereFade.a;
    vec3 phaseTinted = phase.rgb * moonBlend.rgb;
    float phaseAlpha = phase.a * atmosphereFade.a;

    color.rgb = maskTinted * maskAlpha + phaseTinted * phaseAlpha;
    color.a = maskAlpha;
}

void paintSun(inout vec4 color)
{
    color = texture2D(diffuseMap, diffuseMapUV);
    color.a *= gl_FrontMaterial.diffuse.a;
}

void paintSunglare(inout vec4 color)
{
    // MGE parity: the classic Sunshafts shader declares
    // disableSunglare — MGE suppresses the vanilla sunglare while it runs
    // (its own disc + rays replace it). OpenMW has no annotation channel,
    // so suppress here; without this BOTH glare stacks draw and the sun
    // reads far too hot (especially at sunset, amplified by bloom).
    color = vec4(0.0);
}

void processSunflashQuery()
{
    const float threshold = 0.8;

    if (texture2D(diffuseMap, diffuseMapUV).a <= threshold)
        discard;
}

void main()
{
    vec4 color = vec4(0.0);

    if (pass == PASS_ATMOSPHERE)
        paintAtmosphere(color);
    else if (pass == PASS_ATMOSPHERE_NIGHT)
        paintAtmosphereNight(color);
    else if (pass == PASS_CLOUDS)
        paintClouds(color);
    else if (pass == PASS_MOON)
        paintMoon(color);
    else if (pass == PASS_SUN)
        paintSun(color);
    else if (pass == PASS_SUNGLARE)
        paintSunglare(color);
    else if (pass == PASS_SUNFLASH_QUERY)
    {
        processSunflashQuery();
        return;
    }

    // Underwater source probe (mge_fog.glsl, normally off): everything the
    // sky program draws while the camera is submerged tints GREEN.
    if (mgeUwProbe())
        color.xyz = mix(color.xyz, vec3(0.0, 1.0, 0.0), 0.6);

    gl_FragData[0] = color;
}
