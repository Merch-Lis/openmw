#if @skyBlending
#include "lib/core/fragment.h.glsl"

uniform float skyBlendingStart;
#endif

#ifdef LIB_LIGHTING_UTIL
// MGE XE fog & scattering port; see mge_fog.glsl for the model + provenance.
#include "mge_fog.glsl"

// True weather sky colour: mgeSampleSkyCol() moved into mge_fog.glsl
// the vertex stage must compute it, while this file's remaining content
// (sky-RTT sampling, gl_FragCoord reconstruction) is fragment-only. The
// full provenance comment moved with it; history in git.

// Stock sky-RTT systematic error and its rebase. The RTT's sky program has
// a degenerate light 0 on stock, so its scatter runs on the vertical-sun
// guard while the visible dome uses the real sun. The error is therefore
// azimuth-structured, not a constant darkening: sim_holistic_frame.py
// IS the raw RTT content, grey-desaturated exactly like vertical-sun
// scatter) puts it at +25/255 toward the sun to -10/255 away from it; the
// earlier "54/255 darker" v5 figure was a sampling-region artifact.
// Additive rebase: + (scatter(real sun) - scatter(vertical sun)) corrects
// dome pixels exactly (including the near-horizon cloud rim, whose fade
// colour is the same scatter), and cloud-veil pixels to within
// veilAlpha * |dome delta| (sim: <= 11/255 at Clear-day veils, worst
// 28/255 at 80% veil). This restores cloud-aware convergence on stock -
// the parity factor behind Full's silhouette melt. The scene programs DO
// have a usable light 0 on stock, so both scatter terms are computable
// here; at steady day the delta is insensitive to the skyCol estimate
// (sim: 0/255 drift). In bad weather the RTT dome is emission/palette
// based (no sun term; its own nice gate is 0 in that pass) - delta scales
// out with nice.
// Live A/B toggles for the stock sky-blend re-enable. must stay defined
// above mgeSkyBehind.
// MGE_STOCK_SKY_BLEND: 0 = blend skipped on stock (the entry-19 bypass
//   state); 1 = blend + stock skyBehind active, same semantics as Full.
// MGE_STOCK_RTT_REBASE: adds the vertical-sun delta to the sample.
//   889/890 shows the RTT pass renders with a valid real sun on both exes
//   (water rows = RTT samples of the probe-painted sky: guard=0,
//   sunZ 0.855/0.867 at every row) - the RTT needs no correction, and the
//   first in-game test's warm/yellow sun-side corner was this delta
//   correcting a non-error. Keep 0; the machinery stays for reuse if a
//   real systematic RTT error is ever measured.
// Colour-only by construction: mixes the fragment's final colour toward
// the sky-RTT sample from skyBlendingStart (0.8*far) outward. Specific
// A/B's purpose); per-pixel epilogue sample is camera-locked, so cloud
// shapes can paint screen-space pattern onto far content; slight fight
// with the Sky Variations bridge on varied days (RTT dome carries preset
// scatter). Retract = 0 + redeploy both installs.
#define MGE_STOCK_SKY_BLEND 1
#define MGE_STOCK_RTT_REBASE 0
// MGE_SKY_BLEND_MIRROR_GATE: skip the sky-blend epilogue in mirrored
//   passes on every tier (the reported "reflection without a
//   source"). The Full-tier tail of
//   mgeSkyBlendGate ran in the water reflection pass, where
//   sampleSkyColor reads the main camera's sky RTT at the mirror's own
//   fragcoords, a wrong-position paste. Beyond skyBlendingStart the
//   fadeValue tends to 0 and the fragment becomes that sample, so far
//   mirrored distant land (fully concealed in the direct view by the
//   correctly-positioned blend) rendered as pale ghost masses in the
//   reflection. The stock branch (mgeStockMirrored) and mgeSkyBehind
//   always carried this skip; the Full tail lacked it. Pairs with
//   MGE_MIRROR_SEAL_WIDEN in mge_fog.glsl (the concealment-parity
//   half). 0 restores the paste byte-exact for A/B.
#ifndef MGE_SKY_BLEND_MIRROR_GATE
#define MGE_SKY_BLEND_MIRROR_GATE 1
#endif

vec3 mgeStockRttDelta(vec3 dirWorld)
{
    float nice = mgeGetNiceWeather();
    if (nice < 0.001)
        return vec3(0.0);
    vec3 skyCol = mgeSampleSkyCol();
    return nice * (mgeScatter(dirWorld, 1.0, skyCol)
                 - mgeScatterWithSun(dirWorld, 1.0, skyCol, vec3(0.0, 0.0, 1.0)));
}

// Per-pixel sky sample behind this fragment (the sky-blending RTT holds
// the actual rendered sky incl. the cloud layer). a=0 when unavailable or
// in a reflection pass (the RTT belongs to the main camera; reflection
// fragcoords would sample wrong positions).
vec4 mgeSkyBehind(vec3 dirWorld)
{
#if @skyBlending
    // Stock exes: usable after the vertical-sun rebase (mgeStockRttDelta
    // above); mirrored/refraction passes keep the analytic fallback (the
    // main-camera RTT sample at their fragcoords is garbage). Gated with
    // the sky-blend toggle (same A/B unit).
#if MGE_STOCK_SKY_BLEND
    if (mgeWeatherUniforms < 0.5 && (mgeStockMirrored() || !mgeCamAboveWater() || isRefraction))
        return vec4(0.0);
#else
    if (mgeWeatherUniforms < 0.5)
        return vec4(0.0);
#endif
    // Mirror detection needs both channels: isReflection binds per-program
    // and provably misses some of the reflection RTT's programs on stock,
    // where this main-camera RTT sample at the reflection's fragcoords is
    // garbage - camera-dependent neon tints on reflected silhouettes.
    if (!isReflection && !mgeStockMirrored())
    {
        // Wide horizontal average, not the raw pixel: any per-pixel image
        // is camera-locked, so its brightness unevenness reads as a static
        // screen-space fog mask on mid-saturated geometry, even with cloud
        // shapes weighted out. Averaging along the same screen row keeps
        // the sky's true brightness at that elevation (clouds included,
        // which is what fixes the cutouts) while flattening the pattern to
        // a smooth gradient.
        vec2 uv = gl_FragCoord.xy / screenRes;
        vec3 acc = vec3(0.0);
        for (int i = -3; i <= 3; ++i)
            acc += sampleSkyColor(vec2(clamp(uv.x + float(i) * 0.07, 0.02, 0.98), uv.y));
        acc /= 7.0;
        // Degenerate-sample guard (unbound sampler in this program, or an
        // interior/black RTT): report "unavailable" rather than converging
        // fog to black.
        if (dot(acc, acc) < 1e-6)
            return vec4(0.0);
#ifndef MGE_CORRIDOR_SKYROW
// the water-sky line during corridors and did not move the bank,
// rolled back same-day; the row-direction/row-choice questions are the
// next session's opening investigation. The code stays for it.
#define MGE_CORRIDOR_SKYROW 0
#endif
#if MGE_ENDPOINT_DECOMPOSITION && MGE_CORRIDOR_SKYROW
        // fogged far land converges to this sample, the RTT rows behind
        // it, which during storm arrivals carry the horizon glow:
        // measured brighter/paler than the visible sky above the ridge
        // line (measured profile: hidden rows 0.636-0.643 lum against
        // 0.626-0.631 visible; the reported pale-bright early bank).
        // The eye compares silhouettes
        // against the sky above them, so mid-corridor the target blends
        // toward a sample 0.06 uv higher (the C8/147 one-step lesson).
        // steady keeps the exact behind-row (weight 0 at i==j), that is
        // the seamless-horizon invariant's own mechanism. Contraction
        // toward a measured visible value: cannot recreate the
        // white-wall class (which was over-bright vs everything).
        // Weight: the hue family's 4x fade, conf-gated; nice<->nice
        // gated with the rest of the family. Both tiers (the corridor
        // unlock feeds conf on Full; tier consistency).
        {
            int rwI;
            int rwJ;
            float rwA;
            float rwH;
            float rwC = mgeDecomposeIdx(rwI, rwJ, rwA, rwH);
            float rwT = (rwI == rwJ) ? 0.0 : 4.0 * rwA * (1.0 - rwA);
#if MGE_WXT_NICE_GATE
            rwT *= mgeWxtNiceGate();
#endif
            float rwW = rwC * min(1.0, 4.0 * rwT);
            if (rwW > 0.001)
            {
                vec3 accUp = vec3(0.0);
                for (int i = -3; i <= 3; ++i)
                    accUp += sampleSkyColor(vec2(
                        clamp(uv.x + float(i) * 0.07, 0.02, 0.98),
                        min(uv.y + 0.06, 0.98)));
                accUp /= 7.0;
                if (dot(accUp, accUp) > 1e-6)
                    acc = mix(acc, accUp, rwW);
            }
        }
#endif
#if MGE_STOCK_RTT_REBASE
        if (mgeWeatherUniforms < 0.5)
            acc += mgeStockRttDelta(dirWorld); // vertical-sun rebase (refuted; off)
#endif
        return vec4(acc, 1.0);
    }
#endif
    return vec4(0.0);
}

// Sky-blend epilogue gate, shared by the three applyFog* variants below.
// Returns the fadeValue to use and rebases skySample in place on stock.
// Full tier semantics unchanged (bit-identical): skip underwater/refraction.
// Stock tier (behind MGE_STOCK_SKY_BLEND): the blend is re-enabled with
// the vertical-sun rebase; skipped in mirrored passes, underwater, and
// where the RTT pixel is black (below the atmosphere cylinder's bottom
// edge, interiors) so far content is never pulled toward a black sample.
float mgeSkyBlendGate(inout vec3 skySample, vec3 dirWorld, float fadeValue)
{
    if (mgeWeatherUniforms < 0.5)
    {
#if MGE_STOCK_SKY_BLEND
        if (mgeStockMirrored() || !mgeCamAboveWater() || isRefraction
            || dot(skySample, skySample) < 1e-6)
            return 1.0;
#if MGE_STOCK_RTT_REBASE
        skySample += mgeStockRttDelta(dirWorld);
#endif
        // (MGE_STOCK_SKY_BLEND_FADE).
        return fadeValue;
#else
        return 1.0;
#endif
    }
#if MGE_SKY_BLEND_MIRROR_GATE
    // main-camera sky RTT is positionally meaningless in a mirrored
    // pass, never blend toward it there. On Full this rides
    // isReflection (the reflection camera's stateset uniform,
    // water.cpp); mgeStockMirrored() covers the stock tier's known
    // per-program binding gaps (it returns false on Full by design).
    if (isReflection || mgeStockMirrored())
        return 1.0;
#endif
    if (!mgeCamAboveWater() || isRefraction)
        return 1.0;
    return fadeValue;
}

// World-direction entry point (water: MGE fogColourWater analogue;
// pure exp at all ranges, no near-linear switch).
vec4 applyFogAtDirWorld(vec4 color, float dist, vec3 dirWorld, float far)
{
#if @skyBlending && MGE_PARITY_PROBE
    // Probe v5: paint geometry with its own sky-RTT sample; the sky
    // renders normally. Any horizon discontinuity = RTT != visible sky.
    color.xyz = sampleSkyColor(gl_FragCoord.xy / screenRes);
    return color;
#endif
    vec4 f = mgeFogColourWorld(dist, dirWorld, far, mgeSampleSkyCol(), false, mgeSkyBehind(dirWorld));
#ifdef ADDITIVE_BLENDING
    color.xyz *= f.a;
#else
    color.xyz = f.a * color.xyz + f.rgb;
#endif

    // Sky blending kept on the MGE path deliberately. MGE XE itself has
    // no such pass (distantland.cpp renders statics to full DrawDist with
    // fogApply only), but the mix pulls far geometry toward the rendered
    // sky at the fragment's own screen position, possibly including the
    // cloud layer; whether that helps or hurts the fog-weather far-band
    // cutout is untested. The [Fog] 'sky blending' setting toggles it
    // live: off is pure MGE behaviour, on is the stock blend.
#if @skyBlending
    float fadeValue = clamp((far - dist) / (far - skyBlendingStart), 0.0, 1.0);
    fadeValue *= fadeValue;
#ifdef LIB_LIGHTING_UTIL
    // Underwater/refraction skip (murk must win) + mirrored-pass and
    // black-pixel skips + the stock vertical-sun rebase: mgeSkyBlendGate.
    // convergence is the Full-melt parity factor.
    vec3 skySample = sampleSkyColor(gl_FragCoord.xy / screenRes);
    fadeValue = mgeSkyBlendGate(skySample, dirWorld, fadeValue);
  #ifdef ADDITIVE_BLENDING
    color.xyz *= fadeValue;
  #else
    color.xyz = mix(skySample, color.xyz, fadeValue);
  #endif
#else
  #ifdef ADDITIVE_BLENDING
    color.xyz *= fadeValue;
  #else
    color.xyz = mix(sampleSkyColor(gl_FragCoord.xy / screenRes), color.xyz, fadeValue);
  #endif
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
#if @skyBlending && MGE_PARITY_PROBE
    color.xyz = sampleSkyColor(gl_FragCoord.xy / screenRes);
    return color;
#endif
    // MGE fog for distance-only callers (groundcover etc.): reconstruct the
    // view direction from gl_FragCoord so no extra varyings are needed
    // (groundcover's vertex-lit variant has no passViewPos).
    vec2 fogNdc = 2.0 * gl_FragCoord.xy / screenRes - 1.0;
    vec3 fogViewRay = vec3(fogNdc.x / gl_ProjectionMatrix[0][0], fogNdc.y / gl_ProjectionMatrix[1][1], -1.0);
    vec3 fogDirWorld = normalize((osg_ViewMatrixInverse * vec4(fogViewRay, 0.0)).xyz);
    vec4 f = mgeFogColourWorld(dist, fogDirWorld, far, mgeSampleSkyCol(), true, mgeSkyBehind(fogDirWorld));
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
#ifdef LIB_LIGHTING_UTIL
    // Underwater/refraction skip (murk must win) + mirrored-pass and
    // black-pixel skips + the stock vertical-sun rebase: mgeSkyBlendGate.
    // convergence is the Full-melt parity factor. Direction reconstructed
    // from gl_FragCoord (same recipe as the fog call above).
    vec2 sbNdc = 2.0 * gl_FragCoord.xy / screenRes - 1.0;
    vec3 sbViewRay = vec3(sbNdc.x / gl_ProjectionMatrix[0][0], sbNdc.y / gl_ProjectionMatrix[1][1], -1.0);
    vec3 sbDirWorld = normalize((osg_ViewMatrixInverse * vec4(sbViewRay, 0.0)).xyz);
    vec3 skySample = sampleSkyColor(gl_FragCoord.xy / screenRes);
    fadeValue = mgeSkyBlendGate(skySample, sbDirWorld, fadeValue);
  #ifdef ADDITIVE_BLENDING
    color.xyz *= fadeValue;
  #else
    color.xyz = mix(skySample, color.xyz, fadeValue);
  #endif
#else
  #ifdef ADDITIVE_BLENDING
    color.xyz *= fadeValue;
  #else
    color.xyz = mix(sampleSkyColor(gl_FragCoord.xy / screenRes), color.xyz, fadeValue);
  #endif
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
#if @skyBlending && MGE_PARITY_PROBE
    color.xyz = sampleSkyColor(gl_FragCoord.xy / screenRes);
    return color;
#endif
    // MGE XE transmittance + inscatter model (fogApply: T*scene + inscatter)
    vec3 fogPosDirWorld = normalize((osg_ViewMatrixInverse * vec4(normalize(pos), 0.0)).xyz);
    vec4 f = mgeFogColour(pos, far, mgeSampleSkyCol(), mgeSkyBehind(fogPosDirWorld));
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
#ifdef LIB_LIGHTING_UTIL
    // Underwater/refraction skip (murk must win) + mirrored-pass and
    // black-pixel skips + the stock vertical-sun rebase: mgeSkyBlendGate.
    // convergence is the Full-melt parity factor. Direction reconstructed
    // from gl_FragCoord (same recipe as the fog call above).
    vec2 sbNdc = 2.0 * gl_FragCoord.xy / screenRes - 1.0;
    vec3 sbViewRay = vec3(sbNdc.x / gl_ProjectionMatrix[0][0], sbNdc.y / gl_ProjectionMatrix[1][1], -1.0);
    vec3 sbDirWorld = normalize((osg_ViewMatrixInverse * vec4(sbViewRay, 0.0)).xyz);
    vec3 skySample = sampleSkyColor(gl_FragCoord.xy / screenRes);
    fadeValue = mgeSkyBlendGate(skySample, sbDirWorld, fadeValue);
  #ifdef ADDITIVE_BLENDING
    color.xyz *= fadeValue;
  #else
    color.xyz = mix(skySample, color.xyz, fadeValue);
  #endif
#else
  #ifdef ADDITIVE_BLENDING
    color.xyz *= fadeValue;
  #else
    color.xyz = mix(sampleSkyColor(gl_FragCoord.xy / screenRes), color.xyz, fadeValue);
  #endif
#endif
#endif

    return color;
}
