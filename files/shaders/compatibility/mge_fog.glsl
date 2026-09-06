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

// Stock root uniform, fed per frame by the engine (groundcover wind uses
// it). Here it is the height-fog baseline; see MGE_HEIGHT_FOG_PLAYER_BASELINE.
uniform vec3 playerPos;

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

// Weather-transition endpoints (patched engine): Cur = (ff, fo, valid, 0),
// Next = (ff, fo, blend, 0). Consumed by mgeDerivedFog (derivation policy
// commented there) and by the corridor-scoped search unlock in
uniform vec4 mgeFogParamsCur;
uniform vec4 mgeFogParamsNext;

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

// here (all units, the consumers are reader-flavor fragments); the
// omwfx passes do not consume either feature (their paint terms are
// deltas, base-independent).
// MGE_CORRIDOR_REVEAL, in a nice<->storm transition the composition
//   reveals the storm endpoint's palette fog instead of the blend. The
//   blend carries the nice endpoint's palette (Clear fog 48,97,141,
//   far bluer than anything its own steady state shows, since steady
//   nice weather hides the palette behind full scatter), and nice²
//   decays faster than the linear palette lerp, so mid-corridor the
//   hidden blue surfaced at up to ~50% weight, the "intense blueing
//   that reflects neither endpoint" (model and measured hump match).
//   Race verdict: sim_corridor_fix_race.py, excursion
//   0.052-0.107 (shipped) -> <=0.006 on every corridor in both scatter
//   states, endpoints bit-exact, ash-glow metric 0. Also unlocks the
//   lite search on Full during transitions only (the engine uniforms
//   carry only blended colours; see mgeWxCompute).
// MGE_WXT_NICE_GATE, the 101/102 scatter suppression and the fog.glsl
//   sky-blend fade are gated off when both endpoints are nice weathers:
//   their storm-glow justification cannot apply there, and on RP the
//   suppression itself injected the palette blue mid-corridor
//   (Cloudy->Clear; the Full sighting is the separate cloud-layer
//   case).
// MGE_FULL_LUM_CLAMP, the transition brightness clamp (the invariant:
//   distant terrain must never read brighter than the sky) runs on the
//   Full tier too, corridor-scoped. It was stock-only because Full had
//   no decomposition at all when it shipped; the corridor unlock above
//   now provides (i,j,conf) mid-transition, and a weather ladder showed
//   the unclamped Full glow directly: Cloudy->Ashstorm far band up to
//   +0.070 lum above the measured sky, Clear<->Blizzard +0.027
//   (pre-existing; the old build measured +0.054 at the same alphas).
//   Race verdict: sim_corridor_lum.py, Ash +0.058 -> +0.013 modelled,
//   steady states and off-corridor bit-exact (conf 0), scatter
//   suppression untouched
//   (still stock-only). Frame-anchored model validated on 54 frames.
#ifndef MGE_CORRIDOR_REVEAL
#define MGE_CORRIDOR_REVEAL 1
#endif
#ifndef MGE_WXT_NICE_GATE
#define MGE_WXT_NICE_GATE 1
#endif
#ifndef MGE_FULL_LUM_CLAMP
#define MGE_FULL_LUM_CLAMP 1
#endif
// MGE_WXT_SKY_HUE, corridor hue convergence, the chroma sibling of the
//   brightness clamp (on the clamped build the Ash-corridor ridges read
//   blueish/purplish against the reddening ash sky: measured
//   +0.055..+0.067 B-R above the sky at silhouette elevation through
//   f 0.08-0.6; present pre-clamp too, hidden under the brightness
//   glare). Mechanism: the wall's
//   scatter/fog terms are cloud-blind in hue exactly as they were in
//   luminance, the ash cloud sheet reddens the real sky, the analytic
//   terms do not follow. Fix: after the luminance clamp, the fog term's
//   hue converges to the measured sky behind (row-accurate RTT sample),
//   luminance-preserving, at the same wxTc weight. Frame-applied race
//   (exact pixel transform on the measured frames, no geometry model):
//   k=1.0 collapses the mid-band to <=+0.007 on Ash and zeroes the
//   Clear<->Blizzard warm side, strict contraction on every frame
//   (sim_corridor_lum.py). Steady bit-exact (weight 0); skipped where
//   the RTT is absent (reflections/refraction), a palette target would
//   re-introduce palette hue, the exact thing being corrected.
//   only on silhouette-class content, zero on thin near haze (which
//   keeps the reveal's storm hue), see the block comment at the site.
#ifndef MGE_WXT_SKY_HUE
#define MGE_WXT_SKY_HUE 1
#endif
// MGE_SKYCOL_CORRIDOR_UNIFY, corridor unification of the stock skyCol
//   mix(gl_Fog.color, est, nice) slides the wall's scatter/zenith input
//   toward the fog colour as nice falls, invisible at every steady
//   state (weight 1 on nice ends, consumer dead at nice 0 on storm
//   ends), but mid nice->storm corridor it diverges from Full's engine
//   sky. Where the departing fog is blue (Clear->Ashstorm) the stock
//   wall runs measurably bluer than the sky it stands against (the
//   reported pale-blue left mass), matched-pair-verified RP-only (the
//   right-bank luminance excess measured identical on both tiers and
//   is not the artifact). With this on,
//   the mix weight rides to 1 at conf * min(1, 4*4a(1-a)) (the hue
//   family's ramp, nice<->nice gated), so corridor skyCol = the
//   decomposed palette-sky blend = Full's input by construction.
//   Steady bit-exact (weight collapses to the nice mix at wxt 0).
#ifndef MGE_SKYCOL_CORRIDOR_UNIFY
#define MGE_SKYCOL_CORRIDOR_UNIFY 1
#endif

// Reflected-sky scatter in mirrored stock passes (queued alleviation,
// losses item 8). 0 = the palette-base fallback (safe, current look);
// 1 = let the reflected sky run the scatter with the mirror-corrected
// sun (the same resolver that fixed reflected-terrain scatter). Flip for
// one A/B; if the black/faint reflected-sky family returns, the
// reflection RTT's sky program has no usable light 0 - flip back.
#define MGE_STOCK_MIRRORED_SKY_SCATTER 1

// Height baseline. 1 = fragment world height minus the player's height,
// both absolute, so every pass measures the same fog layer (the water
// reflection's mirrored camera included; fragment world positions are
// real in that pass, only the camera is mirrored). 0 = the old camera-ray
// form, which measured from whichever camera renders the pass. The SSAO
// and bloom mirrors already compute fragment height minus the main eye,
// so 1 also matches them (feet-vs-eye offset ~120u, negligible at H=4608).
#define MGE_HEIGHT_FOG_PLAYER_BASELINE 1

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

// The est model below (segment classifier, nice heuristic, stock ladder,
// calm-hold, endpoint decomposition) consumes only frame/draw-constant
// its fragment-program compile footprint at >= 17.9 fps of the dusk gap
// (register pressure, non-additive: only full removal un-spills). So it
// compiles per stage:
//   MGE_WX_STAGE 1 (default): this compilation unit computes the model
//     (pre-hoist behaviour; the oracle's extracted compiles use this).
//     Consumer .vert files use it and emit the verdict via
//     mgeWxEmitVaryings() at the end of main().
//   MGE_WX_STAGE 0 (each consumer .frag defines it before its fog
//     include): the model is not compiled; mgeWxCompute() is a no-op and
//     every frame-constant reader returns the varyings from the paired
//     vertex stage. Do not reintroduce model calls into fragment code -
//     one call chain gives the footprint back (the 146/167 class).
// where changes, what does not: values are identical (same expressions,
// same per-pass uniforms, computed per-vertex; equal per-vertex values
// interpolate exactly within ulp, and the one discrete value i/j is
// packed as i*10+j and round-decoded, exact for all 0..99).
#ifndef MGE_WX_STAGE
#define MGE_WX_STAGE 1
#endif
// The verdict varyings (written by mgeWxEmitVaryings in the vertex stage,
// read by the MGE_WX_STAGE 0 readers; inert in compute-mode fragments).
varying vec4 mgeWxVSky;   // xyz mgeSampleSkyCol(), w mgeGetNiceWeather()
varying vec4 mgeWxVFog;   // mgeGetFogParams(): ff, fo, isExterior, isDay
varying vec4 mgeWxVIdx;   // x conf, y alpha, z hour, w i*10+j
varying vec4 mgeWxVDec;   // xyz decomposed skyBlend, w niceBlend
varying vec4 mgeWxVEnv;   // xy fffoA, zw fffoB (mgeDecomposeWeather)
varying vec4 mgeWxVRev;   // xyz corridor-reveal fog base, w nice-nice wxt gate (198)
varying vec4 mgeWxVScatO; // xyz recovered outscatter, w recovery weight (225)
varying vec4 mgeWxVScatI; // xyz recovered inscatter, w unused

#if MGE_WX_STAGE
// ==== MGG phase-segment sky classifier (stock exes) ====
// phase-invariant only while the palette keeps sky proportional to fog
// across the day; the MGG palette inverts at dawn/dusk (day fog darker
// than its sky, phase fogs bright salmon), so day-derived ratios painted
// sunrise/sunset scatter pink on stock. Instead, locate gl_Fog.color on
// the engine's own piecewise-linear fog path (weather.cpp time-of-day
// interpolation: day<->sunrise / day<->sunset per nice weather, plus the
// day<->day chord of a Clear<->Cloudy weather transition) and lerp the
// matching sky anchors with the same parameter - exact wherever the
// engine itself lerps. Returns xyz = sky estimate, w = confidence
// (1 on-path, 0 beyond ~20/255 residual). Anchors = the MGG fallback
// block in the live MO2 profile openmw.cfg. On a vanilla-palette install
// nothing lands on these segments (w=0) and callers fall through to the
// classic vanilla ratio table. Morning vs evening picked by sun azimuth
// (Morrowind sun rises east = world +x); the mirror z-flip never touches
// x, so no mirrored-pass special case is needed.
void mgeMggSegmentSky(out vec3 skyEst, out float wEst, out float wGate)
{
    // MGG anchors /255: Clear fog day/phase, sky day/sunrise/sunset;
    // Cloudy likewise (sunrise and sunset fogs differ for Cloudy).
    const vec3 cFD = vec3(0.18824, 0.38039, 0.55294);
    const vec3 cFP = vec3(1.00000, 0.74118, 0.61569); // sunrise==sunset fog
    const vec3 cSD = vec3(0.52549, 0.52941, 0.53725);
    const vec3 cSSR = vec3(0.51765, 0.54510, 0.57647);
    const vec3 cSSS = vec3(0.32941, 0.34118, 0.36863);
    const vec3 kFD = vec3(0.78431, 0.76863, 0.73333);
    const vec3 kFSR = vec3(1.00000, 0.81176, 0.58431);
    const vec3 kFSS = vec3(1.00000, 0.60784, 0.41569);
    const vec3 kSD = vec3(0.58039, 0.61961, 0.68627);
    const vec3 kSSR = vec3(0.56863, 0.60784, 0.62745);
    const vec3 kSSS = vec3(0.43529, 0.44706, 0.62353);

    vec3 fc = gl_Fog.color.xyz;
    vec3 sunW = mgeSunDir;
    if (dot(sunW, sunW) < 1e-4)
    {
        vec3 lp = lcalcPosition(0);
        sunW = (dot(lp, lp) > 1e-6)
            ? (osg_ViewMatrixInverse * vec4(normalize(lp), 0.0)).xyz
            : vec3(0.0, 0.0, 1.0);
    }
    bool morning = sunW.x >= 0.0;

    vec3 fA[3]; vec3 fB[3]; vec3 sA[3]; vec3 sB[3];
    fA[0] = cFD; fB[0] = cFP;              sA[0] = cSD; sB[0] = morning ? cSSR : cSSS;
    fA[1] = kFD; fB[1] = morning ? kFSR : kFSS; sA[1] = kSD; sB[1] = morning ? kSSR : kSSS;
    fA[2] = cFD; fB[2] = kFD;              sA[2] = cSD; sB[2] = kSD; // weather-transition chord

    float bestRes = 1e9;
    float phaseRes = 1e9;
    vec3 bestSky = fc;
    for (int i = 0; i < 3; ++i)
    {
        vec3 d = fB[i] - fA[i];
        float t = clamp(dot(fc - fA[i], d) / max(dot(d, d), 1e-9), 0.0, 1.0);
        float res = length(fc - (fA[i] + t * d));
        if (res < bestRes)
        {
            bestRes = res;
            bestSky = sA[i] + t * (sB[i] - sA[i]);
        }
        if (i < 2 && res < phaseRes)
            phaseRes = res; // confidence from the phase segments only
    }
    // Two confidences. wEst (all three segments) drives the sky-estimate
    // mix - the transition chord may supply the estimate (it is exact
    // during Clear<->Cloudy day transitions). wGate (phase segments only)
    // drives the nice-weather gate - the chord runs 5.4/255 from
    // Overcast's day fog (in depth range 0.70) and must never re-light
    // scatter in Overcast; genuine day transitions keep nice = 1 via the
    // sun gate instead (both day suns are bright), and a dusk-time
    // weather transition briefly dips nice - the engine's own transition
    // blend dips it too. Full confidence below 10/255 residual, zero
    // above 20/255 (nearest phase-segment collider: Overcast at 25.6).
    skyEst = bestSky;
    wEst = 1.0 - smoothstep(0.0392, 0.0784, bestRes);
    wGate = 1.0 - smoothstep(0.0392, 0.0784, phaseRes);
}
#endif // MGE_WX_STAGE (segment classifier)

// Pair-decomposition master switch. The machinery lives in the block after
// mgeStockWeatherFF; the define sits here because consumers above that block
// (mgeGetNiceWeather) reference it and the preprocessor reads linearly.
// 0 = every consumer reverts to its pre-decomposition path (weak-GPU / A/B /
// the FPS-bisect C1 cluster): conf-0 stubs for the public entry points,
// day-arm split ladder (no sun-hour recovery), no calm-hold. Repaired
// post-127 rounds); rot-gated by check_glsl_decomposer section [5].
#define MGE_ENDPOINT_DECOMPOSITION 1

#if MGE_ENDPOINT_DECOMPOSITION && MGE_WX_STAGE
// Forward declaration: defined with the endpoint-decomposition block below
// (the tables it needs sit next to the other palette anchors). Returns conf;
// outputs the decomposed blended sky colour and nice weight.
float mgeDecomposeSkyNice(out vec3 skyBlend, out float niceBlend);
// 0 = pre-v2 est/nice behaviour (the est degenerates to the fog colour
// at conf 0 - the 1720 brighter-than-sky band returns). Live A/B unit;
// the est-model mirrors in MGE_SkyEst_Correct/Debug.omwfx carry the
// same define and must flip together (est-model rule).
#define MGE_CALM_HOLD_V2 1
// The hold weight + calm sky for the current fragment's fog state, shared
// by the est and nice consumers. Returns w = calm * (1 - confDec); 0
// wherever the state is not calm-family, the fog range is invalid
// (sentinel/interior lighting), the sun is unusable, or the decomposition
// is confident.
// anchor machinery ran at four textual sites per vertex unit
// (mgeGetFogParams + mgeSampleSkyCol + mgeGetNiceWeather x2) on identical
// draw-constant inputs - memoization capped the runtime
// cost but every call site still inlined the full 2x10 anchor search, and
// that compiled body owned the calm-hold half of
// occupancy cliff (~6.3 fps at the 4K village view). The machinery now
// runs once, in wxHoldFill() inside mgeWxCompute(); this is a trivial
// reader of the wxG_hold* globals (declared with the other wxG_ verdict
// globals - definition sits after the search core, the preprocessor
// reads linearly). Consumer shaders that never call mgeWxCompute() read
// hold 0 and compose the documented pre-hold fallback - the same
// fail-safe contract as the wxG_ verdict globals.
float mgeCalmHoldV2(float confDec, out vec3 calmSky);
#endif

#if MGE_WX_STAGE
float mgeGetNiceWeather()
{
    if (mgeWeatherUniforms > 0.5)
        return mgeNiceWeather; // live from the engine weather system

    // Fallback heuristic (stock exe only). MGE: nice = 1 for Clear/Cloudy.
    // Vanilla-palette signals: Clear fog is bright and blue-tinted
    // (206,227,255); bad-weather fogs are grey/warm and darker. Cloudy fog
    // is warm-white, caught by the sun-luminance gate instead.
    vec3 fc = gl_Fog.color.xyz;
    float lum = dot(fc, vec3(0.299, 0.587, 0.114));
    float blueGate = clamp(8.0 * (fc.b - fc.r), 0.0, 1.0)
                   * clamp(4.0 * (lum - 0.6), 0.0, 1.0);
    float sunLum = dot(lcalcDiffuse(0), vec3(0.299, 0.587, 0.114));
    float sunGate = clamp((sunLum - 0.65) * 4.0, 0.0, 1.0);
    // weathers false-fire the colour/sun heuristics: Foggy's bright blue
    // fog trips blueGate (~0.43), and a bright sun on Snow/Ashstorm trips
    // sunGate - so both must be vetoed, not just blueGate. The depth
    // signal (Clear 0.69 / Cloudy 0.72 in [0.63, 0.76]; every dense
    // weather outside it - Rain 0.8, Foggy/Snow/Thunder 1.0+, Blizzard
    // 2.8) is the reliable dense discriminator; segGate already carries
    // it. Un-vetoed dense nice added scatter that (a) blue-washed far
    // terrain with the fixed mgeSkyBase and (b) made geometry (est
    // skyCol) and the dome (emission skyCol) add different scatter, so
    // terrain popped as bluer/sharper silhouettes vs Full; with nice = 0
    // both reduce to mix(gl_Fog.color, sky, h) and the RP dome becomes
    // byte-identical to Full's (workflow trace + adversarial verify,
    // nice 0, harmless (interior geometry takes the linear branch, no
    // scatter). Full path untouched (early return above). A residual
    // remains only on tall summits (geometry zenith stays fog-colour
    // while the dome lifts to the true bright zenith) - deferred; the
    // post-pass zenith-lift for it was adversarially rejected (overshoot
    // / height-fog desync / double-count with the sky-blend).
    // fog-off sentinel passes (a submerged viewer's refraction RTT, local
    // map, previews): gl_Fog carries ranges of 1e7 and the constructor
    // default black colour, so the depth co-gate below is structurally 0 and
    // the blue gate reads black fog - which made this function return
    // exactly 0 in every sentinel pass. That silently killed both sentinel
    // consumers for months: the from-below refraction haze
    // scatter (mgeFogColourSky:985) - the reported "black sky, terrain entirely
    // unfogged" seen through the surface while emerging. The regression came
    // fog ranges, and no one provoked the sentinel consumers afterwards
    // here - lcalcDiffuse binds in every pass - so it stands alone, exactly
    // the pre-44 behaviour for this pass. Live palette lumas at midday:
    // Clear 0.96 / Cloudy 0.94 (full haze), Overcast 0.66 (trace),
    // Rain 0.61 / Thunder 0.56 / Foggy 0.50 (none - the documented
    // conservative under-fog; dense-weather detection is impossible with no
    // fog signal). Night dies via the dim sun and the scatter's own sun
    // altitude terms.
    //
    // ...with one veto the bare sun gate needs. Entry 44 documented "a
    // bright sun on Snow/Ashstorm trips sunGate" - and Ashstorm's sun
    // (228,139,114, luma 0.638) hovers exactly at the 0.65 threshold, so the
    // live sun tipped it over and the sentinel refraction pass blended the
    // scatter - built on the blue-ish MGG anchor - over an ash-red sky:
    // the magenta-pink dome seen through the surface in an ashstorm. The
    // depth veto that fixes this in normal passes cannot exist here, but sun
    // chroma can: ash/blight suns are strongly red ((r-b)/lum = +0.70/+0.59)
    // while every other weather's sun is neutral-to-blue (Clear +0.16,
    // Cloudy +0.14, the rest negative). Smoothstepped between 0.30 and 0.50,
    // so the veto is total for ash/blight, nil for Clear/Cloudy, and mostly
    // vetoes the reddened Clear sunset sun - conservative under-fog again,
    // never a wrong hue.
    if (gl_Fog.start > 1000000.0)
    {
        vec3 sunC = lcalcDiffuse(0);
        float sunRedness = (sunC.r - sunC.b) / max(sunLum, 0.001);
        return sunGate * (1.0 - smoothstep(0.30, 0.50, sunRedness));
    }

    float depthGate = 0.0;
    float segGate = 0.0;
    float niceHeur;
    if (gl_Fog.end > 1.0 && gl_Fog.end < 1000000.0)
    {
        float d = 1.0 - gl_Fog.start / gl_Fog.end;
        // 86/87). The tight edge was tuned against steady dense weathers, but a
        // weather transition traverses it: blended d walks Clear .69 -> storm
        // 1.1+ and crossed the whole 0.76-0.80 band in ~3 s of a 28.6 s
        // transition, flipping the scatter treatment on distant land in one
        // visible step (probe ladder, screenshots 1203-1204). At the new edge
        // every steady dense weather is still fully vetoed by depth where it
        // must be - Foggy/Snow/Thunder 1.0+, Ash 1.1, Blight 1.2, Blizzard 2.8
        // all sit at d >= 1.0 - while the two sub-1.0 dense weathers die by
        //   Rain (.80): fog (104,122,131) lum 0.462 < 0.6 zeroes blueGate;
        //               sun luma 0.61 < 0.65 zeroes sunGate.
        //   Overcast (.70): inside the old window anyway - trace unchanged.
        // No steady weather occupies (0.80, 1.00). Transitions now fade the
        // scatter over the blue/sun colour ramps (~8-11 s measured for
        // clear->ash / cloudy->storm) instead of snapping on the depth edge.
        depthGate = smoothstep(0.60, 0.63, d) * (1.0 - smoothstep(0.85, 1.00, d));
        vec3 segSky; float segWEst; float segWGate;
        mgeMggSegmentSky(segSky, segWEst, segWGate);
        segGate = segWGate * depthGate;
    }
    niceHeur = max(max(blueGate, sunGate) * depthGate, segGate);

#if MGE_ENDPOINT_DECOMPOSITION
    // Endpoint decomposition (block below): during a transition the gate
    // heuristics above read blended signals and produce the wrong trajectory
    // - the widened veto stretched the ramp but the weight still followed
    // gate geometry, holding blue-tinted scatter deep into a storm arrival
    // (the 1225-1239 terrain-vs-sky colour divergence). MGE's own nice is
    // a per-weather constant (1 for Clear/Cloudy, 0 otherwise) blended by
    // the transition factor - which is exactly what the decomposed endpoints
    // give. conf 0 (steady off-palette, sentinel, interior, flash) falls
    // back to the heuristic above.
    {
        vec3 skyDec;
        float niceDec;
        float conf = mgeDecomposeSkyNice(skyDec, niceDec);
        niceHeur = mix(niceHeur, niceDec, conf);
#if MGE_CALM_HOLD_V2
        // the calm family at conf 0, the true nice is ~1 (Clear/Cloudy)
        // but the heuristic above reads the blended signals, at dawn the
        // dim sun kills sunGate outright (nice 0 vs true 0.9+, scatter
        // snapping off at transition start and back ON at completion).
        // Hold nice toward the calm value 1.0. The weight rides a
        // smoothstep(0.6, 1.0) knee of the hold, not the raw hold: at
        // partial hold the est below is still partly the warm fog colour,
        // and raising the scatter weight against a warm est paints the
        // far band above the sky (measured: raw-w worst-vs-shipped
        // +0.0401, knee +0.0000 over the onset corridor; scratch
        vec3 calmSkyN;
        float wV2 = mgeCalmHoldV2(conf, calmSkyN);
        niceHeur = mix(niceHeur, 1.0, smoothstep(0.6, 1.0, wV2));
#endif
    }
#endif
    return niceHeur;
}

// ==== Stock-exe weather-envelope estimator (Redux Plus tier) ====
// Stock encodes the current weather's fog density in its own fog range
// (fogmanager.cpp: start = vd*(1 - depth), end = vd, lerped through
// weather transitions and day/night phases), so depth = 1 - start/end
// recovers it exactly (fp32 error ~5e-8 against 0.01 node spacing).
// Map that depth onto the MGE per-weather ff/fo tables via the known
// Morrowind.ini depth values; nodes shared by several weathers are
// resolved by fog colour; piecewise-linear between nodes keeps
// transitions smooth. Sim: sim_ff_estimator.py - every weather correct
// at day and night depths except night Ashstorm (fog colour
// indistinguishable from night Snow; it runs ff .5 instead of .2).
// Known tradeoff: stock has no interior signal, so interiors with
// authored fog density >= ~0.69 read as dense weather (the d-guard in
// mgeGetFogParams keeps lighter interiors on the Clear envelope).
//
// single ladder interleaved day node depths (F/T/S 1.00, A/B 1.10,
// Blizzard 2.80) with night ones (Thunder 1.15, the 1.20 three-way,
// Foggy 1.90, Blizzard 3.00) on one axis, so a dusk transition's d
// sweep walked calm/dense night nodes with day fog colours - the
// per-frame ff sawtooth on near terrain (139, the reported "jumps in
// lighting"). Day and night now carry their own ladders, mixed by the
// Fog tent's night weight recovered from the sun at the call site
// zigzag (total variation) -32%, worst 1-second step -18%, steady
// node accuracy unchanged. Known remains: the 0.69-0.72 calm cluster
// dip at transition onset (follow-up; needs colour resolution or the
// steady resolver's rolled-gap fix, not more ladder).
vec2 mgeStockNodeFFDay(int i, vec3 fc)
{
    if (i == 0) return vec2(1.0, 0.0);   // .69 Clear
    if (i == 1) return vec2(0.7, 0.0);   // .70 Overcast
    if (i == 2) return vec2(0.9, 0.0);   // .72 Cloudy
    if (i == 3) return vec2(0.5, 0.1);   // .80 Rain
    if (i == 4)
    {
        // 1.00: Foggy (blue fog) / Snow (bright grey) / Thunder (dark).
        // b-r = 0.125, was passing by 0.5/255; Snow day b-r = 0.051) -
        if (fc.b - fc.r > 0.10) return vec2(0.2, 0.3);
        return (dot(fc, vec3(0.299, 0.587, 0.114)) > 0.5) ? vec2(0.5, 0.4) : vec2(0.5, 0.2);
    }
    if (i == 5) return (fc.g < 0.5 * fc.r) ? vec2(0.2, 0.6) : vec2(0.2, 0.5); // 1.10 Blight/Ash
    return vec2(0.16, 0.7);              // 2.80 Blizzard
}

vec2 mgeStockNodeFFNight(int i, vec3 fc)
{
    if (i == 0) return vec2(1.0, 0.0);   // .69 Clear
    if (i == 1) return vec2(0.7, 0.0);   // .70 Overcast
    if (i == 2) return vec2(0.9, 0.0);   // .72 Cloudy
    if (i == 3) return vec2(0.5, 0.1);   // .80 Rain
    if (i == 4) return vec2(0.5, 0.2);   // 1.15 Thunder (night)
    if (i == 5)
    {
        // 1.20 night: Blight (red) / Snow (brighter blue-grey) / Ash
        // (dark neutral grey). Was a 2-way that sent night Ash to the
        // Snow envelope (entry 18's known loss, present under MGG too);
        // the MGG night fogs split 3-ways by red-dominance + luminance
        // (Ash 0.082 vs Snow 0.136, threshold 0.11).
        if (fc.r > fc.b) return vec2(0.2, 0.55);
        return (dot(fc, vec3(0.299, 0.587, 0.114)) > 0.11) ? vec2(0.5, 0.4) : vec2(0.2, 0.55);
    }
    if (i == 6) return vec2(0.2, 0.3);   // 1.90 Foggy (night)
    return vec2(0.16, 0.7);              // 3.00 Blizzard (night)
}

vec2 mgeStockWeatherFF(float d, float wNight)
{
    const float ndD[7] = float[7](0.69, 0.70, 0.72, 0.80, 1.00, 1.10, 2.80);
    const float ndN[8] = float[8](0.69, 0.70, 0.72, 0.80, 1.15, 1.20, 1.90, 3.00);
    vec3 fc = gl_Fog.color.xyz;
    float dD = clamp(d, ndD[0], ndD[6]);
    vec2 day = mgeStockNodeFFDay(6, fc);
    for (int i = 0; i < 6; ++i)
    {
        if (dD <= ndD[i + 1])
        {
            float t = (dD - ndD[i]) / (ndD[i + 1] - ndD[i]);
            day = mix(mgeStockNodeFFDay(i, fc), mgeStockNodeFFDay(i + 1, fc), t);
            break;
        }
    }
    float dN = clamp(d, ndN[0], ndN[7]);
    vec2 night = mgeStockNodeFFNight(7, fc);
    for (int i = 0; i < 7; ++i)
    {
        if (dN <= ndN[i + 1])
        {
            float t = (dN - ndN[i]) / (ndN[i + 1] - ndN[i]);
            night = mix(mgeStockNodeFFNight(i, fc), mgeStockNodeFFNight(i + 1, fc), t);
            break;
        }
    }
    return mix(day, night, clamp(wNight, 0.0, 1.0));
}
#endif // MGE_WX_STAGE (nice heuristic + stock ladder)

// ==== Pair-decomposition endpoint estimator (stock tier) ====
// The node table above is exact at steady states but a weather transition
// interpolates fog colour and depth between two weathers, and mapping the
// blended depth through a steady-state table visits every weather in
// transit (non-monotonic), the dense knees compress into a ~5 s window,
// and the wave fo ladder crosses the calm weathers, switching the water
//
// The engine lerps fog colour and fog depth by the same factor
// (mwworld/weather.cpp:1391,1397), so the blend is a point on a straight
// segment between two palette entries in (colour, depth) space. For each
// candidate weather pair alpha is over-determined: solve it from depth,
// validate against the predicted colour, take the minimum-residual pair.
// Consumers then derive fog/waves AT the recovered endpoints and lerp the
// derived values, structurally the patched tier's endpoint-uniform design
// (mgeDerivedFog above, water.frag mgeWeatherWaveScale), reconstructed
// from stock signals.
//
// Simulated before implementation (simulations/sim_pair_decomposition.py,
// night has only an immaterial calm-family ambiguity
// (Clear/Cloudy/Overcast night fogs are near-identical by design); the
// cloudy->ash wave curve becomes monotone-smooth (max 1%-step 0.0077, no
// calm-floor dead zone); alien colours, lightning flashes (achromatic
// additive, weather.cpp:1288) and dawn/dusk phase blends all collapse
// confidence softly to 0, and every consumer composes as
// mix(today's path, decomposed, conf), so conf 0 is byte-identical to
// the pre-decomposition behaviour, never worse.
//
// The v1 Day/Night anchor race failed at dawn/dusk (the engine's
// time-of-day tent blends the Sunrise/Sunset palettes, in neither set ->
// conf 0 through prime-time transitions) and on XE Sky Variations days
// (the mod rewrites the Clear/Cloudy fogColor.sunrise/.sunset records
// daily). v2:
//   1. Recovers the game hour from the sun: the engine light/sun position
//      is (400*orbit, -75, 400-|400*orbit|) with orbit linear in hour
//      (weather.cpp:852-884, renderingmanager.cpp:673-696); y is fixed, so
//      orbit = -(x/y)*75/400 survives normalization, the z remap and both
//      `match sunlight to sun` settings. The scene light has no day/night
//      flag, so both branch hours race (they meet continuously at the
//      horizon hours 6/20 -- no seam). No sun signal -> pure hours 12/0
//      with the sun term off == exactly the v1 race (one code path).
//   2. Blends the 4-phase anchor tables with the exact engine tent
//      (TimeOfDayInterpolator, weather.cpp:65-134; depth sunrise/sunset
//      slots are the Day value, weather.cpp:167-170): dawn/dusk anchors
//      become exact instead of absent.
//   3. Adds the sun colour as a third observation: it lerps by the same
//      transition factor as fog colour/depth (weather.cpp:1391-1397),
//      reaches this shader unscaled as lcalcDiffuse(0) (weather.cpp:905),
//      and the variation mod never rewrites it -- it disambiguates pairs
//      the fog signals alone cannot (incl. same-depth ash/blight).
//   4. Models the XE Sky Variations roll family analytically: the roll
//      enters every blended anchor linearly with red pinned at 1.0, so
//      the mixed coefficient U reads off the red channel and G'/B' solve
//      and clamp to the authored box; the clamp distance is the residual
//      (plus a 1e-3 tie-hygiene penalty: the family interior yields exact
//      0.0 and would beat a true cfg fit's float epsilon in argmin).
// Sim: simulations/sim_pair_decomposition.py, all gates pass -- v1 gates
// preserved (the no-sun path is gated bit-identical to v1 over 990
// samples), dusk/dawn/varied sweeps 45k+ samples zero material
// misidentification, flash/alien/out-of-box negative controls collapse
// conf softly. Anchor data between the WX_TABLES markers is generated by
// scripts/gen_wx_tables.py from the live cfg layers -- never hand-edit.
//
// Cost: steady frames exit via the fast path of the first (day-branch)
// candidate at a single anchor set; transition frames run <= 2 x 45 pairs
// of a few ALU, all operands uniform per draw, branches fully coherent.
// The gate (#define MGE_ENDPOINT_DECOMPOSITION) sits above
// mgeGetNiceWeather, which consumes this block from earlier in the file.

#if MGE_ENDPOINT_DECOMPOSITION && MGE_WX_STAGE
// WX_TABLES_BEGIN (generated by scripts/gen_wx_tables.py -- do not hand-edit; regenerate instead)
// 4-phase anchors [i*4 + phase], phase: 0 Sunrise, 1 Day,
// 2 Sunset, 3 Night. Engine registration order: Clear,
// Cloudy, Foggy, Overcast, Rain, Thunderstorm, Ashstorm,
// Blight, Snow, Blizzard.
const vec3 wxFogPh[40] = vec3[40](
    vec3(1.00000, 0.74118, 0.61569), vec3(0.18824, 0.38039, 0.55294), vec3(1.00000, 0.74118, 0.61569), vec3(0.03529, 0.03922, 0.04314), // Clear
    vec3(1.00000, 0.81176, 0.58431), vec3(0.78431, 0.76863, 0.73333), vec3(1.00000, 0.60784, 0.41569), vec3(0.03529, 0.03922, 0.04314), // Cloudy
    vec3(0.67843, 0.64314, 0.58039), vec3(0.64706, 0.72549, 0.77255), vec3(0.44314, 0.52941, 0.61569), vec3(0.08627, 0.09412, 0.09804), // Foggy
    vec3(0.37255, 0.38431, 0.39608), vec3(0.60784, 0.65490, 0.70196), vec3(0.42353, 0.45098, 0.47451), vec3(0.07451, 0.08627, 0.09804), // Overcast
    vec3(0.27843, 0.29020, 0.29412), vec3(0.40784, 0.47843, 0.51373), vec3(0.28627, 0.28627, 0.28627), vec3(0.09412, 0.09804, 0.10196), // Rain
    vec3(0.28235, 0.29020, 0.31765), vec3(0.37647, 0.40392, 0.41569), vec3(0.27451, 0.29020, 0.33333), vec3(0.07451, 0.07843, 0.08627), // Thunderstorm
    vec3(0.35686, 0.21961, 0.20000), vec3(0.48627, 0.28627, 0.22745), vec3(0.41569, 0.21569, 0.15686), vec3(0.07843, 0.08235, 0.08627), // Ashstorm
    vec3(0.35294, 0.13725, 0.13725), vec3(0.43137, 0.16471, 0.13333), vec3(0.36078, 0.12941, 0.12941), vec3(0.17255, 0.05490, 0.05490), // Blight
    vec3(0.41569, 0.35686, 0.35686), vec3(0.60000, 0.61961, 0.65098), vec3(0.37647, 0.45098, 0.52549), vec3(0.12157, 0.13725, 0.15294), // Snow
    vec3(0.35686, 0.38824, 0.41569), vec3(0.49804, 0.51765, 0.53725), vec3(0.42353, 0.45098, 0.47451), vec3(0.08235, 0.09412, 0.10980)); // Blizzard
const vec2 wxDepthDN[10] = vec2[10]( // x Day, y Night; sunrise/sunset slots are Day (weather.cpp:167-170)
    vec2(0.69, 0.69), // Clear
    vec2(0.72, 0.72), // Cloudy
    vec2(1.00, 1.90), // Foggy
    vec2(0.70, 0.70), // Overcast
    vec2(0.80, 0.80), // Rain
    vec2(1.00, 1.15), // Thunderstorm
    vec2(1.10, 1.20), // Ashstorm
    vec2(1.10, 1.20), // Blight
    vec2(1.00, 1.20), // Snow
    vec2(2.80, 3.00)); // Blizzard
const vec3 wxSkyPh[40] = vec3[40](
    vec3(0.51765, 0.54510, 0.57647), vec3(0.52549, 0.52941, 0.53725), vec3(0.32941, 0.34118, 0.36863), vec3(0.03529, 0.03922, 0.04314), // Clear
    vec3(0.56863, 0.60784, 0.62745), vec3(0.58039, 0.61961, 0.68627), vec3(0.43529, 0.44706, 0.62353), vec3(0.03529, 0.03922, 0.04314), // Cloudy
    vec3(0.77255, 0.74510, 0.70588), vec3(0.90588, 0.94510, 0.96863), vec3(0.55686, 0.62353, 0.69020), vec3(0.07059, 0.09020, 0.10980), // Foggy
    vec3(0.38039, 0.38431, 0.38824), vec3(0.56078, 0.57255, 0.58431), vec3(0.42353, 0.45098, 0.47451), vec3(0.07451, 0.08627, 0.09804), // Overcast
    vec3(0.27843, 0.29020, 0.29412), vec3(0.45490, 0.47059, 0.47843), vec3(0.28627, 0.28627, 0.28627), vec3(0.07059, 0.07451, 0.07843), // Rain
    vec3(0.14118, 0.14118, 0.14510), vec3(0.39216, 0.40784, 0.42745), vec3(0.13725, 0.14118, 0.15294), vec3(0.07451, 0.07843, 0.08627), // Thunderstorm
    vec3(0.35686, 0.21961, 0.20000), vec3(0.48627, 0.28627, 0.22745), vec3(0.41569, 0.21569, 0.15686), vec3(0.07843, 0.08235, 0.08627), // Ashstorm
    vec3(0.35294, 0.13725, 0.13725), vec3(0.34118, 0.14510, 0.14510), vec3(0.36078, 0.12941, 0.12941), vec3(0.17255, 0.05490, 0.05490), // Blight
    vec3(0.41569, 0.35686, 0.35686), vec3(0.60000, 0.61961, 0.65098), vec3(0.37647, 0.45098, 0.52549), vec3(0.12157, 0.13725, 0.15294), // Snow
    vec3(0.35686, 0.38824, 0.41569), vec3(0.49412, 0.51765, 0.54510), vec3(0.42353, 0.45098, 0.47451), vec3(0.10588, 0.11373, 0.12157)); // Blizzard
// Sun colour: the decomposer's third observation. Lerps by
// the same transition factor as fog colour/depth
// (weather.cpp:1391-1397); XE Sky Variations never touches it.
const vec3 wxSunPh[40] = vec3[40](
    vec3(0.94902, 0.62353, 0.46667), vec3(1.00000, 0.95686, 0.84706), vec3(1.00000, 0.44706, 0.30980), vec3(0.22353, 0.25098, 0.36471), // Clear
    vec3(0.94510, 0.69412, 0.38824), vec3(1.00000, 0.92549, 0.86667), vec3(1.00000, 0.34902, 0.00000), vec3(0.10196, 0.11373, 0.14510), // Cloudy
    vec3(0.69412, 0.63529, 0.53725), vec3(0.43529, 0.51373, 0.59216), vec3(0.49020, 0.61569, 0.74118), vec3(0.11765, 0.12941, 0.14118), // Foggy
    vec3(0.34118, 0.49020, 0.63922), vec3(0.63922, 0.66275, 0.71765), vec3(0.33333, 0.40392, 0.61569), vec3(0.00392, 0.01176, 0.04314), // Overcast
    vec3(0.51373, 0.47843, 0.47059), vec3(0.58431, 0.61569, 0.66667), vec3(0.47059, 0.49412, 0.51373), vec3(0.03529, 0.03529, 0.03922), // Rain
    vec3(0.38431, 0.38824, 0.41176), vec3(0.54118, 0.56471, 0.60784), vec3(0.37647, 0.39608, 0.45882), vec3(0.05882, 0.07451, 0.10196), // Thunderstorm
    vec3(0.72157, 0.35686, 0.27843), vec3(0.89412, 0.54510, 0.44706), vec3(0.72549, 0.33725, 0.22353), vec3(0.21176, 0.25882, 0.29020), // Ashstorm
    vec3(0.70588, 0.30588, 0.30588), vec3(0.72549, 0.43922, 0.41569), vec3(0.70588, 0.30588, 0.30588), vec3(0.23922, 0.35686, 0.56078), // Blight
    vec3(0.55294, 0.42745, 0.42745), vec3(0.63922, 0.66275, 0.71765), vec3(0.39608, 0.47451, 0.55294), vec3(0.21569, 0.25882, 0.30196), // Snow
    vec3(0.44706, 0.50196, 0.57255), vec3(0.63922, 0.66275, 0.71765), vec3(0.41569, 0.44706, 0.53333), vec3(0.22353, 0.25882, 0.29020)); // Blizzard
const float wxNightEnd = 6.00;   // Weather_Sunrise_Time
const float wxDayStart = 8.00;   // + Sunrise_Duration
const float wxDayEnd = 18.00;     // Weather_Sunset_Time
const float wxNightStart = 20.00; // + Sunset_Duration
const vec4 wxWinFog = vec4(0.50, 1.00, 2.00, 1.00); // Fog pre-sr, post-sr, pre-ss, post-ss
const vec4 wxWinSky = vec4(0.50, 1.00, 1.50, 0.50); // Sky pre-sr, post-sr, pre-ss, post-ss
const vec4 wxWinSun = vec4(0.00, 0.00, 1.00, 1.25); // Sun pre-sr, post-sr, pre-ss, post-ss
// MGE distantland.cpp adjustFog: niceWeather = 1 for
// Clear/Cloudy, 0 else (constant, not cfg -- emitted here
// so all three replicas share one source).
const float wxNice[10] = float[10](
    1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
// XE Sky Variations daily-roll family (mod main.lua):
// roll = (1, G', B'); hazy branch G'=(229-0.9G)/255,
// B'=(197-0.6B)/255, dice 0..99; clear branch = the
// constant point (inside the box) with Cloudy sunset gain
// g = 0.4+0.006*Clarity, branch-coupled at Clarity 70.
const vec4 wxVarBox = vec4(0.54863, 0.89804, 0.53961, 0.77255); // G' lo/hi, B' lo/hi
const vec2 wxVarClearPt = vec2(0.75686, 0.69412);
const vec2 wxVarGainHazy = vec2(0.40000, 0.81400);
const vec2 wxVarGainClear = vec2(0.82000, 0.99400);
// WX_TABLES_END

// Per-weather MGE envelope (ff, fo), same order. These are the values the
// node table encodes at its steady points; the wave table stays in
// water.frag and is evaluated there at the recovered endpoints.
const vec2 mgeWxFFFO[10] = vec2[10](
    vec2(1.00, 0.0),   // Clear
    vec2(0.90, 0.0),   // Cloudy
    vec2(0.20, 0.3),   // Foggy
    vec2(0.70, 0.0),   // Overcast
    vec2(0.50, 0.1),   // Rain
    vec2(0.50, 0.2),   // Thunderstorm
    vec2(0.20, 0.5),   // Ashstorm
    vec2(0.20, 0.6),   // Blight
    vec2(0.50, 0.4),   // Snow
    vec2(0.16, 0.7));  // Blizzard

// The full v2 search core below is compiled only where it runs once
// per screen (the MGE_SkyEst_* passes define WX_NEED_FULL_CORE 1).
// the heavy functions entirely -- compile size and occupancy both.
#ifndef WX_NEED_FULL_CORE
#define WX_NEED_FULL_CORE 0
#endif
// WX_SHARED_BEGIN (search core, synced verbatim into MGE_SkyEst_*.omwfx by scripts/gen_wx_tables.py --write)
// Sun-colour residual weight and the variation-family tie-hygiene penalty
// (design constants, mirrored in the sim -- see the block comment above).
const float wxKSun = 0.7;
const float wxVarPenalty = 0.001;

// Exact port of TimeOfDayInterpolator::getValue (weather.cpp:65-134):
// weights over (Sunrise, Day, Sunset, Night) for one prefix window set.
vec4 wxPhaseW(float hour, vec4 win)
{
    if (hour < wxNightEnd - win.x || hour > wxNightStart + win.w)
        return vec4(0.0, 0.0, 0.0, 1.0);
    if (hour <= wxDayStart + win.y)
    {
        float dur = wxDayStart + win.y - wxNightEnd + win.x;
        float mid = wxNightEnd - win.x + dur * 0.5;
        float f = abs(hour - mid) / dur * 2.0;
        return (hour <= mid) ? vec4(1.0 - f, 0.0, 0.0, f)
                             : vec4(1.0 - f, f, 0.0, 0.0);
    }
    if (hour < wxDayEnd - win.z)
        return vec4(0.0, 1.0, 0.0, 0.0);
    if (hour <= wxNightStart + win.w)
    {
        float dur = wxNightStart + win.w - wxDayEnd + win.z;
        float mid = wxDayEnd - win.z + dur * 0.5;
        float f = abs(hour - mid) / dur * 2.0;
        return (hour <= mid) ? vec4(0.0, f, 1.0 - f, 0.0)
                             : vec4(0.0, 0.0, 1.0 - f, f);
    }
    return vec4(0.0, 0.0, 0.0, 1.0);
}

// Blend one weather's 4-phase table row by tent weights. Note: the weight
// parameter must not be named `w` -- a parameter named `w` would be
// substituted into the `.w` member accesses by the preprocessor
// ((tw).w -> (tw).wSun garbage; caught by the C++ compile harness).
#define MGE_WX_B4(T, i, tw) ((tw).x * T[(i) * 4] + (tw).y * T[(i) * 4 + 1] \
                           + (tw).z * T[(i) * 4 + 2] + (tw).w * T[(i) * 4 + 3])

// Residual of fc against base + U*roll with U in [uLoHi.x, uLoHi.y] and
// roll = (1, G', B') in the given box (a point for the clear branch). U is
// read off the red channel (roll red pinned at 1.0); G'/B' solve linearly
// and clamp -- the clamp distance is the residual. outside the full-core
// guard: the scene's steady dusk/dawn resolver (below) needs it too.
float wxVarRes1(vec3 fc, vec3 base, vec2 uLoHi, vec2 gLoHi, vec2 bLoHi)
{
    float u = fc.r - base.r;
    float ucl = clamp(u, uLoHi.x, uLoHi.y);
    float rr = abs(u - ucl);
    if (ucl < 1e-4)
    {
        vec2 gb = fc.gb - base.gb;
        return sqrt(rr * rr + dot(gb, gb));
    }
    float gp = (fc.g - base.g) / ucl;
    float bp = (fc.b - base.b) / ucl;
    float eg = ucl * (gp - clamp(gp, gLoHi.x, gLoHi.y));
    float eb = ucl * (bp - clamp(bp, bLoHi.x, bLoHi.y));
    return sqrt(rr * rr + eg * eg + eb * eb);
}

// Candidate hours from the sun vector: the exterior sun/light position is
// (400*orbit, -75, z) with orbit linear in hour; y is fixed pre-norm, so
// the x/y ratio recovers orbit through normalization, the z remap and the
// post surface's night z-flip (z is not read). There is no day/night flag
// here, so both branch hours are returned and race by residual (they meet
// continuously at the horizon hours -- no seam). The interior fixed vector
// has positive y (see the mgeGetFogParams detector) -> returns 0 and the
// pure-phase hours 12/0; with the sun term dropped that is bit-identical
// to the old Day/Night race. outside the full-core guard: the scene's
// steady dusk/dawn resolver (below) needs it too.
float wxHoursFromSun(vec3 sunW, out float hd, out float hn)
{
    hd = 12.0;
    hn = 0.0;
    if (sunW.y >= -1e-4)
        return 0.0;
    float orbit = clamp(-(sunW.x / sunW.y) * (75.0 / 400.0), -1.0, 1.0);
    hd = wxNightEnd + (1.0 - orbit) * 0.5 * (wxNightStart - wxNightEnd);
    float adj = wxNightStart
              + (orbit + 1.0) * 0.5 * (24.0 - (wxNightStart - wxNightEnd));
    hn = (adj >= 24.0) ? adj - 24.0 : adj;
    return 1.0;
}

// Day/Night race has NO dusk representation (candidate hours 12/0, pure
// day/night rows only), so every steady dusk state read conf 0 and the
// consumers painted the blue-ratio fallback - the navy cast - while the
// state is exactly representable by these tables (measured: engine dusk
// fogColor = tent(day, rolled-sunset x gain) to ~0.005).
// This is the full core's steady fast path evaluated at the sun-recovered
// branch hours only - 10 tent-blended probes + the variation family, NO
// pair loop - so its body is a fraction of the lite race, nowhere near
// Guards, each forced in by a measured failure (sim gate record in
//   - tent floor 0.30: below it the anchor set is day/night-dominated
//     (the lite rows' regime) and the phantom-branch class lives there
//     (Thunder->Blizzard a=0.05 at hour 19.5 matched steady Snow at the
//     phantom night-branch hour 20.36, conf 1.00);
//   - depth gate 0.005: structurally excludes mid-transition states;
//   - conf floor 0.9 on the steady claim: true steady states sit at
//     res ~ 0; mid-residual matches are grazing transitions.
// Dusk transitions deliberately keep conf 0 (the 109 conf-1-wrong-pair
// crack must not be extended). Tent tails (~20.0-21.0, 5.5-6.2) keep the
// pre-v3 fallback behaviour. Race semantics: updates the incumbent
// result only when it wins outright.
float wxSteadyDusk(vec3 fc, float d, vec3 sunC, vec3 sunW, float bestConf,
                   inout int iOut, inout int jOut, inout float alphaOut,
                   inout float hourOut)
{
    float hd;
    float hn;
    if (wxHoursFromSun(sunW, hd, hn) < 0.5)
        return bestConf;
    float conf = bestConf;
    for (int b = 0; b < 2; ++b)
    {
        float h = (b == 0) ? hd : hn;
        vec4 wF = wxPhaseW(h, wxWinFog);
        float tent = wF.x + wF.z;
        if (tent < 0.30)
            continue;
        vec4 wSun = wxPhaseW(h, wxWinSun);
        for (int i = 0; i < 10; ++i)
        {
            // 5 / 163): the steady depth gate costs one dot and passes
            // 0-2 of 10 candidates -- run it first so the tent-blended
            // colour probe, the variation-family residuals and the sun
            // blend below execute only for depth-passing candidates.
            // Pure reordering: the sim resolver already evaluates in
            // this order (sim_pair_decomposition decompose_scene_v3),
            // verdicts are bit-identical (oracle-gated). This round is
            // also the 162 discriminator: if the dusk fps does not
            // move, the resolver's ~4-5 fps share is register
            // pressure, not execution.
            float aD = dot(vec2(wF.x + wF.y + wF.z, wF.w), wxDepthDN[i]);
            if (abs(d - aD) >= 0.005)
                continue;
            vec3 aF = MGE_WX_B4(wxFogPh, i, wF);
            float res = length(fc - aF);
            if (i < 2)
            {
                vec3 aBase = wF.y * wxFogPh[i * 4 + 1]
                           + wF.w * wxFogPh[i * 4 + 3];
                vec2 uH = (i == 0) ? vec2(tent, tent)
                                   : wF.x + wxVarGainHazy * wF.z;
                vec2 uC = (i == 0) ? vec2(tent, tent)
                                   : wF.x + wxVarGainClear * wF.z;
                float rv = min(
                    wxVarRes1(fc, aBase, uH, wxVarBox.xy, wxVarBox.zw),
                    wxVarRes1(fc, aBase, uC,
                              vec2(wxVarClearPt.x, wxVarClearPt.x),
                              vec2(wxVarClearPt.y, wxVarClearPt.y)))
                    + wxVarPenalty;
                res = min(res, rv);
            }
            float rs = wxKSun * length(sunC - MGE_WX_B4(wxSunPh, i, wSun));
            res = sqrt(res * res + rs * rs);
            float c = 1.0 - smoothstep(0.0392, 0.0784, res);
            if (c >= 0.9 && c > conf)
            {
                conf = c;
                iOut = i;
                jOut = i;
                alphaOut = 0.0;
                hourOut = h;
            }
        }
    }
    return conf;
}

// The first frames of a calm->dense transition put the fog depth into
// the ladder's calm cluster / Rain band (ff 0.7-0.9) while the true
// state is still ~95% calm (ff ~1.0); crossing mgeDenseKneeStart there
// flips the whole distant land into the dense regime - the
// brighter-than-sky cream cutouts. While the fog colour still fits the
// calm family (Clear/Cloudy anchors at the sun-recovered hours,
// variation box included - wxSteadyDusk's colour machinery without its
// steady depth gate), hold ff at the calm value and fade fo out. The
// dense weather has arrived (Ash/Blight 1.10) and a calm-looking
// colour there is a variation-box coincidence (measured: steady dawn
// Ashstorm read calm and broke without it - scratch calm_hold sweep:
// with the decay, steady regression 0.0000, dense corridors bit-equal,
// onset |ff err| Clear->Ashstorm -74%, Clear->Blizzard -23%).
// Returns (calmness, calm ff target); calmSky = the winning anchor's sky
// tent blend at the winning hour branch (wxSkyPh), the calm-hold v2
// palette target: at conf 0 the estimate otherwise degenerates to the
// warm fog colour and the scatter paints the fully-fogged 40-72k band
// above its own-row sky (isolation boxes +0.023..+0.030). Meaningful
// only where calm > 0 (initialized to the Clear day sky anchor
// otherwise).
// hold's release stacked two steep ramps -- the 0.85-1.05 depth decay
// (crossed in ~2.7 s at Blizzard depth speed) and the tight colour fit
// (dies over ~3 s) -- so the whole far-field hold collapsed within two
// screenshot intervals. The corridor arm
// widens both (residual band 0.04-0.24, depth decay 0.85-2.0 -> the
// release paces at ~10 s, Full-like) and stays safe for steady dense
// states by a race, not a gate: the arm is weighted by (1 - best
// dense-anchor fit at the same wide band, dense depth term included) --
// a steady dense state is closest to its own anchor and vetoes the arm
// outright (audit C2: worst steady-dense arm 0.000 over hours x rolls,
// incl. the dawn 5.6-6.2 class that kills depth-window widening and the
// late-dusk 19.3-19.5 class that kills a sun gate). The classic arm is
// kept verbatim and the hold takes max(classic, corridor); the ff/sky
// targets crossfade across the arm seam (a hard select stepped ff by
// ~0.05 -- measured), and the wide arm blends both nice anchors by fit
// (winner-take-all at the wide band flipped calmFF 1.0<->0.9
// mid-corridor -- measured kink). wxS1dR1 range note: mgeCalmWideR1
// 0.20-0.28 trades release rate vs hold duration (taste, a dial).
const float mgeCalmWideR0 = 0.04;
const float mgeCalmWideR1 = 0.24;
const float mgeCalmWideD1 = 2.0;
const float mgeCalmDenseKD = 0.5;

vec2 mgeStockCalmHoldSky(vec3 fc, float d, vec3 sunC, float h1, float h2,
                         out vec3 calmSky)
{
    calmSky = wxSkyPh[1];
    if (d >= mgeCalmWideD1)
        return vec2(0.0, 1.0);
    float calmT = 0.0;
    float ffT = 1.0;
    int iWinT = 0;
    float hWinT = h1;
    float calmW = 0.0;
    float accW = 0.0;
    float accFF = 0.0;
    vec3 accSky = vec3(0.0);
    float denseW = 0.0;
    for (int b = 0; b < 2; ++b)
    {
        float h = (b == 0) ? h1 : h2;
        vec4 wF = wxPhaseW(h, wxWinFog);
        float tent = wF.x + wF.z;
        vec4 wSun = wxPhaseW(h, wxWinSun);
        vec4 wSb = wxPhaseW(h, wxWinSky);
        for (int i = 0; i < 10; ++i)
        {
            vec3 aF = MGE_WX_B4(wxFogPh, i, wF);
            float res = length(fc - aF);
            float rs = wxKSun * length(sunC - MGE_WX_B4(wxSunPh, i, wSun));
            if (i < 2)
            {
                vec3 aBase = wF.y * wxFogPh[i * 4 + 1]
                           + wF.w * wxFogPh[i * 4 + 3];
                vec2 uH = (i == 0) ? vec2(tent, tent)
                                   : wF.x + wxVarGainHazy * wF.z;
                vec2 uC = (i == 0) ? vec2(tent, tent)
                                   : wF.x + wxVarGainClear * wF.z;
                float rv = min(
                    wxVarRes1(fc, aBase, uH, wxVarBox.xy, wxVarBox.zw),
                    wxVarRes1(fc, aBase, uC,
                              vec2(wxVarClearPt.x, wxVarClearPt.x),
                              vec2(wxVarClearPt.y, wxVarClearPt.y)))
                    + wxVarPenalty;
                res = min(res, rv);
                res = sqrt(res * res + rs * rs);
                float ffw = (i == 0) ? 1.0 : 0.9;
                float c = 1.0 - smoothstep(0.0392, 0.0784, res);
                if (c > calmT)
                {
                    calmT = c;
                    ffT = ffw;
                    iWinT = i;
                    hWinT = h;
                }
                float cw = 1.0 - smoothstep(mgeCalmWideR0, mgeCalmWideR1,
                                            res);
                calmW = max(calmW, cw);
                accW += cw;
                accFF += cw * ffw;
                accSky = accSky + cw * MGE_WX_B4(wxSkyPh, i, wSb);
            }
            else
            {
                res = sqrt(res * res + rs * rs);
                float aD = dot(vec2(wF.x + wF.y + wF.z, wF.w),
                               wxDepthDN[i]);
                float rd = mgeCalmDenseKD * abs(d - aD);
                res = sqrt(res * res + rd * rd);
                denseW = max(denseW,
                             1.0 - smoothstep(mgeCalmWideR0, mgeCalmWideR1,
                                              res));
            }
        }
    }
    float aClassic = calmT * (1.0 - smoothstep(0.85, 1.05, d));
    float aCorr = calmW * (1.0 - denseW)
                * (1.0 - smoothstep(0.85, mgeCalmWideD1, d));
    vec3 skyT = MGE_WX_B4(wxSkyPh, iWinT, wxPhaseW(hWinT, wxWinSky));
    if (accW <= 1e-9)
    {
        calmSky = skyT;
        return vec2(aClassic, ffT);
    }
    float sel = smoothstep(-0.05, 0.05, aCorr - aClassic);
    float invW = 1.0 / accW;
    calmSky = mix(skyT, accSky * invW, sel);
    return vec2(max(aClassic, aCorr), mix(ffT, accFF * invW, sel));
}

// Returns (calmness, calm ff target).
vec2 mgeStockCalmHold(vec3 fc, float d, vec3 sunC, float h1, float h2)
{
    vec3 calmSkyUnused;
    return mgeStockCalmHoldSky(fc, d, sunC, h1, h2, calmSkyUnused);
}

// The RP dusk-corridor jumpiness has one cliff (176): conf drives the
// est-error correction (positively) and the calm-hold (negatively) --
// `calm * (1 - confDec)` -- and the lite search's conf/pair output is
// structurally erratic through twilight corridors (19 pair segments
// across one dusk ladder, confident-wrong islands at conf 1.00: the 109
// crack, convicted as the visible distant-land steps). S1d
// replaces the cliff with a smooth ramp inside the dusk/dawn tent:
// steadiness = smooth proximity to every steady anchor, using the
// calm-hold's residual machinery (variation family for Clear/Cloudy +
// sun term) plus a depth term, band 0.015-0.06 (the 179 design point).
// A nice winner (Clear/Cloudy) hands conf to the ramp and pins the
// verdict basis to the anchor (the corridor onset case); a dense winner
// preserves the search's conf up to the anchor's own proximity
// (min(conf, s)): steady dense twilight keeps its correct confident
// verdict, mid-corridor confident-wrong islands are capped by the
// smoothly-decaying s, arrival recovers smoothly on the pinned anchor.
// the S1d branch race (tie -> the smaller tent) disengaged across the
// real corridor -- at dusk 17.6-17.9 the night-branch candidate hour is
// 21.5-21.7 (tent 0), mid-corridor both steadiness values are 0, and
// the tie handed the corridor to plain v3 (the 109 bumps on screen).
// The discriminator the race lacked is the sun: night tie states carry
// near-black sun colour (lum <= ~0.26 across the night rows), dusk
// corridors a bright one (nice->storm p50 ~0.59) -- so the sun owns
// the twilight-ness question: a luminance gate blends the tent from
// the race outcome (dark = the night-phantom protection, S1d
// semantics) toward max(t1, t2) (bright = engaged), smooth in both
// alpha and across the tie edge. Luminance reads the pass-invariant
// sun colour, never sun z (the water-mirror flip, same reason
// wxHoursFromSun reads x/y only). And one symmetric arm: the ramp owns
// conf for any winner with the basis pinned at tent > 0.5 -- the S1d
// dense-arm cap (min(conf, s)) could not raise a collapsed conf, so
// arrival rode v3's erratic near-arrival conf (trace: 0.958 step);
// high s pins the basis to the anchor itself, so the S1c
// confident-wrong-basis class cannot return.
// Reference: sim_pair_decomposition.py decompose_scene_v3_s1e
// (oracle-gated). Gates: corridor worst conf/hold step
// 1.000 -> 0.095/0.094, wrong-pair confident exposure 0.290 -> 0.000,
// day corridor bit-identical, replayed corridor bumps 0.37/0.53
// -> 0, night inventory slice 0 degraded, inventory 2462 rescued vs
// 1234 pushed (the honest-fallback trade at engaged volume).
const float wxS1dR0 = 0.015; // steadiness residual band (band sweep)
const float wxS1dR1 = 0.06;
const float wxS1dKD = 0.5;   // depth-term weight
const float wxS1dSunLo = 0.30; // sun-luminance gate (183 fit: night ties
const float wxS1dSunHi = 0.45; // <= 0.26, dusk nice corridors >= 0.45)

float wxS1dTwilightTent(float h)
{
    return max(smoothstep(5.0, 6.0, h) * (1.0 - smoothstep(8.5, 9.5, h)),
               smoothstep(15.5, 16.5, h) * (1.0 - smoothstep(20.5, 21.5, h)));
}

// Best steadiness over all 10 steady anchors at one branch hour.
// wOut = the winning weather index, -1 when every s is 0.
float wxS1dSteadiness(vec3 fc, float d, vec3 sunC, float h, out int wOut)
{
    wOut = -1;
    float bestS = 0.0;
    vec4 wF = wxPhaseW(h, wxWinFog);
    vec4 wSun = wxPhaseW(h, wxWinSun);
    float tent = wF.x + wF.z;
    for (int i = 0; i < 10; ++i)
    {
        vec3 aF = MGE_WX_B4(wxFogPh, i, wF);
        float res = length(fc - aF);
        if (i < 2)
        {
            vec2 uHi = (i == 0) ? vec2(tent, tent)
                                : wF.x + wxVarGainHazy * wF.z;
            vec2 uCi = (i == 0) ? vec2(tent, tent)
                                : wF.x + wxVarGainClear * wF.z;
            if (max(uHi.y, uCi.y) > 1e-6)
            {
                vec3 aBase = wF.y * wxFogPh[i * 4 + 1]
                           + wF.w * wxFogPh[i * 4 + 3];
                float rv = min(
                    wxVarRes1(fc, aBase, uHi, wxVarBox.xy, wxVarBox.zw),
                    wxVarRes1(fc, aBase, uCi,
                              vec2(wxVarClearPt.x, wxVarClearPt.x),
                              vec2(wxVarClearPt.y, wxVarClearPt.y)))
                    + wxVarPenalty;
                res = min(res, rv);
            }
        }
        float aD = dot(vec2(wF.x + wF.y + wF.z, wF.w), wxDepthDN[i]);
        float rd = wxS1dKD * abs(d - aD);
        res = sqrt(res * res + rd * rd);
        float rs = wxKSun * length(sunC - MGE_WX_B4(wxSunPh, i, wSun));
        res = sqrt(res * res + rs * rs);
        float s = 1.0 - smoothstep(wxS1dR0, wxS1dR1, res);
        if (s > bestS)
        {
            wOut = i;
            bestS = s;
        }
    }
    return bestS;
}

// Branch/tent selection + the conf rewrite, applied to the verdict the
// search chain produced. hour is deliberately not rewritten (the sky
// tent keeps the search's hour; the reference does the same).
void wxS1dStabilize(vec3 fc, float d, vec3 sunC, vec3 sunW,
                    inout int iOut, inout int jOut, inout float alphaOut,
                    inout float confOut)
{
    float hd;
    float hn;
    if (wxHoursFromSun(sunW, hd, hn) < 0.5)
        return;
    int wA;
    int wB;
    float sA = wxS1dSteadiness(fc, d, sunC, hd, wA);
    float sB = wxS1dSteadiness(fc, d, sunC, hn, wB);
    float t1 = wxS1dTwilightTent(hd);
    float t2 = wxS1dTwilightTent(hn);
    float tentRace;
    int wStar;
    float s;
    if (abs(sA - sB) < 0.05)
    {
        // Tie -> the smaller tent (the night-phantom protection arm).
        tentRace = min(t1, t2);
        wStar = (sA >= sB) ? wA : wB;
        s = max(sA, sB);
    }
    else if (sA > sB)
    {
        tentRace = t1;
        wStar = wA;
        s = sA;
    }
    else
    {
        tentRace = t2;
        wStar = wB;
        s = sB;
    }
    // bright sun -> the tent engages regardless of which branch won
    // the race; dark sun -> the race's night-protection semantics.
    float lum = dot(sunC, vec3(0.299, 0.587, 0.114));
    float gate = smoothstep(wxS1dSunLo, wxS1dSunHi, lum);
    float tent = tentRace + gate * (max(t1, t2) - tentRace);
    if (tent <= 0.0)
        return;
    if (wStar >= 0)
    {
        // one symmetric arm: the ramp owns conf for any winner; the
        // basis pins to the anchor at tent > 0.5 (honest exactly where
        // s is high -- the state IS at the anchor).
        confOut = (1.0 - tent) * confOut + tent * s;
        if (tent > 0.5)
        {
            iOut = wStar;
            jOut = wStar;
            alphaOut = 0.0;
        }
    }
    else
        confOut = (1.0 - tent) * confOut;
}

// lite race scores twilight tent-blends against pure Day/Night rows,
// where a wrong pair can fit coincidentally at conf ~1 (the
// crack). The refine below re-runs the search on
// tent-blended anchors at the sun-recovered hour(s), where the true
// state is representable by construction. The 134 refine raced a lite
// search (no variation family, no sun term) -- measured blind to XE
// Sky Variations days: it demoted the resolver's correct rolled
// steady-dusk verdicts (conf 0 -> bright far field, A/B frames
// 1642/1621) and let wrong pairs win against rolled observations (187
// confident-wrong states on the 22,736-state rolled sweep, 92
// v4-introduced). The refine now races the full search core wxSearch
// (variation family + sun term -- the same machinery the resolver and
// the posts already carry): rolled sweep 1426 improved, 0 degraded,
// 0 cracks. Set 0 for the pre-134 behaviour (live A/B via shader
// hot-reload; the est-model replicas sync this block, so both
// surfaces flip together).
//
// every scene fragment shader under this guard halved the frame
// rate (~24 fps at 4K day; recovered on the measured A/B). The refine
// itself early-outs outside twilight, so the cost is the compile
// footprint (worst-case register allocation for the dynamically-
// guarded call), not execution -- it taxes every scene draw on both
// tiers, including Full where mgeWxCompute never runs past the
// engine-uniform early-out. v4b stays the parked verdict-quality bar
// (sim decompose_scene_v4b; sweep baseline): the queued dusk round
// must re-meet it within the scene footprint (per-frame precompute,
// register diet, or a post-only design). Do not flip back to 1
// without an in-game FPS number next to the sweep.
//
// opt IN per compilation unit, water.frag defines V4+rescue+FULL_CORE
// before its fog.glsl include, so one program (water) pays the core's
// compile footprint and gets the full v5 verdict quality; every other
// scene shader keeps the default below.
#ifndef MGE_WX_V4
#define MGE_WX_V4 0
#endif

// conf < 0.9, race the full core at the sun-recovered hours and adopt
// a better verdict. The core solves every twilight-transition state
// exactly (14,850/14,850 sim grid), v4b's refine was vet-only
// (confOut < 0.9 returned untouched) and never rescued the fallback
// stretch that paints the wave rollercoaster / fog sawtooth. Requires
// the full core (wxDecomposeCore); default off, only water.frag
// opts in today (146 footprint rule).
#ifndef MGE_WX_RESCUE
#define MGE_WX_RESCUE 0
#endif
#if MGE_WX_RESCUE && !WX_NEED_FULL_CORE
#error MGE_WX_RESCUE requires WX_NEED_FULL_CORE (wxDecomposeCore)
#endif

#if MGE_WX_V4
// The v4b epilogue, shared by the scene and the est-model replicas:
// every >=0.9-confident result -- lite OR resolver -- must survive the
// full search (wxSearch: variation family + sun term) at the
// sun-recovered hour(s). The incumbent is among the candidates, so a
// true winner self-confirms; a coincidental day/night-row match is
// outscored by the true state at its own hour; a rolled steady state
// self-confirms through the variation box instead of being demoted
// (the v4-lite regression). Below 0.9 the state already sits in the
// designed fallback regime and is left alone.
// wxSearch's body sits in the full-core section below -- compiled into
// the scene by the WX_NEED_FULL_CORE || MGE_WX_V4 guard; prototype
// here because the refine precedes it textually.
float wxSearch(vec3 fc, float d, vec3 sunC, float ksun, float hour,
               out int iOut, out int jOut, out float alphaOut);

void wxV4Refine(vec3 fc, float d, vec3 sunC, vec3 sunW, inout int iOut,
                inout int jOut, inout float alphaOut,
                inout float hourOut, inout float confOut)
{
    if (confOut < 0.9)
        return;
    float hd4;
    float hn4;
    if (wxHoursFromSun(sunW, hd4, hn4) < 0.5)
        return;
    vec4 wd4 = wxPhaseW(hd4, wxWinFog);
    vec4 wn4 = wxPhaseW(hn4, wxWinFog);
    // Twilight gate: at day/night hours the blended anchors are the
    // lite rows -- nothing to re-check (and the whole-screen skip is
    // frame-coherent, so it saves the runtime it looks like it saves).
    if (max(wd4.x + wd4.z, wn4.x + wn4.z) < 0.05)
        return;
    int bi = 0;
    int bj = 0;
    float ba = 0.0;
    float bh = hd4;
    float bc = -1.0;
    for (int b4 = 0; b4 < 2; ++b4)
    {
        float h4 = (b4 == 0) ? hd4 : hn4;
        int i4;
        int j4;
        float a4;
        float c4 = wxSearch(fc, d, sunC, wxKSun, h4, i4, j4, a4);
        if (c4 > bc)
        {
            bc = c4;
            bi = i4;
            bj = j4;
            ba = a4;
            bh = h4;
        }
    }
    if (bc >= 0.9)
    {
        iOut = bi;
        jOut = bj;
        alphaOut = ba;
        hourOut = bh;
        confOut = bc;
    }
    else
        confOut = min(confOut, bc);
}
#endif

#if WX_NEED_FULL_CORE || MGE_WX_V4
// One anchor-set search at a candidate hour. ksun = 0 disables the sun
// observation; combined with hours 12/0 that reproduces the v1 Day/Night
// race exactly (sim identity gate, 990 samples). Returns confidence
// (residual edges as mgeMggSegmentSky: full below 10/255, zero above
// 20/255).
//
// inlined instances, so this function must be reachable from exactly one
// textual call chain per shader (mgeWxCompute). Within that single
// instance, static bounds + precomputed anchor arrays are deliberate:
// they let the driver fully unroll and constant-fold the search into
// straight-line code (v1-class runtime). A "keep the loops rolled"
// variant was measured to save nothing at compile time and pessimized
// runtime badly (dynamic local-array indexing spills to local memory).
float wxSearch(vec3 fc, float d, vec3 sunC, float ksun, float hour,
               out int iOut, out int jOut, out float alphaOut)
{
    iOut = 0;
    jOut = 0;
    alphaOut = 0.0;
    vec4 wF = wxPhaseW(hour, wxWinFog);
    vec4 wSun = wxPhaseW(hour, wxWinSun);
    vec3 aF[10];
    float aD[10];
    vec3 aSun[10];
    for (int i = 0; i < 10; ++i)
    {
        aF[i] = MGE_WX_B4(wxFogPh, i, wF);
        aD[i] = dot(vec2(wF.x + wF.y + wF.z, wF.w), wxDepthDN[i]);
        aSun[i] = MGE_WX_B4(wxSunPh, i, wSun);
    }
    // XE Sky Variations family: the daily roll rewrites the Clear (0) and
    // Cloudy (1) sunrise/sunset fog records; it enters the blended anchor
    // linearly: anchor = base + U*roll. uPhase = the rolled-slot weight.
    float uPhase = wF.x + wF.z;
    bool hasVar = uPhase > 1e-6;
    vec3 aBase[2];
    aBase[0] = wF.y * wxFogPh[1] + wF.w * wxFogPh[3];
    aBase[1] = wF.y * wxFogPh[5] + wF.w * wxFogPh[7];
    // U ranges (x lo, y hi) per authored branch; Clear is g-independent.
    vec2 uH[2];
    vec2 uC[2];
    uH[0] = vec2(uPhase, uPhase);
    uC[0] = vec2(uPhase, uPhase);
    uH[1] = wF.x + wxVarGainHazy * wF.z;
    uC[1] = wF.x + wxVarGainClear * wF.z;

    // Steady-state fast path: most frames are not in a transition, and a
    // steady state matches one anchor directly - 10 probes instead of ~45
    // candidate pairs, per fragment, per call site. Output-equivalent to
    // the full search (sim-gated). Colour tolerance 0.012, not the conf
    // edge: same-depth pairs (ash/blight, foggy/snow/thunder) can't be
    // disambiguated by d, so this alone bounds how much of a blend may
    // snap to an endpoint (<0.016 wave strength). This is also the
    // ash-storm FPS path: steady dense weather exits here.
    for (int i = 0; i < 10; ++i)
    {
        if (abs(d - aD[i]) < 0.005)
        {
            float res = length(fc - aF[i]);
            if (hasVar && i < 2)
            {
                float rv = min(
                    wxVarRes1(fc, aBase[i], uH[i], wxVarBox.xy, wxVarBox.zw),
                    wxVarRes1(fc, aBase[i], uC[i],
                              vec2(wxVarClearPt.x, wxVarClearPt.x),
                              vec2(wxVarClearPt.y, wxVarClearPt.y)))
                    + wxVarPenalty;
                res = min(res, rv);
            }
            float rs = ksun * length(sunC - aSun[i]);
            res = sqrt(res * res + rs * rs);
            if (res < 0.012)
            {
                iOut = i;
                jOut = i;
                return 1.0 - smoothstep(0.0392, 0.0784, res);
            }
        }
    }

    float bestRes = 1e9;
    for (int i = 0; i < 10; ++i)
    {
        bool varI = hasVar && i < 2;
        vec3 bA = varI ? aBase[i] : aF[i];
        vec2 uiH = varI ? uH[i] : vec2(0.0, 0.0);
        vec2 uiC = varI ? uC[i] : vec2(0.0, 0.0);
        for (int j = i + 1; j < 10; ++j)
        {
            // Only j == 1 (Cloudy) can be variation-bearing here (j > i).
            bool varJ = hasVar && j < 2;
            vec3 bB = varJ ? aBase[1] : aF[j];
            vec2 ujH = varJ ? uH[1] : vec2(0.0, 0.0);
            vec2 ujC = varJ ? uC[1] : vec2(0.0, 0.0);
            bool varPair = varI || varJ;
            float dd = aD[j] - aD[i];
            // Candidate alphas: depth-solved when depths differ (alpha is
            // over-determined; colour validates). Same-depth pairs take
            // the colour projection, plus - on variation-bearing pairs -
            // the red-channel solve at the u-range corners of each
            // authored branch (roll red is pinned at 1.0, so R gives one
            // equation in alpha alone; cfg projection alone was measured
            // 0.15 vs truth 0.30 on varied Clear->Overcast dawns).
            float cand[5];
            int nc = 0;
            if (abs(dd) > 0.02)
            {
                float alpha = (d - aD[i]) / dd;
                if (alpha < -0.05 || alpha > 1.05)
                    continue;
                cand[0] = clamp(alpha, 0.0, 1.0);
                nc = 1;
            }
            else
            {
                if (abs(d - aD[i]) > 0.02)
                    continue;
                vec3 seg = aF[j] - aF[i];
                float den = dot(seg, seg);
                if (den < 1e-9)
                    continue;
                cand[0] = clamp(dot(fc - aF[i], seg) / den, 0.0, 1.0);
                nc = 1;
                if (varPair)
                {
                    for (int c = 0; c < 4; ++c)
                    {
                        float uA = (c == 0) ? uiH.x : (c == 1) ? uiH.y
                                 : (c == 2) ? uiC.x : uiC.y;
                        float uB = (c == 0) ? ujH.x : (c == 1) ? ujH.y
                                 : (c == 2) ? ujC.x : ujC.y;
                        float ar = bA.r + uA;
                        float br = bB.r + uB;
                        if (abs(br - ar) > 1e-6)
                        {
                            cand[nc] = clamp((fc.r - ar) / (br - ar),
                                             0.0, 1.0);
                            ++nc;
                        }
                    }
                }
            }
            for (int c = 0; c < 5; ++c)
            {
                if (c >= nc)
                    break;
                float a = cand[c];
                float res = length(fc - mix(aF[i], aF[j], a));
                if (varPair)
                {
                    vec3 baseMix = mix(bA, bB, a);
                    float rv = min(
                        wxVarRes1(fc, baseMix, mix(uiH, ujH, a),
                                  wxVarBox.xy, wxVarBox.zw),
                        wxVarRes1(fc, baseMix, mix(uiC, ujC, a),
                                  vec2(wxVarClearPt.x, wxVarClearPt.x),
                                  vec2(wxVarClearPt.y, wxVarClearPt.y)))
                        + wxVarPenalty;
                    res = min(res, rv);
                }
                float rs = ksun * length(sunC - mix(aSun[i], aSun[j], a));
                res = sqrt(res * res + rs * rs);
                if (res < bestRes)
                {
                    bestRes = res;
                    iOut = i;
                    jOut = j;
                    alphaOut = a;
                }
            }
        }
    }
    return 1.0 - smoothstep(0.0392, 0.0784, bestRes);
}
#endif // WX_NEED_FULL_CORE || MGE_WX_V4

#if WX_NEED_FULL_CORE
// The full decomposition: candidate-hour race over wxSearch. Identical on
// both surfaces (the post replicas call this with omw.sunPos/omw.sunColor;
// the correction pass must model the scene's race, not shortcut it).
float wxDecomposeCore(vec3 fc, float d, vec3 sunW, vec3 sunCIn,
                      out int iOut, out int jOut, out float alphaOut,
                      out float hourOut)
{
    float hd;
    float hn;
    float valid = wxHoursFromSun(sunW, hd, hn);
    float ksun = valid * wxKSun;
    vec3 sunC = (valid > 0.5) ? sunCIn : vec3(0.0, 0.0, 0.0);
    float c1 = wxSearch(fc, d, sunC, ksun, hd, iOut, jOut, alphaOut);
    hourOut = hd;
    // Race short-circuit: a >=0.999-conf candidate cannot be beaten (ties
    // prefer the day candidate, matching the old rd >= rn preference), so
    // steady frames cost a single anchor set.
    if (c1 >= 0.999)
        return c1;
    int i2;
    int j2;
    float a2;
    float c2 = wxSearch(fc, d, sunC, ksun, hn, i2, j2, a2);
    if (c2 > c1)
    {
        iOut = i2;
        jOut = j2;
        alphaOut = a2;
        hourOut = hn;
        return c2;
    }
    return c1;
}
#endif // WX_NEED_FULL_CORE
// WX_SHARED_END

// S1d kill-switch (outside the sync span on purpose -- the span must not
// gain preprocessor lines; the est-model replicas carry their own copy of
// this define next to MGE_CALM_HOLD_V2 and must flip together, est-model
// rule). 0 = the pre-S1d conf cliff returns (live A/B unit; rot-gated by
// check_glsl_decomposer section [6], which compiles both variants and
// proves 0 ≡ plain v3). Applies only to the lite-tier verdict: the
// full-core opt-ins (water: V4+rescue) solve twilight transitions
// wrapping v3 alone -- capping the full core's correct confident
// corridor verdicts with min(conf, s) would re-create the fallback
// stretch S1d exists to remove.
#ifndef MGE_WX_S1D
#define MGE_WX_S1D 1
#endif

// LB4 -- the lite-race twilight bypass + donated sky-tent hour
// decompose_scene_v3_s1e_lb4 + lb4_sky_from). At S1e tent > 0.999 the
// stabilizer pin owns conf exactly (dconf <= 0.00075 over the
// 26,325-state twilight sweep) and the only channel the two lite
// 45-pair searches still deliver is the sky-tent hour -- a wrong-phase
// 12/0 coin-flip, mean 0.26 off the true record-tent sky. In-gate this
// switch skips both lite races (~9 ms at the uncapped dusk view,
// outside the gate the sky-tent consumer blends toward the donated
// hour by smoothstep(0.90, 0.999, tent) -- continuous at the gate
// boundary (the unsmoothed gate snapped up to 0.86 of sky in one
// frame at steady twilight window-edge crossings; temporal-race T1),
// byte-identical below tent 0.90. Scoped to the S1e lite tier
// (S1D && !V4 && !rescue): water's v5 composition is untouched. The
// donated hour cannot reach the reveal or the roll recovery (both
// early-out at i == j, and the donation only applies where the pin
// set i = j). 0 = byte-exact shipped behaviour (the reordered
// race/adopt plumbing is output-identical; gated by section [6]'s
// kill-switch control + the sim oracle). est-model rule: the scene
// and both omwfx replicas carry this define and must flip together
// (shipped_kind enforces presence + value equality).
#ifndef MGE_WX_LITE_BYPASS
#define MGE_WX_LITE_BYPASS 1
#endif

// the all-units block at the top, the consumers are reader-flavor
// fragments). This helper is stage-side (it needs the tables): pure
// table lookup on decomposition results, shipped to fragments via
// mgeWxVRev. storm<->storm keeps the blend (both looks are palette,
// the blend is between them); nice<->nice never reveals. conf-mixed:
// conf 0 reproduces today's behaviour exactly.
vec3 wxRevealFog(vec3 fogBlend, int i, int j, float conf, float hour)
{
    if (conf < 0.001 || i == j)
        return fogBlend;
    bool niceI = wxNice[i] > 0.5;
    bool niceJ = wxNice[j] > 0.5;
    if (niceI == niceJ)
        return fogBlend;
    int s = niceI ? j : i;
    vec4 wF = wxPhaseW(hour, wxWinFog);
    vec3 fogS = MGE_WX_B4(wxFogPh, s, wF);
    return mix(fogBlend, fogS, conf);
}

// Single-instance decomposition cache (compile-size fix): the GLSL
// compiler fully inlines every call, and each inlined
// instance of the search cost ~0.3-0.5 s of driver compile per shader
// permutation -- 4-6 live consumer sites serialized across the
// load. The heavy search is therefore textually instantiated once per
// shader inside mgeWxCompute(), called at the top of every consumer
// shader's main() (objects/terrain/groundcover/water/sky .frag); the
// readers below only copy these globals. fail-safe: a shader that never
// calls mgeWxCompute() reads conf 0 and every consumer composes its
// pre-decomposition fallback.
float wxG_conf = 0.0;
int wxG_i = 0;
int wxG_j = 0;
float wxG_alpha = 0.0;
float wxG_hour = 12.0;

// The calm-hold outputs, computed once per invocation by wxHoldFill()
// (called from mgeWxCompute, stock-gated) and read by every consumer:
//   wxG_holdSky   xyz = the winning calm anchor's sky tent blend,
//                 w   = calm (the mgeGetFogParams arm: sun-hour fallback
//                       12/0 as that call site always had)
//   wxG_holdFF    the calm ff target (mgeStockCalmHoldSky .y)
//   wxG_holdV2    calm gated by sun-hours validity - the calm-hold v2
//                 arm: the old lazy fill computed nothing without a
//                 valid sun, so its weight must read 0 there. (The sky
//                 xyz then holds the 12/0-fallback evaluation instead of
//                 the old zeros - consumed only scaled by this weight,
//                 outcome-identical; the harness's own calm==0 basis.)
//   wxG_holdWNight the fog-tent night weight at the day-branch hour
//                 (the split-ladder input mgeGetFogParams derived itself)
// Defaults = the no-fill outcomes of every consumer (hold 0, weight 0).
vec4 wxG_holdSky = vec4(0.0, 0.0, 0.0, 0.0);
float wxG_holdFF = 1.0;
float wxG_holdV2 = 0.0;
float wxG_holdWNight = 0.0;

// wxDuskChain now runs before the lite races (the bypass gate needs
// the S1e tent, which needs the chain's steadiness pair); the chain
// therefore no longer writes the wxG_ verdict itself -- it exports the
// resolver's best candidate and the S1e tent state here, and
// mgeWxCompute applies adoption vs the incumbent conf and the S1e
// epilogue after the races. The candidate argmax (strictly-greater,
// same iteration order) adopts exactly the state the old in-loop race
// adopted -- output-bit-identical, gated by section [6] + the oracle.
// Defaults = the no-signal outcomes (no candidate, tent 0, no dusk).
float wxG_dcCand = 0.0;   // resolver candidate conf (0 = none; the
                          // >= 0.9 floor is applied at collection)
int wxG_dcI = 0;          // its anchor
float wxG_dcHour = 12.0;  // its branch hour
float wxG_dcDusk = 0.0;   // hoursOK (sun-derived branch hours valid)
#if MGE_WX_S1D && !MGE_WX_V4 && !MGE_WX_RESCUE
float wxG_dcTent = 0.0;   // the S1e tent (bypass gate + blend input)
int wxG_dcWStar = -1;     // steadiness winner anchor (-1 = none)
float wxG_dcS = 0.0;      // its steadiness
float wxG_dcHSky = 12.0;  // the donated sky-tent hour (348 rule)
#endif
#if MGE_WX_LITE_BYPASS && MGE_WX_S1D && !MGE_WX_V4 && !MGE_WX_RESCUE
float wxG_lb4Hour = 12.0; // out-of-gate donated hour (sky blend)
float wxG_lb4W = 0.0;     // its smoothstep(0.90, 0.999, tent) weight
#endif

// wxSteadyDusk, the S1d steadiness pair and the calm-hold machinery
// (the 342 fill) each evaluate the same (branch-hour x anchor) grid -
// tents, anchor blends, variation-family + sun residuals, depth
// terms - and combine the shared components with per-consumer
// is ~11 ms of executed per-vertex work (occupancy ~0: a branched-off
// compiled body is free). This scene-side fold computes the grid once
// and applies each consumer's combination verbatim - the fp nesting
// of every sqrt chain and every race/tie order is preserved
// deliberately, so each output is bit-identical to its span original.
// The span originals (wxSteadyDusk, wxS1dStabilize/Steadiness,
// mgeStockCalmHoldSky) stay untouched for the est-model replicas
// (per-screen cost, immaterial); drift between this fold and the span
// is caught structurally by the existing battery - both surfaces are
// gated against the same sim oracle (check_glsl_decomposer
// [3]/[3b]/[6]), so a one-sided edit fails one of them. The
// old-vs-new consumer equivalence proof: _hold_diet_equiv.py.
// Fill-half hour semantics: on stock the resolved sunW IS the light-0
// derivation the 342 fill used (mgeSunDir reads 0 there), and
// wxHoursFromSun outputs hd/hn = 12/0 on failure - exactly the old
// fallback; on the patched tier the fill-half is skipped (every hold
// consumer early-outs to engine truth there). The z-flip deletion of
void wxDuskChain(vec3 fc, float d, vec3 sunC, vec3 sunW)
{
    // Self-resetting exports (the fail-safe contract, and the C++
    // oracle harness keeps file-scope globals across samples where
    // GLSL re-initializes per invocation): every export is written
    // every call, defaults = the no-signal outcomes.
    wxG_dcCand = 0.0;
    wxG_dcI = 0;
    wxG_dcHour = 12.0;
    wxG_dcDusk = 0.0;
#if MGE_WX_S1D && !MGE_WX_V4 && !MGE_WX_RESCUE
    wxG_dcTent = 0.0;
    wxG_dcWStar = -1;
    wxG_dcS = 0.0;
    wxG_dcHSky = 12.0;
#endif
    float hd;
    float hn;
    float hoursOK = wxHoursFromSun(sunW, hd, hn);
    bool duskOK = hoursOK > 0.5;
    bool fillOK = mgeWeatherUniforms < 0.5
        && gl_Fog.end > 1.0 && gl_Fog.end < 1000000.0 && d > 0.65;
    if (fillOK && d >= mgeCalmWideD1)
    {
        // the machinery's own far-depth early return: calm 0, ff 1,
        // calmSky = its Cloudy-day-anchor initializer
        wxG_holdSky = vec4(wxSkyPh[1], 0.0);
        wxG_holdFF = 1.0;
        wxG_holdV2 = 0.0;
        wxG_holdWNight = duskOK ? wxPhaseW(hd, wxWinFog).w : 0.0;
        fillOK = false;
    }
    // The resolver races to a candidate here (incumbent-free argmax;
    // >= 0.9 floor at collection); adoption vs the incumbent conf --
    // the old sdRun/sdConf semantics -- happens in mgeWxCompute after
    // the lite races (the LB4 reorder). Winner identity is unchanged:
    // the old running race adopted the first-on-tie maximum among
    // candidates beating both 0.9 and the incumbent, which is exactly
    // argmax-then-compare (section [6] + the oracle gate it).
#if MGE_WX_S1D && !MGE_WX_V4 && !MGE_WX_RESCUE
    float s1A = 0.0;
    int s1WA = -1;
    float s1B = 0.0;
    int s1WB = -1;
#endif
    float calmT = 0.0;
    float ffT = 1.0;
    int iWinT = 0;
    float hWinT = hd;
    float calmW = 0.0;
    float accW = 0.0;
    float accFF = 0.0;
    vec3 accSky = vec3(0.0);
    float denseW = 0.0;
    for (int b = 0; b < 2; ++b)
    {
        float h = (b == 0) ? hd : hn;
        vec4 wF = wxPhaseW(h, wxWinFog);
        float tent = wF.x + wF.z;
        vec4 wSun = wxPhaseW(h, wxWinSun);
        vec4 wSb = wxPhaseW(h, wxWinSky);
        bool sdBranch = duskOK && tent >= 0.30;
        for (int i = 0; i < 10; ++i)
        {
            // the shared components (identical expressions in all
            // three span originals)
            vec3 aF = MGE_WX_B4(wxFogPh, i, wF);
            float colRes = length(fc - aF);
            float rs = wxKSun * length(sunC - MGE_WX_B4(wxSunPh, i, wSun));
            float aD = dot(vec2(wF.x + wF.y + wF.z, wF.w), wxDepthDN[i]);
            float adDiff = abs(d - aD);
            float rv = 0.0;
            vec2 uH = vec2(0.0, 0.0);
            vec2 uC = vec2(0.0, 0.0);
            if (i < 2)
            {
                vec3 aBase = wF.y * wxFogPh[i * 4 + 1]
                           + wF.w * wxFogPh[i * 4 + 3];
                uH = (i == 0) ? vec2(tent, tent)
                              : wF.x + wxVarGainHazy * wF.z;
                uC = (i == 0) ? vec2(tent, tent)
                              : wF.x + wxVarGainClear * wF.z;
                rv = min(
                    wxVarRes1(fc, aBase, uH, wxVarBox.xy, wxVarBox.zw),
                    wxVarRes1(fc, aBase, uC,
                              vec2(wxVarClearPt.x, wxVarClearPt.x),
                              vec2(wxVarClearPt.y, wxVarClearPt.y)))
                    + wxVarPenalty;
            }
            // -- wxSteadyDusk's combination (depth pre-filter + race
            // to the exported candidate; adoption in mgeWxCompute)
            if (sdBranch && adDiff < 0.005)
            {
                float res = colRes;
                if (i < 2)
                    res = min(res, rv);
                res = sqrt(res * res + rs * rs);
                float c = 1.0 - smoothstep(0.0392, 0.0784, res);
                if (c >= 0.9 && c > wxG_dcCand)
                {
                    wxG_dcCand = c;
                    wxG_dcI = i;
                    wxG_dcHour = h;
                }
            }
#if MGE_WX_S1D && !MGE_WX_V4 && !MGE_WX_RESCUE
            // -- wxS1dSteadiness's combination (per-branch best)
            if (duskOK)
            {
                float res = colRes;
                if (i < 2 && max(uH.y, uC.y) > 1e-6)
                    res = min(res, rv);
                float rd = wxS1dKD * adDiff;
                res = sqrt(res * res + rd * rd);
                res = sqrt(res * res + rs * rs);
                float s = 1.0 - smoothstep(wxS1dR0, wxS1dR1, res);
                if (b == 0)
                {
                    if (s > s1A)
                    {
                        s1WA = i;
                        s1A = s;
                    }
                }
                else
                {
                    if (s > s1B)
                    {
                        s1WB = i;
                        s1B = s;
                    }
                }
            }
#endif
            // -- mgeStockCalmHoldSky's combination (calm + wide arms)
            if (fillOK)
            {
                if (i < 2)
                {
                    float res = min(colRes, rv);
                    res = sqrt(res * res + rs * rs);
                    float ffw = (i == 0) ? 1.0 : 0.9;
                    float c = 1.0 - smoothstep(0.0392, 0.0784, res);
                    if (c > calmT)
                    {
                        calmT = c;
                        ffT = ffw;
                        iWinT = i;
                        hWinT = h;
                    }
                    float cw = 1.0 - smoothstep(mgeCalmWideR0,
                                                mgeCalmWideR1, res);
                    calmW = max(calmW, cw);
                    accW += cw;
                    accFF += cw * ffw;
                    accSky = accSky + cw * MGE_WX_B4(wxSkyPh, i, wSb);
                }
                else
                {
                    float res = sqrt(colRes * colRes + rs * rs);
                    float rd = mgeCalmDenseKD * adDiff;
                    res = sqrt(res * res + rd * rd);
                    denseW = max(denseW,
                                 1.0 - smoothstep(mgeCalmWideR0,
                                                  mgeCalmWideR1, res));
                }
            }
        }
    }
    wxG_dcDusk = hoursOK;
#if MGE_WX_S1D && !MGE_WX_V4 && !MGE_WX_RESCUE
    // -- wxS1dStabilize's branch race + S1e sun gate, verbatim on the
    // precomputed pair, exported (the conf rewrite + basis pin -- the
    // epilogue -- applies in mgeWxCompute after the races, on these
    // exports; the LB4 reorder). Plus the donated sky-tent hour
    // decisive, else the engaged-tent branch).
    if (duskOK)
    {
        float t1 = wxS1dTwilightTent(hd);
        float t2 = wxS1dTwilightTent(hn);
        float tentRace;
        int wStar;
        float s;
        if (abs(s1A - s1B) < 0.05)
        {
            tentRace = min(t1, t2);
            wStar = (s1A >= s1B) ? s1WA : s1WB;
            s = max(s1A, s1B);
        }
        else if (s1A > s1B)
        {
            tentRace = t1;
            wStar = s1WA;
            s = s1A;
        }
        else
        {
            tentRace = t2;
            wStar = s1WB;
            s = s1B;
        }
        float lum = dot(sunC, vec3(0.299, 0.587, 0.114));
        float gate = smoothstep(wxS1dSunLo, wxS1dSunHi, lum);
        wxG_dcTent = tentRace + gate * (max(t1, t2) - tentRace);
        wxG_dcWStar = wStar;
        wxG_dcS = s;
        wxG_dcHSky = (abs(s1A - s1B) >= 0.05) ? ((s1A > s1B) ? hd : hn)
                                              : ((t1 >= t2) ? hd : hn);
    }
#endif
    if (fillOK)
    {
        // -- mgeStockCalmHoldSky's tail, verbatim
        float aClassic = calmT * (1.0 - smoothstep(0.85, 1.05, d));
        float aCorr = calmW * (1.0 - denseW)
                    * (1.0 - smoothstep(0.85, mgeCalmWideD1, d));
        vec3 skyT = MGE_WX_B4(wxSkyPh, iWinT, wxPhaseW(hWinT, wxWinSky));
        vec3 sky;
        float calm;
        float ff;
        if (accW <= 1e-9)
        {
            sky = skyT;
            calm = aClassic;
            ff = ffT;
        }
        else
        {
            float sel = smoothstep(-0.05, 0.05, aCorr - aClassic);
            float invW = 1.0 / accW;
            sky = mix(skyT, accSky * invW, sel);
            calm = max(aClassic, aCorr);
            ff = mix(ffT, accFF * invW, sel);
        }
        wxG_holdSky = vec4(sky, calm);
        wxG_holdFF = ff;
        wxG_holdV2 = hoursOK * calm;
        wxG_holdWNight = duskOK ? wxPhaseW(hd, wxWinFog).w : 0.0;
    }
}

// The calm-hold v2 reader (declaration above mgeGetNiceWeather).
float mgeCalmHoldV2(float confDec, out vec3 calmSky)
{
    calmSky = wxG_holdSky.xyz;
    return wxG_holdV2 * (1.0 - confDec);
}

// search measured 9.9 ms per 4K screen-coverage on the 5090 (vs v1's
// 0.06 ms steady) -- the huge unrolled body sets register pressure /
// occupancy for every fragment regardless of the dynamic path, so the
// fast path buys nothing. The scene therefore runs this compact v1
// Day/Night race (identical to the old shipped search over the v2
// tables' pure-phase rows); the omwfx passes keep the full v2 core
// (one screen instance, ~1.6 ms) and correct the far field. Scene-side
// dusk/varied states return conf 0 here -> consumers take their
// heuristics, as they did pre-v2.
float wxSearchLite(vec3 fc, float d, int ph,
                   out int iOut, out int jOut, out float alphaOut)
{
    iOut = 0;
    jOut = 0;
    alphaOut = 0.0;
    // Steady fast path (v1 form; tolerances as the sim).
    for (int i = 0; i < 10; ++i)
    {
        vec3 aF = wxFogPh[i * 4 + 1 + 2 * ph];
        float aD = (ph == 0) ? wxDepthDN[i].x : wxDepthDN[i].y;
        if (abs(d - aD) < 0.005 && length(fc - aF) < 0.012)
        {
            iOut = i;
            jOut = i;
            return 1.0 - smoothstep(0.0392, 0.0784, length(fc - aF));
        }
    }
    float bestRes = 1e9;
    for (int i = 0; i < 10; ++i)
    {
        vec3 fcA = wxFogPh[i * 4 + 1 + 2 * ph];
        float dA = (ph == 0) ? wxDepthDN[i].x : wxDepthDN[i].y;
        for (int j = i + 1; j < 10; ++j)
        {
            vec3 fcB = wxFogPh[j * 4 + 1 + 2 * ph];
            float dB = (ph == 0) ? wxDepthDN[j].x : wxDepthDN[j].y;
            float dd = dB - dA;
            float alpha;
            if (abs(dd) > 0.02)
            {
                alpha = (d - dA) / dd;
                if (alpha < -0.05 || alpha > 1.05)
                    continue;
                alpha = clamp(alpha, 0.0, 1.0);
            }
            else
            {
                if (abs(d - dA) > 0.02)
                    continue;
                vec3 seg = fcB - fcA;
                float den = dot(seg, seg);
                if (den < 1e-9)
                    continue;
                alpha = clamp(dot(fc - fcA, seg) / den, 0.0, 1.0);
            }
            float res = length(fc - mix(fcA, fcB, alpha));
            if (res < bestRes)
            {
                bestRes = res;
                iOut = i;
                jOut = j;
                alphaOut = alpha;
            }
        }
    }
    return 1.0 - smoothstep(0.0392, 0.0784, bestRes);
}

// verdict, blind at dusk corridors - engagement domain measured empty
// in-game; the variation duty moved to the Correct pass, MGE_R2V) and
// (docs/retired-mechanisms.md, MGE_SCAT_ROLL_RECOVERY). The globals
// and the mgeWxVScat* varyings stay declared, permanently zero, so
// the removal is a pure dead branch (preprocessed output unchanged);
// linkers strip unused varyings.
float wxG_scatW = 0.0;
vec3 wxG_scatOut = vec3(0.0);
vec3 wxG_scatIn = vec3(0.0);
// The recovery solver (wxScatTryHour/wxScatRecover) lived here;
// MGE_SCAT_ROLL_RECOVERY).

void mgeWxCompute()
{
    // Patched engine: consumers take the engine-uniform paths -- skip
    // the search at runtime, except while a weather transition is
    // running: the corridor endpoint-reveal (wxRevealFog) needs (i,j)
    // on Full too, since the engine uniforms carry
    // only blended colours. Cost is corridor-scoped by construction.
    // Every other Full consumer keeps its engine-uniform path:
    // mgeDerivedFog returns on the endpoint-uniform path first, and
    // the nice/sky/fog readers early-out to engine truth before their
    // est code.
    if (mgeWeatherUniforms > 0.5
#if MGE_CORRIDOR_REVEAL
        && !(mgeFogParamsNext.z > 0.001 && mgeFogParamsNext.z < 0.999)
#endif
    )
        return;
    // Fog-off sentinel / invalid range: no weather signal exists here.
    if (gl_Fog.end <= 1.0 || gl_Fog.end > 1000000.0)
        return;

    vec3 fc = gl_Fog.color.xyz;
    float d = 1.0 - gl_Fog.start / gl_Fog.end;

    // Sun source = the established scene idiom (mgeParityProbe /
    // mgeScatterWithSun): mgeSunDir when the patched engine feeds it
    // (dead here in practice - the engine-uniform early-out above fires
    // first), else light 0 through the view inverse, exactly the
    // interior detector's read; interiors return no hour signal and the
    // resolver no-ops. Moved before the races (the LB4 reorder: the
    // chain needs sunW and the bypass gate needs the chain) - pure,
    // value-identical.
    vec3 sunW = vec3(0.0);
    if (dot(mgeSunDir, mgeSunDir) > 1e-4)
        sunW = normalize(mgeSunDir);
    else
    {
        vec3 slp = lcalcPosition(0);
        if (dot(slp, slp) > 1e-6)
            sunW = normalize(
                (osg_ViewMatrixInverse * vec4(normalize(slp), 0.0)).xyz);
    }
    // resolver, the S1d stabilizer and the calm-hold fill share one
    // (branch-hour x anchor) grid evaluation - wxDuskChain above. Each
    // consumer's gating is internal and mirrors the pre-fold call
    // sites exactly (invalid sun/hours -> resolver + S1d no-op, fill
    // takes the 12/0 fallback; the fill-half is stock-gated). Since
    // races and exports candidates (wxG_dc*) instead of writing the
    // verdict; adoption + the S1e epilogue apply below, after the
    // races - output-bit-identical plumbing, section [6]-gated.
    wxDuskChain(fc, d, lcalcDiffuse(0), sunW);
    // owns conf and the sky-hour is donated - both lite races are
    // skipped (uniform-coherent branch: a branched-off body is free,
    // keep their conf-0 incumbents (i=j=0, alpha 0, hour 12), exactly
    // the sim kind's resolver-only front.
    bool lb4 = false;
#if MGE_WX_LITE_BYPASS && MGE_WX_S1D && !MGE_WX_V4 && !MGE_WX_RESCUE
    wxG_lb4Hour = 12.0;   // self-resetting (fail-safe + oracle harness)
    wxG_lb4W = 0.0;
    lb4 = wxG_dcTent > 0.999;
#endif
    if (!lb4)
    {
        // v1 Day/Night race (day preferred on ties), hour = the
        // pure-phase hour so the sky-tent readers degenerate to the
        // Day/Night tables. Note (v4): the pre-134 early `return`s at
        // conf >= 0.999 became nested guards -- confident twilight
        // winners are exactly the crack class and must reach the v4
        // epilogue below; the sim (v3 -> v4 call order) is the
        // reference for this ordering.
        int i2;
        int j2;
        float a2;
        float c1 = wxSearchLite(fc, d, 0, wxG_i, wxG_j, wxG_alpha);
        wxG_hour = 12.0;
        wxG_conf = c1;
        if (c1 < 0.999)
        {
            float c2 = wxSearchLite(fc, d, 1, i2, j2, a2);
            if (c2 > c1)
            {
                wxG_i = i2;
                wxG_j = j2;
                wxG_alpha = a2;
                wxG_hour = 0.0;
                wxG_conf = c2;
            }
        }
    }
    // argmax form of the old in-loop race - winner identity unchanged):
    // the lite race has no dusk representation, so steady dusk read
    // conf 0 and the far field painted the navy blue-ratio fallback.
    bool sdAdopt = wxG_dcDusk > 0.5 && wxG_conf < 0.999
                   && wxG_dcCand > wxG_conf;
    if (sdAdopt)
    {
        wxG_i = wxG_dcI;
        wxG_j = wxG_dcI;
        wxG_alpha = 0.0;
        wxG_hour = wxG_dcHour;
        wxG_conf = wxG_dcCand;
    }
#if MGE_WX_S1D && !MGE_WX_V4 && !MGE_WX_RESCUE
    // -- wxS1dStabilize's epilogue (conf rewrite + basis pin), verbatim
    if (wxG_dcDusk > 0.5 && wxG_dcTent > 0.0)
    {
        if (wxG_dcWStar >= 0)
        {
            wxG_conf = (1.0 - wxG_dcTent) * wxG_conf
                     + wxG_dcTent * wxG_dcS;
            if (wxG_dcTent > 0.5)
            {
                wxG_i = wxG_dcWStar;
                wxG_j = wxG_dcWStar;
                wxG_alpha = 0.0;
            }
        }
        else
            wxG_conf = (1.0 - wxG_dcTent) * wxG_conf;
    }
#endif
#if MGE_WX_LITE_BYPASS && MGE_WX_S1D && !MGE_WX_V4 && !MGE_WX_RESCUE
    if (lb4)
    {
        // in-gate: donate the sky-tent hour (348 rule) unless the
        // resolver won (its wins keep their exact hours). The donated
        // hour cannot reach the reveal / roll recovery (i == j here).
        if (!sdAdopt && wxG_dcWStar >= 0)
            wxG_hour = wxG_dcHSky;
    }
    else if (wxG_dcDusk > 0.5 && !sdAdopt && wxG_dcWStar >= 0)
    {
        // out-of-gate: the sky-tent consumer blends toward the donated
        // hour by gate proximity (the boundary smoothing; weight 0
        // below tent 0.90 keeps byte identity there).
        wxG_lb4Hour = wxG_dcHSky;
        wxG_lb4W = smoothstep(0.90, 0.999, wxG_dcTent);
    }
#endif
#if MGE_WX_V4
    if (dot(sunW, sunW) > 0.5)
        wxV4Refine(fc, d, lcalcDiffuse(0), sunW, wxG_i, wxG_j, wxG_alpha,
                   wxG_hour, wxG_conf);
#endif
#if MGE_WX_RESCUE
    // transition is exactly representable by the full core, race it at
    // the sun-recovered hours (wxDecomposeCore handles an invalid sun
    // internally: hours 12/0, ksun 0, the v1-race degeneration) and
    // adopt a strictly better verdict. Runs outside the sun-valid guard
    // on purpose, mirroring sim decompose_scene_v5 (oracle-gated).
    if (wxG_conf < 0.9)
    {
        int ri;
        int rj;
        float ra;
        float rh;
        float rc = wxDecomposeCore(fc, d, sunW, lcalcDiffuse(0),
                                   ri, rj, ra, rh);
        if (rc > wxG_conf)
        {
            wxG_i = ri;
            wxG_j = rj;
            wxG_alpha = ra;
            wxG_hour = rh;
            wxG_conf = rc;
        }
    }
#endif
    // (S1d and the calm-hold fill now live inside wxDuskChain above -
    // kill-switch and full-core-exclusion guards inside the fold;
    // the fill half keeps the stock gate and the 12/0 fallback.)
}

// Core-search reader: recovered (weather i, weather j, alpha, hour) from
// the cache. hourOut is the winning candidate hour - consumers blend
// their own 4-phase tables (sky uses the Sky tent) at this hour.
float mgeDecomposeIdx(out int iOut, out int jOut, out float alphaOut, out float hourOut)
{
    iOut = wxG_i;
    jOut = wxG_j;
    alphaOut = wxG_alpha;
    hourOut = wxG_hour;
    return wxG_conf;
}

// Envelope view of the decomposition (mgeDerivedFog, water waves).
float mgeDecomposeWeather(out vec2 fffoA, out vec2 fffoB, out float alphaOut)
{
    int i;
    int j;
    float hour;
    float conf = mgeDecomposeIdx(i, j, alphaOut, hour);
    fffoA = mgeWxFFFO[i];
    fffoB = mgeWxFFFO[j];
    return conf;
}

// Sky-colour + nice view (mgeGetNiceWeather, fog.glsl mgeSampleSkyCol).
// The blended outputs are already lerped to alpha - unlike the envelope
// view, no consumer needs these per-endpoint.
float mgeDecomposeSkyNice(out vec3 skyBlend, out float niceBlend)
{
    int i;
    int j;
    float hour;
    float alpha;
    float conf = mgeDecomposeIdx(i, j, alpha, hour);
    // Sky anchors blend by the sky tent (its windows differ from the fog
    // tent's) at the recovered hour; in the no-sun fallback hour is 12/0
    // and this degenerates to the old Day/Night sky selection.
    vec4 wS = wxPhaseW(hour, wxWinSky);
    skyBlend = mix(MGE_WX_B4(wxSkyPh, i, wS), MGE_WX_B4(wxSkyPh, j, wS), alpha);
#if MGE_WX_LITE_BYPASS && MGE_WX_S1D && !MGE_WX_V4 && !MGE_WX_RESCUE
    // the bypass gate, when the search kept the lite 12/0 hour, blend
    // toward the donated hour's sky by gate proximity - continuous at
    // the gate boundary, weight 0 below tent 0.90 (byte identity).
    // Mirror: sim lb4_sky_from.
    if (wxG_lb4W > 0.0)
    {
        vec4 wSd = wxPhaseW(wxG_lb4Hour, wxWinSky);
        vec3 skyD = mix(MGE_WX_B4(wxSkyPh, i, wSd),
                        MGE_WX_B4(wxSkyPh, j, wSd), alpha);
        skyBlend = mix(skyBlend, skyD, wxG_lb4W);
    }
#endif
    niceBlend = mix(wxNice[i], wxNice[j], alpha);
    // MGE squares the blended nice (distantland.cpp adjustFog:
    // niceWeather *= niceWeather; the patched engine replicates it at
    // weather.cpp:922-924 before feeding the uniform). Without the square
    // the scatter ran at double the Full tier's weight at mid-transition
    // whole storm arrival - measured in screenshot 1248: terrain 0.79 vs
    // its own convergence sky 0.74.
    niceBlend *= niceBlend;
    return conf;
}
#elif MGE_WX_STAGE
// out, the public entry points collapse to the documented conf-0
// fail-safe -- every consumer composes its pre-decomposition fallback
// (raw split-ladder fog via mgeGetFogParams, ladder waves, heuristic
// every consumer shader (the guard compiled out these definitions
// while their callers stayed); verified compiling + conf-0 by
// check_glsl_decomposer section [5], which also carries the
// stripped-stub negative control so this branch cannot rot silently.
void mgeWxCompute() {}

float mgeDecomposeIdx(out int iOut, out int jOut, out float alphaOut, out float hourOut)
{
    iOut = 0;
    jOut = 0;
    alphaOut = 0.0;
    hourOut = 12.0;
    return 0.0;
}

float mgeDecomposeWeather(out vec2 fffoA, out vec2 fffoB, out float alphaOut)
{
    fffoA = vec2(1.0, 0.0);
    fffoB = vec2(1.0, 0.0);
    alphaOut = 0.0;
    return 0.0;
}

float mgeDecomposeSkyNice(out vec3 skyBlend, out float niceBlend)
{
    skyBlend = vec3(0.0);
    niceBlend = 0.0;
    return 0.0;
}
#endif // MGE_ENDPOINT_DECOMPOSITION

#if MGE_WX_STAGE
// call this repeatedly per fragment, mgeScatterWithSun reads .w for the
// night flip on every scatter call, so since the
// stock ladder + calm-hold rode along 2-3x per fragment. Computed once;
// any returned p has x >= 0.16 (ladder floor) or the uniform value, so
// x = -1 is a safe not-yet sentinel.
vec4 mgeFogParamsCache = vec4(-1.0, 0.0, 0.0, 0.0);
vec4 mgeGetFogParams() // (ff, fo, isExterior, isDay)
{
    if (mgeFogParamsCache.x >= 0.0)
        return mgeFogParamsCache;
    vec4 p = mgeFogParams;
    if (p.x < 0.01)
    {
        p = vec4(1.0, 0.0, 1.0, 1.0); // Clear weather defaults, exterior, day
        if (mgeWeatherUniforms < 0.5)
        {
            // light 0 the fixed vector (-1, 0.785, 0.785) ("total
            // nonsense but it's what Morrowind uses",
            // renderingmanager.cpp setSunColour path), whose Y is
            // positive, while the exterior orbit position is
            // (400*orbit, -75, ...) - Y always negative, preserved by
            // the water-mirror flip (z-only). One sign test separates
            // them and routes interiors to the MGE linear-fog branch,
            // closing the "authored interior fog >= 0.69 depth reads as
            // dense weather" exposure.
            vec3 lp = lcalcPosition(0);
            if (dot(lp, lp) > 1e-6
                && (osg_ViewMatrixInverse * vec4(normalize(lp), 0.0)).y > 0.0)
                p.z = 0.0;
            // Stock estimator (block comment above). The d-guard keeps
            // light-fog interiors and the fog-off sentinel on Clear.
            else if (gl_Fog.end > 1.0 && gl_Fog.end < 1000000.0)
            {
                float d = 1.0 - gl_Fog.start / gl_Fog.end;
                if (d > 0.65)
                {
                    // Fog-tent night weight for the split ladder
                    // interior detector reads. Invalid sun (night
                    // moonlight, sentinel) -> day arm: the floor is
                    // effectively unused there (night states decompose
                    // confidently - inventory 148: night 90/90 clean).
                    // hour recovery and the calm-hold run once in
                    // wxHoldFill (mgeWxCompute) - this reads the
                    // globals. Reachability: this block requires stock +
                    // exterior + valid range + d > 0.65, and every
                    // WX_STAGE-1 flow calls mgeWxCompute first (emitter
                    // top), so the fill has run whenever this is read.
                    // At define-0 wNight stays 0 -> day-arm ladder, the
                    // pre-152 floor.
                    float wNight = 0.0;
#if MGE_ENDPOINT_DECOMPOSITION
                    wNight = wxG_holdWNight;
#endif
                    p.xy = mgeStockWeatherFF(d, wNight);
#if MGE_ENDPOINT_DECOMPOSITION
                    // still fits the calm family, keep ff above the
                    // dense knees and fade fo - kills the onset
                    // cream-cutout regime flip.
                    p.x = max(p.x, wxG_holdSky.w * wxG_holdFF);
                    p.y *= 1.0 - wxG_holdSky.w;
#endif
                }
            }
        }
    }
    mgeFogParamsCache = p;
    return p;
}
#endif // MGE_WX_STAGE (fog params)
// WX_KILLSWITCH_COVERAGE_END (check_glsl_decomposer section [5] compiles
// WX_TABLES_BEGIN..here under MGE_ENDPOINT_DECOMPOSITION 0/1 x scene/water

#if MGE_WX_STAGE
// True weather sky colour: on a patched engine it is fed live; on stock
// it is an analytic estimate from the fog palette. moved here from
// fragment-only references, and the vertex stage must compute it. The
// full provenance comment lives with the history in git; the short form:
// weather-exact MGG ratios via the phase-segment classifier, vanilla
// ratio-table fallback, decomposition mix (conf-gated), calm-hold v2.
#if MGE_ENDPOINT_DECOMPOSITION && MGE_SKYCOL_CORRIDOR_UNIFY
float mgeWxtNiceGate(); // defined below; forward-declared for the
                        // corridor unification block (GLSL 120 needs
                        // declaration before call)
#endif
vec3 mgeSampleSkyCol()
{
    if (mgeWeatherUniforms > 0.5)
        return mgeSkyColor; // live from the engine weather system
    vec3 segSky; float segWEst; float segWGate;
    mgeMggSegmentSky(segSky, segWEst, segWGate);
    // Fallback tier for fogs off the MGG path (e.g. a vanilla-palette
    // install): the classic vanilla-derived ratio table.
    float skyD = 1.0 - gl_Fog.start / max(gl_Fog.end, 1.0);
    vec3 est = gl_Fog.color.xyz;
    if (gl_Fog.end > 1.0 && gl_Fog.end < 1000000.0 && skyD > 0.65)
    {
        float t = clamp((skyD - 0.69) / 0.03, 0.0, 1.0);
        // Blueness gate on the ratio product: valid only for clear-family
        // fog; ungated it painted navy from warm transition fog
        // (screenshot 1288, +0.022 blue excess).
        float blueOK = clamp(8.0 * (gl_Fog.color.b - gl_Fog.color.r), 0.0, 1.0);
        vec3 ratio = mix(vec3(0.4612, 0.5947, 0.7961), vec3(0.4776, 0.6809, 0.9598), t);
        est = mix(gl_Fog.color.xyz, gl_Fog.color.xyz * ratio, blueOK);
    }
    est = mix(est, segSky, segWEst);
#if MGE_ENDPOINT_DECOMPOSITION
    // transitions: the decomposed sky is the per-weather sky anchors
    // lerped at the recovered endpoints - the correct trajectory by
    // 0 at steady off-palette states, where the chain above is the
    // better estimator.
    {
        vec3 skyDec; float niceDec;
        float confDec = mgeDecomposeSkyNice(skyDec, niceDec);
        est = mix(est, skyDec, confDec);
#if MGE_CALM_HOLD_V2
        // the calm family at conf 0, pull the estimate toward the winning
        // calm anchor's sky tent (est rides the raw hold weight; the nice
        // consumer rides a knee - see mgeGetNiceWeather).
        vec3 calmSkyE;
        float wV2 = mgeCalmHoldV2(confDec, calmSkyE);
        est = mix(est, calmSkyE, wV2);
#endif
    }
#endif
    float wxSkyW = mgeGetNiceWeather();
#if MGE_ENDPOINT_DECOMPOSITION && MGE_SKYCOL_CORRIDOR_UNIFY
    // top): mid nice->storm corridor the nice mix below slides skyCol
    // toward the (blue, on Clear) fog colour while Full's engine sky
    // stays on the palette blend, ride the mix weight to 1 during
    // confident corridors so both tiers feed the wall the same sky.
    {
        int uI;
        int uJ;
        float uA;
        float uH;
        float uC = mgeDecomposeIdx(uI, uJ, uA, uH);
        float uT = (uI == uJ) ? 0.0 : 4.0 * uA * (1.0 - uA);
#if MGE_WXT_NICE_GATE
        uT *= mgeWxtNiceGate();
#endif
        wxSkyW = mix(wxSkyW, 1.0, uC * min(1.0, 4.0 * uT));
    }
#endif
    return mix(gl_Fog.color.xyz, est, wxSkyW);
}

// directly; the emitter below also packs them into mgeWxVRev for the
// fragment readers. Fall back to today's values when the decomposition
// is compiled out or the switches are off.
vec3 mgeRevealFogBase()
{
#if MGE_ENDPOINT_DECOMPOSITION && MGE_CORRIDOR_REVEAL
    int rvI; int rvJ; float rvA; float rvH;
    float rvC = mgeDecomposeIdx(rvI, rvJ, rvA, rvH);
    return wxRevealFog(gl_Fog.color.xyz, rvI, rvJ, rvC, rvH);
#else
    return gl_Fog.color.xyz;
#endif
}
float mgeWxtNiceGate()
{
#if MGE_ENDPOINT_DECOMPOSITION && MGE_WXT_NICE_GATE
    int rvI; int rvJ; float rvA; float rvH;
    mgeDecomposeIdx(rvI, rvJ, rvA, rvH);
    return (wxNice[rvI] > 0.5 && wxNice[rvJ] > 0.5) ? 0.0 : 1.0;
#else
    return 1.0;
#endif
}

// consumer .vert main(); packs every frame-constant product the fragment
// consumers read. All values identical to the pre-hoist per-fragment
// computation (same expressions, same per-pass uniforms).
void mgeWxEmitVaryings()
{
    mgeWxCompute();
    int wxi; int wxj; float wxa; float wxh;
    float wxc = mgeDecomposeIdx(wxi, wxj, wxa, wxh);
    mgeWxVIdx = vec4(wxc, wxa, wxh, float(wxi) * 10.0 + float(wxj));
    vec3 sb; float nb;
    mgeDecomposeSkyNice(sb, nb);
    mgeWxVDec = vec4(sb, nb);
    vec2 eA; vec2 eB; float ea;
    mgeDecomposeWeather(eA, eB, ea);
    mgeWxVEnv = vec4(eA, eB);
    mgeWxVFog = mgeGetFogParams();
    mgeWxVSky = vec4(mgeSampleSkyCol(), mgeGetNiceWeather());
    mgeWxVRev = vec4(mgeRevealFogBase(), mgeWxtNiceGate());
    mgeWxVScatO = vec4(wxG_scatOut, wxG_scatW);
    mgeWxVScatI = vec4(wxG_scatIn, 0.0);
}

// Scatter triplet accessor, stage flavor: preset/uniform baseline plus
// the recovered daily roll at the corridor weight. one site so wall,
// dome, seal and water scatter shift together, a wall-only shift would
void mgeScatterTriplets(out vec3 sOut, out vec3 sIn)
{
    sOut = (mgeScatterUniformsOn > 0.5) ? mgeOutscatterU : mgeOutscatter;
    sIn = (mgeScatterUniformsOn > 0.5) ? mgeInscatterU : mgeInscatter;
}
#else // !MGE_WX_STAGE: fragment-decode readers (scene verdict hoist)
// The est model is not compiled in this unit. Every reader returns the
// verdict emitted by the paired vertex stage; interfaces and call sites
// are unchanged, so consumer code is identical in both modes.
void mgeWxCompute() {}
float mgeDecomposeIdx(out int iOut, out int jOut, out float alphaOut, out float hourOut)
{
    // i*10+j round-decode: exact for all 0..99 under the equal-value
    // interpolation epsilon (same recipe as the SkyEst Debug RT decode).
    float pk = floor(mgeWxVIdx.w + 0.5);
    iOut = int(floor((pk + 0.5) / 10.0));
    jOut = int(pk) - 10 * iOut;
    alphaOut = mgeWxVIdx.y;
    hourOut = mgeWxVIdx.z;
    return mgeWxVIdx.x;
}
float mgeDecomposeWeather(out vec2 fffoA, out vec2 fffoB, out float alphaOut)
{
    fffoA = mgeWxVEnv.xy;
    fffoB = mgeWxVEnv.zw;
    alphaOut = mgeWxVIdx.y;
    return mgeWxVIdx.x;
}
float mgeDecomposeSkyNice(out vec3 skyBlend, out float niceBlend)
{
    skyBlend = mgeWxVDec.xyz;
    niceBlend = mgeWxVDec.w;
    return mgeWxVIdx.x;
}
vec4 mgeGetFogParams() { return mgeWxVFog; }
float mgeGetNiceWeather() { return mgeWxVSky.w; }
vec3 mgeSampleSkyCol() { return mgeWxVSky.xyz; }
vec3 mgeRevealFogBase() { return mgeWxVRev.xyz; }
float mgeWxtNiceGate() { return mgeWxVRev.w; }
// Scatter triplet accessor, reader flavor (the retired recovery's
// varyings carry zeros; see the roll-recovery block).
void mgeScatterTriplets(out vec3 sOut, out vec3 sIn)
{
    sOut = (mgeScatterUniformsOn > 0.5) ? mgeOutscatterU : mgeOutscatter;
    sIn = (mgeScatterUniformsOn > 0.5) ? mgeInscatterU : mgeInscatter;
}
#endif // MGE_WX_STAGE

// Weather-transition endpoint policy (the uniforms are declared in the
// top block): the fog ranges below contain knee-shaped terms (dense
// pull-in, layer gates) that ramp over a narrow ff band; deriving from
// the blended ff would compress their whole visual change into a
// fraction of a transition. Instead derive at both endpoint weathers
// and lerp the derived values: endpoint looks are unchanged and the
// transition path is even.

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
    MgeFogDerived s = mgeDeriveFogAt(p.x, p.y);
#if MGE_ENDPOINT_DECOMPOSITION
    // Stock tier: recover the transition endpoints and lerp derived values,
    // conf-mixed with the single-envelope path above, conf 0 (steady
    // mismatch, sentinel pass, lightning flash, dawn/dusk) is byte-identical
    // to the pre-decomposition behaviour. Interiors are excluded: their
    // authored fog has no weather to decompose (p.z carries the interior
    // detector's verdict).
    if (p.z > 0.5)
    {
        vec2 eA, eB;
        float ea;
        float conf = mgeDecomposeWeather(eA, eB, ea);
        if (conf > 0.001)
        {
            MgeFogDerived a = mgeDeriveFogAt(eA.x, eA.y);
            MgeFogDerived b = mgeDeriveFogAt(eB.x, eB.y);
            s.expStart = mix(s.expStart, mix(a.expStart, b.expStart, ea), conf);
            s.expDiv   = mix(s.expDiv,   mix(a.expDiv,   b.expDiv,   ea), conf);
            s.fogEnd   = mix(s.fogEnd,   mix(a.fogEnd,   b.fogEnd,   ea), conf);
            s.wDense   = mix(s.wDense,   mix(a.wDense,   b.wDense,   ea), conf);
            s.wLayer   = mix(s.wLayer,   mix(a.wLayer,   b.wLayer,   ea), conf);
        }
    }
#endif
    return s;
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
// Stock-exe mirrored-pass detection (water-reflection RTT). On stock,
// programs rendered into that RTT (sky and scene: probe history shows
// per-program binding gaps, and the reflected-terrain blackout confirms
// the scene side) have no usable light 0 and no mgeSunDir, so the
// scatter's sun fallback is garbage - a below-horizon sun zeroes the
// whole scatter term (sim-confirmed exact black). Callers use this to
// fall back to the palette base in mirrored passes. isReflection alone
// is not enough: it provably does not bind in the reflection's sky
// program, hence the handedness determinant channel.
bool mgeStockMirrored()
{
    if (mgeWeatherUniforms > 0.5)
        return false; // patched engine: mgeSunDir makes scatter pass-safe
    if (isReflection)
        return true;
    mat3 vm = mat3(osg_ViewMatrixInverse);
    return dot(vm[0], cross(vm[1], vm[2])) < 0.0;
}

// The entry-32 medium fix assumed the reflection camera's inverse-view
// translation is the mirrored position; the bright-water regression says
// some pass violates that, and the triangle-fix observation contradicts
// the opposite reading too - the RELATIVE_RF composition order must be
// measured, not derived (three derivations produced three consistent
// wrong answers). Flip to 1, take one above-water shot of calm water and
// one submerged: every fog-touched fragment paints
//   R = clamp(0.5 + camZ/200)  (camZ = osg_ViewMatrixInverse[3].z:
//       0.5 = z 0, 0.7 = z +40, 0.3 = z -40)
//   G = 1 if this pass is mirrored (handedness/isReflection), else 0
//   B = 0.5 constant
// The water surface shows the reflection pass's values as the reflected
// content's colour; direct land shows the main pass. The pair answers:
// what is camZ in the mirrored pass for a viewer above (+40 -> R 0.7,
// mirrored -> R 0.3) and below - which decides the correct
// mgeCamAboveWater mirrored-branch test.
#define MGE_MIRROR_PROBE 0

bool mgeCamAboveWater()
{
    if (mgeWeatherUniforms < 0.5)
    {
        // Stock-exe fallback (Redux Plus tier) - measured form
        // reflection view is composed view-space (scale(1,1,-1)*
        // translate(0,0,2h) applied after the parent view), so
        // osg_ViewMatrixInverse[3] is the viewer's own position in every
        // pass - mirrored ones included (probe: reflected geometry
        // painted the viewer's +z above water and the viewer's shallow
        // -z submerged). One universal test therefore covers main,
        // reflection and refraction passes alike; a submerged viewer's
        // reflection content correctly takes the murk. Near-zero
        // water-level assumption as documented; fog-sentinel utility
        // cameras (preview, local map) never reach this (the sentinel
        // branch precedes every consumer).
        return osg_ViewMatrixInverse[3].z >= -1.0;
    }
    return !viewerUnderwater || isRefraction;
}

// ==== Parity input probe (diagnostic, normally 0) ====
// False-colours every fog-touched fragment with the actual scatter
// inputs, for pixel-decoding from screenshots when Full and Redux Plus
// disagree visually while all reasoned inputs claim equality:
//   R = sunWorld.z * 0.5 + 0.5  (the sun the scatter actually uses;
//       also detects game-hour drift between comparison sessions)
//   G = 1 when the light-0 guard fired (no usable sun in this program)
//   B = niceWeather
#define MGE_PARITY_PROBE 0
// Probe v6 - the per-program sun. Every fog-touched fragment shows the
// sun its own program's scatter would use:
//   G = 1 when the light-0 guard fired (vertical-sun fallback)
//   B = 0.5 constant (sanity)
// Regions whose R/G differ from the near-field's have a degenerate sun -
// the far-silhouette suspects.
vec3 mgeParityProbe()
{
    float guard = 0.0;
    vec3 sunWorld;
    if (dot(mgeSunDir, mgeSunDir) > 1e-4)
        sunWorld = normalize(mgeSunDir);
    else
    {
        vec3 lp = lcalcPosition(0);
        if (dot(lp, lp) > 1e-6)
            sunWorld = normalize((osg_ViewMatrixInverse * vec4(normalize(lp), 0.0)).xyz);
        else
        {
            guard = 1.0;
            sunWorld = vec3(0.0, 0.0, 1.0);
        }
    }
    return vec3(sunWorld.z * 0.5 + 0.5, guard, 0.5);
}

// Probe v3 - content probe: geometry is colour-striped by distance band
// (one hue per cell, cycling 8), sky is black. A screenshot from each exe
// shows exactly which geometry is submitted at which distance - the
// far-band population difference the flat probes hid.
vec3 mgeContentProbe(float dist)
{
    float band = floor(dist / 8192.0);
    return 0.5 + 0.5 * cos(6.2832 * (band * 0.618 + vec3(0.0, 0.33, 0.67)));
}

// ==== Scatter-uniform link probe (diagnostic, normally 0) ====
// patched engine yet the screen is pin-invariant, and the whole static
// chain (declarations, consumers, mRootNode stateset, exe vintage) reads
// intact. This probe splits the remaining runtime question in one capture:
// every fog-touched fragment false-colours to the uniform state its own
// program received:
//   R = mgeScatterUniformsOn   (0 -> near-black frame: the values never
//       reached this program - engine/stateset/apply side; 1 -> bright)
//   G = mgeInscatterU.g * 1.5  (pin s3 expects ~0.41, pin s6 ~0.48)
//   B = mgeOutscatterU.b * 0.7 (pin s3 expects ~0.66, pin s6 ~0.31)
// Verdict table (Full install, MGE_SkyEst_Debug chain tolerated - hue
// classes survive the post response): all-black = uniforms never
// set/applied in GL; coloured but pin-invariant = stale values reach the
// programs; pink (s3) vs orange (s6) flip = the engine link is live and
// the gap sits in consumption or measurement. Stock exe (Redux Plus)
// paints black by construction - the built-in negative control.
#define MGE_SCATTER_UNIFORM_PROBE 0
vec3 mgeScatterUniformProbe()
{
    return vec3(mgeScatterUniformsOn,
                clamp(mgeInscatterU.g * 1.5, 0.0, 1.0),
                clamp(mgeOutscatterU.b * 0.7, 0.0, 1.0));
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
// Submersion depth of the viewer, world units, on both tiers. Same source
// and the same near-zero water-level assumption mgeCamAboveWater documents;
// osg_ViewMatrixInverse[3] is the viewer's own position in every pass,
// superseding 454's fitted exponential). XE fogs underwater linearly from
// Below Water Fog Start -0.5 cells to End 0.3 cells (src/mge/inidata.h),
// and the engine already feeds exactly those numbers into gl_Fog.start/end
// while submerged (fogmanager.cpp, 'mge underwater fog start/end cells').
// 454 fitted an exponential to that line because a linear chord had once
// drawn a hard horizontal ring - but the ring was a symptom of one
// consumer converging while its neighbours did not. With every from-below
// consumer routed through this single owner, the full-fog ring at
// gl_Fog.end has nothing to contrast against: the medium, the terrain, the
// seabed and the water surface all arrive at the same colour there, which
// is precisely how XE looks. The exponential's tail was also visible:
// it never reaches zero, so distant terrain kept ~2x XE's silhouette
// contrast at 2.4k u ("distant terrain isn't properly murked", frame
// 3523; simulations/sim_uw_holistic.py).
// Stock-exe fallback (Redux Plus tier): the setting doesn't exist there
// and stock's underwater gl_Fog range is the far-too-thin vanilla one, so
// bake XE's own -0.5/0.3 cells.
const float MGE_UW_FOG_START = -0.5 * 8192.0;
const float MGE_UW_FOG_END = 0.3 * 8192.0;
const float MGE_UW_COLOUR_DEPTH = 1500.0;   // the reference the mechanic uses
const float MGE_UW_COLOUR_FLOOR = 0.15;     // never fully black

float mgeUwDepthFactor()
{
    return clamp(-osg_ViewMatrixInverse[3].z / MGE_UW_COLOUR_DEPTH, 0.0, 1.0);
}

// both water-surface fades in water.frag and the murk pass must converge
// and at 807 u the surface seen from below converged ~2x brighter than
// everything around it - hard-edged flat spots where the murk's dark
// target met the fades' bright one.
vec3 mgeUwFogColour()
{
    return gl_Fog.color.xyz * max(1.0 - mgeUwDepthFactor(),
                                  MGE_UW_COLOUR_FLOOR);
}

// The from-below transmittance: XE's linear fog law on the engine-fed
// distances. every consumer goes through here - the scene fog and both
// water-surface fades - because splitting them is what banded the
// veil: the negative fog start), T(gl_Fog.end) = 0 exactly.
float mgeUwTrans(float dist)
{
    float s = gl_Fog.start;
    float e = gl_Fog.end;
    if (mgeWeatherUniforms < 0.5 || !(e > 1.0 && e < 1000000.0 && e > s))
    {
        s = MGE_UW_FOG_START;
        e = MGE_UW_FOG_END;
    }
    return clamp((e - dist) / max(e - s, 1.0), 0.0, 1.0);
}

// Core scatter equation: XE Common.fx fogColourScatter nice branch,
// verbatim (live 0.18 constants). fogdist in [0,1]. Explicit-sun entry
// point: callers that need the scatter under a known sun (the vertical-sun
// RTT rebase in fog.glsl) pass it directly; mgeScatter below resolves the
// pass's own sun first. The night flip lives here so both paths share it.
vec3 mgeScatterWithSun(vec3 dir, float fogdist, vec3 skyCol, vec3 sunWorld)
{
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
    vec3 scIn;
    vec3 scOut;
    mgeScatterTriplets(scOut, scIn);   // baseline + roll recovery (225)
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
    vec3 scIn;
    vec3 scOut;
    mgeScatterTriplets(scOut, scIn);   // baseline + roll recovery (225)
    vec3 sunscatter = mix(scIn, scOut, 0.5 * (1.0 + suncos));
    vec3 att = atmdep * sunscatter * (sunaltitude_a + 0.7 * mie);
    att = (1.0 - exp(-fogdist * att)) / att;

    vec3 colour = vec3(0.125 * mie) + newSkyCol * rayl;
    colour *= att * (1.17 * atmdep + 0.89) * sunaltitude_b;
    return colour;
#endif
}

// Pass-sun resolver + scatter (the general entry point).
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
        // Mirrored stock passes: light 0 reaches the shader in the main
        // camera's frame, so unprojecting with the mirrored camera's
        // inverse yields the true sun with z exactly negated
        // (inv(V*M)*(V*s) = M*s; sim_mirror_sun.py verifies for arbitrary
        // camera bases). A below-horizon sun zeroes the scatter - that
        // was the black/faint/purple reflected-terrain family. Restoring
        // z reproduces the true-sun scatter exactly. Stock daytime sun
        // never has z < 0 in a mirrored pass (OpenMW's night sun also
        // rides above the horizon), so the flip cannot misfire.
        if (mgeStockMirrored() && sunWorld.z < 0.0)
            sunWorld.z = -sunWorld.z;
    }
    return mgeScatterWithSun(dir, fogdist, skyCol, sunWorld);
}

// MGE_MIRROR_SEAL_WIDEN: in mirrored passes, start the horizon seal at
// pairs with fog.glsl's MGE_SKY_BLEND_MIRROR_GATE). The main view
// conceals far geometry from skyBlendingStart outward by blending to
// the real rendered sky; a mirrored pass cannot run that blend (the
// sky RTT is main-camera-only), so with the gate alone its far land
// would stay a partially-fogged silhouette that the direct view no
// longer shows, the reported "reflection without a source". Widening the
// seal to the same window makes the mirror conceal exactly where the
// main view conceals, by the dome convergence the main view already
// uses at the horizon. Main-camera rendering is untouched by
// construction (the branch rides isReflection/mgeStockMirrored).
// 0 restores the 0.88 seal in mirrors byte-exact for A/B.
#ifndef MGE_MIRROR_SEAL_WIDEN
#define MGE_MIRROR_SEAL_WIDEN 1
#endif

// converge the fog base toward the directional dome law at the
// skyBehind term's own weight, and give the widened seal the same
// dome target. The direct view converges fogged geometry to the
// measured rendered sky (skyBehind); no reflection pass can have that
// RTT, so mirrored reflections kept an unconverged composition and
// measured ~1.5x the direct view's land-vs-local-sky relation on the
// pass's own composition at the fragment's direction - the mirror's
// best reachable stand-in for the RTT. sim_mirror_arm.py proves the
// form is the skyBehind law verbatim with the dome as target (I3
// identity below the seal window) and that the shared seal target
// removes the skyBehind pattern's nice*(1-nice) scatter surplus at
// mid-corridor (its I1 finding). Main view untouched by construction.
// 0 = off byte-exact (the post-392, pre-conv mirror composition).
#ifndef MGE_MIRROR_DOME_CONV
#define MGE_MIRROR_DOME_CONV 1
#endif

// Scalar above-water fog transmittance at a distance: the XE
// fogColourWater alpha (pure exp - water skips the near-linear fit and
// the height layer), from the same derived envelope the full composer
// uses, so there is exactly one law. Consumer: water.frag's displaced
float mgeAWWaterTransmittance(float dist)
{
    MgeFogDerived dv = mgeDerivedFog();
    return clamp(exp(-(dist - dv.expStart) / dv.expDiv), 0.0, 1.0);
}

// fogColour(): rgb = inscattered light, a = transmittance.
// Apply as: scene' = a * scene + rgb   (XE Common.fx fogApply)
// useNearLinear: XE fogColour (land/objects) switches to the vanilla
// linear near fog inside nearViewRange; fogColourWater is pure exp.
vec4 mgeFogColourWorld(float dist, vec3 dirWorld, float far, vec3 skyCol, bool useNearLinear, vec4 skyBehind)
{
#if MGE_PARITY_PROBE
    return vec4(mgeParityProbe(), 0.0);
#endif
#if MGE_SCATTER_UNIFORM_PROBE
    return vec4(mgeScatterUniformProbe(), 0.0);
#endif
#if MGE_MIRROR_PROBE
    {
        // probe painted every pass, so the water fragment's own main-pass
        // paint replaced the sampled reflection and no mirrored data
        // reached the screen. Now the main pass fogs normally and the
        // water's reflection component displays the reflection pass's
        // encoding: R = 0.5 + camZ/200 (0.5 = z 0), G = 1 (mirrored
        // marker), B = 0.25. Bright green-tinted reflections = mirrored
        // pass reached; R decodes its camera z. Compare the reflected
        // colour above water vs submerged.
        float camZmp = osg_ViewMatrixInverse[3].z;
        mat3 vmP = mat3(osg_ViewMatrixInverse);
        if (isReflection || dot(vmP[0], cross(vmP[1], vmP[2])) < 0.0)
            return vec4(clamp(0.5 + camZmp / 200.0, 0.0, 1.0), 1.0, 0.25, 0.0);
    }
#endif
    // Fog-off convention: utility RTT cameras (local map, character preview)
    // "disable" fog by setting gl_Fog.start/end = 1e7 ("shaders don't
    // respect glDisable(GL_FOG)", localmap.cpp). The absolute world-unit
    // ranges here must honour that sentinel or map tiles get hazed.
    if (gl_Fog.start > 1000000.0)
    {
        // 0.51 feeds the water-refraction camera the sentinel fog
        // (water.cpp; isRefraction/setViewerFog are the patch's
        // additions), so above-water trees rendered for a submerged
        // viewer had NO atmosphere - very visible through calm water.
        // This pass is uniquely identifiable on stock: sentinel fog +
        // submerged non-mirrored camera (utility cameras sit above
        // z = -1; the near-zero-water-level assumption is the tier's
        // documented one). No weather signal exists here (gl_Fog IS the
        // sentinel), so approximate with the Clear ff=1 envelope and the
        // MGG Clear day sky anchor, weighted by the nice heuristic
        // (its sun gate works in this pass and kills the haze at night
        // and in dim weathers - conservative under-fogging, never wrong
        // extra haze).
        if (mgeWeatherUniforms < 0.5 && osg_ViewMatrixInverse[3].z < -1.0
            && !mgeStockMirrored())
        {
            float nice = mgeGetNiceWeather();
            if (nice > 0.001)
            {
                float x = (dist - 4096.0) / 9216.0; // Clear: ff=1, fo=0, era-2020 scale
                float fogR = clamp(exp(-x), 0.0, 1.0);
                float fdR = clamp(mgeInscatterDistScale * x, 0.0, 1.0);
                const vec3 mggClearSky = vec3(0.52549, 0.52941, 0.53725);
                // standard nice-weather application: inscatter = scatter at
                // this fogdist (the att integral carries transmittance),
                // T = fog; nice-weighted toward the no-fog identity.
                vec3 rgbR = nice * mgeScatter(dirWorld, fdR, mggClearSky);
                return vec4(rgbR, 1.0 - nice * (1.0 - fogR));
            }
        }
        return vec4(0.0, 0.0, 0.0, 1.0);
    }

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
        // full-fog ring at gl_Fog.end cannot read as a line because the
        // water surface, seabed, terrain and the reflection/refraction
        // fades in water.frag all converge to gl_Fog.color on this same
        // law - at the ring everything is one colour, exactly as in XE.
        float T = mgeUwTrans(dist);
        // `underwaterColor = default * (1 - depthFactor)` in the source mechanic.
        // Note it keys on depth alone there - no night-eye, no clarity - so
        // it needs nothing from Lua and belongs here in the core, where every
        // submerged pixel already reads this colour.
        // The reference stays the original's 1500, not our 600 murk depth: at
        // 600 this would reach black in water the original barely dimmed.
        // the floor only engages past ~1275 u, deeper than Morrowind water
        // goes, where the original was heading to near-black anyway.
        vec3 uwFogCol = mgeUwFogColour();
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
#if MGE_HEIGHT_FOG_PLAYER_BASELINE
        float dz = (osg_ViewMatrixInverse[3].z + dirWorld.z * dist) - playerPos.z;
#else
        float dz = dirWorld.z * dist;
#endif
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
    // corridor exposes is the storm endpoint's palette, not the blend
    // (whose nice-endpoint half is a blue no steady frame shows).
    // Steady/off-corridor/conf-0: identical to gl_Fog.color.
    vec3 fogBase = gl_Fog.color.xyz;
#if MGE_CORRIDOR_REVEAL
    fogBase = mgeRevealFogBase();
#endif
    // Stock zenith fallback: skyCol (the direction-locked sky-RTT sample
    // on stock, see fog.glsl) instead of the old gl_Fog.color. With the
    // fog colour as zenith the whole convBase was fog-coloured, so far
    // geometry in reflection passes (skyBehind is disabled there)
    // converged to bright fog while the main view converged to the real
    // darker sky - the white-distant-reflections mismatch over dark water.
    vec3 zenith = (mgeWeatherUniforms > 0.5) ? mgeSkyColor : skyCol;
    vec3 convBase = mix(fogBase, zenith, hSky);
    // The real-sky sample carries the cloud image; at partial fog on near
    // geometry it would paint a screen-fixed cloud pattern onto walls.
    // The sky image belongs in the convergence only when the fragment is
    // nearly saturated (a silhouette against the sky), so it is weighted
    // in by saturation: light haze converges to the flat colour
    // (pattern-free), full fog to the exact sky pixel.
    if (skyBehind.a > 0.5)
        convBase = mix(convBase, skyBehind.rgb, smoothstep(0.55, 0.92, 1.0 - fog));
#if MGE_MIRROR_DOME_CONV
    // top): the skyBehind convergence above, with the dome law
    // standing in for the RTT a mirrored pass cannot have. The dome
    // is computed from the pre-convergence convBase (the sky pass's
    // own law) and reused as the seal target below - one consistent
    // sky for everything a mirror melts into. mgeGetNiceWeather()
    // here equals the `nice` computed later: the wxT suppression it
    // docs/retired-mechanisms.md, MGE_STOCK_CORRIDOR_SUPPRESS).
    // Cost: one mgeScatter eval, mirrored passes only.
    vec3 wxMirDome = vec3(0.0);
    float wxMirOn = 0.0;
    if ((isReflection || mgeStockMirrored()) && skyBehind.a < 0.5)
    {
        float mcN = mgeGetNiceWeather();
        wxMirDome = convBase;
        if (mcN > 0.001)
            wxMirDome = mix(convBase, mgeScatter(dirWorld, 1.0, skyCol), mcN);
        wxMirOn = 1.0;
        float mcw = smoothstep(0.55, 0.92, 1.0 - fog);
        if (mcw > 0.001)
            convBase = mix(convBase, wxMirDome, mcw);
    }
#endif
    vec3 rgb = (1.0 - fog) * convBase;

    // wxT is the retired 101/102 scatter-suppression weight: always 0
    // docs/retired-mechanisms.md). The declaration and its consumer
    // below stay so the retirement is a pure dead-branch removal
    // (preprocessed output unchanged); compilers fold the zero.
    float wxT = 0.0;   // scatter-suppression weight (retired, always 0)
    float wxTc = 0.0;  // clamp weight (steeper fade, see the clamp)
    float wxHs = 0.0;  // hue-convergence weight
#if MGE_ENDPOINT_DECOMPOSITION
    // feeds it (i,j,conf) on Full mid-transition, and outside a
    // corridor the engine-uniform early-out leaves conf 0, steady
    // states bit-exact by the same mechanism as stock.
    {
        int wxi;
        int wxj;
        float wxa;
        float wxh;
        float wxc = mgeDecomposeIdx(wxi, wxj, wxa, wxh);
        float wxt = (wxi == wxj) ? 0.0 : 4.0 * wxa * (1.0 - wxa);
#if MGE_WXT_NICE_GATE
        // nice<->nice pairs: the storm-glow justification cannot apply
        // and the suppression itself injected the palette blue
        wxt *= mgeWxtNiceGate();
#endif
#if MGE_FULL_LUM_CLAMP
        wxTc = wxc * min(1.0, 2.0 * wxt);
#else
        if (mgeWeatherUniforms < 0.5)
            wxTc = wxc * min(1.0, 2.0 * wxt);
#endif
        // at the family 2x curve the fix sat at 0.42 weight at f=0.055,
        // where the early-corridor cool fog bank is fully visible
        // (measured on matched frames: the artifact halved exactly
        // proportionally to the weight), so
        // the steeper ramp shrinks the visible window to ~f < 0.03. The
        // entry-flip step grows to ~0.012 (visibility-floor scale),
        // accepted against the 3-8x larger sustained artifact.
        wxHs = wxc * min(1.0, 4.0 * wxt);
    }
#endif

    float nice = mgeGetNiceWeather() * (1.0 - wxT);
    // Mirrored stock passes need no scatter gate here: mgeScatter's
    // sun z-correction recovers the true sun in those passes, so
    // reflected fogged terrain scatters identically to the direct view.
    if (nice > 0.001)
        rgb = mix(rgb, mgeScatter(dirWorld, fogdist, skyCol), nice);

    // Horizon seal: with the 2020-era fog scale the inscatter distance
    // caps at 0.224*4 = 0.896 at the view edge, so the farthest water/land
    // only reaches ~97% of the sky dome's colour, leaving a dark line
    // where the sea meets the sky. Blend the final stretch of the view
    // distance to the analytic dome colour for this direction (scatter at
    // fogdist=1, or palette fog in bad weather), which is the colour the
    // sky shows behind the far plane by construction.
    float sealA = 0.88;
    float sealB = 0.995;
#if MGE_MIRROR_SEAL_WIDEN
    // mgeFogColourWorld): in mirrored passes the seal takes over the
    // engine sky-blend's window, so far land melts into the dome where
    // the direct view melts into the rendered sky. 0.80 mirrors the
    // skyBlendingStart default; 0.96 completes well inside the far
    // plane (the wrong-position blend it replaces had already fully
    // substituted the fragment there).
    if (isReflection || mgeStockMirrored())
    {
        sealA = 0.80;
        sealB = 0.96;
    }
#endif
    float seal = smoothstep(sealA, sealB, dist / far);
    if (seal > 0.001)
    {
        vec3 domeBad = convBase;
        vec3 domeCol = mix(domeBad,
            (nice > 0.001) ? mgeScatter(dirWorld, 1.0, skyCol) : domeBad, nice);
#if MGE_MIRROR_DOME_CONV
        // Mirrored passes seal to the same dome the convergence above
        // used (computed from the pre-convergence convBase):
        // recomputing from the converged convBase leaves a
        // nice*(1-nice) scatter surplus against the rendered sky at
        // mid-corridor (sim_mirror_arm's I1, measured -0.062 worst) -
        // the direct view masks the same term with its sky-blend
        // epilogue, a mirror has no epilogue to hide it behind.
        if (wxMirOn > 0.5)
            domeCol = wxMirDome;
#endif
        rgb = mix(rgb, domeCol, seal);
        fog *= 1.0 - seal;
    }


    // Seamless-horizon invariant, stock side: handled at the input level -
    // mgeSampleSkyCol's stock branch uses weather-exact palette ratios
    // (fog.glsl), so scene scatter equals the dome's scatter exactly in
    // steady nice weather, same as the patched engine. Converging output
    // over-melts: Full's residual silhouette visibility IS the difference
    // between analytic (cloudless) convergence and the cloud-textured sky
    // behind, which output-side convergence erases.

#if MGE_ENDPOINT_DECOMPOSITION
    // transition brightness clamp (the invariant: distant terrain must
    // With the scatter mix suppressed above, this demotes from stopgap
    // to backstop, with two 102-round upgrades from the sim envelope:
    // - The ceiling is the measured sky behind (skyBehind RTT
    //   row-average) where available: the real sky is cloud-darkened
    //   below its palette, and the palette ceiling let terrain ride up
    //   to 0.017 lum brighter than the actual sky. Palette fallback
    //   (fog vs sky estimate, the 101 form) where the RTT is absent
    //   (reflections, underwater refraction, sky blending off).
    // - Faded by conf * min(1, 2 * 4a(1-a)) - full enforcement across
    //   the whole mid-band; the plain 4a(1-a) fade let half the scatter
    //   excess through at the half-gate states (a ~ 0.15 / 0.85).
    // Chroma preserved (uniform scale). Bit-exact at every steady state
    // (weight 0 at i == j; on Full additionally conf 0 outside a
    // clamp also runs on Full mid-corridor (MGE_FULL_LUM_CLAMP): the
    // unclamped Full glow measured up to +0.070 lum above the sky on
    // Cloudy->Ashstorm.
    if (wxTc > 0.001)
    {
        const vec3 wxLumW = vec3(0.299, 0.587, 0.114);
        float wxSkyL = (skyBehind.a > 0.5)
            ? dot(skyBehind.rgb, wxLumW)
            : max(dot(gl_Fog.color.xyz, wxLumW), dot(skyCol, wxLumW));
        float wxCeil = wxSkyL * (1.0 - fog);
        float wxL = dot(rgb, wxLumW);
        if (wxL > wxCeil && wxL > 1e-5)
            rgb *= mix(1.0, wxCeil / wxL, wxTc);
#if MGE_WXT_SKY_HUE
        // corridor hue convergence (the clamp's chroma sibling, switch
        // comment at the top): the fog term's hue converges to the
        // measured sky behind at the same weight, luminance-preserving.
        // RTT-only: no palette fallback (it would re-introduce the very
        // palette hue the corridor work removes).
        // at full weight on thin near haze this would undo the reveal's
        // storm-consistent hue on near geometry (up to 0.09 B-R modelled
        // on Clear<->Ashstorm). The sky is the hue reference only where
        // the fragment is a silhouette against it -- the same
        // smoothstep(0.55, 0.92, saturation) the skyBehind convergence
        // above uses. Ridge-class content (saturation >= 0.92, where
        // the artifact was measured) keeps the full raced correction;
        // near haze keeps the reveal's palette hue.
        // both tiers (history: gated Full-only in 204 as the blotch A/B;
        // 205's A/B exonerated this transform -- the blotches were the
        // Correct pass's stale scene model, fixed by R2 (206-208). With
        // the collider gone, RP's mid-distance band showed the same
        // cloud-blind blue this transform fixes on Full (209/R2b:
        // prediction on 2272-2278: collapses to <= +0.05 worst-bound,
        // ~0 mid-corridor). The far-plane band stays the pass's
        // territory -- this transform is saturation-scoped and its
        // silhouette-class content is sky-converged on both tiers.
        if (skyBehind.a > 0.5)
        {
            float wxSbL = dot(skyBehind.rgb, wxLumW);
            float wxRl = dot(rgb, wxLumW);
            float wxHw = wxHs * smoothstep(0.55, 0.92, 1.0 - fog);
            if (wxSbL > 1e-5 && wxRl > 1e-5 && wxHw > 0.001)
                rgb = mix(rgb, skyBehind.rgb * (wxRl / wxSbL), wxHw);
        }
#endif
    }
#endif
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
#if MGE_PARITY_PROBE
    return mgeParityProbe(); // v6: the sky shows its program's sun too
#endif
#if MGE_SCATTER_UNIFORM_PROBE
    return mgeScatterUniformProbe(); // the dome shows its program's uniforms
#endif
    float h = mgeSkyFogH(dirWorld.z);
    // the wall: the corridor exposes the storm endpoint's palette, not
    // the blend. Steady/off-corridor/conf-0: identical to gl_Fog.color.
    vec3 fogBaseSky = gl_Fog.color.xyz;
#if MGE_CORRIDOR_REVEAL
    fogBaseSky = mgeRevealFogBase();
#endif
    vec3 base = mix(fogBaseSky, zenithCol, h);
#if !MGE_STOCK_MIRRORED_SKY_SCATTER
    // Mirrored stock passes: the palette base is stable and bright; the
    // historical black-reflected-sky family motivated this early-out,
    // which predates the mirror sun z-unflip in mgeScatter - see the
    // MGE_STOCK_MIRRORED_SKY_SCATTER toggle above.
    if (mgeStockMirrored())
        return base;
#endif
    float nice = mgeGetNiceWeather();
    // The dome half of the 101/102 scatter suppression lived here;
    // ahead of the banks at corridor entry, the early pale-bright
    // (MGE_STOCK_CORRIDOR_SUPPRESS, docs/retired-mechanisms.md).
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
