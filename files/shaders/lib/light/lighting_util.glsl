#ifndef LIB_LIGHTING_UTIL
#define LIB_LIGHTING_UTIL

#include "lib/util/quickstep.glsl"

#if @lightingMethodUBO

const int mask = int(0xff);
const ivec4 shift = ivec4(int(0), int(8), int(16), int(24));

vec3 unpackRGB(int data)
{
    return vec3( (float(((data >> shift.x) & mask)) / 255.0)
                ,(float(((data >> shift.y) & mask)) / 255.0)
                ,(float(((data >> shift.z) & mask)) / 255.0));
}

vec4 unpackRGBA(int data)
{
    return vec4( (float(((data >> shift.x) & mask)) / 255.0)
                ,(float(((data >> shift.y) & mask)) / 255.0)
                ,(float(((data >> shift.z) & mask)) / 255.0)
                ,(float(((data >> shift.w) & mask)) / 255.0));
}

/* Layout:
packedColors: 8-bit unsigned RGB packed as (diffuse, ambient, specular).
              sign bit is stored in unused alpha component
attenuation: constant, linear, quadratic, light radius (as defined in content)
*/
struct LightData
{
    ivec4 packedColors;
    vec4 position;
    vec4 attenuation;
};

uniform int PointLightIndex[@maxLights];
uniform int PointLightCount;

// Defaults to shared layout. If we ever move to GLSL 140, std140 layout should be considered
uniform LightBufferBinding
{
    LightData LightBuffer[@maxLightsInScene];
};

#elif @lightingMethodPerObjectUniform

/* Layout:
--------------------------------------- -----------
|  pos_x  |  ambi_r  |  diff_r  |  spec_r         |
|  pos_y  |  ambi_g  |  diff_g  |  spec_g         |
|  pos_z  |  ambi_b  |  diff_b  |  spec_b         |
|  att_c  |  att_l   |  att_q   |  radius/spec_a  |
 --------------------------------------------------
*/
uniform mat4 LightBuffer[@maxLights];
uniform int PointLightCount;

#endif

float lcalcConstantAttenuation(int lightIndex)
{
#if @lightingMethodPerObjectUniform
    return LightBuffer[lightIndex][0].w;
#else
    return LightBuffer[lightIndex].attenuation.x;
#endif
}

float lcalcLinearAttenuation(int lightIndex)
{
#if @lightingMethodPerObjectUniform
    return LightBuffer[lightIndex][1].w;
#else
    return LightBuffer[lightIndex].attenuation.y;
#endif
}

float lcalcQuadraticAttenuation(int lightIndex)
{
#if @lightingMethodPerObjectUniform
    return LightBuffer[lightIndex][2].w;
#else
    return LightBuffer[lightIndex].attenuation.z;
#endif
}

float lcalcRadius(int lightIndex)
{
#if @lightingMethodPerObjectUniform
    return LightBuffer[lightIndex][3].w;
#else
    return LightBuffer[lightIndex].attenuation.w;
#endif
}

float lcalcIllumination(int lightIndex, float dist)
{
    float illumination = 1.0 / (lcalcConstantAttenuation(lightIndex) + lcalcLinearAttenuation(lightIndex) * dist + lcalcQuadraticAttenuation(lightIndex) * dist * dist);
#if !@classicFalloff
    // Fade illumination between the radius and the radius doubled to diminish pop-in
    illumination *= 1.0 - quickstep((dist / lcalcRadius(lightIndex)) - 1.0);
#endif
    return illumination;
}

vec3 lcalcPosition(int lightIndex)
{
#if @lightingMethodPerObjectUniform
    return LightBuffer[lightIndex][0].xyz;
#else
    return LightBuffer[lightIndex].position.xyz;
#endif
}

vec3 lcalcDiffuse(int lightIndex)
{
#if @lightingMethodPerObjectUniform
    return LightBuffer[lightIndex][2].xyz;
#else
    return unpackRGB(LightBuffer[lightIndex].packedColors.x) * float(LightBuffer[lightIndex].packedColors.w);
#endif
}

vec3 lcalcAmbient(int lightIndex)
{
#if @lightingMethodPerObjectUniform
    return LightBuffer[lightIndex][1].xyz;
#else
    return unpackRGB(LightBuffer[lightIndex].packedColors.y);
#endif
}

vec4 lcalcSpecular(int lightIndex)
{
#if @lightingMethodPerObjectUniform
    return LightBuffer[lightIndex][3];
#else
    return unpackRGBA(LightBuffer[lightIndex].packedColors.z);
#endif
}

// Per-subgraph clamp override: actor faces/armor carry their contrast baked
// into the texture and clip badly at light peaks. The engine raises this
// uniform on actor roots when [Shaders] 'clamp lighting actors' is enabled;
// everything else keeps the global @clamp behaviour (MGE tonemap curve).
uniform float uClampLightingActor;       // raised on actor subgraphs (identity)
uniform float uClampLightingActorsGate;  // the live [Shaders] 'clamp lighting actors' switch

void clampLightingResult(inout vec3 lighting)
{
#if @clamp
    lighting = clamp(lighting, vec3(0.0), vec3(1.0));
#else
    if (uClampLightingActor > 0.5 && uClampLightingActorsGate > 0.5)
        lighting = clamp(lighting, vec3(0.0), vec3(1.0));
    else
        lighting = max(lighting, 0.0);
#endif
}

// MGE XE-style per-object tonemap: polynomial maps [0, 2.2] -> [0, 1].
vec3 perObjectTonemap(vec3 c)
{
    c = clamp(c, 0.0, 2.2);
    return (((0.0548303 * c - 0.189786) * c - 0.154732) * c + 1.12969) * c;
}

// User option: the cloud-cover shadow fade. 0.25 = MGE XE behaviour
// (cloud cover weakens shadows: overcast shadows run ~half of vanilla
// OpenMW's depth), 1.0 = no fade (shadows keep near-vanilla strength in
// every weather). OpenMW Graphics Extender rewrites the value on this
// line in the installed copy; keep the define on one line. At 0.25 the
// arithmetic below is identical to the original hardcoded form.
#define MGE_CLOUD_SHADOW_FADE_FLOOR 0.25

// MGE XE shadow receiver, ported from "XE Mod Shadow.fx" (MGE XE 0.16.0).
// shade (0.4) is the half-saturation constant of the saturating curve
// x/(shade+x) on incoming sun luminance - not a linear factor (the first
// port used it as one and shipped shadows 3-6x weaker than MGE). The
// result multiplies the final colour, ambient included
// (XE Main.fx: SrcBlend=Zero, DestBlend=InvSrcColor) - MGE's own comment:
// "Non-standard shadow luminance, to create sufficient contrast when
// ambient is high". Cloud cover enters inside x (x *= 0.25 + 0.75*sunVis),
// weakening overcast shadows along the same curve. Deliberate delta from
// XE: we apply this before fog, so fog is never shadowed and XE's
// pow(fogatt, 2) term is unnecessary; shadows reach slightly deeper into
// dense-weather haze than XE's (bounded in scripts sim: <= 43/255 at 50%
// fog, zero at no fog, and the shadow-map distance fade ends shadows long
// before clear-weather fog matters).
vec3 mgeShadowMult(float shadowing, vec3 viewNormal)
{
    float lambert = clamp(dot(viewNormal, normalize(lcalcPosition(0))), 0.0, 1.0);
    float x = lambert * dot(lcalcDiffuse(0).xyz, vec3(0.36, 0.53, 0.11));
    x *= MGE_CLOUD_SHADOW_FADE_FLOOR
        + (1.0 - MGE_CLOUD_SHADOW_FADE_FLOOR) * clamp(lcalcSpecular(0).a, 0.0, 1.0);
    float light = x / (0.4 + x);
    return vec3(1.0) - (1.0 - shadowing) * light * vec3(1.0, 0.97, 0.81);
}

#endif
