#ifndef MGE_FOG_GLSL
#define MGE_FOG_GLSL
// ============================================================================
// MGE XE fog & atmospheric scattering port (shared core), live 0.18 model.
// Reference implementation: MGE XE shaders\core\XE Common.fx
// (fogColourScatter/fogColour/fogColourSky, USE_EXPFOG + USE_SCATTERING
// branches) + MGE XE engine source distantland.cpp
// (adjustFog/setupCommonEffect).
//
// Model (XE Common.fx verbatim):
//   x   = (dist - fogExpStart) / fogExpDivisor        optical depth
//   fog = saturate(exp(-x))                           transmittance
//   inscatter = scatterColour(dir, saturate(0.224*x)) in nice weather
//             = (1 - fog) * fogColour(palette)        otherwise
//   applied as: scene' = fog * scene + inscatter      (fogApply)
// The 0.224 inscatter distance keeps mid-range haze dim and blue relative
// to the fogdist=1 horizon/sky; don't substitute the sky colour here.
//
// Engine-side range setup (distantland.cpp adjustFog, exp-fog branch):
//   fogEnd   = max(0.875, ff * AboveWaterFogEnd)                    [cells]
//   fogStart = ff * AboveWaterFogStart + (lg/(1+lg)) * fogEnd,
//              lg = ln(1 - 0.25*fo)                                 [cells]
//   fogExpStart   = fogStart * cell / 4.4      (expFogDistScale hardcoded;
//   fogExpDivisor = (fogEnd * cell - fogExpStart) / 4.4    the MGE.ini
//              "Exponential Distance Multiplier" key is dead legacy)
//   ff/fo = per-weather Fog Ratio / Fog Offset (XE defaults; live install
//   has no override): fed by the engine patch as mgeFogParams.
//
// MGE.ini reference values: Above Water Fog Start=2, End=5, exp fog on.
// ============================================================================

uniform mat4 osg_ViewMatrixInverse;

// Engine-patch uniforms (MGE parity). A patched OpenMW sets
// mgeWeatherUniforms=1 and feeds live values; on stock builds GLSL defaults
// them to 0 and the palette heuristics below take over.
uniform float mgeWeatherUniforms;
uniform float mgeNiceWeather; // squared transition blend, as in MGE
uniform vec3 mgeSkyColor;
// (ff = weather Fog Ratio, fo = weather Fog Offset [0..2], isExterior, isDay).
// A patched exe that predates this uniform leaves it at 0 -> the x<0.01
// guard falls back to Clear weather (ff=1, fo=0, exterior, day).
uniform vec4 mgeFogParams;
// World-space sun direction (patch v5+), identical to light 0 in the main
// pass but valid in every pass. RTT passes (e.g. the reflected sky) have
// no usable light 0, and normalize(0) there produces NaN.
uniform vec3 mgeSunDir;

// Scattering coefficients. Managed by scripts/wa_preset_apply.py, currently
// the WA "MGG" preset. XE engine defaults (distantinit.cpp)
// would be out (0.07,0.36,0.76) / in (0.25,0.38,0.48).
const vec3 mgeOutscatter        = vec3(0.2411, 0.4339, 0.6677);
const vec3 mgeInscatter         = vec3(0.0443, 0.1836, 0.2887);
// Runtime override (XE Sky Variations port): the Lua API
// core.weather.setMgeScattering() feeds these via engine uniforms for the
// daily scattering variation. 0 = use the preset consts above (default;
// wa_preset_apply.py keeps managing the consts as the baseline).
uniform vec3 mgeOutscatterU;
uniform vec3 mgeInscatterU;
uniform float mgeScatterUniformsOn;

// Scatter formula era. The constants changed between the 2020-era XE build
// (MGE XE 0.11-era XE Common.fx, which the MGG preset was tuned against)
// and the live 2023 install (0.18-style). Mixing MGG coefficients with the
// live formula washes clear weather to white (doc §4f), so keep preset era
// and formula era together. 1 = 2020/0.11-era, 0 = live/0.18-style.
#define MGE_SCATTER_ERA_2020 1

// Height-aware scene fog in dense weathers (summits shed fog, valleys
// gain it). 0 = plain distance fog. The same switch exists in
// STEP_SSAO_HQ.omwfx and MGG_Bloom_Soft.omwfx, which mirror the fog
// curve; keep all three in the same state.
#define MGE_HEIGHT_FOG 1

#if MGE_SCATTER_ERA_2020
// newskycol = 0.38*sky + fixed blue; the fixed term keeps clear haze blue.
const vec3 mgeSkyBase           = vec3(0.23, 0.39, 0.68);
const float mgeSkyWeight        = 0.38;
const float mgeExpFogDistScale  = 4.0;   // ini "Exponential Distance
                                         // Multiplier=4" was live in 0.11
#else
const vec3 mgeSkylightScatter   = vec3(0.4456, 0.6194, 1.0);
const float mgeSkylightMix      = 0.44;
const float mgeExpFogDistScale  = 4.4;   // constexpr in distantland.cpp
#endif

// MGE.ini [Distant Land] (live install) + hardcoded engine constants.
const float mgeCell             = 8192.0;
const float mgeAWFogStart       = 2.0;   // Above Water Fog Start [cells]
const float mgeAWFogEnd         = 5.0;   // Above Water Fog End   [cells]
// Morrowind's own draw range in MGE XE: inside it the vanilla renderer
// fogs the scene with the linear near-fog range adjustFog fits to the exp
// curve (see mgeFogColourWorld); MGE's exp fog only rules beyond.
const float mgeNearViewRange    = 7168.0;
// Live override from the engine ([Fog] 'mge fog start/end cells', fed as a
// uniform; the Distant Land Generator app edits those settings). 0 = use
// the constants above (also what stock builds get).
uniform vec2 mgeFogRange;

float mgeGetNiceWeather()
{
    if (mgeWeatherUniforms > 0.5)
        return mgeNiceWeather; // live from the engine weather system

    // Fallback heuristic (stock exe only). MGE: nice = 1 for Clear/Cloudy.
    // Live (vanilla) palette signals: Clear fog is bright and blue-tinted
    // (206,227,255); bad-weather fogs are grey/warm and darker. Cloudy fog
    // is warm-white, caught by the sun-luminance gate instead.
    vec3 fc = gl_Fog.color.xyz;
    float lum = dot(fc, vec3(0.299, 0.587, 0.114));
    float blueGate = clamp(8.0 * (fc.b - fc.r), 0.0, 1.0)
                   * clamp(4.0 * (lum - 0.6), 0.0, 1.0);
    float sunLum = dot(lcalcDiffuse(0), vec3(0.299, 0.587, 0.114));
    float sunGate = clamp((sunLum - 0.65) * 4.0, 0.0, 1.0);
    return max(blueGate, sunGate);
}

vec4 mgeGetFogParams() // (ff, fo, isExterior, isDay)
{
    vec4 p = mgeFogParams;
    if (p.x < 0.01)
        p = vec4(1.0, 0.0, 1.0, 1.0); // Clear weather defaults, exterior, day
    return p;
}

// Weather-transition endpoints (patched engine): Cur = (ff, fo, valid, 0),
// Next = (ff, fo, blend, 0). The fog ranges below contain knee-shaped
// terms (dense pull-in, layer gates) that ramp over a narrow ff band;
// deriving from the blended ff would compress their whole visual change
// into a fraction of a transition. Instead derive at both endpoint
// weathers and lerp the derived values: endpoint looks are unchanged and
// the transition path is even.
uniform vec4 mgeFogParamsCur;
uniform vec4 mgeFogParamsNext;

// Dense-weather response knees (authored on top of XE): the weights ramp in
// as the per-weather fog ratio ff drops below Cloudy (ff = 0.9).
const float mgeDenseKneeStart = 0.9;  // ff at which dense-weather terms begin
const float mgeDenseKneeWidth = 0.4;  // full dense weight at ff = 0.5
const float mgeLayerKneeWidth = 0.2;  // full layer/pull-in weight at ff = 0.7
const float mgeFogStartPullIn = 0.65; // dense weather shrinks the clear-air fog start to 65%
// XE adjustFog verbatim: the linear near-fog range is fitted to the exp
// curve at this distance and at min(fogEnd, nearViewRange).
const float mgeNearFitDist = 1280.0;
// XE Common.fx verbatim: inscatter colour distance scale (see header).
const float mgeInscatterDistScale = 0.224;

struct MgeFogDerived
{
    float expStart;   // exp curve start [units]
    float expDiv;     // exp curve divisor [units]
    float fogEnd;     // envelope end [cells]
    float wDense;     // dense-weather weight (floor, sky band)
    float wLayer;     // height-layer gate
};

MgeFogDerived mgeDeriveFogAt(float ff, float fo)
{
    MgeFogDerived d;
    float awStart = mgeFogRange.x > 0.0 ? mgeFogRange.x : mgeAWFogStart;
    float awEnd = mgeFogRange.y > 0.0 ? mgeFogRange.y : mgeAWFogEnd;
    d.fogEnd = max(0.875, ff * awEnd);
    float lg = log(max(1.0 - 0.25 * fo, 0.05));
    float fogStart = ff * awStart + (lg / (1.0 + lg)) * d.fogEnd;
    // dense-weather pull-in: the clear-air start shrinks by up to 35% as
    // the envelope compresses; Clear/Cloudy unaffected
    fogStart *= mix(1.0, mgeFogStartPullIn, clamp((mgeDenseKneeStart - ff) / mgeLayerKneeWidth, 0.0, 1.0));
    d.expStart = fogStart * mgeCell / mgeExpFogDistScale;
    d.expDiv = (d.fogEnd * mgeCell - d.expStart) / mgeExpFogDistScale;
    d.wDense = clamp((mgeDenseKneeStart - ff) / mgeDenseKneeWidth, 0.0, 1.0);
    d.wLayer = clamp((mgeDenseKneeStart - ff) / mgeLayerKneeWidth, 0.0, 1.0);
    return d;
}

MgeFogDerived mgeDerivedFog()
{
    if (mgeFogParamsCur.z > 0.5)
    {
        MgeFogDerived a = mgeDeriveFogAt(mgeFogParamsCur.x, mgeFogParamsCur.y);
        MgeFogDerived b = mgeDeriveFogAt(mgeFogParamsNext.x, mgeFogParamsNext.y);
        float t = clamp(mgeFogParamsNext.z, 0.0, 1.0);
        MgeFogDerived d;
        d.expStart = mix(a.expStart, b.expStart, t);
        d.expDiv = mix(a.expDiv, b.expDiv, t);
        d.fogEnd = mix(a.fogEnd, b.fogEnd, t);
        d.wDense = mix(a.wDense, b.wDense, t);
        d.wLayer = mix(a.wLayer, b.wLayer, t);
        return d;
    }
    vec4 p = mgeGetFogParams();
    return mgeDeriveFogAt(p.x, p.y);
}

// Dense-weather sky-fog band raise. The XE dome blend puts solid fog
// colour only below dirZ ~0.075 (~4 deg); tall massifs (Red Mountain
// subtends 10-15 deg from Ald-Ruhn) poke above the fogged sky into the
// cloud layer and read as cutouts, while ordinary low landscape sits
// inside the band and looks right. In dense weathers the band can be
// raised: the same XE curve evaluated at dirZ / raise, lerped in by the
// ff weight so Clear/Cloudy keep the exact XE dome. Tune mgeFogSkyRaise:
// 2.0 (subtle) .. 5.0 (fog wraps very tall peaks). Kept at 1.0 (stock XE
// dome) because the layered per-fragment height fog below covers the same
// problem: summits shed fog by their own altitude instead of the sky band
// being lifted to meet them.
const float mgeFogSkyRaise = 1.0;
float mgeSkyFogH(float dirZ)
{
    float wDense = mgeDerivedFog().wDense;
    float zEff = dirZ / mix(1.0, mgeFogSkyRaise, wDense);
    return 1.0 - pow(clamp(1.0 - 2.22 * clamp(zEff - 0.075, 0.0, 1.0), 0.0, 1.0), 1.15);
}

// Set to true on the water-reflection camera's StateSet by the engine
// (water.cpp "Inform the shader that we're in a reflection"); GLSL default
// false everywhere else.
uniform bool isReflection;

// True when the main viewer is underwater; set per frame on the root
// stateset by the engine (SharedUniformStateUpdater, from the same
// isUnderwater state that switches gl_Fog). Authoritative for every pass:
// deriving underwater state from the view matrix or camera z is unreliable
// per-program under OSG's matrix plumbing.
uniform bool viewerUnderwater;

// Set true on the water-refraction camera's StateSet by the engine
// (water.cpp); GLSL/root default false everywhere else.
uniform bool isRefraction;

// True when fog should use the above-water model. Follows the main viewer
// for the reflection RTT too: the water-reflection camera is mirrored
// through the surface, so its distances equal the full camera->surface->
// object light path. Fogging the reflection with the viewer's own medium
// therefore fades submerged objects in the reflection at the same rate
// the murk hides them in direct view, while above-water reflections stay
// on the atmospheric model. The refraction RTT is the exception: from
// below it renders the above-water world (the engine feeds it the
// above-water gl_Fog state), so it stays on the above-water model and
// distant trees keep their haze when the viewer surfaces. Other
// fog-disabled utility RTTs (local map, previews) early-out on the
// gl_Fog.start sentinel before this matters.
bool mgeCamAboveWater()
{
    return !viewerUnderwater || isRefraction;
}

// ==== Underwater source probe (diagnostic, normally 0) ====
// False-colours the from-below view by source renderer so one screenshot
// attributes any banding to the pass that draws it:
//   blue  tint = scene geometry fogged by the underwater fog branch
//   green tint = the sky dome drawn directly (sky.frag)
//   red   tint = the water surface plane (water.frag from below)
// Reflection RTT content is deliberately untinted (isReflection forces the
// above-water path). Untinted bright areas inside the red surface region
// point to reflection/refraction injection; untinted banding across all
// regions points to the post chain (bisect with the F2 live toggles).
#define MGE_UW_SOURCE_PROBE 0
bool mgeUwProbe()
{
#if MGE_UW_SOURCE_PROBE
    return !mgeCamAboveWater();
#else
    return false;
#endif
}

// Underwater exponential-murk fade distance (transmittance 1/e here). Shared
// by the below-water fog above and by the reflection/refraction fades in
// water.frag so all three converge to gl_Fog.color at one rate. Derived from
// the underwater fog end (settings 'mge underwater fog end cells') so that
// remains the single live tuning knob; falls back if the range is unset.
float mgeUwFogDist()
{
    return (gl_Fog.end > 1.0 && gl_Fog.end < 1000000.0) ? gl_Fog.end * 0.33 : 800.0;
}

// Core scatter equation: XE Common.fx fogColourScatter nice branch,
// verbatim (live 0.18 constants). fogdist in [0,1].
vec3 mgeScatter(vec3 dir, float fogdist, vec3 skyCol)
{
    vec3 sunWorld;
    if (dot(mgeSunDir, mgeSunDir) > 1e-4)
    {
        sunWorld = normalize(mgeSunDir); // patch v5+: pass-independent
    }
    else
    {
        // pre-v5 exe / stock: derive from light 0, guarded against the
        // degenerate light state of RTT passes
        vec3 lp = lcalcPosition(0);
        if (dot(lp, lp) > 1e-6)
            sunWorld = normalize((osg_ViewMatrixInverse * vec4(normalize(lp), 0.0)).xyz);
        else
            sunWorld = vec3(0.0, 0.0, 1.0);
    }
    // MGE parity: at night the engine sun light still travels above the
    // horizon (invisible); MGE flips sunPos.z downward when sunVis==0 so the
    // scattering sees a below-horizon sun and sunaltitude_b kills the scatter
    // (near-black night fog). Replicate via the isDay flag.
    if (mgeGetFogParams().w < 0.5)
        sunWorld.z = -abs(sunWorld.z);
    float sunZ = sunWorld.z;
    float sunaltitude = pow(1.0 + sunZ, 10.0);
    float sunaltitude_a = 2.8 + 4.3 / sunaltitude;
    float sunaltitude_b = clamp(1.0 - exp2(-1.9 * sunaltitude), 0.0, 1.0);
    float sunaltitude_c = clamp(exp(-4.0 * sunZ), 0.0, 1.0) * clamp(sunaltitude, 0.0, 1.0);

#if MGE_SCATTER_ERA_2020
    // 0.11-era branch (2020 XE Common.fx): exp(-2) mie damping,
    // 1.62/(1.3-suncos), full mie in att, (1.1*atmdep+0.5) gain.
    float sunaltitude2 = clamp(exp(-2.0 * sunZ), 0.0, 1.0) * clamp(sunaltitude, 0.0, 1.0);
    vec3 newSkyCol = mgeSkyWeight * skyCol + mgeSkyBase;

    float suncos = dot(dir, sunWorld);
    float mie = (1.62 / (1.3 - suncos)) * sunaltitude2;
    float rayl = 1.0 - 0.09 * mie;

    float atmdep = 1.33 * exp(-2.0 * clamp(dir.z, 0.0, 1.0));
    vec3 scIn = (mgeScatterUniformsOn > 0.5) ? mgeInscatterU : mgeInscatter;
    vec3 scOut = (mgeScatterUniformsOn > 0.5) ? mgeOutscatterU : mgeOutscatter;
    vec3 sunscatter = mix(scIn, scOut, 0.5 * (1.0 + suncos));
    vec3 att = atmdep * sunscatter * (sunaltitude_a + mie);
    att = (1.0 - exp(-fogdist * att)) / att;

    vec3 colour = vec3(0.125 * mie) + newSkyCol * rayl;
    colour *= att * (1.1 * atmdep + 0.5) * sunaltitude_b;
    return colour;
#else
    vec3 newSkyCol = mix(skyCol, mgeSkylightScatter, mgeSkylightMix);

    float suncos = dot(dir, sunWorld);
    float mie = (1.58 / (1.24 - suncos)) * sunaltitude_c;
    float rayl = 1.0 - 0.09 * mie;

    float atmdep = 1.33 * exp(-2.0 * clamp(dir.z, 0.0, 1.0));
    vec3 scIn = (mgeScatterUniformsOn > 0.5) ? mgeInscatterU : mgeInscatter;
    vec3 scOut = (mgeScatterUniformsOn > 0.5) ? mgeOutscatterU : mgeOutscatter;
    vec3 sunscatter = mix(scIn, scOut, 0.5 * (1.0 + suncos));
    vec3 att = atmdep * sunscatter * (sunaltitude_a + 0.7 * mie);
    att = (1.0 - exp(-fogdist * att)) / att;

    vec3 colour = vec3(0.125 * mie) + newSkyCol * rayl;
    colour *= att * (1.17 * atmdep + 0.89) * sunaltitude_b;
    return colour;
#endif
}

// fogColour(): rgb = inscattered light, a = transmittance.
// Apply as: scene' = a * scene + rgb   (XE Common.fx fogApply)
// useNearLinear: XE fogColour (land/objects) switches to the vanilla
// linear near fog inside nearViewRange; fogColourWater is pure exp.
vec4 mgeFogColourWorld(float dist, vec3 dirWorld, float far, vec3 skyCol, bool useNearLinear, vec4 skyBehind)
{
    // Fog-off convention: utility RTT cameras (local map, character preview)
    // "disable" fog by setting gl_Fog.start/end = 1e7 ("shaders don't
    // respect glDisable(GL_FOG)", localmap.cpp). The absolute world-unit
    // ranges here must honour that sentinel or map tiles get hazed.
    if (gl_Fog.start > 1000000.0)
        return vec4(0.0, 0.0, 0.0, 1.0);

    vec4 p = mgeGetFogParams();

    if (p.z < 0.5)
    {
        // Interior: MGE runs plain linear fog to the palette colour
        // (adjustFog interior branch); gl_Fog carries the matching ranges.
        float f = clamp((gl_Fog.end - dist) / max(gl_Fog.end - gl_Fog.start, 1.0), 0.0, 1.0);
        return vec4((1.0 - f) * gl_Fog.color.xyz, f);
    }
    if (!mgeCamAboveWater())
    {
        // Exterior underwater: one smooth exponential murk. A linear chord
        // clamps to full fog at a fixed distance, producing a fixed
        // world-elevation ring that reads as a hard horizontal line sliding
        // with camera pitch; exp has no such kink and reaches clear (T=1)
        // at the camera. The water surface, seabed, and the reflection/
        // refraction fades in water.frag all converge to gl_Fog.color on
        // the same law, so the from-below view is a single medium instead
        // of stacked bands.
        float T = exp(-dist / mgeUwFogDist());
        vec3 uwFogCol = gl_Fog.color.xyz;
        if (mgeUwProbe())
            uwFogCol = mix(uwFogCol, vec3(0.0, 0.0, 1.0), 0.6); // probe: murk tinted blue
        return vec4((1.0 - T) * uwFogCol, T);
    }

    // Engine-side range setup (adjustFog), in shader because OpenMW's fog
    // params carry different semantics. Derived at both transition
    // endpoints and lerped (see mgeDerivedFog).
    MgeFogDerived dv = mgeDerivedFog();
    float fogEnd = dv.fogEnd;
    float fogExpStart = dv.expStart;
    float fogExpDivisor = dv.expDiv;

    // ===== Height-aware scene fog =====
    // A camera-anchored height profile lets summits shed accumulated depth
    // and valleys gain it, and after the curve a transmittance floor stops
    // fog from ever fully owning a surface: geometry always keeps a slice
    // of its own shading, so silhouettes read slightly darker than the
    // adjacent sky instead of milking out whiter than the fog. Scene-only
    // (a unified post-pass variant is kept in reserve as
    // mwse_fog_volumetric.omwfx, currently passthrough).
    float wDense = dv.wDense;
    float distEff = dist;
#if MGE_HEIGHT_FOG
    if (wDense > 0.001)
    {
        // Layer model: the fog-layer density falls off with altitude as
        // exp(-dz/H), dz = fragment height above the camera, integrated
        // along the ray in closed form. Per-fragment by construction: one
        // mountain fogs fully at its base and sheds fog up its slopes. A
        // ray-averaged density would give the whole entity one uniform
        // treatment; a pure fragment-endpoint density would treat the
        // whole path as summit-thin air and strip all atmosphere off
        // elevated massifs. The ray-integrated closed form is the middle:
        // dense air near the base still contributes, thin air at altitude
        // relieves. Not path-physical, a deliberate perceptual choice.
        // Full-strength wLayer gate from Overcast (ff<=0.7) down.
        // Calibration knobs: H (layer thickness) and the clamp floor
        // (max shed).
        const float mgeFogScaleHeight = 4608.0;
        float wLayer = dv.wLayer;
        float dz = dirWorld.z * dist;
        float F = 1.0;
        if (abs(dz) > 1.0)
            F = (mgeFogScaleHeight / dz) * (1.0 - exp(-clamp(dz / mgeFogScaleHeight, -30.0, 30.0)));
        // Angle-dependent shed limit: a steep look-up (local towering
        // rock) may shed far more fog than a distant massif at grazing
        // elevation.
        float steep = smoothstep(0.25, 0.6, dirWorld.z);
        F = clamp(F, mix(0.25, 0.08, steep), 2.5);
        distEff = dist * mix(1.0, F, wLayer);
    }
#endif
    // ===== end height-aware scene fog (floor applied after the curve below) =====

    float x = (distEff - fogExpStart) / fogExpDivisor;
    float fog;
    if (useNearLinear && distEff <= mgeNearViewRange)
    {
        // XE Common.fx fogColour: fog = (dist > nearViewRange) ? exp :
        // fogMWScalar. Inside Morrowind's own draw range MGE fogs with
        // vanilla linear fog whose range adjustFog fits to the exp curve
        // at 1280 units and at min(fogEnd, nearViewRange). exp(-x) is
        // convex, so this chord sits above it and keeps mid-range objects
        // considerably more readable in dense weather (Foggy at 4000u:
        // ~60% fogged vs ~83% pure-exp). Running the exp curve at all
        // ranges washes out close objects.
        float farIntercept = min(fogEnd * mgeCell, mgeNearViewRange);
        float eN = exp(-(mgeNearFitDist - fogExpStart) / fogExpDivisor);
        float eF = exp(-(farIntercept - fogExpStart) / fogExpDivisor);
        float fogNearStart = mgeNearFitDist + (farIntercept - mgeNearFitDist) * (1.0 - eN) / (eF - eN);
        float fogNearEnd = mgeNearFitDist + (farIntercept - mgeNearFitDist) * (0.0 - eN) / (eF - eN);
        fog = clamp((fogNearEnd - distEff) / (fogNearEnd - fogNearStart), 0.0, 1.0);
    }
    else
        fog = clamp(exp(-x), 0.0, 1.0);

    // Transmittance floor: in dense weathers geometry keeps at least this
    // share of its own colour no matter the distance. Tune 0 (pure MGE
    // convergence) .. 0.25 (strong).
    const float mgeFogFloor = 0.04;
    fog = mix(fog, max(fog, mgeFogFloor), wDense);

    float fogdist = clamp(mgeInscatterDistScale * x, 0.0, 1.0);

    // Bad-weather base colour invariant: fog on geometry must be exactly
    // as solid as the general sky fog at that elevation, never more.
    // Implemented by converging to the sky's own colour at this direction
    // (the same raise-aware band blend mgeFogColourSky uses) instead of
    // XE's flat palette colour: at full saturation geometry equals the
    // sky behind it at any elevation, so a massif can never read more
    // fogged than its backdrop. At the horizon (h=0) this is
    // byte-identical to the classic (1-fog)*fogColour.
    // Convergence base: prefer the real rendered sky behind this pixel
    // (sky-blending RTT sample, passed in by fog.glsl; a=0 when absent or
    // in a reflection pass). The analytic dome proxy overshoots at steep
    // elevations: h -> 1 converges to the weather zenith palette (Foggy:
    // ~231,241,247) while the visible sky there is the darker cloud
    // layer, whitening tall silhouettes.
    float hSky = mgeSkyFogH(dirWorld.z);
    vec3 zenith = (mgeWeatherUniforms > 0.5) ? mgeSkyColor : gl_Fog.color.xyz;
    vec3 convBase = mix(gl_Fog.color.xyz, zenith, hSky);
    // The real-sky sample carries the cloud image; at partial fog on near
    // geometry it would paint a screen-fixed cloud pattern onto walls.
    // The sky image belongs in the convergence only when the fragment is
    // nearly saturated (a silhouette against the sky), so it is weighted
    // in by saturation: light haze converges to the flat colour
    // (pattern-free), full fog to the exact sky pixel.
    if (skyBehind.a > 0.5)
        convBase = mix(convBase, skyBehind.rgb, smoothstep(0.55, 0.92, 1.0 - fog));
    vec3 rgb = (1.0 - fog) * convBase;

    float nice = mgeGetNiceWeather();
    if (nice > 0.001)
        rgb = mix(rgb, mgeScatter(dirWorld, fogdist, skyCol), nice);

    // Horizon seal: with the 2020-era fog scale the inscatter distance
    // caps at 0.224*4 = 0.896 at the view edge, so the farthest water/land
    // only reaches ~97% of the sky dome's colour, leaving a dark line
    // where the sea meets the sky. Blend the final stretch of the view
    // distance to the analytic dome colour for this direction (scatter at
    // fogdist=1, or palette fog in bad weather), which is the colour the
    // sky shows behind the far plane by construction.
    float seal = smoothstep(0.88, 0.995, dist / far);
    if (seal > 0.001)
    {
        vec3 domeBad = convBase;
        vec3 domeCol = mix(domeBad,
            (nice > 0.001) ? mgeScatter(dirWorld, 1.0, skyCol) : domeBad, nice);
        rgb = mix(rgb, domeCol, seal);
        fog *= 1.0 - seal;
    }

    return vec4(rgb, fog);
}

// Back-compat 4-arg form: land/object semantics (near-linear active).
vec4 mgeFogColourWorld(float dist, vec3 dirWorld, float far, vec3 skyCol, bool useNearLinear)
{
    return mgeFogColourWorld(dist, dirWorld, far, skyCol, useNearLinear, vec4(0.0));
}

vec4 mgeFogColourWorld(float dist, vec3 dirWorld, float far, vec3 skyCol)
{
    return mgeFogColourWorld(dist, dirWorld, far, skyCol, true, vec4(0.0));
}

// View-space convenience wrapper (objects/terrain path).
vec4 mgeFogColour(vec3 viewPos, float far, vec3 skyCol, vec4 skyBehind)
{
    vec3 dir = normalize((osg_ViewMatrixInverse * vec4(normalize(viewPos), 0.0)).xyz);
    return mgeFogColourWorld(length(viewPos), dir, far, skyCol, true, skyBehind);
}

vec4 mgeFogColour(vec3 viewPos, float far, vec3 skyCol)
{
    return mgeFogColour(viewPos, far, skyCol, vec4(0.0));
}

// Sky-dome variant (XE Common.fx fogColourSky): fogdist=1, fog=0, base =
// horizon blend from fog colour up to the weather zenith colour.
vec3 mgeFogColourSky(vec3 dirWorld, vec3 zenithCol, vec3 skyCol)
{
    float h = mgeSkyFogH(dirWorld.z);
    vec3 base = mix(gl_Fog.color.xyz, zenithCol, h);
    float nice = mgeGetNiceWeather();
    // Fog-disabled cameras (the underwater refraction RTT, local map,
    // previews) render the above-water world by definition, so they always
    // paint the above-water sky. Without this, a submerged viewer's
    // refraction RTT skips the scatter and blends its horizon toward the
    // global gl_Fog.color (the underwater murk), drawing a dark band
    // across the above-water sky seen through the surface.
    if (nice > 0.001 && (mgeCamAboveWater() || gl_Fog.start > 1000000.0))
        return mix(base, mgeScatter(dirWorld, 1.0, skyCol), nice);
    return base;
}

// Ordered 4x4 dither from XE Mod Sky.fx SkyPS; removes sky gradient banding.
float mgeSkyDither(vec2 fragCoord)
{
    const float d[16] = float[16](
         0.001176,  0.001961, -0.001176, -0.001699,
        -0.000654, -0.000915,  0.000392,  0.000131,
        -0.000131, -0.001961,  0.000654,  0.000915,
         0.001699,  0.001438, -0.000392, -0.001438);
    int i = int(mod(fragCoord.x, 4.0)) * 4 + int(mod(fragCoord.y, 4.0));
    return d[i];
}
#endif
