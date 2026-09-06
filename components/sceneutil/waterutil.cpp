#include "waterutil.hpp"

#include <cmath>

#include <osg/Depth>
#include <osg/Geometry>
#include <osg/Material>
#include <osg/StateSet>

#include "depth.hpp"

namespace SceneUtil
{
    // disable nonsense test against a worldsize bb what will always pass
    class WaterBoundCallback : public osg::Drawable::ComputeBoundingBoxCallback
    {
        osg::BoundingBox computeBound(const osg::Drawable&) const override { return osg::BoundingBox(); }
    };

    osg::ref_ptr<osg::Geometry> createWaterGeometry(float size, int segments, float textureRepeats)
    {
        osg::ref_ptr<osg::Vec3Array> verts(new osg::Vec3Array);
        osg::ref_ptr<osg::Vec2Array> texcoords(new osg::Vec2Array);

        // some drivers don't like huge triangles, so we do some subdivisons
        // a paged solution would be even better
        const float step = size / segments;
        const float texCoordStep = textureRepeats / segments;
        for (int x = 0; x < segments; ++x)
        {
            for (int y = 0; y < segments; ++y)
            {
                float x1 = -size / 2.f + x * step;
                float y1 = -size / 2.f + y * step;
                float x2 = x1 + step;
                float y2 = y1 + step;

                verts->push_back(osg::Vec3f(x1, y2, 0.f));
                verts->push_back(osg::Vec3f(x1, y1, 0.f));
                verts->push_back(osg::Vec3f(x2, y1, 0.f));
                verts->push_back(osg::Vec3f(x2, y2, 0.f));

                float u1 = x * texCoordStep;
                float v1 = textureRepeats - y * texCoordStep;
                float u2 = u1 + texCoordStep;
                float v2 = v1 - texCoordStep;

                texcoords->push_back(osg::Vec2f(u1, v2));
                texcoords->push_back(osg::Vec2f(u1, v1));
                texcoords->push_back(osg::Vec2f(u2, v1));
                texcoords->push_back(osg::Vec2f(u2, v2));
            }
        }

        osg::ref_ptr<osg::Geometry> waterGeom(new osg::Geometry);
        waterGeom->setVertexArray(verts);
        waterGeom->setTexCoordArray(0, texcoords);

        osg::ref_ptr<osg::Vec3Array> normal(new osg::Vec3Array);
        normal->push_back(osg::Vec3f(0, 0, 1));
        waterGeom->setNormalArray(normal, osg::Array::BIND_OVERALL);

        waterGeom->addPrimitiveSet(
            new osg::DrawArrays(osg::PrimitiveSet::QUADS, 0, static_cast<GLsizei>(verts->size())));
        waterGeom->setComputeBoundingBoxCallback(new WaterBoundCallback);
        waterGeom->setCullingActive(false);
        return waterGeom;
    }

    osg::ref_ptr<osg::Geometry> createRadialWaterGeometry(
        int segments, int rings, float ringMax, float horizonRadius)
    {
        osg::ref_ptr<osg::Vec3Array> verts(new osg::Vec3Array);
        verts->reserve(segments * rings + 1);

        verts->push_back(osg::Vec3f(0.f, 0.f, 0.f));
        const float dS = static_cast<float>(2.0 * osg::PI / segments);
        for (int t = 0; t < rings; ++t)
        {
            float u = static_cast<float>(t) / rings;
            float r = ringMax * (0.9f * u * u * u + 0.1f * u);
            if (t + 1 == rings)
                r = horizonRadius; // extend last ring past the horizon (XE)
            for (int sgt = 0; sgt < segments; ++sgt)
                verts->push_back(osg::Vec3f(r * std::cos(dS * sgt), r * std::sin(dS * sgt), 0.f));
        }

        osg::ref_ptr<osg::DrawElementsUInt> indices(new osg::DrawElementsUInt(osg::PrimitiveSet::TRIANGLES));
        indices->reserve((2 * segments * rings - segments) * 3);
        // centre fan
        for (int sgt = 0; sgt < segments; ++sgt)
        {
            indices->push_back(0);
            indices->push_back(1 + sgt);
            indices->push_back(1 + (sgt + 1) % segments);
        }
        // ring strips, indexed exactly as XE (distantinit.cpp:616-626)
        for (int t = 1; t < rings; ++t)
        {
            for (int sgt = 0; sgt < segments; ++sgt)
            {
                unsigned tbase = 1 + segments * (t - 1);
                unsigned s2 = (sgt + 1) % segments;
                indices->push_back(tbase + sgt);
                indices->push_back(segments + tbase + sgt);
                indices->push_back(tbase + s2);
                indices->push_back(segments + tbase + sgt);
                indices->push_back(segments + tbase + s2);
                indices->push_back(tbase + s2);
            }
        }

        osg::ref_ptr<osg::Geometry> waterGeom(new osg::Geometry);
        waterGeom->setVertexArray(verts);

        osg::ref_ptr<osg::Vec3Array> normal(new osg::Vec3Array);
        normal->push_back(osg::Vec3f(0, 0, 1));
        waterGeom->setNormalArray(normal, osg::Array::BIND_OVERALL);

        waterGeom->addPrimitiveSet(indices);
        // same policy as the flat sheet: never culled, no bbox test
        waterGeom->setComputeBoundingBoxCallback(new WaterBoundCallback);
        waterGeom->setCullingActive(false);
        return waterGeom;
    }

    osg::ref_ptr<osg::StateSet> createSimpleWaterStateSet(float alpha, int renderBin)
    {
        osg::ref_ptr<osg::StateSet> stateset(new osg::StateSet);

        osg::ref_ptr<osg::Material> material(new osg::Material);
        material->setEmission(osg::Material::FRONT_AND_BACK, osg::Vec4f(0.f, 0.f, 0.f, 1.f));
        material->setDiffuse(osg::Material::FRONT_AND_BACK, osg::Vec4f(1.f, 1.f, 1.f, alpha));
        material->setAmbient(osg::Material::FRONT_AND_BACK, osg::Vec4f(1.f, 1.f, 1.f, 1.f));
        material->setColorMode(osg::Material::OFF);
        stateset->setAttributeAndModes(material, osg::StateAttribute::ON);

        stateset->setMode(GL_BLEND, osg::StateAttribute::ON);
        stateset->setMode(GL_CULL_FACE, osg::StateAttribute::OFF);

        osg::ref_ptr<osg::Depth> depth = new SceneUtil::AutoDepth;
        depth->setWriteMask(false);
        stateset->setAttributeAndModes(depth, osg::StateAttribute::ON);

        stateset->setRenderBinDetails(renderBin, "RenderBin");

        return stateset;
    }
}
