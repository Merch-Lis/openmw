#version 120

#include "lib/core/vertex.h.glsl"

#include "lib/sky/passes.glsl"

uniform int pass;

varying vec4 passColor;
varying vec2 diffuseMapUV;
// MGE XE fog port: view-space position for per-pixel scattering direction
varying vec3 passViewPos;

void main()
{
    vec4 vertex = gl_Vertex;

    // MGE-equivalent sky ownership (XE SkyVS "screw around with skydome",
    // adapted to the measured mesh). Vanilla sky_atmosphere.nif is a 32-vert
    // cylinder band: rings at mesh z=-100 / z=-800 (trishape rotation flips
    // z, so world +100..+800 over radius ~1587 = 3.6°..26.7° elevation).
    // Vanilla shows the raw clear colour (the palette fog) above and below
    // the band; MGE fixes that by stretching the band and recolouring the
    // engine fog. Here paintAtmosphere colours per-pixel by view direction,
    // so geometry only needs coverage: reshape the band into a closed dome,
    // lower ring well below the horizon, upper ring converged to the zenith
    // (16-gon pinhole ~0.3° wide, invisible). Vertex distances kept ~6000 so
    // no far-plane interaction. Assumes the vanilla mesh (two rings split at
    // mesh z = -400); a replacer sky_atmosphere.nif may need retuning.
    // OpenMW's optimizer flattens the trishape's flip-rotation into the
    // vertices by default (scenemanager.cpp FLATTEN_STATIC_TRANSFORMS), so
    // the shader may see z = +100/+800 (baked, +z up) or -100/-800 (raw,
    // flipped by the node matrix). Sign-relative reshaping is correct under
    // both: the horizon-ward ring flips sign (ends below the horizon), the
    // zenith-ward ring keeps it.
    if (pass == PASS_ATMOSPHERE)
    {
        if (abs(vertex.z) > 400.0)
        {
            // upper ring (|z| ~ 800) -> zenith cone (0.3 degree pinhole)
            vertex.xy *= 0.02;
            vertex.z = sign(vertex.z) * 6000.0;
        }
        else
        {
            // lower ring (|z| ~ 100) -> ~37 degrees below the horizon
            vertex.z = -sign(vertex.z) * 1200.0;
        }
    }

    gl_Position = modelToClip(vertex);
    passColor = gl_Color;
    passViewPos = (gl_ModelViewMatrix * vertex).xyz;

    if (pass == PASS_CLOUDS)
        diffuseMapUV = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    else
        diffuseMapUV = gl_MultiTexCoord0.xy;
}
