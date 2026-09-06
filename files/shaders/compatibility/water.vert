#version 120

#if @useUBO
    #extension GL_ARB_uniform_buffer_object : require
#endif

#if @useGPUShader4
    #extension GL_EXT_gpu_shader4: require
#endif

#include "lib/core/vertex.h.glsl"

varying vec4  position;
varying float linearDepth;

#include "shadows_vertex.glsl"
#include "lib/view/depth.glsl"

// water.frag with the hoist; the fragment now decodes varyings and pays
// no core footprint at all. mge_fog.glsl declares playerPos itself (do
// not redeclare below).
#define WX_NEED_FULL_CORE 1
#define MGE_WX_V4 1
#define MGE_WX_RESCUE 1
#include "lib/light/lighting_util.glsl"
#include "mge_fog.glsl"

// Displaced wave geometry (Full tier, water layer): the vertex
// stage displaces the radial mesh with the same height field the fragment
// shades with (mge_water_data.glsl - the strength chain, the octave core).
// MGE_WATER_VERTEX_STAGE trims the fragment-only machinery (normals,
// raymarch) out of this compile; everything the displacement calls is the
// one shared definition. docs/full-water-geometry-design.md (WFR repo).
#define MGE_WATER_VERTEX_STAGE 1
#include "mge_water_data.glsl"

uniform vec3 nodePosition;

varying vec3 worldPos;
varying vec2 rippleMapUV;

#if MGE_WATER_WAVE_SHAPES && MGE_WATER_DISPLACE
// Runtime gate: fed 1 by the patched engine only while the radial mesh is
// live (mwrender/water.cpp ShaderWaterStateSetUpdater); a stock exe never
// declares it and GLSL reads 0, so this whole path multiplies out there -
// the mgeWeatherUniforms pattern, RP byte-identity rides it.
uniform float mgeWaterDisplace;
uniform float osg_SimulationTime;
varying float mgeDispV;
varying vec4 mgeScreenPosClamp;
// height map around the camera. params = (origin.xy, 1/extent, valid).
// Stock never binds these - valid reads 0, attenuation stays 1.
uniform sampler2D mgeShoreMap;
uniform vec4 mgeShoreParams;
#endif

void main(void)
{
    vec4 mgeVert = gl_Vertex;
#if MGE_WATER_WAVE_SHAPES && MGE_WATER_DISPLACE
    mgeDispV = 0.0;
    if (mgeWaterDisplace > 0.5)
    {
        // Camera in model space - the node is translate-only, so model
        // distances equal world distances (same derivation the fragment's
        // raymarch block uses).
        vec3 mgeCamModel = (gl_ModelViewMatrixInverse * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
        float mgeDCam = distance(gl_Vertex.xyz, mgeCamModel);
        vec2 mgeWxy = gl_Vertex.xy + nodePosition.xy;
        // Waves fade to nothing over shallow and dry ground: raced in the
        // sand exposure and zero waterline sweep on every tested beach
        // slope while keeping full waves past 90 u of depth. The 15 guards
        // the height map's 192 u texel blur.
        float mgeShoreAtt = 1.0;
        float mgeShoreBand = 0.0;   // 1 at the waterline, 0 past the surf band
        if (mgeShoreParams.w > 0.5)
        {
            vec2 mgeShoreUV = (mgeWxy - mgeShoreParams.xy) * mgeShoreParams.z;
            float mgeTerrH = texture2DLod(mgeShoreMap, mgeShoreUV, 0.0).r;
            float mgeWDepth = nodePosition.z - mgeTerrH;
            // deep term: full waves past 90 u of depth (434 race); wash
            // term: a bounded surf floor so the waterline breathes (435
            // race - see MGE_WAVE_SHORE_WASH). max() composes them.
            // amplitude the local water column can actually hold, so a
            // trough bottoms out MGE_WAVE_COLUMN_MARGIN above the seabed
            // BY construction. It replaces the hand-fitted
            // smoothstep(15, 90) of 434, which was far more conservative
            // than the safety bound at mid depths and cost the surf its
            // motion; wash term: the bounded surf floor so the waterline
            // breathes (435 race - see MGE_WAVE_SHORE_WASH). max() composes.
            mgeShoreAtt = max(MGE_WAVE_SHORE_WASH * smoothstep(-10.0, 15.0, mgeWDepth),
                              clamp((mgeWDepth - MGE_WAVE_COLUMN_MARGIN)
                                    / MGE_WAVE_COLUMN_MAX, 0.0, 1.0));
            mgeShoreBand = 1.0 - smoothstep(0.0, MGE_WAVE_SURGE_BAND, mgeWDepth);
        }
#if MGE_WATER_XE_FIELD
        if (mgeWaterXeField > 0.5)
        {
            // the XE field, verbatim law (XE Mod Water.fx:134-141):
            // height from the original volume texture, XE's own window,
            // amplitude = ini base x the weather multiplier (the mod's
            // semantics; raw scale, not the shape-field mapping).
            float mgeWinXe = clamp(mgeDCam / MGE_XE_WIN_INNER, 0.0, 1.0)
                           * clamp(1.0 - mgeDCam / MGE_XE_WIN_OUTER, 0.0, 1.0);
            if (mgeWinXe > 0.0)
            {
                mgeDispV = mgeShoreAtt * mgeWinXe * MGE_WAVE_XE_BASE * mgeWeatherWaveScale()
                         * mgeXeHeight(mgeWxy, mgeDCam, osg_SimulationTime);
                mgeVert.z += mgeDispV;
            }
        }
        else
#endif
        {
        float mgeWin = mgeDispWindow(mgeDCam);
        if (mgeWin > 0.0)
        {
            float mgeS = mgeWaveStrengthResolve(mgeWxy);
            if (mgeS > 0.0)
            {
                // Same timer expression as the fragment's wave field
                // (waterTimer * 0.6 * MGE_WAVE_SPEED) - the two stages must
                // sample the same instant or the shading detaches from the
                // shape.
                float mgeT = osg_SimulationTime * 0.6 * MGE_WAVE_SPEED;
                mgeDispV = mgeShoreAtt * (1.0 - mgeShoreBand) * mgeWin
                         * mgeDispHeight(mgeWxy, mgeT, mgeDCam,
                                         mgeWaveStrengthFanout(mgeS),
                                         normalize(MGE_WAVE_HEADING));
                // the shore surge. Same phase expression, constants and
                // clock as the foam's own swash (MGE_FOAM_SURGE_K/_W on the
                // raw timer, along MGE_WAVE_HEADING), so the waterline and
                // the foam band breathe together instead of independently.
                // (0.5 - 0.5*sin) keeps it in [0,1], subtracted - so the
                // surface only ever sits AT or below the still level here,
                // and no crest can cross onto dry ground.
                float mgeSurgePh = dot(mgeWxy, normalize(MGE_WAVE_HEADING))
                                     * MGE_FOAM_SURGE_K
                                 + osg_SimulationTime * MGE_FOAM_SURGE_W
                                     * MGE_WAVE_TRAVEL;
                mgeDispV -= MGE_WAVE_SURGE_AMP * mgeS * mgeShoreBand * mgeWin
                          * (0.5 - 0.5 * sin(mgeSurgePh));
                mgeVert.z += mgeDispV;
            }
        }
        }
    }
#endif

    gl_Position = modelToClip(mgeVert);

    position = mgeVert;

    worldPos = position.xyz + nodePosition.xyz;
    rippleMapUV = (worldPos.xy - playerPos.xy + (@rippleMapSize * @rippleMapWorldScale / 2.0)) / @rippleMapSize / @rippleMapWorldScale;

    vec4 viewPos = modelToView(mgeVert);
    linearDepth = getLinearDepth(gl_Position.z, viewPos.z);

#if MGE_WATER_WAVE_SHAPES && MGE_WATER_DISPLACE
    // XE's screenposclamp (XE Mod Water.fx:147-151): a second clip position
    // at the vertex lowered by |displacement|, so the fragment's reflection
    // lookup never samples below the displaced surface. Identical to
    // gl_Position at zero displacement.
    // clamp draws a line somewhere: raw, it folds the lookup across the
    // horizon; capped at the vertex's own elevation, it pins every
    // above-horizon sample onto the horizon row; faded by elevation, it
    // cuts - and no fade width helps, because at swim height the whole
    // visible sea sits within ~3 deg of the horizon. Off is the only
    // continuous form, and it is the planar lookup the raymarch tier has
    // always used. The varying stays (identical to gl_Position now) so
    // flipping the define restores XE's construct for comparison.
    vec4 mgeLowered = mgeVert;
#if MGE_WATER_REFL_CLAMP
    mgeLowered.z -= abs(mgeDispV);
#endif
    mgeScreenPosClamp = modelToClip(mgeLowered);
#endif

    setupShadowCoords(viewPos, normalize((gl_NormalMatrix * gl_Normal).xyz));

    mgeWxEmitVaryings(); // scene verdict hoist (mge_fog.glsl)
}
