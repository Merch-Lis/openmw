#define SHADOWS @shadows_enabled

// ============================================================================
// redux plus variant of shadows_fragment.glsl (deployed to the stock-exe
// tier AS shadows_fragment.glsl; the file next to this one is the Full
// tier's). The Full filter rides the engine's 'soft shadows' setting
// through a fork-provided shader define and a per-map shadow-space
// matrix uniform - both exist only on the patched exe, so that file
// cannot compile on stock. (No fork token may appear anywhere in this
// file, comments included: the stock shader manager substitutes tokens
// by plain text search and errors on unknown ones.) This variant
// carries the same 8-tap rotated-spiral filter driven entirely by tokens
// the stock 0.51 shader manager provides. Deliberate deltas from Full:
//   - filter axes from screen-space derivatives (the Full tier's tangent
//     frame needs the fork-only matrix uniform); this is the Full file's
//     own documented fallback path;
//   - no pseudo-PCSS penumbra widening: minimum-radius anti-aliasing
//     only, shadow edges soften by about a texel and no more;
//   - agreement early-out: if the first 4 taps agree the fragment is
//     fully lit or fully shadowed, the last 4 are skipped - only
//     penumbra pixels pay the full 8.
// OpenMW Graphics Extender rewrites the two option lines below; keep
// each define on one line.
// ============================================================================

// 1 = 8-tap soft filtering, 0 = the stock single hardware tap.
#define MGE_SOFT_SHADOWS 1

// Must match 'shadow map resolution' in settings.cfg. Texel sizing only:
// a mismatch filters somewhat too wide or too narrow, nothing worse.
#define MGE_SHADOWMAP_RES 2048.0

#if SHADOWS
    uniform float maximumShadowMapDistance;
    uniform float shadowFadeStart;
    @foreach shadow_texture_unit_index @shadow_texture_unit_list
        uniform sampler2DShadow shadowTexture@shadow_texture_unit_index;
        varying vec4 shadowSpaceCoords@shadow_texture_unit_index;

#if @perspectiveShadowMaps
        varying vec4 shadowRegionCoords@shadow_texture_unit_index;
#endif
    @endforeach

#if MGE_SOFT_SHADOWS

#define SHADOWMAP_RES (MGE_SHADOWMAP_RES * 0.5)

// Minimum texels the filter should span. 1.3 = the Full tier's
// 366/367): beyond the first cascade boundary texels run 1-3u and a
// straight shadow edge serrates at that scale - a 3-texel filter spans
// the serration and melts it. Cost: none (the same 8 taps, spread
// wider); shadow edges soften ~3 texels everywhere.
#define FILTER_MIN_TEXELS 3.0

// Interleaved Gradient Noise - smooth spatial variation for rotation
float getIGNRotation()
{
    float noise = fract(52.9829189 * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y));
    return noise * 6.283185;
}

// Precomputed 8-tap spiral with alternating flip
// Designed so rotated copies interleave rather than overlap
const vec2 spiralDisc[8] = vec2[8](
    vec2(-0.7071,  0.7071),
    vec2( 0.0000, -0.8750),
    vec2( 0.5303,  0.5303),
    vec2(-0.6250,  0.0000),
    vec2( 0.3536, -0.3536),
    vec2( 0.0000,  0.3750),
    vec2(-0.1768, -0.1768),
    vec2( 0.1250,  0.0000)
);

float getFilteredShadowing(sampler2DShadow tex, vec4 coord)
{
    vec3 shadowUV = coord.xyz / coord.w;
    float texelScale = coord.w / SHADOWMAP_RES;

    // Filter directions from screen-space derivatives (the stock-safe
    // path; see the header note)
    vec3 filterX = normalize(dFdx(shadowUV));
    vec3 filterY = normalize(dFdy(shadowUV));

    // Enforce orthogonality between filter axes
    filterY = normalize(cross(filterX, cross(filterX, filterY)));

    // Build offset vectors (scaled to shadow map texels)
    vec4 offs_x = vec4(filterX, 0.0) * texelScale;
    vec4 offs_y = vec4(filterY, 0.0) * texelScale;

    // ---- Ensure minimum texel coverage (prevents undersampling at distance) ----
    float minSize = texelScale * FILTER_MIN_TEXELS;
    offs_x *= max(1.0, minSize / length(offs_x.xy));
    offs_y *= max(1.0, minSize / length(offs_y.xy));

    // ---- Sample shadow map with rotated spiral disc ----
    float rotation = getIGNRotation();
    float c = cos(rotation);
    float s = sin(rotation);

    float shadow = 0.0;
    for (int i = 0; i < 4; i++)
    {
        vec2 p = spiralDisc[i];
        vec2 rotated = vec2(p.x * c - p.y * s, p.x * s + p.y * c);
        shadow += shadow2DProj(tex, coord + offs_x * rotated.x + offs_y * rotated.y).r;
    }

    // Agreement early-out: interiors and fully lit areas are spatially
    // coherent, so whole warps take this path together; only shadow
    // edges continue to the full spiral.
    if (shadow < 0.001 || shadow > 3.999)
        return shadow * 0.25;

    for (int i = 4; i < 8; i++)
    {
        vec2 p = spiralDisc[i];
        vec2 rotated = vec2(p.x * c - p.y * s, p.x * s + p.y * c);
        shadow += shadow2DProj(tex, coord + offs_x * rotated.x + offs_y * rotated.y).r;
    }

    return shadow * 0.125;
}

#endif // MGE_SOFT_SHADOWS

#endif // shadows

// ============================================================================

float unshadowedLightRatio(float distance)
{
    float shadowing = 1.0;
#if SHADOWS
#if @limitShadowMapDistance
    float fade = clamp((distance - shadowFadeStart) / (maximumShadowMapDistance - shadowFadeStart), 0.0, 1.0);
    if (fade == 1.0)
        return shadowing;
#endif
    bool doneShadows = false;
    @foreach shadow_texture_unit_index @shadow_texture_unit_list
        if (!doneShadows)
        {
            vec3 shadowXYZ = shadowSpaceCoords@shadow_texture_unit_index.xyz / shadowSpaceCoords@shadow_texture_unit_index.w;
#if @perspectiveShadowMaps
            vec3 shadowRegionXYZ = shadowRegionCoords@shadow_texture_unit_index.xyz / shadowRegionCoords@shadow_texture_unit_index.w;
#endif
            if (all(lessThan(shadowXYZ.xy, vec2(1.0, 1.0))) && all(greaterThan(shadowXYZ.xy, vec2(0.0, 0.0))))
            {
#if MGE_SOFT_SHADOWS
                shadowing = min(getFilteredShadowing(
                    shadowTexture@shadow_texture_unit_index,
                    shadowSpaceCoords@shadow_texture_unit_index
                ), shadowing);
#else
                shadowing = min(shadow2DProj(shadowTexture@shadow_texture_unit_index, shadowSpaceCoords@shadow_texture_unit_index).r, shadowing);
#endif

                doneShadows = all(lessThan(shadowXYZ, vec3(0.95, 0.95, 1.0))) && all(greaterThan(shadowXYZ, vec3(0.05, 0.05, 0.0)));
#if @perspectiveShadowMaps
                doneShadows = doneShadows && all(lessThan(shadowRegionXYZ, vec3(1.0, 1.0, 1.0))) && all(greaterThan(shadowRegionXYZ.xy, vec2(-1.0, -1.0)));
#endif
            }
        }
    @endforeach
#if @limitShadowMapDistance
    shadowing = mix(shadowing, 1.0, fade);
#endif
#endif // shadows
    return shadowing;
}

void applyShadowDebugOverlay()
{
#if SHADOWS && @useShadowDebugOverlay
    bool doneOverlay = false;
    float colourIndex = 0.0;
    @foreach shadow_texture_unit_index @shadow_texture_unit_list
        if (!doneOverlay)
        {
            vec3 shadowXYZ = shadowSpaceCoords@shadow_texture_unit_index.xyz / shadowSpaceCoords@shadow_texture_unit_index.w;
#if @perspectiveShadowMaps
            vec3 shadowRegionXYZ = shadowRegionCoords@shadow_texture_unit_index.xyz / shadowRegionCoords@shadow_texture_unit_index.w;
#endif
            if (all(lessThan(shadowXYZ.xy, vec2(1.0, 1.0))) && all(greaterThan(shadowXYZ.xy, vec2(0.0, 0.0))))
            {
                colourIndex = mod(@shadow_texture_unit_index.0, 3.0);
                if (colourIndex < 1.0)
                    gl_FragData[0].x += 0.1;
                else if (colourIndex < 2.0)
                    gl_FragData[0].y += 0.1;
                else
                    gl_FragData[0].z += 0.1;

                doneOverlay = all(lessThan(shadowXYZ, vec3(0.95, 0.95, 1.0))) && all(greaterThan(shadowXYZ, vec3(0.05, 0.05, 0.0)));
#if @perspectiveShadowMaps
                doneOverlay = doneOverlay && all(lessThan(shadowRegionXYZ.xyz, vec3(1.0, 1.0, 1.0))) && all(greaterThan(shadowRegionXYZ.xy, vec2(-1.0, -1.0)));
#endif
            }
        }
    @endforeach
#endif // shadows
}
