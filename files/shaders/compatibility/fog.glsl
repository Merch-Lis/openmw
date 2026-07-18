#if @skyBlending
#include "lib/core/fragment.h.glsl"

uniform float skyBlendingStart;
#endif

#ifdef LIB_LIGHTING_UTIL
// MGE XE fog & scattering port — see mge_fog.glsl for the model + provenance.
#include "mge_fog.glsl"

// True weather sky colour: sample the sky-blending RTT high on screen
// (always sky, regardless of scene occlusion). Falls back to fog colour.
vec3 mgeSampleSkyCol()
{
    if (mgeWeatherUniforms > 0.5)
        return mgeSkyColor; // live from the engine weather system
#if @skyBlending
    return sampleSkyColor(vec2(0.5, 0.9));
#else
    return gl_Fog.color.xyz;
#endif
}

// Per-pixel sky sample behind this fragment (the sky-blending RTT holds
// the REAL rendered sky incl. the cloud layer). a=0 when unavailable or in
// a reflection pass (the RTT belongs to the main camera; reflection
// fragcoords would sample wrong positions).
vec4 mgeSkyBehind()
{
#if @skyBlending
    if (!isReflection)
    {
        // WIDE HORIZONTAL AVERAGE, not the raw pixel: any per-pixel
        // image is camera-locked - even with cloud
        // shapes weighted out, its brightness unevenness showed as a
        // static screen-space fog mask on mid-saturated geometry.
        // Averaging along the same screen row keeps the sky's true
        // brightness AT THAT ELEVATION (clouds included - what fixes the
        // cutouts) while flattening the pattern to a smooth gradient.
        vec2 uv = gl_FragCoord.xy / screenRes;
        vec3 acc = vec3(0.0);
        for (int i = -3; i <= 3; ++i)
            acc += sampleSkyColor(vec2(clamp(uv.x + float(i) * 0.07, 0.02, 0.98), uv.y));
        return vec4(acc / 7.0, 1.0);
    }
#endif
    return vec4(0.0);
}

// World-direction entry point (water: MGE fogColourWater analogue —
// pure exp at all ranges, no near-linear switch).
vec4 applyFogAtDirWorld(vec4 color, float dist, vec3 dirWorld, float far)
{
    vec4 f = mgeFogColourWorld(dist, dirWorld, far, mgeSampleSkyCol(), false, mgeSkyBehind());
#ifdef ADDITIVE_BLENDING
    color.xyz *= f.a;
#else
    color.xyz = f.a * color.xyz + f.rgb;
#endif

    // Sky blending kept on the MGE path deliberately. MGE XE itself has
    // no such pass (distantland
    // .cpp renders statics to full DrawDist with fogApply only), but the
    // mix pulls far geometry toward the RENDERED sky at the fragment's own
    // screen position - possibly including the cloud layer - and whether
    // that helps or hurts the fog-weather far-band cutout has never been
    // A/B tested. The [Fog] 'sky blending' setting toggles it live: OFF =
    // pure MGE behaviour, ON = stock blend. Test before deciding.
#if @skyBlending
    float fadeValue = clamp((far - dist) / (far - skyBlendingStart), 0.0, 1.0);
    fadeValue *= fadeValue;
#ifdef ADDITIVE_BLENDING
    color.xyz *= fadeValue;
#else
    color.xyz = mix(sampleSkyColor(gl_FragCoord.xy / screenRes), color.xyz, fadeValue);
#endif
#endif

    return color;
}
#endif

vec4 applyFogAtDist(vec4 color, float euclideanDist, float linearDist, float far)
{
#if @radialFog
    float dist = euclideanDist;
#else
    float dist = abs(linearDist);
#endif

#ifdef LIB_LIGHTING_UTIL
    // MGE fog for distance-only callers (groundcover etc.): reconstruct the
    // view direction from gl_FragCoord so no extra varyings are needed
    // (groundcover's vertex-lit variant has no passViewPos).
    vec2 fogNdc = 2.0 * gl_FragCoord.xy / screenRes - 1.0;
    vec3 fogViewRay = vec3(fogNdc.x / gl_ProjectionMatrix[0][0], fogNdc.y / gl_ProjectionMatrix[1][1], -1.0);
    vec3 fogDirWorld = normalize((osg_ViewMatrixInverse * vec4(fogViewRay, 0.0)).xyz);
    vec4 f = mgeFogColourWorld(dist, fogDirWorld, far, mgeSampleSkyCol(), true, mgeSkyBehind());
  #ifdef ADDITIVE_BLENDING
    color.xyz *= f.a;
  #else
    color.xyz = f.a * color.xyz + f.rgb;
  #endif
#else
  #if @exponentialFog
    float fogValue = 1.0 - exp(-2.0 * max(0.0, dist - gl_Fog.start/2.0) / (gl_Fog.end - gl_Fog.start/2.0));
  #else
    float fogValue = clamp((dist - gl_Fog.start) * gl_Fog.scale, 0.0, 1.0);
  #endif
  #ifdef ADDITIVE_BLENDING
    color.xyz *= 1.0 - fogValue;
  #else
    color.xyz = mix(color.xyz, gl_Fog.color.xyz, fogValue);
  #endif
#endif

#if @skyBlending
    float fadeValue = clamp((far - dist) / (far - skyBlendingStart), 0.0, 1.0);
    fadeValue *= fadeValue;
#ifdef ADDITIVE_BLENDING
    color.xyz *= fadeValue;
#else
    color.xyz = mix(sampleSkyColor(gl_FragCoord.xy / screenRes), color.xyz, fadeValue);
#endif
#endif

    return color;
}

vec4 applyFogAtPos(vec4 color, vec3 pos, float far)
{
#if @radialFog
    float dist = length(pos);
#else
    float dist = abs(pos.z);
#endif

#ifdef LIB_LIGHTING_UTIL
    // MGE XE transmittance + inscatter model (fogApply: T*scene + inscatter)
    vec4 f = mgeFogColour(pos, far, mgeSampleSkyCol(), mgeSkyBehind());
  #ifdef ADDITIVE_BLENDING
    color.xyz *= f.a;
  #else
    color.xyz = f.a * color.xyz + f.rgb;
  #endif
#else
  #if @exponentialFog
    float fogValue = 1.0 - exp(-2.0 * max(0.0, dist - gl_Fog.start/2.0) / (gl_Fog.end - gl_Fog.start/2.0));
  #else
    float fogValue = clamp((dist - gl_Fog.start) * gl_Fog.scale, 0.0, 1.0);
  #endif
  #ifdef ADDITIVE_BLENDING
    color.xyz *= 1.0 - fogValue;
  #else
    color.xyz = mix(color.xyz, gl_Fog.color.xyz, fogValue);
  #endif
#endif

#if @skyBlending
    float fadeValue = clamp((far - dist) / (far - skyBlendingStart), 0.0, 1.0);
    fadeValue *= fadeValue;
#ifdef ADDITIVE_BLENDING
    color.xyz *= fadeValue;
#else
    color.xyz = mix(sampleSkyColor(gl_FragCoord.xy / screenRes), color.xyz, fadeValue);
#endif
#endif

    return color;
}
