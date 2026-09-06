#ifndef MGE_WATER_DATA_GLSL
#define MGE_WATER_DATA_GLSL

// ---------------------------------------------------------------------------
// Water tuning data, the compile-time half of the water configuration.
//
// Everything the core water shader needs lives here, because core shaders
// cannot receive Lua uniforms and so cannot be driven from the in-game Scripts
// menu. Changing anything in this file needs a game restart.
//
// The other half of the configuration is live and in-game:
//   Options -> Scripts (underwater effects)  feature toggles, per-weather
//                                            clarity, vampire sun damage
//   F2 -> MGE_Underwater_Effects             depth-clarity intensities
//
// Feature sources: weather-driven waves and depth clarity after NullCascade's
// the MWSE weather-driven water mod; caustics, water types and foam after Rafael's
// "Enhanced Water for OpenMW". Both re-implemented for this stack rather than
// ported verbatim.
// ---------------------------------------------------------------------------

// ---- feature switches (1 = on) --------------------------------------------
#define MGE_WATER_WEATHER_WAVES   1   // wave height responds to the weather
#define MGE_WATER_CAUSTICS        1   // light caustics on submerged surfaces
#define MGE_WATER_TYPES           1   // per-region water colour/behaviour
#define MGE_WATER_FOAM            1   // foam on steep wave faces and shores
#define MGE_FOAM_VOLUME           0   // 1 = real MGE XE frames from a 4x4 atlas
                                      //     in the alpha; 0 = offset cross-dissolve
#define MGE_FOAM_DEBUG            0   // paint R=foam texture G=drive B=foam
#define MGE_FOAM_CREST_FIELD      1   // field-driven whitecaps;
                                      // 0 = the texture-driven mask
#define MGE_FOAM_SWASH_V2         1   // constructed 1-D swash;
                                      // 0 = the texture-driven swash
#define MGE_UW_REFR_EDGE_GUARD    1   // from-below refraction edge guard
#define MGE_UW_GRAZE_MURK         1   // from-below grazing-transmission murk
#define MGE_WAVE_DETAIL_DISTFADE  1   // fade detail-normal xy to 0 by
                                      // FADE_END (XE getFinalWaterNormal
const float MGE_WAVE_DETAIL_FADE_END = 12000.0; // XE 8000 x1.5
#define MGE_WATER_REFL_FILTER     1   // XE FILTER_WATER_REFLECTION port
                                      // (six-tap reflection blur, the
                                      // shimmer's sampling-side remedy,

// From below, the refraction offset was never depth-guarded (the shore
// nullifier is cameraPos.z > 0 only), so ripple offsets sample the
// above-water RTT across object silhouettes: thin bright halos around
// above-water objects and washed-bright thin silhouettes under a dark
// sky. Through a smooth surface the offset is ~0 and there is no
// offset where the distorted depth sample crosses a break larger than
// this, i.e. where the offset lands on a different surface (object <->
// sky, near <-> far object); ripples over open sky or within one
// surface keep their wobble. World units of linearized depth.
#if MGE_UW_REFR_EDGE_GUARD
const float MGE_UW_EDGE_DEPTH = 2500.0;
#endif

// the edge guard cleaning the smear, near-waterline objects read
// "fully visible without being fogged and no sky above them"). The
// physics gate the void fill already uses - from below, transmission
// dies toward grazing and the surface shows the water's own medium -
// applied only to far-plane texels, so objects at the same grazing
// angles rendered raw against the murk-filled backdrop. One shared
// ramp for every from-below refraction texel: objects and backdrop
// fade together into the medium as the view flattens; a diver looking
// steeply up (viewDir.z above the HI edge) keeps the true sky and
// crisp objects.
#if MGE_UW_GRAZE_MURK
const float MGE_UW_GRAZE_LO = 0.10;   // full murk at/below this viewDir.z
const float MGE_UW_GRAZE_HI = 0.55;   // untouched above this
#endif

// Wave shape. OpenMW's water surface is a flat plane (every vertex Z is
// literally 0 - components/sceneutil/waterutil.cpp:36-39), so the stock
// "waves" are entirely a normal-map lighting trick with no height at all.
// These two switches add a real height field - not real geometry, which would
// need an engine change - after Rafael's Enhanced Water.
//
//   WAVE_SHAPES   builds the surface normal from the gradient of a real wave
//                 height function instead of from a normal-map tap. Cheap
//                 (three height evaluations). Gives waves a genuine directional
//                 shape that tiling normal maps cannot produce.
//   WAVE_RAYMARCH marches the view ray against that height field per pixel, so
//                 the surface gains real parallax and self-occlusion. Requires
//                 WAVE_SHAPES. Considerably more expensive - leave it off on a
//                 weak GPU.
//
// Staged deliberately: WAVE_SHAPES may be most of the visible win on its own,
// in which case the raymarch is an optional quality tier. See
// docs/water-raymarch-port-plan.md.
#define MGE_WATER_WAVE_SHAPES     0
#define MGE_WATER_WAVE_RAYMARCH   0

// Full-tier displaced wave geometry (docs/full-water-geometry-design.md,
// displacement path into water.vert/water.frag; the runtime gate is the
// fork-fed uniform mgeWaterDisplace (unset = 0 on a stock exe, and the fork
// feeds 1 only while the radial mesh is live), so a stock engine running
// this build is bit-identical in behaviour either way. deploy_water.py
// overrides per target: 1 on the Full install + the water-layer
// package, 0 elsewhere.
#define MGE_WATER_DISPLACE        0

// achieve such parity on RP?" - yes: neither device needs the patched
// engine). 1 = the fresnel normal fades toward flat/vertical with the
// water fog's transmittance and grazing+distance (XE Mod Water.fx:246-249)
// and the vertical reflection distortion is downward-only (:243), on the
// strength-scaled fresnel ceiling (MGE_WAVE_FRESNEL_MAX) composes with the
// pair instead of standing down: the pair owns distance glare, the ceiling
// owns the near faces our sharper-than-XE field creates.
// 0 = ceiling-only glare handling on both paths (no XE pair, symmetric
// distortion) - the pre-427 state, byte-exact.
#define MGE_WATER_XE_ANTIGLARE    1

// "why can't our texture normals here be soft?" - they can, and XE proves
// the license). Measured from XE's own water_NRM texture: its baked shading
// normals run p50 6.7 / p99 18.4 deg and never scale with waveHeight - at
// storm, XE shades ~calm-soft normals over full-height displaced geometry.
// Our field's shading slope at strength 0.5 reproduces that distribution
// (6.4/17.4 measured). So the displaced path's shading-normal strength is
// min(true, this) - calm stays calm, storms keep their geometry but shade
// XE-soft. Raymarch tier unaffected (there the normal IS the wave and must
// scale). 0.0 = shading follows the field on both paths, byte-exact.
// a soft gel: deep-water shading tilt ran 0.46x the raymarch tier's, the
// same halving that cost the surf its life inshore. It was bought for
// storm glare, and glare no longer needs it - the fresnel ceiling and
// XE's adjustnormal pair already hold the mirror-patch fraction at 0.000
// still fires at 0.635 on the 428-era law, so it is a live detector).
// 0.8 restores 0.69x of the reference structure and keeps a nod to XE's
// softer baked normals; 1.0 (freeze off) is available and also clean.
#define MGE_WAVE_SHADE_REF_S      0.8

// own water_NRM volume texture as the displaced path's height and shading
// field - the original Wonders-of-Water sea verbatim. a = height, rg = the
// baked shading normals (amplitude-frozen by construction - XE's storm
// trick), w = time (0.4*time, a 2.5 s loop). Displacement scales:
// 1104/3900 u blended by dist/8000; shading adds the 527 u close scale
// (getFinalWaterNormal). Runtime-gated by mgeWaterXeField, which the fork
// feeds 1 only when the volume actually loaded - asset absent means the
// procedural field serves, never black water. Raced in
// simulations/sim_xe_field_race.py: our 384x120 mesh samples this field
// better than XE's own 150x120 at every radius, so the window is XE's
// verbatim 6400. 0 = the procedural-field displaced path, byte-exact.
//
// cauldron"): measured, the texture's real features are 70-140 u (the
// 1104 is only the tiling period), morphing in place at every scale and
// decorrelating within ~a second - it structurally cannot travel (the
// morph destroys pattern identity faster than its ~55 u/s drift) and has
// no long swells. Rendered as geometry that IS a boiling cauldron. The
// texture stays shipped for its measured statistics (amplitude reference,
// the frozen-shading distribution ported in 430) and as a comparison
// toggle; the procedural field - travelling, directional, longer-waved
// than XE's real content - is the displacement.
#define MGE_WATER_XE_FIELD        0

// waves coming back and forth during storm - is desirable"). The depth
// attenuation keeps a small floor near the waterline so surf washes a
// bounded distance up the beach and exposes a thin retreating strip -
// raced at storm extremes: on a 0.05-slope beach ~90 u of breathing swash
// + ~50 u of run-up, surface never more than 2.5 u below the seabed
// (a receding film, not a gaping trough); full waves still past 90 u of
// depth, and inland crest patches stay impossible (the floor caps crest
// reach at ~7 u above the plane). Scales with weather through the field
// itself. 0.0 = the static waterline (the pure 434 attenuation).
const float MGE_WAVE_SHORE_WASH = 0.15;
// Displacement is capped at the amplitude the local water column can hold:
// att <= (depth - margin) / MAX, so a trough bottoms out margin units above
// the seabed by construction instead of by a fitted ramp. MAX is the storm
// field's trough magnitude with headroom (the battery measures -48.1 u at
// the 0.1 percentile); margin is the receding-film allowance W3 permits.
// MGE XE's from-above water depth fade (XE Mod Water.fx:196-200).
// Measured against stock's rational curve: ours reached the body colour
// far sooner despite the larger constant, so adopting XE's exponential
const float MGE_XE_DEPTH_SCALE = 800.0;
const float MGE_XE_DEPTH_SHORE_POW = 90.0;
const float MGE_WAVE_COLUMN_MAX = 55.0;
// kind behind the outline, while ensuring no angular breaking appears and
// the waves oscillation is synchronous with the foam, while somewhat lesser
// than it"). Inside the surf band the multi-octave field hands over to a
// single smooth 1-D surge running on the foam's own phase constants, and it
// is strictly non-positive: the surface can recede and return but can never
// rise over dry ground, which is the grey edge's trigger ("appears when
// water goes beyond its limit"). Raced in sim_water_shore_mirror --race:
// The shore surge and the foam swash keep their own 138.3 u/s: they are
// the same construct (the surge runs on MGE_FOAM_SURGE_K/_W by design, so
// they stay synchronous by design), and MGE_FOAM_SURGE_W is read by
// the foam on both tiers - speeding it would be an undeclared RP change.
const float MGE_WAVE_SURGE_AMP  = 12.0;  // world units of recession at storm
const float MGE_WAVE_SURGE_BAND = 40.0;  // depth over which it hands over
const float MGE_WAVE_COLUMN_MARGIN = 2.0;
// (XE Mod Water.fx:147-151) lowers the reflection lookup by |disp| so a
// wave face never reads reflected content from below its own surface.
// Every form of it was measured across the horizon by following where a
// fragment fetches its reflection as its elevation varies - content
// reads as continuous when d(sample)/d(elev) stays near 1:
//   raw (as XE has it)   1.21 departure, slope goes negative (-0.21):
//                        the lookup folds back on itself - a hard edge,
//                        and the source of the "unmurked reflection
//                        above the horizon" family (434, 438)
//   capped at own elev   pins 100% of above-horizon samples onto the
//                        horizon row - vertical smears
//   faded by elevation   0.90 departure at 0.02 rad - the reported
//                        cut; and no width helps,
//                        because at swim height the entire visible sea
//                        lies within ~3 deg of the horizon, so a fade
//                        broad enough to be smooth has already removed
//                        the clamp everywhere it is being looked at
//   off                  0.00 departure - continuous by construction
// So the clamp is off on the displaced path, which is exactly the planar
// lookup the raymarch tier has always used and has not been faulted.
// A deliberate XE deviation, and the only form that does not draw a line
// somewhere. 1 restores it for comparison.
#define MGE_WATER_REFL_CLAMP 0
// Depth by which the 430 shading freeze is fully back in force. The freeze
// was bought for open-water glare, so holding it in the surf zone only cost
// the shore its liveliness (439): lift it where the water is shallow.
const float MGE_WAVE_SHADE_SHALLOW = 200.0;

// Set to 1 by water.vert before including this file: trims the
// fragment-only machinery (wave normals, the raymarch) out of the vertex
// compile. Never set anywhere else; 0 = the full file, exactly as before.
#ifndef MGE_WATER_VERTEX_STAGE
#define MGE_WATER_VERTEX_STAGE    0
#endif

// Baked coastline table (generated per load order; stub ships zero segments).
#include "mge_shore_data.glsl"


// Should the fine normal-map detail follow the raymarched relief?
//
// 1 is the "correct" answer in principle - the detail would parallax with the
// waves rather than sliding across them. In practice it costs the surface its
// fine texture: texture2D chooses its mip from screen-space derivatives, the
// raymarch lands on a different t for neighbouring pixels, so the derivatives
// blow up and the sampler falls to a coarse mip. The dense stipple of small
// ripples blurs into soft undulations.
//
// Fixing it properly needs explicit-gradient sampling (textureGrad, with the
// derivatives taken from the undisplaced UV), which #version 120 does not offer
// without an extension. Until then, 0. The relief is unaffected either way -
// it comes from the wave normal, which is always evaluated at the displaced
// position. Set to 1 to see the trade for yourself.
#define MGE_WAVE_DETAIL_PARALLAX  0

// Debug: 1 = draw the wave height as greyscale instead of shading the water.
// Useful for confirming the field is alive, oriented and moving before any of
// it reaches the lighting.
#define MGE_WATER_WAVE_DEBUG      0

// Paint the shore query itself onto the water: red = east component of the
// shoreward direction, green = north component (0.5 = zero), blue = influence
// strength. The point is to measure rather than perceive - wave motion is easy
// to misread (a wrong direction facing the camera looks right), a painted
// direction field is not. Compare against the Water Test Kit readout's
// ground-truth line, which computes the same kernel from the full table in Lua.
#define MGE_SHORE_DEBUG           0

// The per-weather amplitude multipliers were a hand-tuned table (NullCascade
// derived from the game's own per-weather wind speeds
// (fallback=Weather_*_Wind_Speed, the same values the engine drives cloud
// motion with), through one response curve fitted so the calm-range anchors
// storm saturates the wave field exactly as before. Deliberate look changes
// a glassy sea under snowfall (the 0.35 taste value is retired); storm foam
// churns slightly faster for Ash/Blight/Blizzard (they cap at Thunder's
// level instead of sitting below it, their wind is higher than Thunder's).
// Weather blends happen in wind, which the engine itself lerps linearly
// through transitions; the curve applies once, after the blend.
// uniform - the engine broadcasts the blended authored wind to every
// shader on both tiers, so waves read it directly and NO reconstruction
// from fog signals remains in the wave path. The constants below are the
// per-weather anchor table: reference data for the queued
// wind-observation round of the weather decomposition (and the human-
// readable record of what the curve was fitted against).
// WX_WIND_BEGIN (generated by scripts/gen_wx_tables.py -- do not hand-edit; regenerate instead)
const float MGE_WIND_CLEAR    = 0.10;
const float MGE_WIND_CLOUDY   = 0.20;
const float MGE_WIND_FOGGY    = 0.00;
const float MGE_WIND_OVERCAST = 0.20;
const float MGE_WIND_RAIN     = 0.30;
const float MGE_WIND_THUNDER  = 0.50;
const float MGE_WIND_ASH      = 0.80;
const float MGE_WIND_BLIGHT   = 0.90;
const float MGE_WIND_SNOW     = 0.00;
const float MGE_WIND_BLIZZARD = 0.90;
// WX_WIND_END
// The wind -> wave-multiplier response curve:
//   wave = min(base + gain * wind^3, cap)
// Cubic because the retired table's calm range demands it (wind 0.2 -> wave
// 0.4 but wind 0.3 -> wave 1.2: tripling across one step). cap bounds the
// derived value where the old table topped out, the wave field saturates at
// strength 1.0 regardless, but mgeFoamRate consumes this scale raw, so an
// uncapped cubic would run storm foam at 10x. Every wind >= ~0.36 caps: all
// four storms, matching the old saturation behaviour.
const float MGE_WAVES_WIND_BASE = 0.06;
const float MGE_WAVES_WIND_GAIN = 42.0;
const float MGE_WAVES_WIND_CAP  = 2.0;

// Converts the weather multiplier above into the 0..1 strength the wave-shape
// height field expects (MGE_WATER_WAVE_SHAPES). The table runs 0.1 at Foggy to
// 2.0 at Thunderstorm, so 0.5 maps a full thunderstorm to open-sea strength and
// keeps every other weather proportional. Raise it to make all weathers rougher
// (they saturate at 1.0 together); lower it for a calmer world overall.
// 0.7 rather than 0.5: it lets every storm (Ash 1.5, Blight 1.8, Thunder 2.0)
// reach full field strength after the water-type multiply, instead of sitting
const float MGE_WAVES_SHAPE_SCALE = 0.7;

// Below this strength the wave field is switched off entirely and the surface
// is exactly the stock MGE XE water - no height field, no frame tilt, nothing.
// Clear resolves to ~0.09 after the water-type multiply, so 0.10 pins Clear to
// the look MGE XE was dialled in for, which is the reference this project is
// trying not to lose. Rescaled above the floor rather than clipped, so Cloudy
// and up still ramp smoothly instead of jumping.
const float MGE_WAVE_CALM_FLOOR = 0.10;

// Overall wave size, ON top of the 0..1 weather strength.
//
// Strength saturates at 1.0 - Thunderstorm on open sea already reaches it - so
// once there, raising the weather table buys nothing. This scales the height
// field itself and is the only way past that ceiling. It multiplies real world
// units: at 1.0 a full storm swell is about +-36 units peak, at 2.0 about +-72
// (a bit over half player height), at 3.0 about +-108.
//
// Raising it steepens wave faces as well as raising crests, since wavelength is
// unchanged - so past roughly 3.0 the sea starts to look corrugated rather than
// large. If you want big slow swells instead of steep ones, this wants pairing
// with a longer wavelength, which lives in the octave constants.
// How fast the wave field itself travels. Amplitude already rises with the
// weather, and a bigger sea moving at the same rate reads as unnaturally quick,
// so this trims the whole field's speed. Applies at every strength.
// which is 69% of the deep-water gravity-wave speed for its own
// wavelength (sqrt(g*lambda/2pi) = 201.6 u/s at 64 units = 1 yard) - a
// true observation, and not the owner of the reported "too viscous" reading.
// This constant is tier-shared, the raymarch tier runs the identical
// 138.3 u/s, and RP does not read as viscous to him. A symptom present
// on one tier cannot be owned by a quantity both tiers share: the owner
// was the Full-only shading freeze (MGE_WAVE_SHADE_REF_S below). Raising
// this was briefly deployed and withdrawn the same day, unmeasured
// against any report. If a faster sea is ever wanted for its own sake it
// is a look decision affecting both tiers, taken on its own evidence.
const float MGE_WAVE_SPEED       = 0.62;

const float MGE_WAVE_AMPLITUDE = 1.4;

// How widely the octaves fan out around the heading, in degrees either side.
//
// Rafael gives each octave its own direction, and he is right to: crossing
// swells are what stop a sea reading as corrugated iron. The problem with his
// values is that the spread is unbounded - dir1 (-0.67, +0.74) against dir2
// (+0.39, -0.92) is a dot of -0.94, i.e. one octave running very nearly
// backwards. Combined with the distance LOD, which fades octaves 3-5 out with
// range, the mix of headings changes with distance too, so near water and far
// water visibly disagree about which way the sea is going.
//
// A fan fixes both while keeping the diversity: every octave sits within
// +-MGE_WAVE_SPREAD of the heading, so they cross each other but none of them
// ever opposes it. 0 = one rigid direction, 30-40 = a lively crossing sea,
// past ~70 the backwards look starts to return.
const float MGE_WAVE_SPREAD = 32.0;

// ---- coast-following waves (Redux Plus method) -----------------------------
// Real waves bend shoreward because they slow in the shallows. See
// docs/water-raymarch-port-plan.md for why this is two problems and why the
// Full tier will solve the first one differently (a baked shore field).
//
// shore = 1: waves come ashore on every coast, via the baked coastline table
// (mge_shore_data.glsl, generated per load order by scripts/bake_coastline.py)
// and a wave rose - six fixed global swell directions whose per-pixel energy
// weights favour the train travelling toward the local shore.
//
// each train's direction is spatially uniform, so the phase-decorrelation
// theorem is respected; the weights come from world-space analytic
// distance-to-segment, so they are smooth (no terrain-triangle squares) and
// view-independent (no swimming). The earlier screen-space estimate failed
// both and is gone. With the stub table (zero segments) this switch compiles
// to nothing.
#define MGE_WATER_WAVE_SHORE      0


// ---- wave rose / baked coast ----------------------------------------------
// Coast influence only exists near the player (the swells are only readable
// there, and this caps the per-pixel table walk). World units.
const float MGE_SHORE_ACTIVE_RANGE = 24576.0;   // 3 cells around the player
// Distance-to-coast band: full shoreward energy inside near, none past far.
const float MGE_SHORE_COAST_NEAR = 4096.0;
const float MGE_SHORE_COAST_FAR  = 20480.0;
// How decisively energy concentrates on the best-aligned train. Higher =
// waves aim more squarely at the shore; lower = broader, softer rose.
const float MGE_SHORE_SHARPEN    = 3.0;
// Kernel width of the nearest-coast blend, world units. Small keeps island
// mazes honest (each islet's own shore wins nearby, with a smooth handover
// mid-channel); large would average opposing shores into nonsense - the
const float MGE_SHORE_KERNEL     = 1024.0;

// The direction the swells travel, in world XY.
//
// Default is exactly where MGE XE's own surface detail goes: every normal-map
// tap scrolls by WIND_DIR = (0.5, -0.8), and a UV offset moves the pattern the
// other way, so stock water has always drifted along (-0.53, +0.848) - roughly
// north-northwest. That diagonal is not new; it was simply unreadable when the
// surface carried nothing but fine ripples, and became obvious the moment there
// were coherent swells to see it in.
//
// Rafael's dir1 sat 10.4 degrees off that, so the swells and the detail drifted
// slightly apart. This pins them together. Edit the vector to aim the sea
// somewhere else - it is normalised at use, so magnitude does not matter.
const vec2 MGE_WAVE_HEADING = vec2(-0.5299989, 0.8479983);

// Reverses the heading. Aim the sea with MGE_WAVE_HEADING; this only flips it.
//
// -1.0 is the default because the octaves advance by dirN * time and adding an
// offset to the sample position moves the pattern the opposite way - so at -1.0
// the swells travel along MGE_WAVE_HEADING as written, which is what makes that
// vector readable. At +1.0 they run against it.
//
// Note this is one global heading: the direction vectors are fixed in world
// space, so waves cannot curve to meet a coastline the way real refracting
// waves do. That would need per-coast refraction, a much bigger job.
//
// Declared here, beside the heading it flips, rather than inside the
// MGE_WATER_WAVE_SHAPES block where it used to live, so that code compiled on
// the pre-wave tier (where that block is absent) may reference it.
const float MGE_WAVE_TRAVEL = -1.0;

// The wave field's travel speed, in world units per second - a reference
// quantity for tuning notes, consumed by nothing at present. derived, not
// chosen: octave 1 samples the noise at worldXY * 0.003 * 0.77 * 1.164, so one
// noise unit spans 371.9 world units, and its argument advances by
// waterTimer * 0.6 * MGE_WAVE_SPEED. 371.9 * 0.6 * 0.62 = 138.3 world units/s,
// against a ~372-unit wavelength - a 2.7 s swell period. If MGE_WAVE_SPEED
// changes, re-derive: speed = 223.1 * MGE_WAVE_SPEED.
//
// History: briefly drove a uniform foam advection at this speed. Removed -
// MGE XE foam has no net travel (see MGE_FOAM_SLOSH) - but the number itself
// keeps earning its keep whenever two water speeds must share units.
const float MGE_WAVE_FIELD_SPEED = 138.3;

// How much rain roughens the fine detail while the height field is active.
//
// Stock trades on rain to imply rough water: rainIntensity pushes bump from
// 0.5 to BUMP_RAIN 2.5 and triples the mid/small normal-map amplitudes. With a
// real height field underneath, that much micro-chop buries the swells - which
// is why Thunderstorm reads as lower than Blight despite a higher wave value,
// and why its surface races (the finest taps scroll fastest, and rain makes
// them dominant). 1.0 = full stock rain roughness, 0 = none.
const float MGE_WAVE_RAIN_CHOP = 0.45;   // ~100 units crest-to-trough at Thunderstorm

// Indoors. Deliberately neutral (1.0): the water-type resolve further down
// already multiplies interior water by MGE_TYPE_INTERIOR.x, so interior calm
// has exactly one owner. Setting this below 1.0 applies the interior factor
// twice - the original code used 0.5 here and 0.5 there and quietly delivered
// 0.25. To make indoor water calmer or flatter, change MGE_TYPE_INTERIOR.x.
const float MGE_WAVES_INTERIOR = 1.0;

// How far the weather may pull the waves away from the engine default.
// 0 = ignore the table above entirely, 1 = apply it at full strength.
const float MGE_WAVES_WEATHER_AUTHORITY = 1.0;

// ---- weather wave strength (shared by water.frag and water.vert) -----------
// vertex displacement and the fragment shading read one strength chain -
// the 171/172 lesson: the height function and everything feeding it must be
// shared exactly between the stages or the shading detaches from the shape.

// Authored per-weather wind speed, transition-blended engine-side by the
// same factor as the fog (weather.cpp:1403); shared root uniform
// (stateupdater.cpp:88), present on stock and patched engines alike.
uniform float windSpeed;

float mgeWeatherWaveScale()
{
    // authored per-weather wind speed to every shader on the shared root
    // stateset (stateupdater.cpp:88/101, fed from renderingmanager.cpp:852),
    // transition-blended by the same factor as the fog (weather.cpp:1403) -
    // on both tiers, stock included. Full provenance and the retired
    // fo-node reconstruction chain: git history of water.frag.
    float w = windSpeed;

    // Wind -> wave multiplier (curve constants above).
    w = min(MGE_WAVES_WIND_BASE + MGE_WAVES_WIND_GAIN * w * w * w,
            MGE_WAVES_WIND_CAP);

    // Interiors. The water-type resolve already multiplies by
    // MGE_TYPE_INTERIOR.x further down, so this term must stay neutral or the
    // interior factor lands twice (the old code applied 0.5 here and 0.5 there,
    // giving 0.25). Interior calm is owned by MGE_TYPE_INTERIOR.x alone.
    float isExterior = clamp(mgeGetFogParams().z, 0.0, 1.0);
    w = mix(MGE_WAVES_INTERIOR, w, isExterior);

    // Authority: how far the weather may pull away from the engine default.
    return mix(1.0, w, clamp(MGE_WAVES_WEATHER_AUTHORITY, 0.0, 1.0));
}

// Defined further down; prototyped so the strength resolve can call it.
void mgeResolveWaterType(vec2 xy, float isInterior, out vec3 typeColour, out vec4 typeParams, out float typeWeight);

// The full wave-strength chain the shape field runs on: weather wind curve,
// water-type factor, the shape-scale mapping and the calm floor. Verbatim
// the block that lived inline in water.frag main() - one owner now, called
// from both stages.
float mgeWaveStrengthResolve(vec2 wxy)
{
    float s = 1.0;
#if MGE_WATER_WEATHER_WAVES
    s = mgeWeatherWaveScale();
#endif
#if MGE_WATER_TYPES
    {
        vec3 tc; vec4 tp; float tw;
        mgeResolveWaterType(wxy, 1.0 - clamp(mgeGetFogParams().z, 0.0, 1.0), tc, tp, tw);
        s *= mix(1.0, tp.x, tw);
    }
#endif
    // Map the weather multiplier (0.1 Foggy .. 2.0 Thunderstorm) onto the 0..1
    // strength the height field expects. scaled, not clamped: a bare clamp to
    // 1.0 would flatten Ashstorm 1.5, Blight 1.8 and Thunderstorm 2.0 onto the
    // same value and destroy exactly the distinction the table exists to make.
    s = clamp(s * MGE_WAVES_SHAPE_SCALE, 0.0, 1.0);
    // Calm floor: below it the field is off and the water is exactly stock MGE
    // XE. Rescaled rather than clipped so the ramp above the floor stays smooth.
    return max(0.0, s - MGE_WAVE_CALM_FLOOR) / max(1.0 - MGE_WAVE_CALM_FLOOR, 0.001);
}

// ---- caustics --------------------------------------------------------------
// Caustics are the moving bands of focused sunlight cast onto submerged
// surfaces by the wavy surface above. They need refraction enabled
// ([Water] refraction = true) because they are applied to the refracted
// scene; with refraction off this whole section is inert.
const float MGE_CAUSTIC_INTENSITY   = 0.40;   // global scale for the from-above
                                              // its own uCausticIntensity in
                                              // MGE_Underwater_Effects.omwfx,
                                              // deliberately untouched)
const float MGE_CAUSTIC_SCALE       = 0.025;  // pattern size (smaller = larger cells)
const float MGE_CAUSTIC_SPEED       = 3.0;    // animation rate
// How far each bright seam is spread. The raw maths draws an exact cell
// boundary - a thin hard web - but water scatters the light before it lands,
// so real seams arrive soft-edged. Averaging the pattern over an area is the
// only thing that reproduces this: reshaping a single sample changes its
// brightness, not the width of the seam.
// 0 = hard web and one sample (cheapest); above 0 costs five samples per
// water pixel, so leave it at 0 on a weak GPU if water costs you frames.
const float MGE_CAUSTIC_SOFTNESS    = 0.25;   // matched to the underwater pass
const float MGE_CAUSTIC_DEPTH_FADE  = 0.002;  // how quickly depth softens the pattern
// Beyond this distance caustics are not evaluated at all (world units).
// Not a look setting: at grazing angles near the horizon the view ray runs
// almost parallel to the surface, so the submerged position is reconstructed
// from a ratio of two near-far-plane depths and loses all precision. The
// Voronoi pattern then degenerates into coherent flat bars rather than noise.
// The pattern is not resolvable at these distances anyway.
const float MGE_CAUSTIC_MAX_DIST    = 12288.0; // 1.5 cells

// ---- water types -----------------------------------------------------------
// (Red, Green, Blue, Absorption). Absorption governs how fast the water
// swallows the refracted scene with depth.
const vec4 MGE_WATER_SEA      = vec4(0.031, 0.092, 0.147, 0.003596);
const vec4 MGE_WATER_CALM     = vec4(0.039, 0.113, 0.107, 0.002296);
const vec4 MGE_WATER_SWAMP    = vec4(0.233, 0.211, 0.131, 0.005296);
const vec4 MGE_WATER_SULPHUR  = vec4(0.093, 0.131, 0.181, 0.002296);
const vec4 MGE_WATER_TROPICAL = vec4(0.200, 0.379, 0.424, 0.002696);
const vec4 MGE_WATER_INTERIOR = vec4(0.063, 0.131, 0.171, 0.002196);

// Per-type behaviour: (wave strength, foam intensity, caustic intensity, shore blend)
const vec4 MGE_TYPE_SEA      = vec4(1.00, 1.00, 0.50, 0.0);
const vec4 MGE_TYPE_CALM     = vec4(0.65, 0.65, 0.40, 0.0);
const vec4 MGE_TYPE_SWAMP    = vec4(0.65, 0.65, 0.40, 0.0);
const vec4 MGE_TYPE_SULPHUR  = vec4(0.40, 0.65, 0.50, 0.0);
const vec4 MGE_TYPE_TROPICAL = vec4(0.80, 1.00, 0.60, 0.0);
const vec4 MGE_TYPE_INTERIOR = vec4(0.50, 0.00, 0.60, 0.0);

// Regions, in world units, as corner pairs, order does not matter, the shader
// normalises them. Each blends into the surrounding sea over its own blend
// distance (negative = the blend happens inside the box, so the border never
// shows as a line). Coordinates are Rafael's from "Enhanced Water for OpenMW",
// which are playtested against the real Vvardenfell map; do not replace them
// with estimates.
//
// The vvBox is a cheap bounding test around every Vvardenfell region, water
// outside it skips the per-region work entirely. Widen it if you add a region
// beyond its edges, or the new region will never trigger.
const vec4 MGE_VV_BOX = vec4(154000.0, 174500.0, -103000.0, -76000.0);

// --- calm water ---
const vec2 MGE_CALM1_A = vec2(  -3500.0,      0.0);   // Odai River
const vec2 MGE_CALM1_B = vec2( -50000.0, -58000.0);
const float MGE_CALM1_BLEND = -3000.0;

const vec2 MGE_CALM2_A = vec2( 136000.0,   5200.0);   // southern Vvardenfell
const vec2 MGE_CALM2_B = vec2( -41000.0, -76000.0);
const float MGE_CALM2_BLEND = -6000.0;

const vec2 MGE_CALM3_A = vec2( -54500.0, 125000.0);   // Gnisis & West Gash
const vec2 MGE_CALM3_B = vec2(-103000.0,  85000.0);
const float MGE_CALM3_BLEND = -2500.0;

const vec2 MGE_CALM4_A = vec2( 154000.0,  69000.0);   // Azura's Coast
const vec2 MGE_CALM4_B = vec2(  82000.0, -67000.0);
const float MGE_CALM4_BLEND = -3000.0;

const vec2 MGE_CALM5_A = vec2(  78000.0, 174500.0);   // Sheogorad
const vec2 MGE_CALM5_B = vec2( -17000.0, 126000.0);
const float MGE_CALM5_BLEND = -3000.0;

// --- swamp ---
const vec2 MGE_SWAMP1_A = vec2( -30500.0,  56500.0);  // Gnaar Mok / Bitter Coast
const vec2 MGE_SWAMP1_B = vec2( -70500.0, -39000.0);
const float MGE_SWAMP1_BLEND = -3000.0;

// --- sulphur (radial, not a box) ---
const vec2  MGE_SULPHUR1_POS    = vec2(43565.0, -16194.0);  // Lake Nabia
const float MGE_SULPHUR1_RADIUS = 15000.0;

// ---- wave shape field ------------------------------------------------------
#if MGE_WATER_WAVE_SHAPES

// Ported from Rafael's Enhanced Water for OpenMW (water.frag, GetNoiseWithGradient
// and CalculateWaveHeight). Rewritten in plain GLSL: his file works through HLSL
// compatibility aliases (float4/saturate/lerp, water.frag:103-110) which would be
// a foreign convention here. Constants are verbatim - they were checked against
//
// Measured mean of h*2.7 as a function of wave strength, on the basis the
// octaves use (first two scale with s, next two with sqrt(s)): subtracting it
// centres the field on the water plane at every strength. Fitted over
const vec3 MGE_WAVE_CENTRE_FIT = vec3(32.3226, 12.3160, -0.8299);

// Half-extent of the centred field, same basis, chosen to sit just outside the
// measured 0.1/99.9 percentiles at every strength. The raymarch searches this
// slab, so it must enclose the field: anything outside is clipped flat.
// Rafael's fixed -15*s .. +50*s envelope clips the trough at every strength
// once the field is centred, which is what flattened calm water types.
const vec3 MGE_WAVE_ENVELOPE_FIT = vec3(32.5, 3.0, 0.5);

// Wave amplitude as the eye actually perceives it.
//
// The surface normal reaches the frame through exactly one term,
// screenCoordsOffset = normal.xy * REFL_BUMP (water.frag), which shifts where
// the reflection and refraction are sampled. That shift IS the visible wave
// size. REFL_BUMP is 0.07 here (stock OpenMW ships 0.10; we lowered it to tame
// the pale contact halo at island shores), and sin(tilt) cannot exceed 1, so
// 0.07 is a hard ceiling no wave setting can pass.
//
// This multiplies it while the wave-shape path is active. It is the knob to
// turn when waves look too small - not the weather table, and not the wave
// strength, both of which change the shape of the normal rather than how much
// of it survives to the screen.
//
// Cost of raising it: the shore halo comes back, and at large values the
// reflection smears. 3.0 puts the effective value at 0.21, roughly twice
// stock. Try 2.0 if shores look wrong, 4.0-5.0 for a deliberately stormy sea.
// 1.0 = MGE XE's own tuned REFL_BUMP, unchanged, in every weather.
//
// Raising this was the wrong lever and is kept only as an escape hatch. A large
// REFL_BUMP displaces where the reflection is sampled, so the broad faces of a
// swell all drag the reflected sky sideways together - that is a smear, not a
// shape, and it is what made the highlights read as plastic.
//
// Wave size should come from the fresnel response instead: dot(-viewDir, normal)
// darkens slopes facing the viewer and brightens grazing ones, which is how real
// water shows its shape. That term always existed; it just never saw the wave
// tilt, because the old additive composition diluted a 2 deg detail normal and a
// wave normal into 0.64 deg. With the tangent frame the surface genuinely tilts,
// so Fresnel does the work MGE XE always intended it to do.
//
// Still scaled by wave strength at the use site, so anything above 1.0 affects
// storms far more than calm weather.
const float MGE_WAVE_DISTORT = 1.0;

// Gain on the fine normal-map ripples once the wave field is present.
//
// The waves raise the surface tilt from ~2 deg to ~17 deg, but the normal-map
// detail contributes the same ~9 px of screen modulation it always did - so it
// falls from ~90% of the visible signal to ~4% and the surface reads as bare
// swells with no texture between them. This scales the detail's xy back up so
// it sits legibly on top: 3.0 gives ~25 px of ripple, 5.0 gives ~42 px.
// Lower it for a glassier, more sculpted sea; raise it for a busier surface.
const float MGE_WAVE_DETAIL_WEIGHT = 1.0;

// How strongly the wave-shape normal drives the surface, against the fine
// normal-map detail added on top. The stock composition gave the coarsest
// normal a weight of 0.1 alongside five sibling taps, which attenuated a real
// 30 deg wave face to 6.2 deg; 1.0 renders it as 22 deg. Raise for a harder,
// more sculpted sea; lower to let the normal-map detail dominate again.
const float MGE_WAVE_SHAPE_WEIGHT = 1.0;

// Raymarch quality and the near-camera fade.
const int   MGE_WAVE_RAY_STEPS       = 24;
// Near-camera relief fade. Rafael uses 80/500, which flattens the surface over
// the whole range you actually stand in - water at your feet, and the rain rings
// that make a flat plane obvious.
//
// It was not protecting march quality: steps span the slab, so a near-vertical
// ray gets ~4.7 units per step where a horizon ray gets ~84. Close water is the
// best resolved, not the worst. What close water genuinely risks is a crest
// rising above the eye when the camera sits low, and that is what
// MGE_WAVE_EYE_GUARD handles directly - so this fade can be short.
// overhead surface for any swimmer shallower than ~150 units - most of the
// "water still too calm when I'm in it" report - and the file's own analysis
// above says near water is the best-resolved, so short is safe.
const float MGE_WAVE_NEAR_FADE_START = 10.0;   // relief is fully flat closer than this
const float MGE_WAVE_NEAR_FADE_END   = 60.0;   // and reaches full strength here

// Suppress relief when the camera is close to the waterline.
//
// A crest is only a problem when it can rise past the eye: the engine still
// thinks you are above water, the flat plane is still what gets rasterised, and
// in with headroom - the height of the eye above the water plane measured in
// crest heights. 1.5 means full relief once the eye clears 1.5 crests.
const float MGE_WAVE_EYE_GUARD = 1.5;
// ...but the suppression is local now, not global. As first shipped, the
// headroom factor multiplied the field at every march distance, so wading in a
// thunderstorm flattened the entire ocean ("waves height around me reduced to
// almost nothing" ): the crest half-height scales with the weather, so
// the suppression band is tallest (~75 units of eye height) exactly when the
// waves matter most. The genuine constraint is near-field only - a taller-
// than-eye crest needs pixels above the flat quad's rasterised horizon, which
// cannot exist, so it renders beheaded; but the beheading angle falls as
// atan((crest - eye)/distance), sub-degree past ~2000 units. So the guard now
// fades out between GUARD_NEAR and GUARD_FAR: water at your feet still cannot
// climb past your eye, while the storm sea beyond stays mountainous.
// Simulated worst case (eye 5u above plane, Thunderstorm, t just past far):
// 1.1 deg of crest clipping at the horizon line - fog-buried in every weather
// that has waves that tall. Raise GUARD_FAR if a hard horizontal wave-top cut
// ever shows; the cost is only how far the wading-flat zone reaches.
// job needs only the water the eye could collide with; starting the release
// earlier brings visible swell hundreds of units closer to a wading player.
const float MGE_WAVE_GUARD_NEAR = 150.0;   // fully guarded closer than this
const float MGE_WAVE_GUARD_FAR  = 2500.0;  // full relief beyond this

// water, waves seem to flatten" - twice: the 357 below-only fix never
// engaged because a swimmer's camera bobs at/just above the plane).
// The wading guard scales the whole field by
// smoothstep(0, halfExtent*EYE_GUARD, abs(eyeZ - planeZ)): any camera
// within ~75-105 u of the plane (storm halfExtent 50-70 x 1.5) gets
// the sea flattened over the whole 150-2500 u zone, from either side.
// The guard's real job is only "the surface must not cross the eye":
// the switch replaces the amplitude flattening on both sides with an
// eye clamp - full-strength waves everywhere, but within ~30-120 u
// the surface cannot cross eye level (a floor from below, a ceiling
// from above; near crests read as ducking just under the eye instead
// of the whole sea lying down). Note this also changes the wading
// look: the deliberate wading-flat zone (the 150-2500 guard) becomes
// full waves with the near ceiling - to be judged by eye.
// 0 = the flattening behaviour, byte-exact.
#define MGE_WAVE_UW_RELIEF 1
#if MGE_WAVE_UW_RELIEF
const float MGE_WAVE_UW_MARGIN     = 4.0;   // eye clearance, world units
const float MGE_WAVE_UW_FLOOR_NEAR = 30.0;  // clamp fully active closer
const float MGE_WAVE_UW_FLOOR_FAR  = 120.0; // and released beyond this
#endif

// Value noise returning (value, d/dx, d/dy) in one go, so a height sample also
// yields its slope. Value channel is 0..1, not -1..1 - which is why the height
// function has to subtract a strength-dependent mean rather than a constant.
vec3 mgeWaveNoise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = p - i;

    vec2 df = 6.0 * f * (1.0 - f);      // derivative of the smoothstep below
    f = f * f * (3.0 - 2.0 * f);

    vec2 np = vec2(0.0, 1.0);
    vec4 ix = mod(i.x + np.xyxy, 271.0);
    vec4 iy = mod(i.y + np.xxyy, 227.0);

    vec4 h = fract(sin(ix * 127.1 + iy * 311.7) * 43758.5453);

    float ba = h.y - h.x;
    float dc = h.w - h.z;
    float ab = mix(h.x, h.y, f.x);
    float cd = mix(h.z, h.w, f.x);

    vec2 grad;
    grad.x = mix(ba, dc, f.y) * df.x;
    grad.y = (cd - ab) * df.y;

    return vec3(mix(ab, cd, f.y), grad);
}

// Wave height in game units at a world XY.
//
// Five octaves of domain-warped value noise: each octave displaces the sample
// position of the next by its own gradient, which is what turns round noise
// blobs into directional, crested swells. `strength` is the vec4 fanout
// (x = linear, y = sqrt, z = 4th root, w = a sharpening gate that is off at
// full strength), matching his waveStrengthFBM.
//
// `targetH`/`bounds` drive the raymarch early-out: when marching we can abandon
// an octave as soon as the partial height plus its remaining bound cannot reach
// the ray. Pass targetH >= 999.0 to evaluate the field unconditionally.
#if MGE_WATER_WAVE_SHORE && (MGE_SHORE_PIECE_COUNT > 0)
// Per-pixel wave-rose energy. Written once per fragment by mgeShoreSetRose()
// and read inside mgeWaveHeight; globals rather than parameters so five
// call-signatures stay untouched. Defaults = all energy on the heading train,
// which makes deep water bit-for-bit the single-swell path.
// Pure shore rose weights (sum to 1) plus fan-shifted variants, and the
// shore blend factor. Every octave crossfades single-direction -> rose by
// mgeShoreW, so deep water (mgeShoreW = 0) never evaluates the rose at all
// and remains bit-identical to the approved open sea.
float mgeShoreW = 0.0;
vec2 mgeShoreDirDbg = vec2(0.0);        // for MGE_SHORE_DEBUG's painted view
vec3 mgeRoseWA = vec3(1.0, 0.0, 0.0);   // trains 0-2 (0 = the heading itself)
vec3 mgeRoseWB = vec3(0.0);             // trains 3-5
// The same energy rotated +/-MGE_WAVE_SPREAD around the rose: the crossing-sea
// fan, re-centred on the local dominant direction. Directions never move
vec3 mgeRoseWpA = vec3(0.0);  vec3 mgeRoseWpB = vec3(0.0);
vec3 mgeRoseWmA = vec3(0.0);  vec3 mgeRoseWmB = vec3(0.0);

// Train i's direction: the heading rotated i*60 degrees. Rotation entries are
// literals because cos()/sin() cannot initialise a const at #version 120.
vec2 mgeRoseDir(int i)
{
    vec2 h = normalize(MGE_WAVE_HEADING);
    if (i == 0) return h;
    if (i == 1) return vec2(h.x * 0.5 - h.y * 0.86602540, h.x * 0.86602540 + h.y * 0.5);
    if (i == 2) return vec2(-h.x * 0.5 - h.y * 0.86602540, h.x * 0.86602540 - h.y * 0.5);
    if (i == 3) return -h;
    if (i == 4) return vec2(-h.x * 0.5 + h.y * 0.86602540, -h.x * 0.86602540 - h.y * 0.5);
    return vec2(h.x * 0.5 + h.y * 0.86602540, -h.x * 0.86602540 + h.y * 0.5);
}

// Walk the baked table (vicinity-gated, cluster-culled), find the nearest
// coast segment, and set the rose weights toward its shoreward direction.
// Pure ALU - no derivatives, no texture fetches - so the branches are legal.
void mgeShoreSetRose(vec2 pos)
{
    vec2 dp = pos - playerPos.xy;
    if (dot(dp, dp) > MGE_SHORE_ACTIVE_RANGE * MGE_SHORE_ACTIVE_RANGE)
        return;

    // Nearest-coast direction via a peaked inverse-power blend over the
    // midpoint pieces: w = L / (d2 + s2)^2, direction pre-scaled by L in the
    // table. Peaked enough that the closest shore wins - a symmetric blend
    // cancels opposing channel banks to garbage in island mazes - while the
    // handover mid-channel stays smooth. One flat sequentially-indexed loop:
    float s2 = MGE_SHORE_KERNEL * MGE_SHORE_KERNEL;
    vec2 dir = vec2(0.0);
    float d2min = 1e30;
    // The scan lives in the generated file: NVIDIA caps how much data one
    // array constructor may carry (C1068 at 4397 vec4s), so the table is
    // emitted as <=1024-entry chunks and the chunk loops are generated with it.
    mgeShoreScan(pos, s2, dir, d2min);
    float dlen = length(dir);
    float shoreW = 1.0 - smoothstep(MGE_SHORE_COAST_NEAR, MGE_SHORE_COAST_FAR,
                                    sqrt(d2min));
    if (shoreW < 0.001 || dlen < 1e-20)
        return;
    vec2 shoreDir = dir / dlen;
    mgeShoreDirDbg = shoreDir;

    // Energy per train: alignment of its travel direction with shoreward,
    // sharpened, normalised. MGE_WAVE_TRAVEL flips all trains together.
    float trav = -sign(MGE_WAVE_TRAVEL);
    float w0 = pow(max(0.0, dot(mgeRoseDir(0) * trav, shoreDir)), MGE_SHORE_SHARPEN);
    float w1 = pow(max(0.0, dot(mgeRoseDir(1) * trav, shoreDir)), MGE_SHORE_SHARPEN);
    float w2 = pow(max(0.0, dot(mgeRoseDir(2) * trav, shoreDir)), MGE_SHORE_SHARPEN);
    float w3 = pow(max(0.0, dot(mgeRoseDir(3) * trav, shoreDir)), MGE_SHORE_SHARPEN);
    float w4 = pow(max(0.0, dot(mgeRoseDir(4) * trav, shoreDir)), MGE_SHORE_SHARPEN);
    float w5 = pow(max(0.0, dot(mgeRoseDir(5) * trav, shoreDir)), MGE_SHORE_SHARPEN);
    float tot = w0 + w1 + w2 + w3 + w4 + w5;
    if (tot < 1e-5)
        return;
    w0 /= tot; w1 /= tot; w2 /= tot; w3 /= tot; w4 /= tot; w5 /= tot;
    mgeShoreW = shoreW;
    mgeRoseWA = vec3(w0, w1, w2);
    mgeRoseWB = vec3(w3, w4, w5);
    // Fractional circular shift of the energy by +/-MGE_WAVE_SPREAD (in units
    // of the 60-degree rose slot). Linear, so the weights still sum to 1 and
    // the centring fit / raymarch bounds stay valid.
    float f = clamp(MGE_WAVE_SPREAD, 0.0, 60.0) / 60.0;
    float g = 1.0 - f;
    mgeRoseWpA = vec3(g * w0 + f * w5, g * w1 + f * w0, g * w2 + f * w1);
    mgeRoseWpB = vec3(g * w3 + f * w2, g * w4 + f * w3, g * w5 + f * w4);
    mgeRoseWmA = vec3(g * w0 + f * w1, g * w1 + f * w2, g * w2 + f * w3);
    mgeRoseWmB = vec3(g * w3 + f * w4, g * w4 + f * w5, g * w5 + f * w0);
}

// Weighted rose evaluation of the value noise: P and T are the octave's fully
// scaled position and time terms, R its rotation. Trains below half a percent
// of the energy are skipped.
vec3 mgeRoseNoise(vec2 P, float T, mat2 R, vec3 wa, vec3 wb)
{
    vec3 r = vec3(0.0);
    if (wa.x > 0.004) r += wa.x * mgeWaveNoise(R * (P + mgeRoseDir(0) * T));
    if (wa.y > 0.004) r += wa.y * mgeWaveNoise(R * (P + mgeRoseDir(1) * T));
    if (wa.z > 0.004) r += wa.z * mgeWaveNoise(R * (P + mgeRoseDir(2) * T));
    if (wb.x > 0.004) r += wb.x * mgeWaveNoise(R * (P + mgeRoseDir(3) * T));
    if (wb.y > 0.004) r += wb.y * mgeWaveNoise(R * (P + mgeRoseDir(4) * T));
    if (wb.z > 0.004) r += wb.z * mgeWaveNoise(R * (P + mgeRoseDir(5) * T));
    return r;
}
#endif // MGE_WATER_WAVE_SHORE && segments

// Three headings fanned about dir1: the octaves cross one another, but none can
// oppose the heading, so no wave train travels against the run of the sea.
// Built at runtime because cos()/sin() cannot initialise a const at #version 120.
void mgeWaveFanDirs(vec2 dir1, out vec2 dir2, out vec2 dir3)
{
    float sp = radians(clamp(MGE_WAVE_SPREAD, 0.0, 85.0));
    float cs = cos(sp), sn = sin(sp);
    dir2 = vec2(dir1.x * cs - dir1.y * sn, dir1.x * sn + dir1.y * cs);
    dir3 = vec2(dir1.x * cs + dir1.y * sn, -dir1.x * sn + dir1.y * cs);
}

// displaced-geometry round). fade2 scales octave 2, lodA octaves 3+4, lodB
// octave 5 - value and domain warp together, exactly as the shipped distance
// LOD always did. The fragment callers below pass fade2 = 1.0 and the
// shipped smoothsteps for lodA/lodB, which reproduces the pre-refactor
// arithmetic term for term (multiplying by a precomputed 1.0 is exact);
// the vertex displacement passes the tighter mesh-matched fades measured in
float mgeWaveHeightCore(vec2 pos, float time, vec4 strength, vec2 heading,
                        vec2 octW, float fade2, float lodA, float lodB,
                        float targetH, vec4 bounds)
{
    // Travel direction. The octaves advance by dirN * time, and adding an
    // offset to the sample position moves the pattern the opposite way, so
    // the sign here is the whole heading control.
    time *= MGE_WAVE_TRAVEL;

    // Precomputed literals, not the normalize()/cos()/sin() expressions Rafael
    // writes. This tree compiles at #version 120 (water.frag:1), where a const
    // initialiser must be a constant expression - a function call is not one,
    // and nothing else in our shader tree relies on a driver being lenient
    // about it. Values are exact to 8 dp; also saves the per-fragment work.
    vec2 dir1 = normalize(heading);
    vec2 dir2, dir3;
    mgeWaveFanDirs(dir1, dir2, dir3);
    const mat2 rot1 = mat2(0.82533561, -0.56464247, 0.56464247, 0.82533561); // 0.6 rad
    const mat2 rot2 = mat2(0.36235775, -0.93203909, 0.93203909, 0.36235775); // 1.2 rad

    pos = rot1 * pos * 0.003;
    pos.x *= 1.17;

    float h = 0.0;
    vec3 r = vec3(0.0);
    vec4 fbm = vec4(1.164, 1.0, 22.5, 0.0055 * strength.x);

    // Octave 1 - the dominant swell: ~372 unit wavelength, and on its own about
    // 61 units peak to trough at full strength.
r = fbm.z * mgeWaveNoise(rot1 * (pos * 0.77 * fbm.x + dir1 * time * fbm.y));
    h = r.x * strength.x;
    pos = -r.yz * fbm.w + pos;

    bool doEarlyOut = targetH < 999.0;
    if (!(doEarlyOut && (h + bounds.x < targetH || h - bounds.x > targetH)))
    {
        fbm *= vec4(2.17, 1.6141, 0.29, 1.3);
        r = fbm.z * mgeWaveNoise(rot1 * (pos * 0.92 * fbm.x + dir2 * time * fbm.y));
    r *= octW.x;   // dir2 train
        r *= fade2;    // 1.0 on the fragment paths (exact); mesh fade in the vertex stage
        h = r.x * strength.x + h;
        pos = -r.yz * fbm.w + pos;

        // Distance LOD: the fine octaves are dropped far away, where they would
        // alias into noise rather than resolve as detail. The caller supplies
        // the fade (the shipped smoothsteps, or the vertex mesh fades).
        float lod = lodA;
        if (lod > 0.0 && !(doEarlyOut && (h + bounds.y < targetH || h - bounds.y > targetH)))
        {
            pos.xy = pos.yx;

            fbm *= vec4(2.17, 1.6141, 0.46, 1.3);
            r = mgeWaveNoise(rot2 * (pos * fbm.x + dir3 * time * fbm.y));
            r = lod * fbm.z * mix(r * 0.7, exp(r * 2.0 - 1.9), strength.w);
            r *= octW.y;   // dir3 train
            h = r.x * strength.y + h;
            pos = -r.yz * fbm.w + pos;

            if (!(doEarlyOut && (h + bounds.z < targetH || h - bounds.z > targetH)))
            {
                fbm *= vec4(1.618, 1.346321, 0.45, 1.3);
                r = mgeWaveNoise(rot2 * (pos * fbm.x + dir1 * time * fbm.y));
                r = lod * fbm.z * mix(r * 0.7, exp(r * 2.0 - 1.7), strength.w);
                h = r.x * strength.y + h;
                pos = -r.yz * fbm.w + pos;

                lod = lodB;
                if (lod > 0.0 && !(doEarlyOut && (h + bounds.w < targetH || h - bounds.w > targetH)))
                {
                    fbm *= vec4(1.618, 1.346321, 0.45, 1.3);
                    r = lod * fbm.z * exp(mgeWaveNoise(rot1 * (pos * fbm.x + dir3 * time * fbm.y))
                                          * 2.0 - 1.5 - strength.x * 0.7);
                    r *= octW.y;   // dir3 train
                    h = r.x * strength.z + h;
                }
            }
        }
    }

    // Scale to game units and centre on the water plane.
    //
    // Rafael's constant "- 27.0" does not centre the field: the noise value
    // channel is 0..1 rather than -1..1, so the octave sum has a positive mean
    // that grows with strength. Measured, his field sits +16.9 units above the
    // plane at open sea and -7.2 below it at Sulphur strength. While only the
    // gradient is consumed that is invisible (a constant offset cancels in a
    // finite difference), but once the raymarch reads absolute height it means
    // the water surface renders at the wrong level, and at a level that changes
    // with water type.
    //
    // MGE_WAVE_CENTRE_FIT is the measured mean of h*2.7 as a function of
    // strength, fitted on the basis the octaves actually use (the first two
    // scale with s, the next two with sqrt(s)) - so it is a description of this
    // field, not a curve fit of convenience. Max error 0.52 units across
    // costs two multiplies. See docs/sims/wave_height_field_check.py.
    return (h * 2.7 - (MGE_WAVE_CENTRE_FIT.x * strength.x
                     + MGE_WAVE_CENTRE_FIT.y * strength.y
                     + MGE_WAVE_CENTRE_FIT.z)) * MGE_WAVE_AMPLITUDE;
}

// The shipped signatures, now thin wrappers over the core: the distance LOD
// smoothsteps are computed here with the exact shipped edges and passed in,
// so the raymarch/normal paths are arithmetic-identical to the pre-refactor
// build (same inputs, same order; fade2 = 1.0 multiplies exactly).
float mgeWaveHeight(vec2 pos, float time, float distFromCamera,
                    vec4 strength, vec2 heading, vec2 octW, float targetH, vec4 bounds)
{
    return mgeWaveHeightCore(pos, time, strength, heading, octW, 1.0,
                             smoothstep(10000.0, 2000.0, distFromCamera),
                             smoothstep(2000.0, 700.0, distFromCamera),
                             targetH, bounds);
}

float mgeWaveHeight(vec2 pos, float time, float distFromCamera, vec4 strength,
                    vec2 heading, vec2 octW)
{
    return mgeWaveHeight(pos, time, distFromCamera, strength, heading, octW, 999.9, vec4(0.0));
}

#if MGE_WATER_DISPLACE
// ---- vertex-stage displacement (Full tier, water layer) --------------------
// The XE window (XE Mod Water.fx:141): a fade-in ramp from zero AT the camera
// to full at 200 u - the surface is pinned to the plane at the eye itself,
// which is what keeps the per-camera above/below branch honest at the camera
// point - and a fade-out ending at the outer edge. The outer edge is ours,
// not XE's 6400: 5000 u is bounded by the 384x120 mesh's measured carrying
// XE's 6400 pairs with XE's much coarser 3900 u far wave scale).
const float MGE_DISP_WIN_INNER = 200.0;
const float MGE_DISP_WIN_OUTER = 5000.0;

float mgeDispWindow(float dist)
{
    return clamp(dist / MGE_DISP_WIN_INNER, 0.0, 1.0)
         * clamp(1.0 - dist / MGE_DISP_WIN_OUTER, 0.0, 1.0);
}

// The displacement height: the same core chain the fragment shades with,
// under mesh-matched octave fades - which octaves 384x120 ring spacing can
// ~100 u, 4 to ~350, 2 to ~1900, the dominant swell alone beyond). The
// fragment keeps every octave in its normals regardless - the geometry
// carries the swell, the normal map carries the detail, exactly XE's own
// split between its two texture scales.
float mgeDispHeight(vec2 pos, float time, float distFromCamera, vec4 strength, vec2 heading)
{
    float fade2 = 1.0 - smoothstep(1100.0, 1900.0, distFromCamera);
    float lodA  = 1.0 - smoothstep(150.0, 350.0, distFromCamera);
    float lodB  = 1.0 - smoothstep(60.0, 160.0, distFromCamera);
    return mgeWaveHeightCore(pos, time, strength, heading, vec2(1.0),
                             fade2, lodA, lodB, 999.9, vec4(0.0));
}

#if MGE_WATER_XE_FIELD
// ---- the XE field (see the switch comment above) ---------------------------
uniform sampler3D mgeWave3d;      // fork-bound unit 5; never bound on stock
uniform float mgeWaterXeField;    // 1 only when the volume loaded (fork)

// XE ini semantics: displacement = base * weather multiplier * (a - 0.5).
// The wind curve follows the source mechanic's per-weather table for
// cloudy/overcast/rain/thunder (within 1%) and deliberately departs
// elsewhere - blizzard runs with the other storms by design rather
// weather, so no curve of wind alone could carry that table exactly.
const float MGE_WAVE_XE_BASE = 50.0;   // the MGE.ini Water Wave Height
// XE Mod Water.fx:141 verbatim window (the 6400 is honest for this field:
// sim_xe_field_race X2 - our mesh carries it better than XE's own did).
const float MGE_XE_WIN_INNER = 200.0;
const float MGE_XE_WIN_OUTER = 6400.0;
// Foam crest thresholds matched to the current displaced build's storm
// coverage on this field's amplitude distribution (race X3).
const float MGE_FOAM_CREST_H0_XE = 4.0;
const float MGE_FOAM_CREST_H1_XE = 6.0;
// itself travels - measured, +1 texel diagonally per frame = ~55 u/s on a
// fixed NE diagonal, mostly in-place morph - which reads as bobbing against
// the strongly-directional 138 u/s sea this project shipped for a month.
// A declared taste deviation from XE: the sample position additionally
// scrolls along the authored sea heading. Height and normal samples shift
// together (coherence). 0.0 = XE-verbatim static sampling, byte-exact.
const float MGE_XE_TRAVEL_SPEED = 100.0;   // world u/s along MGE_WAVE_HEADING

// GLSL 1.20: the vertex stage may only use the Lod texture variants.
#if MGE_WATER_VERTEX_STAGE
#define MGE_TEX3D(u) texture3DLod(mgeWave3d, u, 0.0)
#else
#define MGE_TEX3D(u) texture3D(mgeWave3d, u)
#endif

// XE Mod Water.fx:134-138: the displaced height in (a - 0.5) units.
// The travel offset shared by height and normal sampling (see the
// MGE_XE_TRAVEL_SPEED comment). Subtracting moves the pattern with the
// heading - an offset added to the sample position moves it the other way.
vec2 mgeXeTravel(float time)
{
    return -normalize(MGE_WAVE_HEADING) * (MGE_XE_TRAVEL_SPEED * time)
           * sign(-MGE_WAVE_TRAVEL);
}

float mgeXeHeight(vec2 wxy, float dist, float time)
{
    float t = 0.4 * time;
    vec2 p = wxy + mgeXeTravel(time);
    float h1 = MGE_TEX3D(vec3(p / 1104.0, t)).a;
    float h2 = MGE_TEX3D(vec3(p / 3900.0, t)).a;
    return mix(h1, h2, clamp(dist / 8000.0, 0.0, 1.0)) - 0.5;
}

// getFinalWaterNormal (XE Mod Water.fx:36-55) minus the rain/wake sim taps
// (OpenMW has native ripples; the work order scopes the wake sim out).
vec3 mgeXeNormal(vec2 wxy, float dist, float time)
{
    float t = 0.4 * time;
    vec2 p = wxy + mgeXeTravel(time);
    vec2 farN = MGE_TEX3D(vec3(p / 3900.0, t)).rg;
    vec2 closeN = MGE_TEX3D(vec3(p / 527.0, t)).rg;
    vec2 nr = 2.0 * mix(closeN, farN, clamp(dist / 8000.0, 0.0, 1.0)) - 1.0;
    return normalize(vec3(nr, 1.0));
}
#endif // MGE_WATER_XE_FIELD
#endif // MGE_WATER_DISPLACE

#if MGE_WATER_WAVE_SHORE && (MGE_SHORE_PIECE_COUNT > 0)
// The rose-blended field, for shading only - deliberately a separate function.
//
// The first wiring put the rose inside mgeWaveHeight, which the raymarch
// inlines 24+ times: every rose branch multiplied by every march step blew the
// GL program past its link limits (glLinkProgram failed, and a long stall
// while the driver chewed on it). The march does not need the rose - it only
// finds where the ray meets the surface, and both fields share amplitude
// statistics, so marching the base field and shading with this one differs by
// less than the crossfade itself. The rose code is inlined exactly three
// times (the normal taps) instead of ~80.
//
// Body mirrors mgeWaveHeight minus the early-out machinery; keep the two in
// step when octave constants change.
float mgeWaveHeightRose(vec2 pos, float time, float distFromCamera,
                        vec4 strength, vec2 heading)
{
    time *= MGE_WAVE_TRAVEL;
    vec2 dir1 = normalize(heading);
    vec2 dir2, dir3;
    mgeWaveFanDirs(dir1, dir2, dir3);
    const mat2 rot1 = mat2(0.82533561, -0.56464247, 0.56464247, 0.82533561); // 0.6 rad
    const mat2 rot2 = mat2(0.36235775, -0.93203909, 0.93203909, 0.36235775); // 1.2 rad

    pos = rot1 * pos * 0.003;
    pos.x *= 1.17;

    float h = 0.0;
    vec3 r = vec3(0.0);
    vec4 fbm = vec4(1.164, 1.0, 22.5, 0.0055 * strength.x);

    r = mgeWaveNoise(rot1 * (pos * 0.77 * fbm.x + dir1 * time * fbm.y));
    if (mgeShoreW > 0.001)
        r = mix(r, mgeRoseNoise(pos * 0.77 * fbm.x, time * fbm.y, rot1,
                                mgeRoseWA, mgeRoseWB), mgeShoreW);
    r *= fbm.z;
    h = r.x * strength.x;
    pos = -r.yz * fbm.w + pos;

    fbm *= vec4(2.17, 1.6141, 0.29, 1.3);
    r = mgeWaveNoise(rot1 * (pos * 0.92 * fbm.x + dir2 * time * fbm.y));
    if (mgeShoreW > 0.001)
        r = mix(r, mgeRoseNoise(pos * 0.92 * fbm.x, time * fbm.y, rot1,
                                mgeRoseWpA, mgeRoseWpB), mgeShoreW);
    r *= fbm.z;
    h = r.x * strength.x + h;
    pos = -r.yz * fbm.w + pos;

    float lod = smoothstep(10000.0, 2000.0, distFromCamera);
    if (lod > 0.0)
    {
        pos.xy = pos.yx;

        fbm *= vec4(2.17, 1.6141, 0.46, 1.3);
        r = mgeWaveNoise(rot2 * (pos * fbm.x + dir3 * time * fbm.y));
        if (mgeShoreW > 0.001)
            r = mix(r, mgeRoseNoise(pos * fbm.x, time * fbm.y, rot2,
                                    mgeRoseWmA, mgeRoseWmB), mgeShoreW);
        r = lod * fbm.z * mix(r * 0.7, exp(r * 2.0 - 1.9), strength.w);
        h = r.x * strength.y + h;
        pos = -r.yz * fbm.w + pos;

        fbm *= vec4(1.618, 1.346321, 0.45, 1.3);
        r = mgeWaveNoise(rot2 * (pos * fbm.x + dir1 * time * fbm.y));
        if (mgeShoreW > 0.001)
            r = mix(r, mgeRoseNoise(pos * fbm.x, time * fbm.y, rot2,
                                    mgeRoseWA, mgeRoseWB), mgeShoreW);
        r = lod * fbm.z * mix(r * 0.7, exp(r * 2.0 - 1.7), strength.w);
        h = r.x * strength.y + h;
        pos = -r.yz * fbm.w + pos;

        float lod2 = smoothstep(2000.0, 700.0, distFromCamera);
        if (lod2 > 0.0)
        {
            fbm *= vec4(1.618, 1.346321, 0.45, 1.3);
            vec3 r5 = mgeWaveNoise(rot1 * (pos * fbm.x + dir3 * time * fbm.y));
            if (mgeShoreW > 0.001)
                r5 = mix(r5, mgeRoseNoise(pos * fbm.x, time * fbm.y, rot1,
                                          mgeRoseWmA, mgeRoseWmB), mgeShoreW);
            r = lod2 * fbm.z * exp(r5 * 2.0 - 1.5 - strength.x * 0.7);
            h = r.x * strength.z + h;
        }
    }

    return (h * 2.7 - (MGE_WAVE_CENTRE_FIT.x * strength.x
                     + MGE_WAVE_CENTRE_FIT.y * strength.y
                     + MGE_WAVE_CENTRE_FIT.z)) * MGE_WAVE_AMPLITUDE;
}
#endif // MGE_WATER_WAVE_SHORE && segments


// Fan one 0..1 wave strength out to the four channels the octaves consume.
vec4 mgeWaveStrengthFanout(float s)
{
    vec4 f = vec4(s, sqrt(s), 0.0, 0.0);
    f.z = sqrt(f.y);
    // Sharpening gate: ON for calm/sheltered water, off at open-sea strength.
    // Note the reversed smoothstep edges - this is 0 at s = 1.0.
    f.w = smoothstep(0.80, 0.65, f.x);
    return f;
}

#if !MGE_WATER_VERTEX_STAGE
// Surface normal from the height field's gradient, by finite difference.
vec3 mgeWaveNormal(vec2 xy, float time, float distFromCamera, vec4 strength, vec2 heading, vec2 octW, float sampleDist)
{
#if MGE_WATER_WAVE_SHORE && (MGE_SHORE_PIECE_COUNT > 0)
    float hC = mgeWaveHeightRose(xy, time, distFromCamera, strength, heading);
    float hX = mgeWaveHeightRose(xy + vec2(sampleDist, 0.0), time, distFromCamera, strength, heading);
    float hY = mgeWaveHeightRose(xy + vec2(0.0, sampleDist), time, distFromCamera, strength, heading);
#else
    float hC = mgeWaveHeight(xy, time, distFromCamera, strength, heading, octW);
    float hX = mgeWaveHeight(xy + vec2(sampleDist, 0.0), time, distFromCamera, strength, heading, octW);
    float hY = mgeWaveHeight(xy + vec2(0.0, sampleDist), time, distFromCamera, strength, heading, octW);
#endif
    vec3 dX = vec3(sampleDist, 0.0, hX - hC);
    vec3 dY = vec3(0.0, sampleDist, hY - hC);
    return normalize(cross(dX, dY));
}

#if MGE_WATER_WAVE_RAYMARCH

// Distance fade for the relief. Near the camera the view ray meets the surface
// steeply, so 24 steps resolve the height field coarsely and the relief would
// stair-step; Rafael fades it out below 500 units and to nothing below 80.
// Exposed as constants because "water at your feet is flat" is a real cost of
// that choice - see stage 4 of docs/water-raymarch-port-plan.md.
float mgeWaveNearFade(float t)
{
    return smoothstep(MGE_WAVE_NEAR_FADE_START, MGE_WAVE_NEAR_FADE_END, t);
}

// March the view ray against the height field and return the world position
// where it meets the wave surface.
//
// This is relief mapping: the water geometry is still a flat plane (OpenMW
// writes every water vertex at Z=0, sceneutil/waterutil.cpp:36-39), but the
// position used for shading, for the normal-map lookup and for the refraction
// offset comes from the marched surface. That is what produces parallax and
// self-occlusion without touching the engine.
//
// planeZ is the cell's water level; the slab is built around it.
vec3 mgeRaymarchWater(vec3 eyePos, vec3 dir, float t0, float t1, float time,
                      vec4 strength, vec2 heading, vec2 octW, float planeZ, bool underwater)
{
    // Slab enclosing the centred field. Symmetric, unlike Rafael's -15/+50,
    // because the centred field IS symmetric about the plane.
    // Scaled with the amplitude, or the slab would clip the taller field.
    // Envelope and early-out bounds widen with the largest octave weight, or a
    // boosted train could rise past the slab / trip the early-out wrongly.
    float octMax = max(max(octW.x, octW.y), 1.0);
    float halfExtent = (MGE_WAVE_ENVELOPE_FIT.x * strength.x
                      + MGE_WAVE_ENVELOPE_FIT.y * strength.y
                      + MGE_WAVE_ENVELOPE_FIT.z) * MGE_WAVE_AMPLITUDE
                     * (1.0 + 0.25 * (octMax - 1.0));

    float tEnter = ((planeZ + halfExtent) - eyePos.z) / dir.z;
    float tExit  = ((planeZ - halfExtent) - eyePos.z) / dir.z;
    if (tEnter > tExit)
    {
        float tmp = tEnter; tEnter = tExit; tExit = tmp;
    }
    tEnter = max(tEnter, t0);
    tExit  = min(tExit,  t1);

    if (tEnter >= tExit)
        return dir * t1 + eyePos;

    // Headroom guard: fade relief out as the eye approaches the waterline, where
    // a crest could rise past it and the flat-plane rasterisation cannot follow.
    float mgeHeadroom = smoothstep(0.0, max(halfExtent * MGE_WAVE_EYE_GUARD, 1.0),
                                   abs(eyePos.z - planeZ));

    float rayStep = (tExit - tEnter) / float(MGE_WAVE_RAY_STEPS);
    float invDirZ = 1.0 / max(abs(dir.z), 0.2);

    // Per-octave remaining-amplitude bounds for the early-out: once the partial
    // height plus everything still to come cannot reach the ray, stop.
    vec4 bounds = vec4(1.37 * strength.z);
    bounds.z = 1.783 * strength.y + bounds.w;
    bounds.y = 3.244 * strength.y + bounds.z;
    bounds.x = 6.525 * strength.x + bounds.y;
    bounds *= octMax;

    // Convert a world Z into the raw pre-scale h domain the early-out compares
    // in. Must track the centring above exactly, or the early-out rejects steps
    // it should take and the surface develops holes.
    float centre = MGE_WAVE_CENTRE_FIT.x * strength.x
                 + MGE_WAVE_CENTRE_FIT.y * strength.y
                 + MGE_WAVE_CENTRE_FIT.z;

    float t = tEnter;
    vec3 p = eyePos;
    float dynamicStep = rayStep;

    for (int i = 0; i < MGE_WAVE_RAY_STEPS && t < tExit; ++i)
    {
        t += dynamicStep;
        p = dir * t + eyePos;

        float fade = mgeWaveNearFade(t);
        // Localized eye guard (see MGE_WAVE_GUARD_NEAR): full headroom
        // suppression at the camera, none past GUARD_FAR.
        float guard = mix(mgeHeadroom, 1.0,
                          smoothstep(MGE_WAVE_GUARD_NEAR, MGE_WAVE_GUARD_FAR, t));
#if MGE_WAVE_UW_RELIEF
        // The amplitude flattening is replaced ON both sides by the
        // swimmer's camera bobs at/just above the plane, so the
        // below-only fix never engaged - the abs() headroom flattened
        // from the above side).
        guard = 1.0;
#endif

        // The early-out compares in the raw pre-scale domain, and that mapping
        // is only exact where neither the near-fade nor the guard is scaling
        // the result. Where either is, disable the early-out rather than feed
        // it a target it cannot interpret: a wrong early-out rejects steps that
        // should be taken and punches holes in the surface. (The global-guard
        // version had exactly that latent bug: with headroom < 1 the early-out
        // target was mapped without the headroom factor, mis-scaled over the
        // whole wading band - masked only because the surface it punched holes
        // in was flattened anyway.) Cheap in practice - inside the fade/guard
        // zone the surface is small, so the march terminates quickly.
        // Undo the amplitude before comparing: the early-out works in the raw
        // pre-scale domain, so the target has to be mapped back through it too.
#if MGE_WAVE_UW_RELIEF
        // The eye clamp below invalidates the early-out's raw-domain
        // target wherever it could bind - same discipline as fade/guard.
        float targetRaw = (fade > 0.99 && guard > 0.99
                           && t >= MGE_WAVE_UW_FLOOR_FAR)
            ? (((p.z - planeZ) / MGE_WAVE_AMPLITUDE + centre) / 2.7) : 999.9;
#else
        float targetRaw = (fade > 0.99 && guard > 0.99)
            ? (((p.z - planeZ) / MGE_WAVE_AMPLITUDE + centre) / 2.7) : 999.9;
#endif
        float h = mgeWaveHeight(p.xy, time, t, strength, heading, octW, targetRaw, bounds) * fade * guard + planeZ;
#if MGE_WAVE_UW_RELIEF
        // The eye clamp: within FLOOR_NEAR the surface may not cross
        // the eye (a floor from below, a ceiling from above); released
        // by FLOOR_FAR. Full-strength waves everywhere else.
        if (underwater)
            h = max(h, mix(eyePos.z + MGE_WAVE_UW_MARGIN, h,
                           smoothstep(MGE_WAVE_UW_FLOOR_NEAR,
                                      MGE_WAVE_UW_FLOOR_FAR, t)));
        else
            h = min(h, mix(eyePos.z - MGE_WAVE_UW_MARGIN, h,
                           smoothstep(MGE_WAVE_UW_FLOOR_NEAR,
                                      MGE_WAVE_UW_FLOOR_FAR, t)));
#endif

        float delta = underwater ? h - p.z : p.z - h;
        if (delta <= 0.0)
            break;

        dynamicStep = clamp(delta * invDirZ, rayStep * 0.25, rayStep * 3.0);
    }

    // Two bisections to clean up the overshoot from the last step.
    t0 = t - rayStep;
    t1 = t;
    for (int i = 0; i < 2; ++i)
    {
        t = 0.5 * (t0 + t1);
        p = dir * t + eyePos;
#if MGE_WAVE_UW_RELIEF
        float h = mgeWaveHeight(p.xy, time, t, strength, heading, octW)
                * mgeWaveNearFade(t)
                + planeZ;
        if (underwater)
            h = max(h, mix(eyePos.z + MGE_WAVE_UW_MARGIN, h,
                           smoothstep(MGE_WAVE_UW_FLOOR_NEAR,
                                      MGE_WAVE_UW_FLOOR_FAR, t)));
        else
            h = min(h, mix(eyePos.z - MGE_WAVE_UW_MARGIN, h,
                           smoothstep(MGE_WAVE_UW_FLOOR_NEAR,
                                      MGE_WAVE_UW_FLOOR_FAR, t)));
#else
        float h = mgeWaveHeight(p.xy, time, t, strength, heading, octW)
                * mgeWaveNearFade(t)
                * mix(mgeHeadroom, 1.0,
                      smoothstep(MGE_WAVE_GUARD_NEAR, MGE_WAVE_GUARD_FAR, t))
                + planeZ;
#endif
        if (underwater ? p.z >= h : p.z <= h)
            t1 = t;
        else
            t0 = t;
    }

    return dir * (0.5 * (t0 + t1)) + eyePos;
}

#endif // MGE_WATER_WAVE_RAYMARCH

#endif // !MGE_WATER_VERTEX_STAGE (normals + raymarch are fragment-only)
#endif // MGE_WATER_WAVE_SHAPES

// ---- foam ------------------------------------------------------------------
// calibrated TO our normal map, and that is why these differ from Rafael's.
// His mod ships its own textures/omw/water_nm.png (1024x1024, xy rms 0.384) and
// his README tells you to overwrite the stock one with it. Ours is the stock
// 128x128 map at xy rms 0.150 - 2.5x flatter. Measured with his constants on our
// texture, 2.4% of the surface reached MGE_FOAM_MIN and 0.0% reached MAX: foam
// was unreachable, not faint. These values put the same fraction of our surface
// over the threshold. Swapping in his texture instead would work too, but it
// changes the whole water surface and breaks the MGE XE parity at Clear.
// shoaling (wave build only). Waves slow in shallow water and steepen until
// they break. Our substitute for coast-following, which the stock tier's driver
// cannot carry: we cannot aim waves at the shore, but making them grow as they
// arrive gives much of the same impression - and unlike a direction, an
// Scaled by wave strength, so calm weather is untouched and Clear stays exact.
// Upper bound on the reflection/refraction sample offset, in screen units.
// normal.xy * REFL_BUMP is a screen-space displacement, so a steep crest can
// send it 5% of the screen away and sample unrelated geometry. Calm water sits
// far below this, so the cap only engages where the artifact is.
const float MGE_WAVE_DISTORT_MAX = 0.026;
// Ceiling on the fresnel term once waves are present. MGE XE's pow-16 curve
// saturates on the near-grazing faces that real wave shapes create, turning
// individual faces into mirrors. Scaled in by wave strength.
const float MGE_WAVE_FRESNEL_MAX = 0.45;

const float MGE_WAVE_SHOAL       = 0.0;   // dropped by reported: not worth the
                                          // refraction artifacts it brought. At 0 the code is
                                          // inert (normal unchanged, offset undivided). Removing
                                          // it outright - and the early depth sample it needs -
                                          // is a cleanup for a fresh session.
const float MGE_WAVE_SHOAL_DEPTH = 700.0;  // depth by which shoaling has faded, world units

const float MGE_FOAM_INTENSITY = 1.0;    // global scale
// Ported from Liam's Rafael Water Edits (Nexus 59113); values are his unless
// noted. The foam pattern lives in the normal map's alpha channel - we ship his
// authored foam alpha over our stock RGB, so the water surface is unchanged.
const float MGE_FOAM_SCALE     = 0.0005;  // world units -> foam UV (his)
// MGE XE animates foam by walking a 256x256x32 volume texture's time axis, with
// no UV drift at all - which is why its foam never reads as travelling. We have
// a 2D texture here, so MGE_FOAM_MORPH cross-dissolves between decorrelated
// offsets to the same effect (0 = no morphing, pure drift = the old behaviour).
// Costs one extra texture sample per foam layer; set to 0 on a weak card.
const float MGE_FOAM_ATLAS_INSET = 0.004;  // tile inset, stops frames bleeding
const float MGE_FOAM_MORPH     = 1.20;    // pseudo-slices per second, calm water
// one dial for how fast foam appears and dissolves IN place. Scales every
// visibility-shift rate together: the morph (pattern replacement) and both
// gray density pulses. 1.0 is Liam's original tuning, which reads as
// shimmering - at his rates the three multiplied layers replace their pattern
// 0.3-1.6x per second each, out of phase, so the product twinkles constantly.
// 0.4 turns replacement into breathing (layer 1: one dissolve per ~1.9 s calm,
// ~1.2 s storm; density pulses at 6.3 s and 9.2 s periods) without touching
// where foam sits or how it surges - those are the masks and MGE_FOAM_SURGE.
const float MGE_FOAM_CHURN     = 0.40;    // 1.0 = Liam's rates (shimmered)
// Storms churn. The morph rate scales with the weather's wave strength - but
// keep this small. The morph is a cross-dissolve between decorrelated offsets of
// the same texture: it replaces the pattern in place, it does not translate it.
// At 1.60 a thunderstorm ran 5.0 whole-pattern replacements per second and read
// as flashing, which is exactly what it is. Foam moves via MGE_FOAM_SURGE.
const float MGE_FOAM_STORM_RATE = 0.40;   // extra rate per unit of wave strength
const float MGE_FOAM_DRIFT     = 0.10;    // residual directional drift (1.0 = Liam's, 0 = MGE XE)
// slosh - foam surges and withdraws with each passing swell, in world units of
// pattern displacement per unit of surface slope. This replaced a uniform
// advection along the heading (138 u/s, weather-scaled), which correctly
// rejected: it turned surf into a current, foam streaming away from every
// shore. MGE XE has NO net foam travel at all - its foam UVs are bare world
// position (tex3D(sampWater3d, float3(IN.pos.xy / 45, time)), XE Water.fx:494)
// and every to-and-fro it shows comes from the surface normal oscillating the
// shoreline term (depth += 50 * (0.99 - normal.z), line 471). Same physics as
// real foam: orbital motion under a swell is a closed loop, so foam rocks back
// and forth and goes nowhere.
//
// A 1-D travelling compression wave along the heading: displacement =
// heading * sin(k*dot(pos, heading) + w*t*MGE_WAVE_TRAVEL) * amplitude. Foam
// surges down-wave, bunches, and falls back as each surge band passes, with
// zero net drift (a closed oscillation) and zero possibility of swirl: the
// displacement is always parallel to one fixed axis and varies only along that
// axis, so its curl vanishes identically - it can stretch and bunch the
// pattern along the travel direction, never rotate or knead it.
//
// constructed coarse rather than borrowed, after two failed attempts to
// borrow. Displacing by normal0 swirled ("a puddle with oil in it" );
// displacing by mgeWaveN still swirled ("diesel spilled into water"), because
// a noise field's normal is its gradient and gradients weight high
// frequencies: measured on the octave ladder, 67% of mgeWaveN's slope content
// sits at 171-world-unit features and finer - the foam features' own scale -
// and the field's internal domain warp (pos = -r.yz*fbm.w + pos) adds literal
// curl on top. A displacement field reads as body motion only if it varies
// much more coarsely than the pattern it displaces, and no gain can fix a
//
// Wave-build only, scaled by wave strength (calm floor -> zero at Clear). On
// the pre-wave tier the pattern stays put and all motion is the band edge via
// the swash - exactly MGE XE, whose foam UVs are bare world position.
const float MGE_FOAM_SURGE     = 50.0;    // world units of surge at full wave strength
// Distance between surge bands. Strain (pattern stretch) at full strength is
// surge * 2pi/wavelength = 0.29 - visible bunching, no rubber. The band
// travels at the field's own 138.3 wu/s (MGE_WAVE_FIELD_SPEED), so a fixed
// point surges forward and back over ~8 s.
const float MGE_FOAM_SURGE_WAVELENGTH = 1100.0;
// Derived literals (#version 120 consts cannot call functions):
//   K = 2pi / MGE_FOAM_SURGE_WAVELENGTH
//   W = K * MGE_WAVE_FIELD_SPEED     (period 2pi/W = 7.95 s)
const float MGE_FOAM_SURGE_K   = 0.0057120;
const float MGE_FOAM_SURGE_W   = 0.7900;
const float MGE_FOAM_CONTRAST  = 0.40;    // upper edge of the pattern contrast (his)
const float MGE_FOAM_MIN       = 0.08;    // surface slope where crest foam starts (his)
const float MGE_FOAM_MAX       = 0.35;    // slope for full crest foam (his)
const float MGE_FOAM_SHORE     = 1.0;     // shoreline foam amount (0 = none)
const float MGE_FOAM_SHORE_DEPTH = 45.0;  // depth where shore foam is gone (his)
// occluder rejection - kills the foam halo around submerged poles. Shore foam
// keys on the refraction depth buffer, and a submerged object writes its
// surface into that buffer, so the water in front of it reports "shallow" and
// grows a foam outline (every submerged pole, pier leg, statue). The
// discriminator is width: a real shore is shallow across hundreds of units, a
// pole across a few dozen. Two extra depth taps at +-R world units
// (horizontal, screen space; vertical offsets at grazing angles span enormous
// along-plane distances) feed a multiplicative suppression:
//     shoreFoam *= 1 - smoothstep(BAND_REACH, BAND_REACH + fade, min(L, R))
// Suppression, not a remapped depth: the refraction camera clips everything
// above the water plane (mwrender/water.cpp ClipCullNode), so land reads
// far-plane deep in this buffer, and the first, remapping version transplanted
// every waterline/LOD discontinuity into a hard foam seam 55 wu sideways.
// With the window starting AT the band's reach, min(L,R) <= centre <= reach on
// every monotone shore, so the suppression is identically 0 wherever real
// shore foam exists and only fires for shallow readings flanked by
// beyond-band water on both sides - poles, pier legs, narrow ridges.
// Accepted costs: poles standing inside the active surf zone keep foam, and
// channels narrower than ~2R lose shore foam.
const float MGE_FOAM_OCCLUDER_R = 55.0;   // tap radius, world units
// The shore band's true reach in scaled depth: SHORE_DEPTH plus the swash's
// maximum extension, 45 + 380 * (p99 slope 0.273 - SLOPE_MID 0.15) = 92.
// derived - re-derive if SHORE_DEPTH, swash or SLOPE_MID change; a value
// below the real reach re-introduces the entry-71 fold at the band tail.
const float MGE_FOAM_BAND_REACH = 92.0;
const float MGE_FOAM_OCCLUDER_FADE = 30.0; // suppression fade width past the reach
// swash window - a backstop, deliberately clear of the living band. The gate
// fades the swash between SHORE_DEPTH * window/2 and SHORE_DEPTH * window, so
// deep water can never be swash-dragged into the foam band, but the band
// itself (which the +-48-unit swash extends to ~92 scaled units) is
// untouched. Halo suppression is MGE_FOAM_OCCLUDER_R's job now.
//
// (SHORE_DEPTH * window/2) must exceed 1.5x the swash amplitude (~48), i.e.
// window >= 3.2 at current constants. The first shipment used a [1.0, 2.5]
// window whose 67-unit fade sat inside the band: on the foam-extending phase
// it compressed the outer band 2.1x (a visibly squeezed second layer's
// "hard edge between two layers"), and on the retreating phase d+swash*gate
// became non-monotone in depth - a fold, rendering a stripe of uniform foam.
// It also cut the band's reach 92 -> 73 ("foam less pronounced at the shore").
// Simulate d(eff)/dd across both swash extremes before changing either number.
const float MGE_FOAM_SWASH_WINDOW = 4.0;  // fade spans [window/2, window] x SHORE_DEPTH
// swash - the waterline running up the beach and withdrawing. From MGE XE's
// "Small scale shoreline animation": the foam band's depth is perturbed by the
// surface, so the band's edge advances and retreats. Moving the foam texture
// instead only slides the pattern along a fixed edge.
const float MGE_FOAM_SWASH      = 380.0;  // how far the waterline travels, world units
const float MGE_FOAM_SLOPE_MID  = 0.15;  // slope that means "no displacement" (our map's mean)
const float MGE_FOAM_SWASH_WAVE = 90.0;   // extra travel from real wave crests (wave build)
const float MGE_FOAM_WAVE_GAIN   = 1.50;

#if MGE_WATER_FOAM
// Guarded under MGE_WATER_FOAM so the foam-off build stays byte-identical
// (the deploy gate's no-op invariant).
//
// crest foam V2 (MGE_FOAM_CREST_FIELD): the shipped crest mask's wave-field
// arm never reaches its 0.08-0.35 window (the field's slopes are too mild -
// measured coverage 0.00-0.1% at every strength), so in-game "crest" foam was
// painted by the texture-normal arm: round blobs at the big-tap scale,
// travelling at the tap's drift (~57 u/s), spatially uncorrelated with the
// actual crests - the reported "round spots of foam travelling across the water
// rather than bands". The V2 mask is field-driven: an absolute breaking
// height (a fixed threshold gives the strength ladder for free, because the
// field's spread grows with sea state; an sd-relative gate is a fixed
// quantile at every strength and has NO ladder - measured), a leading-face
// bias (whitecaps ride the front face), and slope as a bonus, not a gate.
// Raced in simulations/sim_foam_crest_shape.py: coverage ladder
// 0 / 0.16 / 1.5 / 4.0 % at s 0.30 / 0.60 / 0.822 / 1.00, blob elongation
// 2.2-2.3 along the crest lines (texture arm: round, 1.0), and the ribbons
// travel with the crests instead of with the texture.
#if MGE_FOAM_CREST_FIELD
const float MGE_FOAM_CREST_H0 = 20.0;   // crest height where whitecaps start
                                        // (game units of marched relief)
const float MGE_FOAM_CREST_H1 = 30.0;   // full-foam crest height
const float MGE_FOAM_CREST_TEX = 0.25;  // residual texture-mask weight (breakup)
// The relief itself is faded flat near the camera (mgeWaveNearFade, 80-500 u),
// so nearer than ~500 u there is no visible crest to whiten: the V2 distance
// fade tracks the relief's own fade instead of the old 15-50 u onset.
const float MGE_FOAM_CREST_NEAR0 = 400.0;
const float MGE_FOAM_CREST_NEAR1 = 900.0;
#endif
//
// shore swash V2 (MGE_FOAM_SWASH_V2): the shipped swash displaces the band's
// effective depth by 380*(0.15 - |n0.xy|) = -47..+40 u, driven by the same
// scrolling big-tap texture, on a band 45 u deep with a 5-u inner ramp.
// Measured on the real texture (simulations/sim_foam_shore_band.py): 5
// enclosed no-foam holes per 2048-u beach (roundness 0.60), a 2-u hard-edge
// tail with 22.7% of all band crossings <= 8 u, 85% of beach columns folded
// into split bands - all travelling at the tap drift ~57 u/s. That is the
// reported "circles and bands of no-foam moving through the foam near shores, with
// hard edges". V2 re-bases the swash on a constructed 1-D surge along the
// heading (coarse, smooth, curl-free - the same construction and K/W as the
// foam surge: one band per 1100 u at the field's 138 u/s) plus the texture
// term at a quarter amplitude (organic breakup that can no longer punch
// through the band or fold the mapping) and widens the inner ramp. Raced:
// holes 5 -> 0, hard-edge fraction 22.7% -> 0.0%, folds 85% -> 33% (soft).
#if MGE_FOAM_SWASH_V2
const float MGE_FOAM_SWASH_SURGE = 24.0;  // 1-D surge amplitude, world units
const float MGE_FOAM_SWASH_TEX   = 95.0;  // texture-term amplitude (was 380)
const float MGE_FOAM_SHORE_INNER = 12.0;  // band inner ramp depth (was 5.0)
// the pond trim (report: "too much foam mass away from the shore"
// at shallow calm water). The band is bounded by depth, and on gentle
// bathymetry the depth contour lies hundreds of units offshore, a
// whole shallow pond sits inside the window (geometry: at a 3 % slope,
// depth 4.5 u is already 150 u from the waterline, so no depth-based
// profile can hug the line there). The physical lever is weather:
// surf foam needs waves, and a glassy pond should barely foam. The
// band's amplitude and the swash's motion scale with the same weather
// ramp the waves read; the outer falloff is squared and the reach
// trimmed 45 -> 36 to concentrate what remains toward the line.
// Raced (sim_foam_shore_band.py pond section): calm-pond mass -74 %
// (slope-3 %) / -80 % (flat bowl), rain/storm surf kept, the V2
// artifact metrics (holes 0, hard edges ~0) unchanged.
// any foam at all next to shores" in calm weather). The calm floor
// rises to 0.45 and the reach rides the weather instead (calm 22 ->
// storm 36): calm shores keep a visible waterline band while a calm
// pond keeps only rim foam. The motion has its own gentler ramp,
// coupling it to the amplitude ramp pushed the waterline strip dry
// moved the calm strip +0.3 %; with the split ramp the calm strip
// restored to 56 % of pre-trim while the calm-pond mass stayed -58 %).
const float MGE_FOAM_SHORE_CALM = 0.45;  // band amplitude on a calm sea
const float MGE_FOAM_SHORE_CALM_MOTION = 0.25; // swash motion on a calm sea
const float MGE_FOAM_SHORE_W0 = 0.30;    // weather wave-scale ramp start
const float MGE_FOAM_SHORE_W1 = 1.10;    // full-amplitude weather scale
const float MGE_FOAM_SHORE_REACH = 36.0; // storm outer reach (was SHORE_DEPTH 45)
const float MGE_FOAM_SHORE_REACH_CALM = 22.0; // calm outer reach
#endif
#endif


// How strongly a region's own character replaces the default sea look. The
// sea entry is never applied - open water keeps the MGE body colour this stack
// computes, so parity with the patched engine is untouched everywhere except
// the named regions below. 0 disables regional character entirely.
const float MGE_TYPE_TINT = 0.6;

// Signed-distance test with a soft inner border. blend is negative so the
// transition happens inside the box and no seam is ever visible at its edge.
void mgeWaterFactor(inout float factor, vec2 xy, vec2 a, vec2 b, float blend)
{
    vec2 lo = min(a, b), hi = max(a, b);
    if (factor >= 1.0 || xy.x < lo.x || xy.x > hi.x || xy.y < lo.y || xy.y > hi.y)
        return;
    vec2 centre = (lo + hi) * 0.5;
    vec2 halfSize = (hi - lo) * 0.5;
    vec2 d = abs(xy - centre) - halfSize;
    float sdf = length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
    if (sdf < 0.0)
        factor = max(factor, smoothstep(0.0, blend, sdf));
}

void mgeWaterFactorRadial(inout float factor, vec2 xy, vec2 centre, float radius)
{
    float d = length(xy - centre);
    factor = max(factor, 1.0 - smoothstep(radius * 0.7, radius, d));
}

// Resolve the water character at a world position. Returns the regional colour
// and its behaviour params, plus how strongly the region applies at all.
// params = (wave strength, foam intensity, caustic intensity, shore blend)
void mgeResolveWaterType(vec2 xy, float isInterior, out vec3 typeColour, out vec4 typeParams, out float typeWeight)
{
    typeColour = MGE_WATER_SEA.rgb;
    typeParams = MGE_TYPE_SEA;
    typeWeight = 0.0;

    if (isInterior > 0.5)
    {
        typeColour = MGE_WATER_INTERIOR.rgb;
        typeParams = MGE_TYPE_INTERIOR;
        typeWeight = 1.0;
        return;
    }

    // Cheap bounding test: water outside the Vvardenfell box skips all of it.
    if (xy.x > MGE_VV_BOX.x || xy.y > MGE_VV_BOX.y
        || xy.x < MGE_VV_BOX.z || xy.y < MGE_VV_BOX.w)
        return;

    float calm = 0.0, swamp = 0.0, sulphur = 0.0;
    mgeWaterFactor(calm, xy, MGE_CALM1_A, MGE_CALM1_B, MGE_CALM1_BLEND);
    mgeWaterFactor(calm, xy, MGE_CALM2_A, MGE_CALM2_B, MGE_CALM2_BLEND);
    mgeWaterFactor(calm, xy, MGE_CALM3_A, MGE_CALM3_B, MGE_CALM3_BLEND);
    mgeWaterFactor(calm, xy, MGE_CALM4_A, MGE_CALM4_B, MGE_CALM4_BLEND);
    mgeWaterFactor(calm, xy, MGE_CALM5_A, MGE_CALM5_B, MGE_CALM5_BLEND);
    mgeWaterFactor(swamp, xy, MGE_SWAMP1_A, MGE_SWAMP1_B, MGE_SWAMP1_BLEND);
    mgeWaterFactorRadial(sulphur, xy, MGE_SULPHUR1_POS, MGE_SULPHUR1_RADIUS);

    // Later entries win where they overlap: a sulphur lake inside a calm bay
    // should read as sulphur.
    typeColour = mix(typeColour, MGE_WATER_CALM.rgb, calm);
    typeParams = mix(typeParams, MGE_TYPE_CALM, calm);
    typeColour = mix(typeColour, MGE_WATER_SWAMP.rgb, swamp);
    typeParams = mix(typeParams, MGE_TYPE_SWAMP, swamp);
    typeColour = mix(typeColour, MGE_WATER_SULPHUR.rgb, sulphur);
    typeParams = mix(typeParams, MGE_TYPE_SULPHUR, sulphur);
    typeWeight = max(max(calm, swamp), sulphur);
}
#endif // MGE_WATER_DATA_GLSL
