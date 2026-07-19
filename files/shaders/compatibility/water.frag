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
const float DEPTH_FADE = 0.15;

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
                                                   // (stock 0.10; reduced - narrows the pale
                                                   // contact halo where island shores meet their reflection)
const float REFR_BUMP = 0.07;                      // refraction distortion amount
// XE Mod Water.fx UnderwaterPS verbatim: from-below fresnel curve and the
// distance constant of the refraction-to-fog fade.
const float MGE_UW_FRESNEL_BIAS = 1.12;
const float MGE_UW_FRESNEL_SLOPE = 0.65;
const float MGE_UW_FRESNEL_POWER = 8.0;
const float MGE_UW_REFRACTION_FADE = 500.0;

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
uniform vec3 playerPos;

varying vec3 worldPos;

varying vec2 rippleMapUV;

varying vec4 position;
varying float linearDepth;

uniform sampler2D normalMap;

uniform float osg_SimulationTime;

uniform float near;
uniform float far;

uniform float rainIntensity;

uniform vec2 screenRes;

#define PER_PIXEL_LIGHTING 0

#include "shadows_fragment.glsl"
#include "lib/light/lighting.glsl"
#include "fog.glsl"
#include "lib/water/fresnel.glsl"
#include "lib/water/rain_ripples.glsl"
#include "lib/view/depth.glsl"

void main(void)
{
    vec2 UV = worldPos.xy / (8192.0*5.0) * 3.0;

    float shadow = unshadowedLightRatio(linearDepth);
    // MGE XE Mod Shadow.fx: shadow strength scales with sun visibility
    // (x *= 0.25 + 0.75*sunVis) — cloud cover fades shadows instead of
    // leaving full-strength shadows under an overcast sky. sunVis rides
    // light 0's specular alpha (RenderingManager::setSunColour).
    shadow = 1.0 - (1.0 - shadow) * (0.25 + 0.75 * clamp(lcalcSpecular(0).a, 0.0, 1.0));

    vec2 screenCoords = gl_FragCoord.xy / screenRes;

    #define waterTimer osg_SimulationTime

    vec3 normal0 = 2.0 * texture2D(normalMap,normalCoords(UV, 0.05, 0.04, waterTimer, -0.015, -0.005, vec3(0.0,0.0,0.0))).rgb - 1.0;
    vec3 normal1 = 2.0 * texture2D(normalMap,normalCoords(UV, 0.1,  0.08, waterTimer,  0.02,   0.015, normal0)).rgb - 1.0;
    vec3 normal2 = 2.0 * texture2D(normalMap,normalCoords(UV, 0.25, 0.07, waterTimer, -0.04,  -0.03,  normal1)).rgb - 1.0;
    vec3 normal3 = 2.0 * texture2D(normalMap,normalCoords(UV, 0.5,  0.09, waterTimer,  0.03,   0.04,  normal2)).rgb - 1.0;
    vec3 normal4 = 2.0 * texture2D(normalMap,normalCoords(UV, 1.0,  0.4,  waterTimer, -0.02,   0.1,   normal3)).rgb - 1.0;
    vec3 normal5 = 2.0 * texture2D(normalMap,normalCoords(UV, 2.0,  0.7,  waterTimer,  0.1,   -0.06,  normal4)).rgb - 1.0;

    vec4 rainRipple;

    if (rainIntensity > 0.01)
        rainRipple = rainCombined(position.xy/1000.0, waterTimer) * clamp(rainIntensity, 0.0, 1.0);
    else
        rainRipple = vec4(0.0);

    vec3 rippleAdd = rainRipple.xyz * 10.0;

    float distToCenter = length(rippleMapUV - vec2(0.5));
    float blendClose = smoothstep(0.001, 0.02, distToCenter);
    float blendFar = 1.0 - smoothstep(0.3, 0.4, distToCenter);
    float distortionLevel = 2.0;
    rippleAdd += distortionLevel * vec3(texture2D(rippleMap, rippleMapUV).ba * blendFar * blendClose, 0.0);

    vec2 bigWaves = BIG_WAVES;
    vec2 midWaves = mix(MID_WAVES, MID_WAVES_RAIN, rainIntensity);
    vec2 smallWaves = mix(SMALL_WAVES, SMALL_WAVES_RAIN, rainIntensity);
    float bump = mix(BUMP,BUMP_RAIN,rainIntensity);

    vec3 normal = (normal0 * bigWaves.x + normal1 * bigWaves.y + normal2 * midWaves.x +
                   normal3 * midWaves.y + normal4 * smallWaves.x + normal5 * smallWaves.y + rippleAdd);
    normal = normalize(vec3(-normal.x * bump, -normal.y * bump, normal.z));

    vec3 sunWorldDir = normalize((gl_ModelViewMatrixInverse * vec4(lcalcPosition(0).xyz, 0.0)).xyz);
    vec3 cameraPos = (gl_ModelViewMatrixInverse * vec4(0,0,0,1)).xyz;
    vec3 viewDir = normalize(position.xyz - cameraPos.xyz);

    float sunFade = length(gl_LightModel.ambient.xyz);

    // fresnel
    float ior = (cameraPos.z>0.0)?(1.333/1.0):(1.0/1.333); // air to water; water to air
    float fresnel;
    if (cameraPos.z > 0.0)
    {
        // MGE XE Mod Water.fx fresnel: 0.02 + (0.9988 - slope*cos)^16 -
        // noticeably more reflective at mid angles than the physical
        // dielectric term, so open water carries more sky (the MGE look).
        // slope: 0.28 = MGE verbatim; raised slightly - trims mid-angle
        // reflectivity ~20-25% while keeping grazing/far-water brightness.
        const float mgeFresnelSlope = 0.34;
        float fcos = clamp(dot(-viewDir, normal), 0.0, 1.0);
        fresnel = 0.02 + pow(clamp(0.9988 - mgeFresnelSlope * fcos, 0.0, 1.0), 16.0);
    }
    else
    {
        // MGE XE Mod Water.fx UnderwaterPS fresnel: full internal reflection
        // only near grazing (~79 deg), unlike the physical dielectric term
        // (critical angle 49 deg) which mirrors most of the surface. From
        // below the surface mostly shows the refracted above-water world.
        float fcos = clamp(dot(viewDir, normal), 0.0, 1.0);
        fresnel = pow(clamp(MGE_UW_FRESNEL_BIAS - MGE_UW_FRESNEL_SLOPE * fcos, 0.0, 1.0), MGE_UW_FRESNEL_POWER);
    }

    vec2 screenCoordsOffset = normal.xy * REFL_BUMP;
#if @waterRefraction
    float depthSample = linearizeDepth(sampleRefractionDepthMap(screenCoords), near, far);
    float surfaceDepth = linearizeDepth(gl_FragCoord.z, near, far);
    float realWaterDepth = depthSample - surfaceDepth;  // undistorted water depth in view direction, independent of frustum
    float depthSampleDistorted = linearizeDepth(sampleRefractionDepthMap(screenCoords - screenCoordsOffset), near, far);
    float waterDepthDistorted = max(depthSampleDistorted - surfaceDepth, 0.0);
    screenCoordsOffset *= clamp(realWaterDepth / BUMP_SUPPRESS_DEPTH, 0.0, 1.0);
#endif
    // reflection
    vec3 reflection = sampleReflectionMap(screenCoords + screenCoordsOffset).rgb;

    // MGE XE Mod Water.fx depthBaseColor: deep-water body colour is
    // WEATHER-LIT (sun + 2*sky + fog terms), not a fixed dark constant —
    // under a bright sky deep water stays mid-luminance instead of going
    // black (stock: WATER_COLOR * sunFade, ~3x darker on a hazy day).
    vec3 waterColor = lcalcDiffuse(0).xyz * vec3(0.03, 0.04, 0.05)
        + (2.0 * mgeSampleSkyCol() + gl_Fog.color.xyz) * vec3(0.075, 0.08, 0.085);

    vec4 sunSpec = lcalcSpecular(0);
    // alpha component is sun visibility; we want to start fading lighting effects when visibility is low
    sunSpec.a = min(1.0, sunSpec.a / SUN_SPEC_FADING_THRESHOLD);

    // specular
    const float SPEC_MAGIC = 1.55; // from the original blender shader, changing it makes the spec vanish or become too bright

    vec3 specNormal = normalize(vec3(normal.x * SPEC_BUMPINESS, normal.y * SPEC_BUMPINESS, normal.z));
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
        // the from-below refraction map is the UNDERWATER scene re-rendered
        // z-squashed (water.cpp refraction clip + scale), and unfogged it
        // reads as a displaced copy of the seafloor on the surface.
        float uwDist = length(position.xyz - cameraPos.xyz);
        refraction = mix(gl_Fog.color.rgb, clamp(refraction * 1.5, 0.0, 1.0), exp(-uwDist / MGE_UW_REFRACTION_FADE));
    }
    else
    {
        float depthCorrection = sqrt(1.0 + 4.0 * DEPTH_FADE * DEPTH_FADE);
        float factor = DEPTH_FADE * DEPTH_FADE / (-0.5 * depthCorrection + 0.5 - waterDepthDistorted / VISIBILITY) + 0.5 * depthCorrection + 0.5;
        refraction = mix(refraction, waterColor, clamp(factor, 0.0, 1.0));
    }

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

    gl_FragData[0].rgb += specular * sunSpec.rgb + rainSpecular;

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
    // raw refraction - stock's viewFactor inverts this, making shallow bays
    // read as dry seabed from low camera angles.
    shoreOffset = max(shoreOffset, clamp(fresnel * 3.0, 0.0, 1.0));
    // No-geometry guard: near shore silhouettes the distorted refraction
    // sample can land BEYOND all submerged geometry - the refraction RTT
    // there holds its empty background (bright scatter sky under the MGE
    // fog), which punches white wobble-edged patches into dark water.
    // If the distorted sample hit (near) the far plane, there is no seabed
    // to show - suppress the raw-refraction path entirely.
    if (depthSampleDistorted > far * 0.9)
        shoreOffset = 1.0;
    gl_FragData[0].rgb = mix(rawRefraction, gl_FragData[0].rgb, shoreOffset);
#endif

// ==== WATER PROBE (diagnostic, normally 0) ====
// Mode 1: false-colour R = fresnel, G = reflection luminance,
//         B = refraction luminance.
// Mode 2: raw mirror - display the reflection RTT sample directly (no
//         distortion offset), to see the RTT's actual CONTENT.
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
// ==== END TEMP WATER PROBE ====

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

#if !@disableNormals
    gl_FragData[1].rgb = normalize(gl_NormalMatrix * normal) * 0.5 + 0.5;
#endif

    applyShadowDebugOverlay();
}
