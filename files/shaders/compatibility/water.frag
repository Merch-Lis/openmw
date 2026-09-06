#version 120

#if @useUBO
    #extension GL_ARB_uniform_buffer_object : require
#endif

#if @useGPUShader4
    #extension GL_EXT_gpu_shader4: require
#endif

#include "lib/core/fragment.h.glsl"

// Inspired by Blender GLSL Water by martinsh ( https://devlog-martinsh.blogspot.de/2012/07/waterundewater-shader-wip.html )

// tweakables -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --

const float VISIBILITY = 2500.0;
const float VISIBILITY_DEPTH = VISIBILITY * 1.5;

const vec2 BIG_WAVES = vec2(0.1, 0.1); // strength of big waves
const vec2 MID_WAVES = vec2(0.1, 0.1); // strength of middle sized waves
const vec2 MID_WAVES_RAIN = vec2(0.2, 0.2);
const vec2 SMALL_WAVES = vec2(0.1, 0.1); // strength of small waves
const vec2 SMALL_WAVES_RAIN = vec2(0.3, 0.3);

const float WAVE_CHOPPYNESS = 0.05;                // wave choppyness
const float WAVE_SCALE = 75.0;                     // overall wave scale

const float BUMP = 0.5;                            // overall water surface bumpiness
const float BUMP_RAIN = 2.5;
const float REFL_BUMP = 0.07;                      // reflection distortion amount
                                                   // (stock 0.10; the lower value narrows the pale
                                                   // contact halo where island shores meet their reflection)
const float REFR_BUMP = 0.07;                      // refraction distortion amount
// XE Mod Water.fx UnderwaterPS verbatim: from-below fresnel curve and the
// distance constant of the refraction-to-fog fade.
const float MGE_UW_FRESNEL_BIAS = 1.12;
const float MGE_UW_FRESNEL_SLOPE = 0.65;
const float MGE_UW_FRESNEL_POWER = 8.0;
const float MGE_UW_REFLECTION_SCALE = 1.0;   // from-below mirror intensity (1 = MGE).
                                             // With the reflection RTT murk-fogged over
                                             // the mirrored path, MGE's own fresnel
                                             // strength reads correctly at 1.0; only
                                             // reduce this if that fogging is removed.
// Submersion depth over which the from-below mirror trusts the reflection RTT.
// At the surface-crossing moment the RTT is untrustworthy BY content: OpenMW
// flips the reflection cull plane when the eye submerges (water.cpp:76, the
// PlaneCullCallback), so the RTT holds only the mirrored below-water world -
// the sky is above-water content and is culled - and over deep water the
// mirrored rays hit nothing at all, leaving the camera clear colour, which is
// black (rtt.cpp:188 clears colour; no setClearColor anywhere; OSG default).
// At the crossing every surface ray is near-grazing, the UW fresnel above
// legitimately reaches ~1 on ripple back-faces, and those fragments painted
// the black void over the correct refracted view - the reported "above-water
// surface as black-skied" on emerging. (MGE XE never showed this because its
// underwater reflection texture keeps the mirrored above-water world, sky
// included - same fresnel, opposite RTT content.)
// Physically, an internal-reflection mirror over deep water shows extinction
// - the murk - never black: so the mirror blends from pure murk at the
// crossing back to the RTT over this many units of camera submersion, by
// which point the mirrored-seafloor content is real and the grazing void
// angles are gone. The regular underwater view is untouched either way:
// looking up steeply, this fresnel is ~0 and the surface is pure refraction.
const float MGE_UW_MIRROR_RAMP = 45.0;

// (MGE_UW_GRAZE_MURK and its constants live in mge_water_data.glsl,
// the switch tooling rewrites only that file.)

#if @sunlightScattering
const float SCATTER_AMOUNT = 0.3;                  // amount of sunlight scattering
const vec3 SCATTER_COLOUR = vec3(0.0,1.0,0.95);    // colour of sunlight scattering
const vec3 SUN_EXT = vec3(0.45, 0.55, 0.68);       // sunlight extinction
#endif

const float SUN_SPEC_FADING_THRESHOLD = 0.15;       // visibility at which sun specularity starts to fade
const float SPEC_HARDNESS = 256.0;                 // specular highlights hardness
const float SPEC_BUMPINESS = 5.0;                  // surface bumpiness boost for specular
const float SPEC_BRIGHTNESS = 1.5;                 // boosts the brightness of the specular highlights

const float BUMP_SUPPRESS_DEPTH = 300.0;           // at what water depth bumpmap will be suppressed for reflections and refractions (prevents artifacts at shores)
const float REFR_FOG_DISTORT_DISTANCE = 3000.0;    // at what distance refraction fog will be calculated using real water depth instead of distorted depth (prevents splotchy shores)

const vec2 WIND_DIR = vec2(0.5f, -0.8f);
const float WIND_SPEED = 0.2f;

const vec3 WATER_COLOR = vec3(0.090195, 0.115685, 0.12745);

#if @wobblyShores
const float WOBBLY_SHORE_FADE_DISTANCE = 6200.0;   // fade out wobbly shores to mask precision errors, the effect is almost impossible to see at a distance
#endif

// -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -

vec2 normalCoords(vec2 uv, float scale, float speed, float time, float timer1, float timer2, vec3 previousNormal)
{
  return uv * (WAVE_SCALE * scale) + WIND_DIR * time * (WIND_SPEED * speed) -(previousNormal.xy/previousNormal.zz) * WAVE_CHOPPYNESS + vec2(time * timer1,time * timer2);
}

uniform sampler2D rippleMap;
// playerPos is declared in mge_fog.glsl (included via fog.glsl); the
// fragment stage doesn't use it directly.

varying vec3 worldPos;

varying vec2 rippleMapUV;

varying vec4 position;
varying float linearDepth;

uniform sampler2D normalMap;

uniform float osg_SimulationTime;

uniform float near;
uniform float far;

uniform float rainIntensity;

// (windSpeed and mgeWeatherWaveScale moved to mge_water_data.glsl,
// strength chain, and the 171/172 lesson demands one owner.)

uniform vec2 screenRes;

#define PER_PIXEL_LIGHTING 0

// decomposition core + vet + rescue, so wave state and water fog run
// confident+correct through every twilight transition (the sea
// is computed per-vertex there and this program decodes varyings only,
// paying no core footprint at all.
#define MGE_WX_STAGE 0

#include "shadows_fragment.glsl"
#include "lib/light/lighting.glsl"
#include "fog.glsl"
#include "mge_water_data.glsl"

// (This block must sit below the mge_water_data.glsl include: the guard
// reads MGE_WATER_DISPLACE, which that include defines. Placed above it,
// the preprocessor strips the declarations while the use sites further
#if MGE_WATER_WAVE_SHAPES && MGE_WATER_DISPLACE
// Displaced wave geometry (Full tier). mgeWaterDisplace: fork-fed runtime
// gate, 1 only while the radial mesh is live; a stock exe never declares it
// and GLSL reads 0. mgeDispV: the vertex displacement height - the crest
// input on the displaced path (the marched relief's replacement).
// mgeScreenPosClamp: clip position of the vertex lowered by |displacement| -
// XE's screenposclamp (XE Mod Water.fx:147-151), so the reflection lookup
// never samples below the displaced surface.
uniform float mgeWaterDisplace;
varying float mgeDispV;
varying vec4 mgeScreenPosClamp;
#endif
#include "lib/water/fresnel.glsl"
#include "lib/water/rain_ripples.glsl"
#include "lib/view/depth.glsl"

#if MGE_WATER_FOAM
// Emulates MGE XE's animated water volume. XE Water.fx samples
// tex3D(sampWater3d, vec3(uv, time)) - a 256x256x32 volume - so its foam morphs
// through 32 slices and its foam UVs carry no drift at all. That is why it never
// reads as travelling in one direction. We only have a 2D texture on this tier,
// so we walk a pseudo time axis instead: cross-dissolve between two decorrelated
// offsets of the same texture, jumping to a fresh offset every cycle. The
// pattern evolves in place rather than sliding.
#if MGE_FOAM_VOLUME
// MGE XE's actual animation, not an approximation of it. Its water_NRM.dds is a
// 256x256x32 volume and the foam is composed as col.b*0.5 + col.r*0.25 +
// col.g*0.25 per slice (XE Water.fx:494-496); alpha there carries wave height,
// which is why we could not simply reuse the file. Sixteen of those slices are
// packed as a 4x4 atlas into our alpha channel, so this samples real frames and
// blends between them - the volume walk MGE XE does with tex3D.
vec2 mgeAtlasUV(vec2 uv, float frame)
{
    float f = mod(floor(frame), 16.0);
    vec2 tile = vec2(mod(f, 4.0), floor(f * 0.25));
    // Inset inside the tile: neighbouring frames are adjacent in the atlas, so
    // filtering and mip levels would otherwise bleed one frame into the next.
    // Per-frame spatial jump inside the tile, on top of the frame animation.
    // MGE XE's frames are a coherent animation - adjacent ones decorrelate only
    // 0.665 - so walking them alone is calmer than the offset method it replaced
    // (measured 0.106 against 0.145) and read as static. Jittering per frame as
    // well combines its real frames with the decorrelation the offset method got
    // for free.
    vec2 t = fract(uv + vec2(f * 0.7548, f * 0.5698));
    t = t * (1.0 - 2.0 * MGE_FOAM_ATLAS_INSET) + MGE_FOAM_ATLAS_INSET;
    return (tile + t) * 0.25;
}
float mgeFoamSlice(sampler2D tex, vec2 uv, float t)
{
    float c = floor(t);
    float f = fract(t);
    f = f * f * (3.0 - 2.0 * f);
    return mix(texture2D(tex, mgeAtlasUV(uv, c)).a,
               texture2D(tex, mgeAtlasUV(uv, c + 1.0)).a, f);
}
#else
float mgeFoamSlice(sampler2D tex, vec2 uv, float t)
{
    float c = floor(t);
    float f = fract(t);
    f = f * f * (3.0 - 2.0 * f);
    vec2 j0 = vec2(c * 0.7548, c * 0.5698);
    vec2 j1 = vec2((c + 1.0) * 0.7548, (c + 1.0) * 0.5698);
    return mix(texture2D(tex, uv + j0).a, texture2D(tex, uv + j1).a, f);
}
#endif
#endif



// ---------------------------------------------------------------------------
// Weather-driven wave amplitude.
// Resolved through the same helpers the fog uses, so this file is identical on
// both tiers: the patched engine feeds mgeGetFogParams()/mgeGetNiceWeather()
// from the real weather system, the stock engine reconstructs them from the fog
// palette. rainIntensity is a stock engine uniform and exact on both.
//
// Known approximation: weathers that share a fog density and a dryness cannot be
// told apart from these signals (ash vs blight), so they resolve to the same
// amplitude. Identity is not available to a core shader on the stock tier (the
// estimator only sees the fog uniforms), and waves are an artistic scalar, so
// the approximation is deliberate rather than a limitation to be worked around.

#if MGE_WATER_CAUSTICS
// ---------------------------------------------------------------------------
// Light caustics on submerged surfaces, ported from Rafael's "Enhanced Water
// for OpenMW". The pattern is the near-edge of a jittered 3D Voronoi cell set,
// which is what focused refracted light actually looks like: bright seams where
// wavefronts converge. Animated by a warped sample position rather than a
// scrolling texture, so it never tiles.
//
// Ported rather than adopted wholesale: Rafael's water replaces the reflection
// RTT with raymarched SSR, which would discard the MGE parity model this file
// exists for. Only the caustics travel across.
vec3 mgeCausticHash(vec3 p)
{
    p = fract(p * vec3(0.1031, 0.11369, 0.13787));
    p += dot(p, p.yzx + 19.19);
    return fract((p.xxy + p.yzz) * p.zyx);
}

float mgeCausticEdge(vec3 P, vec3 N, vec3 L)
{
    P += sin(P * 0.9 + 1.7) * 0.125;
    P += sin(P.yzx * 1.7 + 2.3) * 0.08;
    vec3 Pi = floor(P);
    vec3 Pf = P - Pi;

    float best = 1.0;
    float secondBest = 1.0;
    float thirdBest = 1.0;

    for (int z = -1; z <= 1; z++)
    for (int y = -1; y <= 1; y++)
    for (int x = -1; x <= 1; x++)
    {
        vec3 cell = Pi + vec3(x, y, z);
        vec3 h = mgeCausticHash(cell) * 2.0 - 1.0;
        vec3 jitter = clamp(h + sin(h), -0.25, 0.25);
        vec3 site = vec3(x, y, z) + 0.5 + jitter;
        // Squash along the light direction so the cells stretch into the
        // beams the light is travelling down, instead of staying spherical.
        float d = length((Pf - site) - L * dot(Pf - site, L) * 0.6);

        if (d < best)            { thirdBest = secondBest; secondBest = best; best = d; }
        else if (d < secondBest) { thirdBest = secondBest; secondBest = d; }
        else if (d < thirdBest)  { thirdBest = d; }
    }

    float edge = (secondBest - best) * 0.8;
    edge = edge / (edge + 0.25);
    edge *= sqrt(sqrt(edge));
    float edge2 = (thirdBest - best) * 0.8;
    return edge - edge2 * 0.03;
}

float mgeCaustics(vec3 underwaterPos, float time, float waterDepth, vec3 normal, vec3 lightDir)
{
    const float TMIN = -0.70;
    const float TMAX =  0.95;
    float warpAmt = 0.15 / MGE_CAUSTIC_SCALE * 0.04;

    vec3 P = underwaterPos * MGE_CAUSTIC_SCALE;
    float t  = time * MGE_CAUSTIC_SPEED;
    float t1 = t * 1.7;
    float t2 = (t + 1.2) * 1.3;
    float t3 = (t + 2.5) * 1.1;

    vec3 warp;
    warp.x = sin(t1 + underwaterPos.y * 0.13) * cos(t2 + underwaterPos.z * 0.12);
    warp.y = sin(t2 + underwaterPos.z * 0.13) * cos(t3 + underwaterPos.x * 0.12);
    warp.z = sin(t3 + underwaterPos.x * 0.13) * cos(t1 + underwaterPos.y * 0.12);
    warp *= 0.5;
    warp += normal * 0.25;
    warp.z -= time * 5.0;

    vec3 Pw = warp * warpAmt + P;
    // Areal average = genuine softening (see MGE_CAUSTIC_SOFTNESS). At 0 this
    // folds to a single sample at compile time, so the sharp path costs nothing.
    float diff;
    if (MGE_CAUSTIC_SOFTNESS < 0.001)
    {
        diff = mgeCausticEdge(Pw, normal, lightDir);
    }
    else
    {
        float r = MGE_CAUSTIC_SOFTNESS * 0.55;
        diff  = mgeCausticEdge(Pw, normal, lightDir) * 0.36;
        diff += mgeCausticEdge(Pw + vec3( r, 0.0, 0.0), normal, lightDir) * 0.16;
        diff += mgeCausticEdge(Pw - vec3( r, 0.0, 0.0), normal, lightDir) * 0.16;
        diff += mgeCausticEdge(Pw + vec3(0.0,  r, 0.0), normal, lightDir) * 0.16;
        diff += mgeCausticEdge(Pw - vec3(0.0,  r, 0.0), normal, lightDir) * 0.16;
    }
    // Deeper water blurs the pattern out: the band the edge occupies widens
    // with depth until nothing is left.
    float edge = smoothstep(waterDepth * MGE_CAUSTIC_DEPTH_FADE + TMIN,
                            waterDepth * (MGE_CAUSTIC_DEPTH_FADE * 0.35) + TMAX,
                            sqrt(diff));
    // Brighten only. Rafael's form dips to -0.5 between seams, which adds
    // contrast in his water but here can drive the refraction below zero -
    // black bands on the ripple undersides when the camera sits at the
    // surface, where the water is close and the term runs at full strength.
    // The underwater pass already clamps this way; negative light is not a
    // thing regardless.
    return max((1.0 - edge) * 2.25 - 0.5, 0.0);
}
#endif // MGE_WATER_CAUSTICS
// displacement runs the identical strength chain. History in git.)

void main(void)
{
    mgeWxCompute(); // single-instance weather decomposition
    vec2 UV = worldPos.xy / (8192.0*5.0) * 3.0;

    // Raw shadow-map term, stock behaviour. Its only consumer is the sun
    // glint (specular *= shadow * sunSpec.a): an occluder blocking the sun
    // should kill direct reflection outright, and sunSpec.a already carries
    // the sunVis cloud signal, so the old cloud-fade line here was near-inert
    // anyway. MGE XE water receives no geometry shadows at all
    // (XE Mod Water.fx: zero shadow references) - the glint kill is stock
    // OpenMW's deliberate improvement, kept as-is.
    float shadow = unshadowedLightRatio(linearDepth);

    vec2 screenCoords = gl_FragCoord.xy / screenRes;

    // World-anchor for pattern and region consumers. position.xy is model
    // space; the radial mesh recentres on the camera every frame, so on the
    // displaced path model space is camera-relative and every world-intent
    // consumer - the foam texture, the surge/swash phases, the rain-ripple
    // pattern, the water-type region boxes - rides the player (reported as:
    // the foam outline is right, the texture inside moves with the
    // player). The flat sheet keeps plain position.xy, so the stock tiers are
    // arithmetic-identical. Note the flat sheet's own anchor is the player
    // cell centre, not the world origin - the type region boxes have been
    // tested against cell-relative coordinates since they shipped; that
    // pre-existing stock-tier finding is logged in 427 and awaits its own
    // call.
    vec2 mgeWorldXY = position.xy;
#if MGE_WATER_WAVE_SHAPES && MGE_WATER_DISPLACE
    if (mgeWaterDisplace > 0.5)
        mgeWorldXY = worldPos.xy;
#endif

#if MGE_WATER_WAVE_SHAPES && @waterRefraction
    // Water depth, sampled early because shoaling has to modify the wave field
    // and the field is evaluated long before the normal depth code runs. Same
    // undistorted estimate, just hoisted; the later code recomputes its own.
    // viewDir proper is not declared until much later in main(), so the view
    // factor is derived here from position and camera - the same quantity.
    vec3 mgeShoalCam = (gl_ModelViewMatrixInverse * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    vec3 mgeShoalView = normalize(position.xyz - mgeShoalCam);
    float mgeShoalDepth = max(0.0, linearizeDepth(sampleRefractionDepthMap(screenCoords), near, far)
                                   - linearizeDepth(gl_FragCoord.z, near, far))
                          * mix(abs(mgeShoalView.z), 1.0, 0.2);
#endif

    #define waterTimer osg_SimulationTime

#if MGE_WATER_WAVE_SHAPES
    // Stage 1 of the wave-shape port (docs/water-raymarch-port-plan.md).
    //
    // The coarsest normal-map tap is replaced by the gradient of a real wave
    // height field. A tiling normal map can only ever repeat; a domain-warped
    // FBM produces crests with direction and asymmetry, which is what the eye
    // reads as a swell rather than as texture.
    //
    // Only the gradient is consumed here, so the field's DC offset is
    // irrelevant at this stage - it cancels in the finite difference. The
    // absolute height does not matter until the raymarch lands.
    // One strength chain for both stages (mge_water_data.glsl,
    // mgeWaveStrengthResolve - verbatim the block that lived here).
    float mgeWaveStr = mgeWaveStrengthResolve(worldPos.xy);
    vec4 mgeWaveStrV = mgeWaveStrengthFanout(mgeWaveStr);

    // Shoreward heading, estimated from the world-space gradient of water depth.
    //
    // The depth buffer only gives depth per screen pixel, so the world gradient
    // comes by chain rule: dDepth/dScreen and dWorldXY/dScreen give dDepth/dWorldXY
    // after inverting the 2x2. Pointing down that gradient is toward shallower
    // water, i.e. toward shore.
    //
    // Gated hard, because this signal is only trustworthy in a narrow band: it
    // needs a seabed actually present in the depth buffer, it degenerates at
    // view-dependent so it can swim as the camera turns. Restricting it to
    // shallow water keeps it where depth is reliable and where real wave
    // refraction happens, which is the same place.
    vec2 mgeHeading = normalize(MGE_WAVE_HEADING);
    vec2 mgeOctW = vec2(1.0);
#if MGE_WATER_WAVE_SHORE && (MGE_SHORE_PIECE_COUNT > 0)
    // Set this pixel's wave-rose energy from the baked coastline table
    // (player-vicinity gated, cluster-culled; smooth world-space weights).
    mgeShoreSetRose(worldPos.xy);
#if MGE_SHORE_DEBUG
    // Measured, not perceived: the query's own output as colour.
    gl_FragData[0] = vec4(mgeShoreDirDbg * 0.5 + vec2(0.5), mgeShoreW, 1.0);
    return;
#endif
#endif

    // radialDepth proper is not computed until much later in main(); recompute
    // the camera distance here rather than reorder the existing code. Same two
    // lines as :411 and :681.
    vec3 mgeWaveCam = (gl_ModelViewMatrixInverse * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    float mgeWaveDist = distance(position.xyz, mgeWaveCam);

    // The position the wave field is evaluated at. Flat by default; the
    // raymarch replaces it with the point where the view ray actually meets the
    // wave surface, which is what turns shading detail into relief.
    vec3 mgeWavePos = worldPos;

#if MGE_WATER_WAVE_RAYMARCH
#if MGE_WATER_DISPLACE
    // Displaced path: the rasteriser already put this fragment ON the wave
    // surface (worldPos is the displaced position), which is the exact
    // question the march exists to approximate - so the march is off and
    if (mgeWaterDisplace < 0.5)
#endif
    {
        vec3 mgeWaveDir = normalize(position.xyz - mgeWaveCam);
        // Same per-camera test the rest of this shader uses. It is per-camera
        // than fixed, so the raymarch agrees with the branch downstream.
        bool mgeWaveUnder = mgeWaveCam.z < worldPos.z;
        mgeWavePos = mgeRaymarchWater(mgeWaveCam, mgeWaveDir, 0.0, mgeWaveDist,
                                      waterTimer * 0.6 * MGE_WAVE_SPEED, mgeWaveStrV, mgeHeading, mgeOctW, worldPos.z, mgeWaveUnder);
    }
#endif

#if MGE_WATER_WAVE_RAYMARCH && MGE_WAVE_DETAIL_PARALLAX
    // Re-base the normal-map lookup on the displaced position so the fine
    // detail rides the relief instead of sliding across it.
    //
    // off BY default, and the reason is texture sharpness. texture2D picks its
    // mip level from screen-space derivatives, and the raymarch terminates at a
    // different t on neighbouring pixels - so dFdx(UV) blows up, the sampler
    // drops to a coarse mip, and the fine ripple texture is blurred away. That
    // is the standard relief-mapping texture-blur artifact, and it cost the
    // dense stipple of small ripples the stock surface has.
    //
    // Doing this properly needs explicit-gradient sampling (textureGrad with
    // derivatives taken from the UNdisplaced UV), which is not available at
    // #version 120 without an extension. Until then the detail stays on the
    // flat basis: the relief still comes through the wave normal, which IS
    // evaluated at the displaced position.
    //
    // Note this keeps our divisor. Rafael's basis is wp.xy / 163840 where ours
    // is worldPos.xy / (8192*5) * 3 = /13653, twelve times denser; copying his
    // constant along with the displacement would rescale every normal-map
    // wavelength in this shader.
    UV = mgeWavePos.xy / (8192.0*5.0) * 3.0;
#endif

    // Sample spacing for the finite difference, in world units. Widened with
    // distance so the difference stays meaningful once one pixel covers many
    // units - a fixed 1-unit spacing would return gradient noise at range.
    float mgeWaveStep = max(1.0, mgeWaveDist * 0.004);
    // A separate vector, not a replacement for one of the six normal-map taps.
    vec4 mgeShadeStrV = mgeWaveStrV;
#if MGE_WATER_DISPLACE
    // scale with waveHeight - storm geometry, calm-soft shading. min() so
    // calm weather stays exactly itself; only storm shading is capped, the
    // displaced geometry keeps full height. Displaced path only: on the
    // raymarch tier the normal IS the wave and must keep scaling.
    if (mgeWaterDisplace > 0.5 && MGE_WAVE_SHADE_REF_S > 0.0)
    {
        // open-water glare (W5's own sample set is 200-2500 u of deep
        // water), and holding it in the surf zone ran the shore's shading
        // at 0.46x the raymarch tier's for no glare it was buying.
        float mgeShadeRef = MGE_WAVE_SHADE_REF_S;
#if @waterRefraction
        mgeShadeRef = mix(1.0, MGE_WAVE_SHADE_REF_S,
                          smoothstep(0.0, MGE_WAVE_SHADE_SHALLOW, mgeShoalDepth));
#endif
        mgeShadeStrV = mgeWaveStrengthFanout(min(mgeWaveStr, mgeShadeRef));
    }
#endif
    vec3 mgeWaveN = mgeWaveNormal(mgeWavePos.xy, waterTimer * 0.6 * MGE_WAVE_SPEED, mgeWaveDist, mgeShadeStrV, mgeHeading, mgeOctW, mgeWaveStep);
#if MGE_WATER_DISPLACE && MGE_WATER_XE_FIELD
    // XE-field mode: the shading normal is the texture's own baked rg -
    // sampled at 527/3900 u exactly as getFinalWaterNormal does. The raw
    // simulation timer, as XE uses (t = 0.4 * time).
    if (mgeWaterDisplace > 0.5 && mgeWaterXeField > 0.5)
        mgeWaveN = mgeXeNormal(mgeWavePos.xy, mgeWaveDist, waterTimer);
#endif

    // shoaling - waves slow in shallow water, so they steepen and break. This
    // is the honest substitute for coast-following on this tier: we cannot turn
    // the waves toward the shore (the direction table will not fit - see
    // docs/case-files/coast-following-waves-rp.md), but growing them as they
    // reach it produces much of the same reading, and it is real physics.
    //
    // Steepening the normal rather than the amplitude, because amplitude is
    // already clamped to 1.0 at storm strength and would show no change exactly
    // where the effect should be strongest. Gated by mgeWaveStr, which is zero
    // below the calm floor - so Clear and Foggy stay byte-exact stock.
#if @waterRefraction
    float mgeShoal = (1.0 - smoothstep(0.0, MGE_WAVE_SHOAL_DEPTH, mgeShoalDepth))
                     * MGE_WAVE_SHOAL * mgeWaveStr;
    mgeWaveN = normalize(vec3(mgeWaveN.xy * (1.0 + mgeShoal), mgeWaveN.z));
#endif

#if MGE_WATER_WAVE_DEBUG
    {
        float dbg = mgeWaveHeight(mgeWavePos.xy, waterTimer * 0.6 * MGE_WAVE_SPEED, mgeWaveDist, mgeWaveStrV, mgeHeading, mgeOctW);
        // Centred field, so 0.5 grey is the water plane: darker is trough,
        // lighter is crest. 0.015 puts the full +-35 unit range on screen.
        gl_FragData[0] = vec4(vec3(dbg * 0.015 + 0.5), 1.0);
        return;
    }
#endif
#endif

    // Unchanged on both paths: the wave field is additive, so the stock surface
    // texture - including this coarsest tap, which also seeds the domain warp
    // for normal1..5 - is built exactly as it always was.
    vec3 normal0 = 2.0 * texture2D(normalMap,normalCoords(UV, 0.05, 0.04, waterTimer, -0.015, -0.005, vec3(0.0,0.0,0.0))).rgb - 1.0;
    vec3 normal1 = 2.0 * texture2D(normalMap,normalCoords(UV, 0.1,  0.08, waterTimer,  0.02,   0.015, normal0)).rgb - 1.0;
    vec3 normal2 = 2.0 * texture2D(normalMap,normalCoords(UV, 0.25, 0.07, waterTimer, -0.04,  -0.03,  normal1)).rgb - 1.0;
    vec3 normal3 = 2.0 * texture2D(normalMap,normalCoords(UV, 0.5,  0.09, waterTimer,  0.03,   0.04,  normal2)).rgb - 1.0;
#if MGE_WATER_WAVE_SHAPES
    // normal4 is the one tap that runs against the sea.
    //
    // Each tap drifts by WIND_DIR*speed*WIND_SPEED plus its own timer. Summing
    // both, five of the six travel broadly with the swells; normal4's stock
    // timer (-0.02, 0.1) very nearly cancels its wind term and leaves it
    // heading 119 degrees away - across the sea and partly backwards. It is
    // also the second-fastest layer, and rain triples it, which is why an
    // occasional wave appeared to rotate.
    //
    // Its speed is preserved exactly (0.041182); only the direction is turned
    // to follow the swells. Derived from MGE_WAVE_HEADING rather than baked, so
    // re-aiming the sea keeps this tap with it, and MGE_WAVE_TRAVEL's flip is
    // honoured. The other five taps are untouched: their crossing motion is
    // what stops the surface reading as a scrolling texture.
    vec2 mgeT4Swell = normalize(MGE_WAVE_HEADING) * -sign(MGE_WAVE_TRAVEL);
    vec2 mgeT4 = -mgeT4Swell * 0.041182 - WIND_DIR * (WIND_SPEED * 0.4);
    vec3 normal4 = 2.0 * texture2D(normalMap,normalCoords(UV, 1.0,  0.4,  waterTimer, mgeT4.x, mgeT4.y, normal3)).rgb - 1.0;
#else
    vec3 normal4 = 2.0 * texture2D(normalMap,normalCoords(UV, 1.0,  0.4,  waterTimer, -0.02,   0.1,   normal3)).rgb - 1.0;
#endif
    vec3 normal5 = 2.0 * texture2D(normalMap,normalCoords(UV, 2.0,  0.7,  waterTimer,  0.1,   -0.06,  normal4)).rgb - 1.0;

    vec4 rainRipple;

    if (rainIntensity > 0.01)
        rainRipple = rainCombined(mgeWorldXY/1000.0, waterTimer) * clamp(rainIntensity, 0.0, 1.0);
    else
        rainRipple = vec4(0.0);

    vec3 rippleAdd = rainRipple.xyz * 10.0;

#if MGE_WATER_WAVE_SHAPES
    // Rain rings on the wave surface, not on the flat plane.
    //
    // rippleMapUV is a varying, projected in water.vert from the undisplaced
    // vertex, so the impact rings are pinned to the flat water plane however
    // the fragment stage shades it - they read as a grid painted under the
    // swells rather than as rain landing on them. Reprojecting the same
    // world-space mapping from the raymarched position puts them on the
    // surface actually being drawn. Identical to the varying when the raymarch
    // is off, since mgeWavePos is then worldPos.
    vec2 mgeRippleUV = (mgeWavePos.xy - playerPos.xy
                        + (@rippleMapSize * @rippleMapWorldScale / 2.0))
                       / @rippleMapSize / @rippleMapWorldScale;
    float distToCenter = length(mgeRippleUV - vec2(0.5));
    float blendClose = smoothstep(0.001, 0.02, distToCenter);
    float blendFar = 1.0 - smoothstep(0.3, 0.4, distToCenter);
    float distortionLevel = 2.0;
    rippleAdd += distortionLevel * vec3(texture2D(rippleMap, mgeRippleUV).ba * blendFar * blendClose, 0.0);
#else
    float distToCenter = length(rippleMapUV - vec2(0.5));
    float blendClose = smoothstep(0.001, 0.02, distToCenter);
    float blendFar = 1.0 - smoothstep(0.3, 0.4, distToCenter);
    float distortionLevel = 2.0;
    rippleAdd += distortionLevel * vec3(texture2D(rippleMap, rippleMapUV).ba * blendFar * blendClose, 0.0);
#endif

    vec2 bigWaves = BIG_WAVES;
#if MGE_WATER_WAVE_SHAPES
    // Moderated: with a real height field present, full stock rain chop buries
    // the swells entirely (see MGE_WAVE_RAIN_CHOP).
    float mgeRain = rainIntensity * MGE_WAVE_RAIN_CHOP;
    vec2 midWaves = mix(MID_WAVES, MID_WAVES_RAIN, mgeRain);
    vec2 smallWaves = mix(SMALL_WAVES, SMALL_WAVES_RAIN, mgeRain);
#else
    vec2 midWaves = mix(MID_WAVES, MID_WAVES_RAIN, rainIntensity);
    vec2 smallWaves = mix(SMALL_WAVES, SMALL_WAVES_RAIN, rainIntensity);
#endif
#if MGE_WATER_WEATHER_WAVES
    // Apply the weather to bump, not to the wave amplitudes.
    //
    // The amplitudes feed a vector that is then normalize()d, so scaling them
    // all by the same factor is divided straight back out - a uniform amplitude
    // scale is mathematically a no-op here. bump is the only term that survives,
    // because it scales xy relative to z before the normalize and so changes how
    // far the surface normal tilts: which is exactly what reads as wave height.
    float mgeWaveScale = mgeWeatherWaveScale();
#if MGE_WATER_TYPES
    // Sheltered water is calmer than open sea whatever the weather is doing.
    // Resolved here rather than reusing the block below, because waves are
    // composed before waterColor exists.
    {
        vec3 tc; vec4 tp; float tw;
        mgeResolveWaterType(mgeWorldXY, 1.0 - clamp(mgeGetFogParams().z, 0.0, 1.0), tc, tp, tw);
        mgeWaveScale *= mix(1.0, tp.x, tw);
    }
#endif
#endif
#if MGE_WATER_WAVE_SHAPES
    float bump = mix(BUMP, BUMP_RAIN, rainIntensity * MGE_WAVE_RAIN_CHOP);
#else
    float bump = mix(BUMP,BUMP_RAIN,rainIntensity);
#endif
#if MGE_WATER_WEATHER_WAVES && !MGE_WATER_WAVE_SHAPES
    // Clamped: past roughly 3x the surface stops reading as water and
    // starts reading as crumpled foil.
    //
    // Only on the no-height-field path. With MGE_WATER_WAVE_SHAPES the weather
    // drives the wave field, and scaling the micro-detail by it as well flattens
    // the surface texture for no reason: at cloudy this multiplier is 0.26, so
    // bump fell from 0.5 to 0.13 and the fine ripples lost ~4x their steepness.
    // The detail keeps its stock roughness; the weather acts through the waves.
    bump *= clamp(mgeWaveScale, 0.15, 3.0);
#endif

#if MGE_WATER_WAVE_SHAPES
    // normal0 is no longer a normal-map tap - it is the gradient of a real
    // height field, a unit vector carrying the wave's true slope. Feeding it
    // through the stock composition destroys it twice over:
    //
    //   1. weight. At bigWaves.x = 0.1, summed against five unchanged taps, a
    //      genuine 30 deg wave face renders as 6.2 deg.
    //   2. bump. bump multiplies xy only, and it is below 1 in every weather
    //      short of rain (0.45 at blight), so it then flattens that 6.2 deg to
    //      2.8 deg. An ~11x attenuation in total - which is exactly why the
    //      relief read as "mildly higher" rather than as waves.
    //
    // bump is the normal-map roughness knob: it exists to fake steepness that
    // the flat surface does not have. The height field already has the
    // steepness, so bump must not touch it. Detail taps keep bump; the wave
    // normal is added at its own weight afterwards.
    // The wave field adds relief; it does not replace the surface texture.
    // An earlier version consumed the normal0 slot for the height gradient,
    // which cost the coarsest normal-map layer outright. Worse, the fine taps
    // then sat against a wave normal ~25x their size: measured, their
    // contribution held at ~9 px of screen modulation while the total went from
    // 2 deg to 17 deg, so the ripples fell from ~90% of the signal to ~4%. They
    // were drowned, not removed - which is why the surface read as bare waves.
    //
    // So all six taps stay exactly as the stock shader builds them, and
    // MGE_WAVE_DETAIL_WEIGHT scales their xy back up to sit legibly on top of
    // the waves. It multiplies xy only: that steepens the ripples without
    // altering how much they tilt the surface as a whole.
    vec3 mgeDetail = (normal0 * bigWaves.x + normal1 * bigWaves.y + normal2 * midWaves.x +
                      normal3 * midWaves.y + normal4 * smallWaves.x +
                      normal5 * smallWaves.y + rippleAdd);

#if MGE_WAVE_DETAIL_DISTFADE
    // close-scale normal out by dist/8000, so at distance XE's
    // reflection offset carries no detail-frequency motion. Keeping
    // full frequency at every distance strobes the reflection sample
    // across the RTT's bright/dark content edges - the shade-line
    // shimmer (single-frame flips, 6-14x edge-concentrated; raced in
    // simulations/sim_water_edge_flicker.py). Same linear ramp; the
    // wave-frame base keeps the swell shape at all distances and near
    // water keeps its relief (6% fade at 500u). Spec inherits the
    // fade via mgeDetailN - XE-authentic (its spec uses the faded
    // normal too). 0 = byte-exact full-frequency restore.
    mgeDetail.xy *= 1.0 - clamp(
        distance(position.xyz,
                 (gl_ModelViewMatrixInverse * vec4(0.0, 0.0, 0.0, 1.0)).xyz)
            / MGE_WAVE_DETAIL_FADE_END,
        0.0, 1.0);
#endif

    // The stock surface normal, built exactly as it always was.
    vec3 mgeDetailN = normalize(vec3(-mgeDetail.x * bump * MGE_WAVE_DETAIL_WEIGHT,
                                     -mgeDetail.y * bump * MGE_WAVE_DETAIL_WEIGHT,
                                      mgeDetail.z));


    // Then rotate it onto the wave surface, rather than adding the two.
    //
    // Adding was the mistake behind three rounds of "still too flat": summing
    // two normals averages them, so the detail's tilt is diluted by whatever
    // magnitude the wave normal has, and no weight fixes that - raising the
    // detail weight just trades wave shape for texture and back again.
    //
    // A tangent frame built on the wave normal keeps the micro-detail's full
    // relative tilt and tilts the whole patch by the wave underneath it, which
    // is what "the old detailed surface, deformed by the new larger waves"
    // actually means geometrically. The frame is stable here because a water
    // surface normal always has z > 0, so it is never parallel to (0,1,0).
    // MGE_WAVE_SHAPE_WEIGHT tilts the base frame toward or away from flat:
    // 1.0 is the field's true slope, below flattens the swells, above
    // exaggerates them. It scales the wave, not the detail, which is what its
    // name says - in a tangent frame the detail always keeps its own tilt.
    vec3 mgeBase = normalize(mix(vec3(0.0, 0.0, 1.0), mgeWaveN, MGE_WAVE_SHAPE_WEIGHT));
    vec3 mgeT = normalize(cross(vec3(0.0, 1.0, 0.0), mgeBase));
    vec3 mgeB = cross(mgeBase, mgeT);
    vec3 normal = normalize(mgeT * mgeDetailN.x + mgeB * mgeDetailN.y + mgeBase * mgeDetailN.z);
#else
    vec3 normal = (normal0 * bigWaves.x + normal1 * bigWaves.y + normal2 * midWaves.x +
                   normal3 * midWaves.y + normal4 * smallWaves.x + normal5 * smallWaves.y + rippleAdd);
    normal = normalize(vec3(-normal.x * bump, -normal.y * bump, normal.z));
#endif

    vec3 sunWorldDir = normalize((gl_ModelViewMatrixInverse * vec4(lcalcPosition(0).xyz, 0.0)).xyz);
    vec3 cameraPos = (gl_ModelViewMatrixInverse * vec4(0,0,0,1)).xyz;
    vec3 viewDir = normalize(position.xyz - cameraPos.xyz);
    // to the undisplaced surface point. Every from-below term that
    // classifies the sightline by angle - the fresnel's mirror transition,
    // the grazing-transmission murk, the sky void fill - reads this one,
    // never the displaced viewDir: a facet's +-35 u of interpolated z
    // swings the displaced direction across those terms' transition bands
    // (measured up to 0.35 of the void fill's mix per facet), carving
    // travelling web-free patches into the from-below surface. The flat
    // direction is exact per pixel: position and mgeDispV interpolate the
    // same vertex values, so their difference reconstructs the plane.
    vec3 mgeViewBelow = viewDir;
#if MGE_WATER_WAVE_SHAPES && MGE_WATER_DISPLACE
    if (mgeWaterDisplace > 0.5 && cameraPos.z < 0.0)
        mgeViewBelow = normalize(position.xyz - vec3(0.0, 0.0, mgeDispV)
                                 - cameraPos.xyz);
#endif

    float sunFade = length(gl_LightModel.ambient.xyz);

    // fresnel
    float ior = (cameraPos.z>0.0)?(1.333/1.0):(1.0/1.333); // air to water; water to air
    float fresnel;
    if (cameraPos.z > 0.0)
    {
        // MGE XE Mod Water.fx fresnel: 0.02 + (0.9988 - slope*cos)^16.
        // Noticeably more reflective at mid angles than the physical
        // dielectric term, so open water carries more sky (the MGE look).
        // Slope 0.28 is MGE verbatim; 0.34 trims mid-angle reflectivity
        // ~20-25% while keeping grazing/far-water brightness.
        const float mgeFresnelSlope = 0.34;
        vec3 mgeFresnelN = normal;
#if MGE_WATER_WAVE_SHAPES && MGE_WATER_XE_ANTIGLARE
        {
            // XE Mod Water.fx:246-249 verbatim, the anti-glare pair
            // (both wave tiers since 428): with distance the fresnel normal
            // fades toward flat at the water fog's own transmittance, and
            // toward vertical with grazing + distance. XE never lets a far
            // steep face reach the pow-16 curve - which is what turned
            // isolated crests into the bright mirror patches. Deliberately
            // unnormalized, as XE has it: far water converges to a smooth
            // full reflection (the horizon seal), losing only the sparkle.
            float mgeVDist = length(position.xyz - cameraPos.xyz);
            float mgeWFogA = mgeAWWaterTransmittance(mgeVDist);
            mgeFresnelN = mix(vec3(0.0, 0.0, 0.1), normal,
                              pow(clamp(1.05 * mgeWFogA, 0.0, 1.0), 2.0));
            mgeFresnelN = mix(mgeFresnelN, vec3(0.0, 0.0, 1.0),
                              (1.0 + viewDir.z)
                              * (1.0 - clamp(1.0 / (mgeVDist / 1000.0 + 1.0), 0.0, 1.0)));
        }
#endif
        float fcos = clamp(dot(-viewDir, mgeFresnelN), 0.0, 1.0);
        fresnel = 0.02 + pow(clamp(0.9988 - mgeFresnelSlope * fcos, 0.0, 1.0), 16.0);
#if MGE_WATER_WAVE_SHAPES
        // MGE XE's pow-16 curve was authored for a gently-tilted surface. Real
        // wave shapes put whole faces near grazing, where it saturates and the
        // face reads as a mirror - the isolated over-reflective patches on
        // storm crests. The ceiling scales in with wave strength, so calm
        // weather keeps MGE XE's curve exactly and Clear stays byte-exact.
        // The strength-scaled ceiling composes with XE's adjustnormal pair
        // (min of both): the pair owns the distance glare (XE's soft texture
        // normals never produce our steep near faces, so XE needed nothing
        // more), the ceiling owns the near faces our sharper field creates.
        // Standing either down alone re-opens its half - 428 stood this one
        // down and the next test still had strong near glare
        fresnel = min(fresnel, mix(1.0, MGE_WAVE_FRESNEL_MAX, mgeWaveStr));
#endif
    }
    else
    {
        // MGE XE Mod Water.fx UnderwaterPS fresnel: full internal reflection
        // only near grazing (~79 deg), unlike the physical dielectric term
        // (critical angle 49 deg) which mirrors most of the surface. From
        // below the surface mostly shows the refracted above-water world.
        // the sim-raced softening menu). The travelling web-free blobs are
        // mirror patches: the wave field's broad tilt pushes whole regions
        // past this curve's knee, and the patches march at the field's
        // 100 u/s travel offset (replicated offline with the real textures,
        // sim_uw_web_render.py replication gate: 930 px/s with travel, 228
        // without). From below, the curve therefore reads the detail normal
        // in the identity frame - the wave base's rotation is left out of
        // this one dot product. Raced against a re-anchored curve power
        // (floods the underside with mirror, area 9 -> 69-96%) and a cap
        // (bites nothing: patch interiors average fresnel 0.29): the
        // edges 2.5x and dims interiors, with the web untouched - it is
        // carried by the detail ripple, which this keeps in full. The
        // grazing mirror stays: the view-angle term still dominates at
        // grazing. Above water, geometry, foam, fades: untouched.
        // XE's own input (the composed surface normal) on the flat view
        // direction. The earlier substitutions here (field tilt out, then
        // fine-taps-only) were measured invisible in-game once the visible
        // web was identified as the caustics pass, and were reverted.
        float fcos = clamp(dot(mgeViewBelow, normal), 0.0, 1.0);
        fresnel = pow(clamp(MGE_UW_FRESNEL_BIAS - MGE_UW_FRESNEL_SLOPE * fcos, 0.0, 1.0), MGE_UW_FRESNEL_POWER);
        fresnel *= MGE_UW_REFLECTION_SCALE;   // from-below mirror intensity scale
    }

    // the amplitude knob. Everything the eye reads as wave size arrives through
    // this one line: the surface normal shifts where the reflection and
    // refraction are sampled, and that shift is REFL_BUMP screen units at most.
    // sin(tilt) is bounded by 1, so no wave table, height field or bump value
    // can ever exceed it - measured, 0.07 caps the shift at ~269 px at 4K, and
    // a 21 deg tilt only reaches 97 px.
    //
    // Which is why a better normal (the height field) sharpened the character of
    // the waves without making them read as bigger. Magnitude lives here.
#if MGE_WATER_WAVE_SHAPES
    // Scaled BY wave strength, not applied flat. At full strength this is
    // MGE_WAVE_DISTORT; at Clear (strength ~0.09) it is ~1.0, i.e. stock
    // REFL_BUMP and therefore stock MGE XE reflection behaviour.
    //
    // Applying it flat was wrong twice over: calm water got 3x the stock
    // reflection offset with no waves to justify it, so Clear no longer matched
    // MGE XE; and tripling the offset smears the reflected sky across the broad
    // faces of the swells, which is what reads as a plastic highlight.
    vec2 screenCoordsOffset = normal.xy * (REFL_BUMP * mix(1.0, MGE_WAVE_DISTORT, mgeWaveStr));
    // bound the distortion. This is a screen-space sample offset, and steep
    // crests - especially shoaling ones, which reach ~50deg - push it to ~5% of
    // the screen (200px at 4K), so the refraction samples unrelated geometry.
    // Stock's own damper (BUMP_SUPPRESS_DEPTH, 300u) fades out before shoaling
    // does (700u), so the two never overlap. Cap is well above anything calm
    // weather produces, so Clear is untouched.
    // Shoaling is excluded from the refraction path. A/B testing confirmed that
    // the storm refraction artifact was shoaling's: it steepens the normal to
    // ~50deg, and this offset is a screen-space displacement, so the refraction
    // sampled ~200px away at 4K. A cap alone was not enough. Dividing the shoal
    // factor back out keeps the steepening where it belongs - shading, foam and
    // the visible wave shape - while refraction sees the unshoaled surface.
#if MGE_WATER_WAVE_SHAPES && @waterRefraction
    screenCoordsOffset /= (1.0 + mgeShoal);
#endif
    float mgeOffLen = length(screenCoordsOffset);
    screenCoordsOffset *= (mgeOffLen > MGE_WAVE_DISTORT_MAX)
                          ? (MGE_WAVE_DISTORT_MAX / mgeOffLen) : 1.0;
#else
    vec2 screenCoordsOffset = normal.xy * REFL_BUMP;
#endif
#if @waterRefraction
    float depthSample = linearizeDepth(sampleRefractionDepthMap(screenCoords), near, far);
    float surfaceDepth = linearizeDepth(gl_FragCoord.z, near, far);
    float realWaterDepth = depthSample - surfaceDepth;  // undistorted water depth in view direction, independent of frustum
    float depthSampleDistorted = linearizeDepth(sampleRefractionDepthMap(screenCoords - screenCoordsOffset), near, far);
    float waterDepthDistorted = max(depthSampleDistorted - surfaceDepth, 0.0);
    screenCoordsOffset *= clamp(realWaterDepth / BUMP_SUPPRESS_DEPTH, 0.0, 1.0);
#endif
    // reflection
#if MGE_WATER_WAVE_SHAPES
    vec2 mgeReflBase = screenCoords;
    vec2 mgeReflOff = screenCoordsOffset;
#if MGE_WATER_XE_ANTIGLARE
    // XE Mod Water.fx:243, both wave tiers since 428: the vertical
    // reflection distortion only ever pulls the sample downward (XE's
    // -abs(reffactor.y); our screen y is up, so downward = negative). An
    // upward pull samples the bright sky above the reflected horizon - the
    // other half of the bright-spot family. Horizontal distortion
    // untouched; refraction untouched (XE keeps the true position there).
    if (cameraPos.z >= 0.0)
        mgeReflOff.y = -abs(mgeReflOff.y);
#endif
#if MGE_WATER_DISPLACE
    // Displaced path, from above only (XE's own split - the underwater
    // pixel shader keeps the true position): sample the reflection through
    // the clamped screen position so a wave face never reads reflected
    // content from below its own surface. At zero displacement the clamped
    // position equals the true one, so the flat state is unchanged.
#if MGE_WATER_REFL_CLAMP
    if (mgeWaterDisplace > 0.5 && cameraPos.z >= 0.0)
        mgeReflBase = (mgeScreenPosClamp.xy / mgeScreenPosClamp.w) * 0.5 + 0.5;
#endif
#endif
#if MGE_WATER_REFL_FILTER
    // XE's FILTER_WATER_REFLECTION (XE Mod Water.fx:67-80, the "Blur
    // Water Reflections" mechanism), ported as the shimmer's
    // RTT's hard bright/dark content edges over the blur radius, so
    // the offset's strobe becomes a gradient instead of a per-frame
    // flip. Radius law verbatim: screen-space 0.006*sat(0.11+w/6000),
    // pixel-circular via the aspect term - ~4.5 px at 500u (near
    // swing x0.34, raced in sim_water_edge_flicker's blur arm), 23 px
    // far (x0.07). Tap set verbatim; the ramp denominator deviates
    // from XE (3000 vs 6000) per the mid-band ruling.
    // 0 = single-tap byte-exact restore.
    float mgeReflFW = linearizeDepth(gl_FragCoord.z, near, far);
    float mgeReflFR = 0.006 * clamp(0.11 + mgeReflFW / 3000.0, 0.0, 1.0); // 6000 in XE; halved on the mid-band ruling (deviation)
    // beyond the detail fade's reach the flicker has no driver, so
    // blur there is pure sharpness cost. Wind the radius back down
    // over 6000..12000 (the fade's own end) - at and below 6000 the
    // profile is untouched, past 12000 reflections are single-tap
    // sharp. Release aligned to MGE_WAVE_DETAIL_FADE_END by design.
    mgeReflFR *= 1.0 - clamp((mgeReflFW - 6000.0) / 6000.0, 0.0, 1.0);
    vec2 mgeReflRadius = vec2(mgeReflFR, mgeReflFR * (screenRes.x / screenRes.y));
    vec2 mgeReflUV = mgeReflBase + mgeReflOff;
    vec3 reflection = (sampleReflectionMap(mgeReflUV).rgb
        + sampleReflectionMap(mgeReflUV + mgeReflRadius * vec2( 0.60,  0.10)).rgb
        + sampleReflectionMap(mgeReflUV + mgeReflRadius * vec2( 0.30, -0.21)).rgb
        + sampleReflectionMap(mgeReflUV + mgeReflRadius * vec2( 0.96, -0.03)).rgb
        + sampleReflectionMap(mgeReflUV + mgeReflRadius * vec2(-0.40,  0.06)).rgb
        + sampleReflectionMap(mgeReflUV + mgeReflRadius * vec2(-0.70,  0.18)).rgb) / 6.0;
#else
    vec3 reflection = sampleReflectionMap(mgeReflBase + mgeReflOff).rgb;
#endif
#else
    vec3 reflection = sampleReflectionMap(screenCoords + screenCoordsOffset).rgb;
#endif

    // From below, no extra reflection fade is needed on a patched engine:
    // the reflection RTT itself is fogged with the viewer's underwater murk
    // (mge_fog.glsl follows the main viewer's medium via the
    // viewerUnderwater uniform), and the mirrored-camera distance equals
    // the full camera->surface->object light path, so the RTT already
    // hides submerged objects in the reflection to the correct degree.
    // Fading again here would double-count that path.
    //
    // Stock-exe fallback (Redux Plus tier): nothing feeds viewerUnderwater,
    // the heuristic routes the reflection RTT to the above-water model, and
    // the from-below surface turns into an unfogged bright mirror. Restore
    // the pre-engine fade: dissolve the reflection into the murk with the
    // same exponential law as the refraction and the below-water fog.
    if (mgeWeatherUniforms < 0.5 && cameraPos.z < 0.0)
        reflection = mix(mgeUwFogColour(), reflection,
            mgeUwTrans(length(position.xyz - cameraPos.xyz)));

    // void guard, both tiers (see MGE_UW_MIRROR_RAMP above): at the crossing
    // the flipped reflection RTT is black void wherever the mirrored ray hits
    // nothing, and the UW fresnel spikes on ripple back-faces exactly there.
    // The distance fade above cannot help - at the crossing the surface is
    // centimetres away, exp(-0/D) = 1, raw RTT. Blend from murk at zero
    // submersion back to the (already murk-faded) RTT with depth. gl_Fog.color
    // from below is the underwater murk on both tiers - the same colour every
    // neighbouring from-below term converges to, so no seam against them.
    if (cameraPos.z < 0.0)
        reflection = mix(gl_Fog.color.rgb, reflection,
            clamp(-cameraPos.z / MGE_UW_MIRROR_RAMP, 0.0, 1.0));

    // MGE XE Mod Water.fx depthBaseColor: deep-water body colour is
    // weather-lit (sun + 2*sky + fog terms), not a fixed dark constant,
    // so under a bright sky deep water stays mid-luminance instead of
    // going black (stock: WATER_COLOR * sunFade, ~3x darker on a hazy day).
    vec3 waterColor = lcalcDiffuse(0).xyz * vec3(0.03, 0.04, 0.05)
        + (2.0 * mgeSampleSkyCol() + gl_Fog.color.xyz) * vec3(0.075, 0.08, 0.085);

    // ---- regional water character ----
    // Open sea is deliberately a no-op: it keeps the MGE body colour computed
    // above, so parity with the patched engine survives everywhere except the
    // named regions. Only lakes, swamp and sulphur pools deviate, and they blend
    // in over their own inner border so no boundary is ever visible.
    vec4 mgeTypeParams = MGE_TYPE_SEA;
#if MGE_WATER_TYPES
    {
        vec3 typeColour; float typeWeight;
        float isInt = 1.0 - clamp(mgeGetFogParams().z, 0.0, 1.0);
        mgeResolveWaterType(mgeWorldXY, isInt, typeColour, mgeTypeParams, typeWeight);
        // Tint toward the region's colour, preserving the scene's own luminance
        // so a regional character changes hue without lightening or darkening
        // water the rest of the stack has already balanced.
        if (typeWeight > 0.001 && MGE_TYPE_TINT > 0.0)
        {
            vec3 tinted = mix(waterColor, typeColour, MGE_TYPE_TINT * typeWeight);
            float lw = dot(waterColor, vec3(0.2126, 0.7152, 0.0722));
            float lt = dot(tinted, vec3(0.2126, 0.7152, 0.0722));
            waterColor = (lt > 1e-4) ? tinted * (lw / lt) : waterColor;
        }
    }
#endif

    vec4 sunSpec = lcalcSpecular(0);
    // alpha component is sun visibility; we want to start fading lighting effects when visibility is low
    sunSpec.a = min(1.0, sunSpec.a / SUN_SPEC_FADING_THRESHOLD);

    // specular
    const float SPEC_MAGIC = 1.55; // from the original blender shader, changing it makes the spec vanish or become too bright

#if MGE_WATER_WAVE_SHAPES
    // SPEC_BUMPINESS is a micro-roughness boost: MGE XE tuned 5.0 against a
    // nearly-flat normal, where it turns a ~2 deg surface into a ~10 deg
    // specular normal and yields tight glints. Applied to the full normal once
    // real waves exist it amplifies the wave tilt too - a 23 deg swell becomes
    // 65 deg - so broad faces enter the specular lobe together and read as one
    // white sheet instead of sparkle.
    //
    // So boost only the detail, exactly as MGE XE does, then rotate it onto the
    // wave with the same frame the surface normal uses. Highlights are then no
    // brighter than stock, and the wave breaks them up instead of widening them.
    vec3 mgeSpecDetail = normalize(vec3(mgeDetailN.x * SPEC_BUMPINESS,
                                        mgeDetailN.y * SPEC_BUMPINESS,
                                        mgeDetailN.z));
    vec3 specNormal = normalize(mgeT * mgeSpecDetail.x + mgeB * mgeSpecDetail.y
                                + mgeBase * mgeSpecDetail.z);
#else
    vec3 specNormal = normalize(vec3(normal.x * SPEC_BUMPINESS, normal.y * SPEC_BUMPINESS, normal.z));
#endif
    vec3 viewReflectDir = reflect(viewDir, specNormal);
    float phongTerm = max(dot(viewReflectDir, sunWorldDir), 0.0);
    float specular = pow(atan(phongTerm * SPEC_MAGIC), SPEC_HARDNESS) * SPEC_BRIGHTNESS;
    specular = clamp(specular, 0.0, 1.0) * shadow * sunSpec.a;

    // artificial specularity to make rain ripples more noticeable
    vec3 skyColorEstimate = vec3(max(0.0, mix(-0.3, 1.0, sunFade)));
    vec3 rainSpecular = abs(rainRipple.w)*mix(skyColorEstimate, vec3(1.0), 0.05)*0.5;
    float waterTransparency = clamp(fresnel * 6.0 + specular, 0.0, 1.0);

#if @waterRefraction
    // selectively nullify screenCoordsOffset to eliminate remaining shore artifacts, not needed for reflection
    if (cameraPos.z > 0.0 && realWaterDepth <= VISIBILITY_DEPTH && waterDepthDistorted > VISIBILITY_DEPTH)
        screenCoordsOffset = vec2(0.0);
#if MGE_UW_REFR_EDGE_GUARD
    // depth-guarded on the underwater side - ripple offsets sampled
    // the above-water RTT across silhouettes (bright halos, washed
    // thin objects under a dark sky; smooth surface = no offset = no
    // artifact). Zero it where the distorted sample crosses a large
    // depth break; the smooth-surface look is the correct one is the
    // fallback by construction. See MGE_UW_EDGE_DEPTH.
    if (cameraPos.z < 0.0
        && abs(depthSampleDistorted - depthSample) > MGE_UW_EDGE_DEPTH)
        screenCoordsOffset = vec2(0.0);
#endif

    depthSampleDistorted = linearizeDepth(sampleRefractionDepthMap(screenCoords - screenCoordsOffset), near, far);
    waterDepthDistorted = max(depthSampleDistorted - surfaceDepth, 0.0);

    // fade to realWaterDepth at a distance to compensate for physically inaccurate depth calculation
    waterDepthDistorted = mix(waterDepthDistorted, realWaterDepth, min(surfaceDepth / REFR_FOG_DISTORT_DISTANCE, 1.0));

    // refraction
    vec3 refraction = sampleRefractionMap(screenCoords - screenCoordsOffset).rgb;
    vec3 rawRefraction = refraction;

    // brighten up the refraction underwater
    if (cameraPos.z < 0.0)
    {
        // MGE XE UnderwaterPS: from below, refraction fades to the fog
        // colour within ~1500u (exp(-dist/500)). Necessary, not cosmetic:
        // the from-below refraction map is the underwater scene re-rendered
        // z-squashed (water.cpp refraction clip + scale), and unfogged it
        // reads as a displaced copy of the seafloor on the surface.
        float uwDist = length(position.xyz - cameraPos.xyz);
        // No brightness gain on the refracted above-water world: the
        // stock-OpenMW `* 1.5` ("brighten up the refraction underwater")
        // MGE's UnderwaterPS has no such gain (parity notes, entry of
        // only dims. Affects both tiers identically (shared file).
        // onto XE's own exp(-dist/500) for parity, and the next dive
        // showed exactly the artifact the split was warned to cause
        //: a hard bright band across the underside of
        // the surface with light streaks jittering above it. Three terms -
        // this refraction, the from-below reflection, and the scene fog -
        // must fade at one rate or the eye sees the edges between them
        // an incoherence between separately-faded terms rather than a bad
        // formula in any one of them). XE gets away with the split because
        // its underwater scene fog is linear and its surface is softer;
        // on our exponential medium it does not survive contact.
        refraction = mix(mgeUwFogColour(), refraction,
            mgeUwTrans(uwDist));   // shared owner: scene fog + both surface fades

#if MGE_UW_GRAZE_MURK
        // Grazing-transmission murk on every from-below texel (objects
        // included) - see the constant block at MGE_UW_GRAZE_LO.
        // web modulates against; keyed on the displaced direction it cut
        // travelling web-free patches (band 0.10-0.55 spans elevations to
        // 33 deg, facet swing up to 0.35 of the mix).
        refraction = mix(gl_Fog.color.rgb, refraction,
                         smoothstep(MGE_UW_GRAZE_LO, MGE_UW_GRAZE_HI,
                                    mgeViewBelow.z));
#endif

        // void fill. The refraction RTT's sky coverage ends at the
        // atmosphere dome's lower rim; between that rim and the waterline
        // the RTT holds only its clear colour - black - because no sky
        // geometry exists at those angles, so no sky-shader fix can ever
        // paint it (the band seen below the ashstorm dome). The
        // refraction depth identifies sky-region texels: nothing wrote
        // depth there, so it reads the far plane - which also matches the
        // dome's own texels (the sky renders without depth writes), so the
        // fill must not be unconditional or it would murk the legitimate
        // steep-up sky. Physics supplies the gate: from below, sky is only
        // visible inside the Snell window (steep views); at grazing the
        // surface shows the water's own medium. Fill toward murk as the
        // view flattens - full below viewDir.z 0.2 (where the black band
        // and the mis-scattered dome rim live), none above 0.45 (a diver
        // looking up keeps the true sky). MGE's own generous window (its
        // UW fresnel knees at ~79 deg) sits inside the kept range. Both
        // tiers.
        // murk above - sky-backed pixels are the cloud view where the
        // reported travelling patches lived.
        if (depthSampleDistorted > far * 0.9)
            refraction = mix(gl_Fog.color.rgb, refraction,
                             smoothstep(0.2, 0.45, mgeViewBelow.z));
    }
    else
    {
#if MGE_WATER_CAUSTICS
        // Light caustics on the submerged surface. The seabed's world position
        // is taken along this fragment's own view ray: surface and seabed share
        // the ray, and view-space depth scales linearly along it, so the seabed
        // sits at the surface distance scaled by the depth ratio. No matrix
        // inverse needed, and it stays correct in the mirrored passes.
        float surfDist = length(position.xyz - cameraPos.xyz);
        // Validity gates, not taste: the submerged position is reconstructed from
        // depthSample/surfaceDepth, which at grazing horizon angles is a ratio of
        // two near-far-plane values and carries no precision. Feeding that to the
        // Voronoi hash produced coherent flat bars on distant water. Require a
        // real, positive water depth and a distance where caustics can be seen.
        if (MGE_CAUSTIC_INTENSITY > 0.0 && surfaceDepth > 1e-4
            && realWaterDepth > 1.0 && surfDist < MGE_CAUSTIC_MAX_DIST)
        {
            vec3 underwaterPos = cameraPos.xyz + viewDir * (surfDist * depthSample / surfaceDepth);

            // Interior pools are shallower, so their pattern has to survive at
            // a smaller depth to be visible at all.
            float isExterior = clamp(mgeGetFogParams().z, 0.0, 1.0);
            float causticDepth = mix(80.0, 150.0, isExterior);
            causticDepth = smoothstep(causticDepth, 0.0, causticDepth - realWaterDepth);

            vec3 cNormal = normal2 * 0.5 + normal1 - rippleAdd * 5.0;
            float caustics = mgeCaustics(underwaterPos, waterTimer, realWaterDepth,
                                         cNormal, sunWorldDir);

            // Split the pattern slightly by wavelength: real caustics disperse,
            // so the edges carry a faint warm/cool fringe rather than reading as
            // flat white lines.
            vec2 grad = clamp(vec2(dFdx(caustics), dFdy(caustics)), -0.2, 0.4);
            vec3 causticsRGB = vec3(1.0);
            causticsRGB.r += dot(grad, vec2(7.5));
            causticsRGB.b -= dot(grad.yx, vec2(9.5));
            causticsRGB = clamp(pow(max(causticsRGB, 0.0), vec3(1.5, 1.0, 2.5)), 0.0, 2.0);

            // Scaled by what is actually lit down there, so caustics brighten
            // the seabed rather than glowing in empty dark water.
            float lit = dot(rawRefraction, vec3(0.2126, 0.7152, 0.0722));
            // ease off toward the cutoff so the pattern fades rather than pops
            float distFade = 1.0 - smoothstep(MGE_CAUSTIC_MAX_DIST * 0.6, MGE_CAUSTIC_MAX_DIST, surfDist);
            // MGE's waterCaustics by a per-weather multiplier, and its
            // caustics table is identical to its waveHeight table in all ten
            // weathers (0.1 foggy .. 2.0 thunder, verified in its config.lua)
            // - so the multiplier IS our weather wave scale, whose wind curve
            // already reproduces that table, transition-blended by the engine.
            // Interiors take 1.0, as the original hardcodes: full strength,
            // which is deliberately stronger than a clear day outside (0.2).
            float mgeCausticWeather = mix(1.0, mgeWeatherWaveScale(), isExterior);
            refraction += MGE_CAUSTIC_INTENSITY * mgeCausticWeather
                        * mgeTypeParams.z / max(MGE_TYPE_SEA.z, 1e-4)
                        * exp2(-realWaterDepth * 0.002)
                        * (lit * sqrt(causticDepth))
                        * causticsRGB
                        * clamp(sunFade * 1.5 - 0.1, 0.0, 1.0)
                        * distFade
                        * caustics;
            refraction = max(refraction, 0.0);
        }
#endif
        // MGE XE's own depth fade, verbatim (XE Mod Water.fx:196-200):
        // depthscale = saturate(exp(-depth/800)), shorefactor =
        // pow(depthscale, 90), and the refraction keeps
        // 0.8*depthscale + 0.2*shorefactor of the frame.
        //
        // Replaces stock's DEPTH_FADE/visibility rational curve, which was
        // measured much faster than XE's despite carrying the larger
        // constant (2500 vs 800): body-colour weight at 100 u of water was
        // 0.66 against XE's 0.29, at 400 u 0.90 against 0.52. Comparing the
        // constants said the opposite of comparing the curves. So this is
        // parity in the direction of seeing more of the seabed in deep
        float mgeDepthScale = clamp(exp(-waterDepthDistorted / MGE_XE_DEPTH_SCALE),
                                    0.0, 1.0);
        float mgeDepthShore = pow(mgeDepthScale, MGE_XE_DEPTH_SHORE_POW);
        refraction = mix(waterColor, refraction,
                         clamp(0.8 * mgeDepthScale + 0.2 * mgeDepthShore,
                               0.0, 1.0));
#if MGE_WATER_WAVE_SHAPES
        // risen against a shore or sky silhouette samples refraction texels
        // the refraction camera never wrote (it clips everything above the
        // waterline), so the depth reads the far plane and the mix above
        // paints the deep-water body colour mid-break. Original XE
        // structurally cannot show this (its "refraction" is the borrowed
        // framebuffer - always real content behind a wave face). 429's
        // stand-in was the reflection, which at sunset is bright orange sky
        // (the second report). v2 resamples at the undisplaced surface
        // position instead - that column exists in the RTT and shows the
        // actual seabed, true continuity with the neighbouring water; the
        // depth-blend result (the body colour) stays only as the last
        // resort when even that column is unwritten.
        if (depthSample > far * 0.9)
        {
#if MGE_WATER_DISPLACE
            if (mgeWaterDisplace > 0.5)
            {
                vec2 mgeClampUV = (mgeScreenPosClamp.xy / mgeScreenPosClamp.w) * 0.5 + 0.5;
                float mgeClampD = linearizeDepth(sampleRefractionDepthMap(mgeClampUV), near, far);
                if (mgeClampD < far * 0.9)
                    refraction = sampleRefractionMap(mgeClampUV).rgb;
            }
#endif
        }
#endif
    }

#if MGE_WATER_FOAM
    // ---------------------------------------------------------------------
    // Foam, ported from Liam's Rafael Water Edits (Nexus 59113). His approach
    // solves the two things our own attempts could not:
    //
    //  * three layers multiplied, each drifting a different way, so the visible
    //    pattern is their intersection. It churns instead of sliding - which is
    //    why ours read as a conveyor however the taps were aimed.
    //  * the gray-mix of each layer pulses on its own period (2.5 and 1.7 rad/s,
    //    deliberately non-harmonic), so foam forms and dissolves in place rather
    //    than only moving.
    //
    // UVs are world-space directly, not the normal-map UV chain, so foam has its
    // own scale independent of the wave texture.
    vec2 mgeFoamBase = mgeWorldXY * MGE_FOAM_SCALE;
    vec2 mgeDrift1 = vec2(waterTimer * 0.0030,  waterTimer * 0.0020) * MGE_FOAM_DRIFT;
    vec2 mgeDrift2 = vec2(waterTimer * 0.0010, -waterTimer * 0.0040) * MGE_FOAM_DRIFT;
    vec2 mgeDrift3 = vec2(-waterTimer * 0.0025, waterTimer * 0.0015) * MGE_FOAM_DRIFT;

    // slosh - the term that makes foam move, and the answer to "it flashes
    // faster rather than moving faster".
    //
    // Not a drift: real foam has none. MGE XE's foam UVs are bare world
    // position (tex3D(sampWater3d, float3(IN.pos.xy / 45, time)), XE
    // Water.fx:494) and all the motion it shows comes from the surface normal
    // oscillating the shoreline term. A uniform advection along the heading was
    // tried here first and read as foam streaming away from every shore - a
    // current, not surf. Under a swell the orbital motion is a closed loop:
    // foam surges in the travel direction on the crest's leading face, falls
    // back on the trailing face, and goes nowhere net.
    //
    // So the pattern is displaced by a 1-D travelling compression wave along
    // the heading: foam surges down-wave, bunches, and falls back as each
    // surge band passes - to-and-fro with zero net travel, and zero
    // possibility of swirl, because the displacement is always parallel to one
    // fixed axis and varies only along that axis: its curl vanishes
    // identically. One world-unit offset shared by all three layers, scaled
    // per layer below so all three surge the same world distance.
    //
    // constructed, not borrowed - both borrowed signals failed in-game.
    // normal0 swirled ("oil in a puddle"): its ripples vary at the foam
    // features' own scale, so adjacent pixels displaced in different
    // directions - a domain warp. mgeWaveN still swirled ("diesel spilled
    // into water"): a field's normal is its gradient, gradients weight high
    // frequencies - 67% of its slope content sits at <=171-unit features, the
    // foam's own scale again - and the field's internal domain warp adds
    // literal curl. No gain fixes a spectrum; the displacing field must be
    //
    // Phase travels with the sea: +w*t*MGE_WAVE_TRAVEL matches the octave
    // convention where travel=-1 sends the swells along the heading as
    // written. mgeWaveStr gates it: calm floor -> zero surge at Clear/Foggy.
    // On the pre-wave tier the pattern stays put and all motion is the band
    // edge via the swash below - exactly MGE XE, whose foam UVs are bare
    // world position and whose one moving part is that shoreline term.
#if MGE_WATER_WAVE_SHAPES
    float mgeSurgePhase = dot(mgeWorldXY, mgeHeading) * MGE_FOAM_SURGE_K
                        + waterTimer * MGE_FOAM_SURGE_W * MGE_WAVE_TRAVEL;
    vec2 mgeFoamSlosh = mgeHeading * (sin(mgeSurgePhase) * mgeWaveStr
                                      * MGE_FOAM_SURGE * MGE_FOAM_SCALE);
#else
    vec2 mgeFoamSlosh = vec2(0.0);
#endif

    // Foam evolves faster in rough weather. mgeWeatherWaveScale() is the same
    // per-weather table the waves use, so foam and sea state stay in step, and
    // it is available on both tiers (the pre-wave build has no mgeWaveStr).
    float mgeFoamRate = 1.0 + mgeWeatherWaveScale() * MGE_FOAM_STORM_RATE;
    // Note: the gray pulses are a density oscillation - how much foam exists.
    // Speeding them up makes foam blink on and off; it does not make it move.
    // All in-place visibility rates - both pulses and the morph - share the
    // MGE_FOAM_CHURN dial: at Liam's rates (churn 1.0) the three multiplied
    // layers each replaced their pattern out of phase and the product read as
    // shimmering. Motion stays the surge's job; amount stays the masks' job.
    float mgeGrayA = 0.40 + sin(waterTimer * 2.5 * MGE_FOAM_CHURN) * 0.15;
    float mgeGrayB = 0.30 + sin(waterTimer * 1.7 * MGE_FOAM_CHURN + 1.9) * 0.09;

    // Layer rates follow MGE XE's (time, time*1.2, time*0.2): the edge layer
    // evolves slowly, the crest layers faster, and none of them harmonise.
    float mgeFoamT = waterTimer * MGE_FOAM_MORPH * MGE_FOAM_CHURN * mgeFoamRate;
    float mgeFoamR = mgeFoamSlice(normalMap,
                                  (mgeFoamBase + mgeFoamSlosh) * 2.1 + mgeDrift1 * 5.5,
                                  mgeFoamT);
    mgeFoamR = mix(mgeFoamR, 0.5, mgeGrayA);
    mgeFoamR *= mgeFoamSlice(normalMap,
                             (mgeFoamBase + mgeFoamSlosh) * 5.0 + mgeDrift2 * 5.0,
                             mgeFoamT * 1.2 + 0.37);
    mgeFoamR = mix(mgeFoamR, 0.5, mgeGrayB);
    mgeFoamR *= mgeFoamSlice(normalMap,
                             (mgeFoamBase + mgeFoamSlosh) * 5.5 + mgeDrift3 * 6.5,
                             mgeFoamT * 0.2 + 0.81);
    float mgeFoamPat = smoothstep(0.0, MGE_FOAM_CONTRAST, mgeFoamR);

#if MGE_FOAM_CREST_FIELD && MGE_WATER_WAVE_SHAPES && MGE_WATER_WAVE_RAYMARCH
    // old mask's field arm never reached its window (the field's slopes
    // are too mild - coverage 0.00-0.1% at every strength), so the
    // texture arm painted round drifting blobs uncorrelated with the
    // crests. Here: the marched relief height (free - the raymarch
    // already computed it) against an absolute breaking height, which
    // also gives the weather ladder for free (the field's spread grows
    // with sea state); a leading-face bias (n.xy = -grad: the front
    // face of a crest travelling along travelDir has
    // dot(n.xy, travelDir) > 0); slope as a bonus, not a gate. The old
    // texture mask survives at MGE_FOAM_CREST_TEX as breakup. Raced in
    // simulations/sim_foam_crest_shape.py (ribbons, elongation ~2.3,
    // aligned with the crest lines, travelling with the crests).
#if MGE_WATER_DISPLACE
    // Displaced path: the relief height is the vertex displacement itself,
    // handed over as a varying - the march input's exact replacement (and
    // simpler, as the work order predicted). Raymarch path unchanged.
    // mgeDispV served as both the geometry and the whitecap input, so foam
    // inherited two limits it never needed: the 434 shore attenuation, and
    // mgeDispHeight's mesh-carrying LOD (octaves 3-5 gone beyond ~350 u
    // because the mesh cannot carry them, 399). Measured, that ran surf
    // whitecaps at 0.21x the raymarch tier; reading the field here instead
    // - every octave, no shore term, full strength - restores 0.94x.
    // Foam is shading: nothing about it needs the mesh's limits.
    float mgeCrestH = (mgeWaterDisplace > 0.5)
        ? mgeWaveHeight(mgeWavePos.xy, waterTimer * 0.6 * MGE_WAVE_SPEED,
                        mgeWaveDist, mgeWaveStrV, mgeHeading, mgeOctW)
        : (mgeWavePos.z - worldPos.z);
#else
    float mgeCrestH = mgeWavePos.z - worldPos.z;
#endif
    float mgeCrestT0 = MGE_FOAM_CREST_H0;
    float mgeCrestT1 = MGE_FOAM_CREST_H1;
#if MGE_WATER_DISPLACE && MGE_WATER_XE_FIELD
    // XE-field amplitudes are smaller than the procedural field's; the
    // matched-coverage thresholds from sim_xe_field_race X3.
    if (mgeWaterXeField > 0.5)
    {
        mgeCrestT0 = MGE_FOAM_CREST_H0_XE;
        mgeCrestT1 = MGE_FOAM_CREST_H1_XE;
    }
#endif
    float mgeCrest = smoothstep(mgeCrestT0, mgeCrestT1,
                                mgeCrestH);
    vec2 mgeTravelDir = mgeHeading * ((MGE_WAVE_TRAVEL < 0.0) ? 1.0 : -1.0);
    mgeCrest *= 0.35 + 0.65 * smoothstep(-0.02, 0.06,
                                         dot(mgeWaveN.xy, mgeTravelDir));
    mgeCrest *= 0.55 + 0.45 * smoothstep(MGE_FOAM_MIN * 0.4,
                                         MGE_FOAM_MAX * 0.4,
                                         (1.0 - mgeWaveN.z)
                                         * MGE_FOAM_WAVE_GAIN * mgeWaveStr);
    float mgeSlope = length(normal0.xy);
    float mgeTexCrest = smoothstep(MGE_FOAM_MIN, MGE_FOAM_MAX, mgeSlope);
    mgeCrest = max(mgeCrest, mgeTexCrest * mgeTexCrest * mgeTexCrest
                             * MGE_FOAM_CREST_TEX);
    // The relief is deliberately faded flat near the camera
    // (mgeWaveNearFade): no visible crest there, so no whitecap either.
    mgeCrest *= smoothstep(MGE_FOAM_CREST_NEAR0, MGE_FOAM_CREST_NEAR1,
                           distance(position.xyz, cameraPos));
#else
    // Crest foam: steep surface only, tightened by a cube so it picks the tops.
    float mgeSlope = length(normal0.xy);
#if MGE_WATER_WAVE_SHAPES
    mgeSlope = max(mgeSlope, (1.0 - mgeWaveN.z) * MGE_FOAM_WAVE_GAIN * mgeWaveStr);
#endif
    float mgeCrest = smoothstep(MGE_FOAM_MIN, MGE_FOAM_MAX, mgeSlope);
    mgeCrest = mgeCrest * mgeCrest * mgeCrest;
    mgeCrest *= smoothstep(15.0, 50.0, distance(position.xyz, cameraPos));
#endif

    // Shore foam: peaks just off the waterline and is gone by MGE_FOAM_SHORE_DEPTH.
    float mgeShoreF = 0.0;
#if @waterRefraction
    // occluder rejection (the pole-halo fix). realWaterDepth comes from the
    // refraction depth buffer, and a submerged pole writes its surface into
    // that buffer - the water in front of it reports "shallow" and grows a
    // foam outline. Width is the discriminator: a real shore is shallow for
    // hundreds of units, a pole for a few dozen. Two depth taps at
    // +-MGE_FOAM_OCCLUDER_R world units, horizontal in screen space (vertical
    // offsets at grazing angles span enormous along-plane distances).
    //
    // The taps produce a multiplicative suppression, not a remapped band
    // depth. The first shipment fed max(centre, min(L,R)) straight into the
    // band and there were hard diagonal seams: the refraction camera clips
    // everything above the water plane (ClipCullNode, mwrender/water.cpp:53),
    // so land above the waterline is not "shallow" in this buffer - it is
    // far-plane deep - and every waterline or LOD step the taps cross made
    // min(L,R) jump, transplanting a hard edge 55 wu sideways. A function of
    // discontinuous data only renders smoothly if its sensitive range sits
    // where the data cannot jump across it: on a monotone shore
    // min(L,R) <= centre <= band reach, so a suppression window starting AT
    // the band's reach is identically zero wherever legitimate shore foam
    // exists (simulated across slopes 0.05-1.0: exactly 0 in-band), and only
    // a shallow reading flanked by beyond-band water on both sides - the
    // artifact set - can enter it. Known accepted costs: a pole standing
    // inside the active surf zone keeps its foam (it is in surf), and
    // channels narrower than ~2R lose shore foam.
    //
    // World -> screen via the projection diagonal, the fog.glsl:254 recipe
    // (verified in-game there); not the depth gradient, which is
    // piecewise-constant per terrain quad and produced the square facets that
    // killed coast-following (case file coast-following-waves-rp.md).
    float mgeTapUV = min(MGE_FOAM_OCCLUDER_R * gl_ProjectionMatrix[0][0]
                         * 0.5 / max(surfaceDepth, 1.0), 0.2);
    float mgeShoreDepthL = linearizeDepth(sampleRefractionDepthMap(
                               screenCoords - vec2(mgeTapUV, 0.0)), near, far)
                         - surfaceDepth;
    float mgeShoreDepthR = linearizeDepth(sampleRefractionDepthMap(
                               screenCoords + vec2(mgeTapUV, 0.0)), near, far)
                         - surfaceDepth;
    float mgeViewFactor = mix(abs(viewDir.z), 1.0, 0.2);
    float mgeOccluderDeep = min(max(mgeShoreDepthL, 0.0), max(mgeShoreDepthR, 0.0))
                          * mgeViewFactor;
    float mgeOccluderSup = smoothstep(MGE_FOAM_BAND_REACH,
                                      MGE_FOAM_BAND_REACH + MGE_FOAM_OCCLUDER_FADE,
                                      mgeOccluderDeep);
    float mgeFoamDepth = realWaterDepth * mgeViewFactor;
    // swash window - a backstop against deep water being swash-dragged into
    // the band, fading across [window/2, window] x SHORE_DEPTH, deliberately
    // beyond the band's ~92-unit reach so the shore keeps its full dynamics.
    // The fade width must exceed 1.5x the swash amplitude or the depth-to-foam
    // mapping folds and the band splits into two layers with a hard edge -
    float mgeSwashGate = 1.0 - smoothstep(MGE_FOAM_SHORE_DEPTH * (0.5 * MGE_FOAM_SWASH_WINDOW),
                                          MGE_FOAM_SHORE_DEPTH * MGE_FOAM_SWASH_WINDOW,
                                          mgeFoamDepth);
    // Shoreline animation, MGE XE's method (XE Water.fx, "Small scale shoreline
    // animation": depth += 50 * (0.99 - normal.z)). Perturbing the depth moves
    // the band edge up and down the beach; perturbing the foam texture's UV -
    // which is what we kept doing - only slides the pattern along the edge, and
    // that is the difference between surf and a conveyor. The normal taps scroll,
    // so at any fixed point this rises and falls as the swell passes.
#if MGE_FOAM_SWASH_V2
    // (+-40..47 u on a 45-u band with a 5-u inner ramp) punched round
    // travelling no-foam holes through the band and folded its profile
    // into split strips with pixel-hard edges - measured on the real
    // texture in simulations/sim_foam_shore_band.py, matching the
    // report verbatim. V2: a constructed 1-D surge along the heading
    // (the foam-surge construction and K/W - coarse, smooth, curl-free;
    // pure ALU, both tiers) + the texture term at a quarter amplitude
    // (organic breakup that can no longer punch through or fold) + a
    // widened inner ramp below. Raced: enclosed holes 5 -> 0,
    // hard-edge fraction 22.7% -> 0.0%, folds 85% -> 33% (soft).
    // the shores-too-bare report): amplitude, reach and motion each
    // ride the weather - surf foam needs waves; a glassy pond keeps a
    // gently-breathing waterline band and loses the offshore mass.
    float mgeShoreWNorm = smoothstep(MGE_FOAM_SHORE_W0, MGE_FOAM_SHORE_W1,
                                     mgeWeatherWaveScale());
    float mgeShoreWRamp = MGE_FOAM_SHORE_CALM
        + (1.0 - MGE_FOAM_SHORE_CALM) * mgeShoreWNorm;
    float mgeShoreWMot = MGE_FOAM_SHORE_CALM_MOTION
        + (1.0 - MGE_FOAM_SHORE_CALM_MOTION) * mgeShoreWNorm;
    vec2 mgeSwashDir = normalize(MGE_WAVE_HEADING);
    float mgeSwashPhase = dot(mgeWorldXY, mgeSwashDir) * MGE_FOAM_SURGE_K
                        + waterTimer * MGE_FOAM_SURGE_W * MGE_WAVE_TRAVEL;
    mgeFoamDepth += (MGE_FOAM_SWASH_SURGE * sin(mgeSwashPhase)
                     + MGE_FOAM_SWASH_TEX
                       * (MGE_FOAM_SLOPE_MID - length(normal0.xy)))
                    * mgeShoreWMot * mgeSwashGate;
#else
    mgeFoamDepth += MGE_FOAM_SWASH * (MGE_FOAM_SLOPE_MID - length(normal0.xy)) * mgeSwashGate;
#endif
#if MGE_WATER_WAVE_SHAPES
    // With a real wave field the exact quantity is available: a crest lifts the
    // surface, so the waterline runs further up the beach and then withdraws.
    mgeFoamDepth -= (1.0 - mgeWaveN.z) * MGE_FOAM_SWASH_WAVE * mgeWaveStr * mgeSwashGate;
#endif
#if MGE_FOAM_SWASH_V2
    // Squared outer falloff (mass concentrated toward the waterline),
    float mgeShoreReach = mix(MGE_FOAM_SHORE_REACH_CALM,
                              MGE_FOAM_SHORE_REACH, mgeShoreWNorm);
    float mgeShoreFall = 1.0 - smoothstep(MGE_FOAM_SHORE_INNER,
                                          mgeShoreReach,
                                          mgeFoamDepth);
    mgeShoreF = smoothstep(0.0, MGE_FOAM_SHORE_INNER, mgeFoamDepth)
              * mgeShoreFall * mgeShoreFall * mgeShoreWRamp
              * (1.0 - mgeOccluderSup)
              * MGE_FOAM_SHORE;
#else
    mgeShoreF = smoothstep(0.0, 5.0, mgeFoamDepth)
              * (1.0 - smoothstep(5.0, MGE_FOAM_SHORE_DEPTH, mgeFoamDepth))
              * (1.0 - mgeOccluderSup)
              * MGE_FOAM_SHORE;
#endif
#endif
    float mgeFoam = mgeFoamPat * max(mgeCrest, mgeShoreF) * MGE_FOAM_INTENSITY;
#if MGE_FOAM_DEBUG
    gl_FragData[0] = vec4(mgeFoamPat, max(mgeCrest, mgeShoreF), mgeFoam, 1.0);
    return;
#endif
    fresnel *= (1.0 - mgeFoam);      // foam is not a mirror
#endif

#if @sunlightScattering
    vec3 scatterNormal = (normal0 * bigWaves.x * 0.5 + normal1 * bigWaves.y * 0.5 + normal2 * midWaves.x * 0.2 +
                          normal3 * midWaves.y * 0.2 + normal4 * smallWaves.x * 0.1 + normal5 * smallWaves.y * 0.1 + rippleAdd);
    scatterNormal = normalize(vec3(-scatterNormal.xy * bump, scatterNormal.z));
    float sunHeight = sunWorldDir.z;
    vec3 scatterColour = mix(SCATTER_COLOUR * vec3(1.0, 0.4, 0.0), SCATTER_COLOUR, max(1.0 - exp(-sunHeight * SUN_EXT), 0.0));
    float scatterLambert = max(dot(sunWorldDir, scatterNormal) * 0.7 + 0.3, 0.0);
    float scatterReflectAngle = max(dot(reflect(sunWorldDir, scatterNormal), viewDir) * 2.0 - 1.2, 0.0);
    float lightScatter = scatterLambert * scatterReflectAngle * SCATTER_AMOUNT * sunFade * sunSpec.a * max(1.0 - exp(-sunHeight), 0.0);
    refraction = mix(refraction, scatterColour, lightScatter);
#endif

    gl_FragData[0].rgb = mix(refraction, reflection, fresnel);
    gl_FragData[0].a = 1.0;
    // no alpha here, so make sure raindrop ripple specularity gets properly subdued
    rainSpecular *= waterTransparency;
#else
    gl_FragData[0].rgb = mix(waterColor, reflection, (1.0 + fresnel) * 0.5);
    gl_FragData[0].a = waterTransparency;
#endif

#if MGE_WATER_FOAM
    // Lit like the rest of the surface, capped so it never blows out.
    // Foam keeps some of the water beneath it - a flat grey reads as paint.
    vec3 mgeFoamCol = mix(gl_FragData[0].rgb,
                          clamp(vec3(sunSpec.a * 0.40 + 0.60), 0.0, 0.74), 0.85);
    gl_FragData[0].rgb = mix(gl_FragData[0].rgb, mgeFoamCol, mgeFoam);
#endif

    gl_FragData[0].rgb += specular * sunSpec.rgb + rainSpecular;

    // term (XE Mod Water.fx:267-270), never ported until now:
    //   spec = sunColAdjusted * pow(dot(-EyeVec, normalize(-sunPos + normal)), 6) * exp(-dist/4096)
    // A broad sun glow through the surface, rippled per pixel by the
    // normal. It is the underside's only content-independent texture: our
    // web is folded content edges, so over smooth content (cloud
    // interiors, terrain masses in the refraction) the underside read as
    // naked webless slicks - the travelling "oil spills". XE never
    // shows them naked because this glow textures everything. Verified in
    // the replication render: slick-interior texture energy goes from
    // zero to web-comparable with the term on (sim_uw_web_render round,
    // as everywhere else in this shader.
    if (cameraPos.z < 0.0)
    {
        float mgeRefrSun = clamp(dot(-viewDir,
                                     normalize(-sunWorldDir + normal)), 0.0, 1.0);
        gl_FragData[0].rgb += sunSpec.rgb * sunSpec.a
                            * pow(mgeRefrSun, 6.0)
                            * clamp(exp(-length(position.xyz - cameraPos.xyz)
                                        / 4096.0), 0.0, 1.0);
    }

#if @waterRefraction && @wobblyShores
    // wobbly water: hard-fade into refraction texture at extremely low depth, with a wobble based on normal mapping
    vec3 normalShoreRippleRain = texture2D(normalMap,normalCoords(UV, 2.0, 2.7, -1.0*waterTimer,  0.05,  0.1,  normal3)).rgb - 0.5
                               + texture2D(normalMap,normalCoords(UV, 2.0, 2.7,      waterTimer,  0.04, -0.13, normal4)).rgb - 0.5;
    float viewFactor = mix(abs(viewDir.z), 1.0, 0.2);
    float verticalWaterDepth = realWaterDepth * viewFactor; // an estimate
    float shoreOffset = verticalWaterDepth - (normal2.r + mix(0.0, normalShoreRippleRain.r, rainIntensity) + 0.15)*8.0;
    float fuzzFactor = min(1.0, 1000.0 / surfaceDepth) * viewFactor;
    shoreOffset *= fuzzFactor;
    shoreOffset = clamp(mix(shoreOffset, 1.0, clamp(linearDepth / WOBBLY_SHORE_FADE_DISTANCE, 0.0, 1.0)), 0.0, 1.0);
    // Fresnel floor: at grazing angles the surface must go reflective, never
    // raw refraction. Stock's viewFactor inverts this, making shallow bays
    // read as dry seabed from low camera angles.
    shoreOffset = max(shoreOffset, clamp(fresnel * 3.0, 0.0, 1.0));
    // No-geometry guard: near shore silhouettes the distorted refraction
    // sample can land beyond all submerged geometry, where the refraction
    // RTT holds its empty background (bright scatter sky under the MGE
    // fog), which shows as bright wobble-edged patches in dark water.
    // If the distorted sample hit (near) the far plane, there is no seabed
    // to show; suppress the raw-refraction path entirely.
    if (depthSampleDistorted > far * 0.9)
        shoreOffset = 1.0;
#if MGE_WATER_DISPLACE
    if (mgeWaterDisplace > 0.5)
    {
        // Displaced path: the stock wobble fakes a moving waterline on a
        // static sheet - with real geometry the line already moves, and the
        // painted wobble rides the real waves on top of it (the reported
        // "malleable edge", a double wobble). Duty transferred to XE's own
        // shore treatment (XE Mod Water.fx:226-229 + :262): depth plus the
        // small-scale shoreline animation term 300*(0.95 - normal.z) - the
        // real wave normal now, so the line breathes with the actual waves -
        // through the sharp exp fade, blending the last units of depth into
        // the refraction (wet ground) instead of a hard sweeping edge.
        float mgeShoreDepth = verticalWaterDepth + 300.0 * (0.95 - normal.z);
        float mgeShoreFactor = pow(clamp(exp(-mgeShoreDepth / 800.0), 0.0, 1.0), 90.0);
        // keep the two shipped guards: never raw refraction at grazing
        // (the fresnel floor's duty) and never where the refraction sample
        // has no seabed behind it
        if (depthSampleDistorted > far * 0.9)
            mgeShoreFactor = 0.0;
        mgeShoreFactor = min(mgeShoreFactor, 1.0 - clamp(fresnel * 3.0, 0.0, 1.0));
        shoreOffset = 1.0 - mgeShoreFactor;
    }
#endif
    gl_FragData[0].rgb = mix(rawRefraction, gl_FragData[0].rgb, shoreOffset);
#endif

// ==== water probe (diagnostic, normally 0) ====
// Mode 1: false-colour R = fresnel, G = reflection luminance,
//         B = refraction luminance.
// Mode 2: raw mirror: display the reflection RTT sample directly (no
//         distortion offset) to inspect the RTT's actual content.
#define MGE_WATER_PROBE 0
#if MGE_WATER_PROBE == 1
    gl_FragData[0] = vec4(fresnel,
        dot(reflection, vec3(0.3333)),
#if @waterRefraction
        dot(rawRefraction, vec3(0.3333)),
#else
        0.0,
#endif
        1.0);
    return;
#elif MGE_WATER_PROBE == 2
    gl_FragData[0] = vec4(sampleReflectionMap(screenCoords).rgb, 1.0);
    return;
#endif
// ==== end TEMP water probe ====

#if @radialFog
    float radialDepth = distance(position.xyz, cameraPos);
#else
    float radialDepth = 0.0;
#endif

#ifdef LIB_LIGHTING_UTIL
    // MGE XE fogColourWater: water shares the scattering fog so the sea
    // horizon meets the sky seamlessly.
    float mgeDist = distance(position.xyz, cameraPos);
    vec3 mgeDir = normalize(position.xyz - cameraPos.xyz);
    gl_FragData[0] = applyFogAtDirWorld(gl_FragData[0], mgeDist, mgeDir, far);
#else
    gl_FragData[0] = applyFogAtDist(gl_FragData[0], radialDepth, linearDepth, far);
#endif

    // Underwater source probe (mge_fog.glsl, normally off): the water
    // surface plane seen from below tints red. Applied after fog so the
    // region reads red wherever the surface plane is what's on screen.
    if (cameraPos.z < 0.0 && mgeUwProbe())
        gl_FragData[0].rgb = mix(gl_FragData[0].rgb, vec3(1.0, 0.0, 0.0), 0.45);

#if !@disableNormals
    gl_FragData[1].rgb = normalize(gl_NormalMatrix * normal) * 0.5 + 0.5;
#endif

    applyShadowDebugOverlay();
}
