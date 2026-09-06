#ifndef OPENMW_MWRENDER_WATER_H
#define OPENMW_MWRENDER_WATER_H

#include <memory>
#include <vector>

#include <osg/Vec3d>
#include <osg/Vec3f>
#include <osg/Vec4f>
#include <osg/ref_ptr>
#include <osg/Image>
#include <osg/Texture2D>
#include <osg/Vec4f>

#include <components/settings/settings.hpp>
#include <components/vfs/pathutil.hpp>

namespace osg
{
    class Group;
    class PositionAttitudeTransform;
    class Geometry;
    class Node;
    class Callback;
}

namespace osgUtil
{
    class IncrementalCompileOperation;
}

namespace Resource
{
    class ResourceSystem;
}

namespace MWWorld
{
    class CellStore;
    class Ptr;
}

namespace Fallback
{
    class Map;
}

namespace MWRender
{

    class Refraction;
    class Reflection;
    class RippleSimulation;
    class RainSettingsUpdater;
    class Ripples;

    /// Water rendering
    class Water
    {
        osg::ref_ptr<RainSettingsUpdater> mRainSettingsUpdater;

        osg::ref_ptr<osg::Group> mParent;
        osg::ref_ptr<osg::Group> mSceneRoot;
        osg::ref_ptr<osg::PositionAttitudeTransform> mWaterNode;
        osg::ref_ptr<osg::Geometry> mWaterGeom;
        bool mDisplacedGeometry = false; // radial mesh + vertex displacement active
        osg::ref_ptr<osg::Image> mShoreImage;    // 64x64 float heights, renderer-baked
        osg::ref_ptr<osg::Texture2D> mShoreTex;
        osg::Vec4f mShoreParams{ 0.f, 0.f, 0.f, 0.f }; // origin.xy, 1/extent, valid
        Resource::ResourceSystem* mResourceSystem;
        osg::ref_ptr<osgUtil::IncrementalCompileOperation> mIncrementalCompileOperation;

        std::unique_ptr<RippleSimulation> mSimulation;

        osg::ref_ptr<Refraction> mRefraction;
        osg::ref_ptr<Reflection> mReflection;
        osg::ref_ptr<Ripples> mRipples;

        bool mEnabled;
        bool mToggled;
        float mTop;
        bool mInterior;
        bool mShowWorld;

        osg::Callback* mCullCallback;
        osg::ref_ptr<osg::Callback> mShaderWaterStateSetUpdater;

        osg::Vec3f getSceneNodeCoordinates(int gridX, int gridY);
        void updateVisible();

        void createSimpleWaterStateSet(osg::Node* node, float alpha);

        void createShaderWaterStateSet(osg::Node* node);

        void updateWaterMaterial();

    public:
        Water(osg::Group* parent, osg::Group* sceneRoot, Resource::ResourceSystem* resourceSystem,
            osgUtil::IncrementalCompileOperation* ico);
        ~Water();

        void setCullCallback(osg::Callback* callback);

        void listAssetsToPreload(std::vector<VFS::Path::Normalized>& textures);

        void setEnabled(bool enabled);

        bool toggle();

        bool isUnderwater(const osg::Vec3f& pos) const;

        /// adds an emitter, position will be tracked automatically using its scene node
        void addEmitter(const MWWorld::Ptr& ptr, float scale = 1.f, float force = 1.f);
        void removeEmitter(const MWWorld::Ptr& ptr);
        void updateEmitterPtr(const MWWorld::Ptr& old, const MWWorld::Ptr& ptr);
        void emitRipple(const osg::Vec3f& pos);

        void removeCell(const MWWorld::CellStore* store); ///< remove all emitters in this cell

        void clearRipples();

        void changeCell(const MWWorld::CellStore* store);
        void setHeight(const float height);
        void setRainIntensity(const float rainIntensity);

        /// Feed the refraction RTT the above-water fog state while the viewer is submerged (it renders the
        /// above-water world), or disable its fog when the viewer is above water (stock behaviour).
        void setRefractionViewerFog(bool viewerUnderwater, float start, float end, const osg::Vec4f& color);

        void update(float dt, bool paused);

        /// Displaced wave geometry (Full tier): recentre the radial water
        /// mesh on the camera every frame, XE's renderwater.cpp:441 move.
        /// No-op when the flat sheet is in use.
        void setCameraPosition(const osg::Vec3f& cameraPos);

        bool isDisplacedGeometry() const { return mDisplacedGeometry; }

        /// Depth-aware wave attenuation (displaced mode): the renderer bakes
        /// a camera-window terrain height map into the image this returns
        /// (null when not in displaced mode) and reports its placement via
        /// setShoreMapParams. The shader fades displacement to zero over
        /// shallow and dry ground - waves can never cross a beach.
        osg::Image* getShoreImage() { return mShoreImage.get(); }
        osg::Texture2D* getShoreTexture() { return mShoreTex.get(); }
        void setShoreMapParams(const osg::Vec2f& origin, float extent, bool valid)
        {
            mShoreParams.set(origin.x(), origin.y(), extent > 0.f ? 1.f / extent : 0.f,
                             valid ? 1.f : 0.f);
        }
        const osg::Vec4f& getShoreMapParams() const { return mShoreParams; }

        osg::Vec3d getPosition() const;

        void processChangedSettings(const Settings::CategorySettingVector& settings);

        void showWorld(bool show);
    };

}

#endif
