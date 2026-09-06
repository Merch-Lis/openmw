// stub shore table - zero pieces. The real file is generated per load order
// by scripts/bake_coastline.py --emit-glsl (an OGE regeneration step,
// DL-style) and replaces this one in the install. With zero pieces every
// consumer compiles to nothing, so a package without the OGE step is exactly
// stock behaviour.
#ifndef MGE_SHORE_DATA_GLSL
#define MGE_SHORE_DATA_GLSL
#define MGE_SHORE_PIECE_COUNT 0
#endif
