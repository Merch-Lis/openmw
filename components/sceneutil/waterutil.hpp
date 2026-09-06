#ifndef OPENMW_COMPONENTS_WATERUTIL_H
#define OPENMW_COMPONENTS_WATERUTIL_H

#include <osg/ref_ptr>

namespace osg
{
    class Geometry;
    class StateSet;
}

namespace SceneUtil
{
    osg::ref_ptr<osg::Geometry> createWaterGeometry(float size, int segments, float textureRepeats);

    // MGE XE-style camera-centred radial water mesh (Full tier, displaced
    // wave geometry). Centre vertex + rings x segments triangle fan/strips,
    // ring radii r = ringMax * (0.9u^3 + 0.1u) (XE distantinit.cpp:585-596),
    // last ring extended to horizonRadius. All z = 0; displacement happens
    // in water.vert. Density is not XE's 150x120: XE's far wave scale is
    // 3900 units where ours is ~372, so the mesh must be denser to carry it
    osg::ref_ptr<osg::Geometry> createRadialWaterGeometry(
        int segments, int rings, float ringMax, float horizonRadius);

    osg::ref_ptr<osg::StateSet> createSimpleWaterStateSet(float alpha, int renderBin);
}

#endif
