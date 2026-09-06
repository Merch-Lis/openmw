#include "water.hpp"

#include <sstream>

#include <osg/ClipNode>
#include <osg/Depth>
#include <osg/Fog>
#include <osg/FrontFace>
#include <osg/Geometry>
#include <osg/Group>
#include <osg/Material>
#include <osg/PositionAttitudeTransform>
#include <osg/Texture3D>
#include <osg/ViewportIndexed>

#include <osgUtil/CullVisitor>
#include <osgUtil/IncrementalCompileOperation>

#include <components/resource/imagemanager.hpp>
#include <components/resource/resourcesystem.hpp>
#include <components/resource/scenemanager.hpp>

#include <components/sceneutil/depth.hpp>
#include <components/sceneutil/rtt.hpp>
#include <components/sceneutil/shadow.hpp>
#include <components/sceneutil/waterutil.hpp>

#include <components/misc/constants.hpp>
#include <components/stereo/stereomanager.hpp>

#include <components/nifosg/controller.hpp>

#include <components/shader/shadermanager.hpp>

#include <components/esm3/loadcell.hpp>

#include <components/fallback/fallback.hpp>

#include <components/settings/values.hpp>

#include "../mwworld/cellstore.hpp"

#include "renderbin.hpp"
#include "ripples.hpp"
#include "ripplesimulation.hpp"
#include "util.hpp"
#include "vismask.hpp"

namespace MWRender
{

    // --------------------------------------------------------------------------------------------------------------------------------

    /// @brief Allows to cull and clip meshes that are below a plane. Useful for reflection & refraction camera effects.
    /// Also handles flipping of the plane when the eye point goes below it.
    /// To use, simply create the scene as subgraph of this node, then do setPlane(const osg::Plane& plane);
    class ClipCullNode : public osg::Group
    {
        class PlaneCullCallback : public SceneUtil::NodeCallback<PlaneCullCallback, osg::Node*, osgUtil::CullVisitor*>
        {
        public:
            /// @param cullPlane The culling plane (in world space).
            PlaneCullCallback(const osg::Plane* cullPlane, const float* clipMargin)
                : mCullPlane(cullPlane)
                , mClipMargin(clipMargin)
            {
            }

            void operator()(osg::Node* node, osgUtil::CullVisitor* cv)
            {
                osg::Polytope::PlaneList origPlaneList
                    = cv->getProjectionCullingStack().back().getFrustum().getPlaneList();

                osg::Plane plane = *mCullPlane;
                plane.transform(*cv->getCurrentRenderStage()->getInitialViewMatrix());

                osg::Vec3d eyePoint = cv->getEyePoint();
                if (mCullPlane->intersect(osg::BoundingSphere(osg::Vec3d(0, 0, eyePoint.z()), 0)) > 0)
                    plane.flip();

                // Displaced wave geometry: keep content the margin's depth past
                // the plane (enlarges the kept half-space whichever way the
                // plane faces) - XE's clip allowance, renderwater.cpp:36-40,
                // expressed as culling slack instead of a moved mirror plane.
                if (*mClipMargin != 0.f)
                    plane = osg::Plane(plane.getNormal(), plane[3] + *mClipMargin);

                cv->getProjectionCullingStack().back().getFrustum().add(plane);

                traverse(node, cv);

                // undo
                cv->getProjectionCullingStack().back().getFrustum().set(origPlaneList);
            }

        private:
            const osg::Plane* mCullPlane;
            const float* mClipMargin;
        };

        class FlipCallback : public SceneUtil::NodeCallback<FlipCallback, osg::Node*, osgUtil::CullVisitor*>
        {
        public:
            FlipCallback(const osg::Plane* cullPlane)
                : mCullPlane(cullPlane)
            {
            }

            void operator()(osg::Node* node, osgUtil::CullVisitor* cv)
            {
                osg::Vec3d eyePoint = cv->getEyePoint();

                osg::RefMatrix* modelViewMatrix = new osg::RefMatrix(*cv->getModelViewMatrix());

                // apply the height of the plane
                // we can't apply this height in the addClipPlane() since the "flip the below graph" function would
                // otherwise flip the height as well
                modelViewMatrix->preMultTranslate(mCullPlane->getNormal() * ((*mCullPlane)[3] * -1));

                // flip the below graph if the eye point is above the plane
                if (mCullPlane->intersect(osg::BoundingSphere(osg::Vec3d(0, 0, eyePoint.z()), 0)) > 0)
                {
                    modelViewMatrix->preMultScale(osg::Vec3(1, 1, -1));
                }

                // move the plane back along its normal a little bit to prevent bleeding at the water shore
                const float fov = Settings::camera().mFieldOfView;
                constexpr double clipFudgeMin = 2.5; // minimum offset of clip plane
                constexpr double clipFudgeScale = -15000.0;
                double clipFudge
                    = std::abs(std::abs((*mCullPlane)[3]) - eyePoint.z()) * fov / clipFudgeScale - clipFudgeMin;
                modelViewMatrix->preMultTranslate(mCullPlane->getNormal() * clipFudge);

                cv->pushModelViewMatrix(modelViewMatrix, osg::Transform::RELATIVE_RF);
                traverse(node, cv);
                cv->popModelViewMatrix();
            }

        private:
            const osg::Plane* mCullPlane;
        };

    public:
        ClipCullNode()
        {
            addCullCallback(new PlaneCullCallback(&mPlane, &mClipMargin));

            mClipNodeTransform = new osg::Group;
            mClipNodeTransform->addCullCallback(new FlipCallback(&mPlane));
            osg::Group::addChild(mClipNodeTransform);

            mClipNode = new osg::ClipNode;

            mClipNodeTransform->addChild(mClipNode);
        }

        void setPlane(const osg::Plane& plane)
        {
            if (plane == mPlane)
                return;
            mPlane = plane;
            applyClipPlane();
        }

        /// Displaced wave geometry: hardware-clip this many units past the
        /// plane. The FlipCallback's mirror transform is untouched (the
        /// mirror stays at the true water level - lowering it would bend the
        /// reflection, the trap XE's D3D clip-plane move does not have);
        /// only the GL clip plane and the frustum cull gain slack, so the
        /// reflection RTT keeps content between a wave trough and the plane.
        void setClipMargin(float margin)
        {
            if (margin == mClipMargin)
                return;
            mClipMargin = margin;
            if (!mClipNode->getClipPlaneList().empty())
                applyClipPlane();
        }

    private:
        void applyClipPlane()
        {
            mClipNode->getClipPlaneList().clear();
            mClipNode->addClipPlane(new osg::ClipPlane(
                0, osg::Plane(mPlane.getNormal(), mClipMargin))); // mPlane.d() applied in FlipCallback
            mClipNode->setStateSetModes(*getOrCreateStateSet(), osg::StateAttribute::ON);
            mClipNode->setCullingActive(false);
        }

        osg::ref_ptr<osg::Group> mClipNodeTransform;
        osg::ref_ptr<osg::ClipNode> mClipNode;

        osg::Plane mPlane;
        float mClipMargin = 0.f;
    };

    /// This callback on the Camera has the effect of a RELATIVE_RF_INHERIT_VIEWPOINT transform mode (which does not
    /// exist in OSG). We want to keep the View Point of the parent camera so we will not have to recreate LODs.
    class InheritViewPointCallback
        : public SceneUtil::NodeCallback<InheritViewPointCallback, osg::Node*, osgUtil::CullVisitor*>
    {
    public:
        InheritViewPointCallback() {}

        void operator()(osg::Node* node, osgUtil::CullVisitor* cv)
        {
            osg::ref_ptr<osg::RefMatrix> modelViewMatrix = new osg::RefMatrix(*cv->getModelViewMatrix());
            cv->popModelViewMatrix();
            cv->pushModelViewMatrix(modelViewMatrix, osg::Transform::ABSOLUTE_RF_INHERIT_VIEWPOINT);
            traverse(node, cv);
        }
    };

    /// Moves water mesh away from the camera slightly if the camera gets too close on the Z axis.
    /// The offset works around graphics artifacts that occurred with the GL_DEPTH_CLAMP when the camera gets extremely
    /// close to the mesh (seen on NVIDIA at least). Must be added as a Cull callback.
    class FudgeCallback : public SceneUtil::NodeCallback<FudgeCallback, osg::Node*, osgUtil::CullVisitor*>
    {
    public:
        void operator()(osg::Node* node, osgUtil::CullVisitor* cv)
        {
            const float fudge = 0.2f;
            if (std::abs(cv->getEyeLocal().z()) < fudge)
            {
                float diff = fudge - cv->getEyeLocal().z();
                osg::RefMatrix* modelViewMatrix = new osg::RefMatrix(*cv->getModelViewMatrix());

                if (cv->getEyeLocal().z() > 0)
                    modelViewMatrix->preMultTranslate(osg::Vec3f(0, 0, -diff));
                else
                    modelViewMatrix->preMultTranslate(osg::Vec3f(0, 0, diff));

                cv->pushModelViewMatrix(modelViewMatrix, osg::Transform::RELATIVE_RF);
                traverse(node, cv);
                cv->popModelViewMatrix();
            }
            else
                traverse(node, cv);
        }
    };

    class RainSettingsUpdater : public SceneUtil::StateSetUpdater
    {
    public:
        RainSettingsUpdater() = default;

        void setRainIntensity(float rainIntensity) { mRainIntensity = rainIntensity; }

    protected:
        void setDefaults(osg::StateSet* stateset) override
        {
            osg::ref_ptr<osg::Uniform> rainIntensityUniform = new osg::Uniform("rainIntensity", 0.0f);
            stateset->addUniform(rainIntensityUniform.get());
        }

        void apply(osg::StateSet* stateset, osg::NodeVisitor* /*nv*/) override
        {
            osg::ref_ptr<osg::Uniform> rainIntensityUniform = stateset->getUniform("rainIntensity");
            if (rainIntensityUniform != nullptr)
                rainIntensityUniform->set(mRainIntensity);
        }

    private:
        float mRainIntensity{ 0.f };
    };

    class Refraction : public SceneUtil::RTTNode
    {
    public:
        Refraction(uint32_t rttSize)
            : RTTNode(rttSize, rttSize, 0, false, 1, StereoAwareness::Aware, shouldAddMSAAIntermediateTarget())
            , mNodeMask(Refraction::sDefaultCullMask)
        {
            setDepthBufferInternalFormat(GL_DEPTH24_STENCIL8);
            mClipCullNode = new ClipCullNode;
            // Created here, not in setDefaults(): setViewerFog is driven per
            // frame by RenderingManager::update, which can run before the
            // RTT's lazy setDefaults has ever been called.
            mFog = new osg::Fog;
            mFog->setDataVariance(osg::Object::DYNAMIC);
            mFog->setStart(10000000);
            mFog->setEnd(10000000);
        }

        void setDefaults(osg::Camera* camera) override
        {
            camera->setReferenceFrame(osg::Camera::RELATIVE_RF);
            camera->setSmallFeatureCullingPixelSize(Settings::water().mSmallFeatureCullingPixelSize);
            camera->setName("RefractionCamera");
            camera->addCullCallback(new InheritViewPointCallback);
            camera->setComputeNearFarMode(osg::CullSettings::DO_NOT_COMPUTE_NEAR_FAR);

            // Viewer above water: no need for fog here, we already apply fog on the water surface itself as well
            // as underwater fog. Fog stays effectively off via the large ranges set in the constructor, since
            // shaders don't respect glDisable(GL_FOG). Viewer below water: the RTT shows the above-water world,
            // and setViewerFog swaps in the real above-water fog state so distant content keeps its atmospheric
            // haze; the shaders route this pass to the above-water fog model via the isRefraction uniform.
            camera->getOrCreateStateSet()->setAttributeAndModes(
                mFog, osg::StateAttribute::OFF | osg::StateAttribute::OVERRIDE);

            // Inform the shader that we're in the refraction pass
            camera->getOrCreateStateSet()->addUniform(new osg::Uniform("isRefraction", true));

            camera->addChild(mClipCullNode);
            camera->setNodeMask(Mask_RenderToTexture);

            if (Settings::water().mRefractionScale != 1) // TODO: to be removed with issue #5709
                SceneUtil::ShadowManager::instance().disableShadowsForStateSet(*camera->getOrCreateStateSet());
        }

        void apply(osg::Camera* camera) override
        {
            camera->setViewMatrix(mViewMatrix);
            camera->setCullMask(mNodeMask);
        }

        void setScene(osg::Node* scene)
        {
            if (mScene)
                mClipCullNode->removeChild(mScene);
            mScene = scene;
            mClipCullNode->addChild(scene);
        }

        void setWaterLevel(float waterLevel)
        {
            const float refractionScale = Settings::water().mRefractionScale;

            mViewMatrix = osg::Matrix::scale(1, 1, refractionScale)
                * osg::Matrix::translate(0, 0, (1.0 - refractionScale) * waterLevel);

            mClipCullNode->setPlane(osg::Plane(osg::Vec3d(0, 0, -1), osg::Vec3d(0, 0, waterLevel)));
        }

        void showWorld(bool show)
        {
            if (show)
                mNodeMask = Refraction::sDefaultCullMask;
            else
                mNodeMask = Refraction::sDefaultCullMask & ~sToggleWorldMask;
        }

        void setViewerFog(bool viewerUnderwater, float start, float end, const osg::Vec4f& color)
        {
            if (!mFog)
                return;
            if (viewerUnderwater)
            {
                mFog->setStart(start);
                mFog->setEnd(end);
                mFog->setColor(color);
            }
            else
            {
                mFog->setStart(10000000);
                mFog->setEnd(10000000);
            }
        }

    private:
        osg::ref_ptr<ClipCullNode> mClipCullNode;
        osg::ref_ptr<osg::Node> mScene;
        osg::ref_ptr<osg::Fog> mFog;
        osg::Matrix mViewMatrix{ osg::Matrix::identity() };

        unsigned int mNodeMask;

        static constexpr unsigned int sDefaultCullMask = Mask_Effect | Mask_Scene | Mask_Object | Mask_Static
            | Mask_Terrain | Mask_Actor | Mask_ParticleSystem | Mask_Sky | Mask_Sun | Mask_Player | Mask_Lighting
            | Mask_Groundcover;
    };

    class Reflection : public SceneUtil::RTTNode
    {
    public:
        Reflection(uint32_t rttSize, bool isInterior)
            : RTTNode(rttSize, rttSize, 0, false, 0, StereoAwareness::Aware, shouldAddMSAAIntermediateTarget())
        {
            setInterior(isInterior);
            setDepthBufferInternalFormat(GL_DEPTH24_STENCIL8);
            mClipCullNode = new ClipCullNode;
        }

        void setDefaults(osg::Camera* camera) override
        {
            camera->setReferenceFrame(osg::Camera::RELATIVE_RF);
            camera->setSmallFeatureCullingPixelSize(Settings::water().mSmallFeatureCullingPixelSize);
            camera->setName("ReflectionCamera");
            camera->addCullCallback(new InheritViewPointCallback);

            // Inform the shader that we're in a reflection
            camera->getOrCreateStateSet()->addUniform(new osg::Uniform("isReflection", true));

            // XXX: should really flip the FrontFace on each renderable instead of forcing clockwise.
            osg::ref_ptr<osg::FrontFace> frontFace(new osg::FrontFace);
            frontFace->setMode(osg::FrontFace::CLOCKWISE);
            camera->getOrCreateStateSet()->setAttributeAndModes(frontFace, osg::StateAttribute::ON);

            camera->addChild(mClipCullNode);
            camera->setNodeMask(Mask_RenderToTexture);

            SceneUtil::ShadowManager::instance().disableShadowsForStateSet(*camera->getOrCreateStateSet());
        }

        void apply(osg::Camera* camera) override
        {
            camera->setViewMatrix(mViewMatrix);
            camera->setCullMask(mNodeMask);
        }

        void setInterior(bool isInterior)
        {
            mInterior = isInterior;
            mNodeMask = calcNodeMask();
        }

        void setWaterLevel(float waterLevel)
        {
            mViewMatrix = osg::Matrix::scale(1, 1, -1) * osg::Matrix::translate(0, 0, 2 * waterLevel);
            mClipCullNode->setPlane(osg::Plane(osg::Vec3d(0, 0, 1), osg::Vec3d(0, 0, waterLevel)));
        }

        /// Displaced wave geometry: keep reflected content down to a wave
        /// trough below the plane (XE's 0.5*waveHeight clip allowance,
        /// renderwater.cpp:36-40). The mirror matrix above is untouched -
        /// only clipping gains slack.
        void setClipMargin(float margin) { mClipCullNode->setClipMargin(margin); }

        void setScene(osg::Node* scene)
        {
            if (mScene)
                mClipCullNode->removeChild(mScene);
            mScene = scene;
            mClipCullNode->addChild(scene);
        }

        void showWorld(bool show)
        {
            if (show)
                mNodeMask = calcNodeMask();
            else
                mNodeMask = calcNodeMask() & ~sToggleWorldMask;
        }

    private:
        unsigned int calcNodeMask()
        {
            int reflectionDetail = Settings::water().mReflectionDetail;
            reflectionDetail = std::clamp(reflectionDetail, mInterior ? 2 : 0, 5);
            unsigned int extraMask = 0;
            if (reflectionDetail >= 1)
                extraMask |= Mask_Terrain;
            if (reflectionDetail >= 2)
                extraMask |= Mask_Static;
            if (reflectionDetail >= 3)
                extraMask |= Mask_Effect | Mask_ParticleSystem | Mask_Object;
            if (reflectionDetail >= 4)
                extraMask |= Mask_Player | Mask_Actor;
            if (reflectionDetail >= 5)
                extraMask |= Mask_Groundcover;
            return Mask_Scene | Mask_Sky | Mask_Lighting | extraMask;
        }

        osg::ref_ptr<ClipCullNode> mClipCullNode;
        osg::ref_ptr<osg::Node> mScene;
        osg::Node::NodeMask mNodeMask;
        osg::Matrix mViewMatrix{ osg::Matrix::identity() };
        bool mInterior;
    };

    /// DepthClampCallback enables GL_DEPTH_CLAMP for the current draw, if supported.
    class DepthClampCallback : public osg::Drawable::DrawCallback
    {
    public:
        void drawImplementation(osg::RenderInfo& renderInfo, const osg::Drawable* drawable) const override
        {
            static bool supported = osg::isGLExtensionOrVersionSupported(
                renderInfo.getState()->getContextID(), "GL_ARB_depth_clamp", 3.3f);
            if (!supported)
            {
                drawable->drawImplementation(renderInfo);
                return;
            }

            glEnable(GL_DEPTH_CLAMP);

            drawable->drawImplementation(renderInfo);

            // restore default
            glDisable(GL_DEPTH_CLAMP);
        }
    };

    Water::Water(osg::Group* parent, osg::Group* sceneRoot, Resource::ResourceSystem* resourceSystem,
        osgUtil::IncrementalCompileOperation* ico)
        : mRainSettingsUpdater(nullptr)
        , mParent(parent)
        , mSceneRoot(sceneRoot)
        , mResourceSystem(resourceSystem)
        , mEnabled(true)
        , mToggled(true)
        , mTop(0)
        , mInterior(false)
        , mShowWorld(true)
        , mCullCallback(nullptr)
        , mShaderWaterStateSetUpdater(nullptr)
    {
        mSimulation = std::make_unique<RippleSimulation>(mSceneRoot, resourceSystem);

        // Displaced wave geometry (Full tier, Wonders of Water layer):
        // swap the flat sheet for the camera-centred radial mesh that the
        // vertex stage displaces. Requires the water shader (the simple
        // path has no vertex program to displace anything). Density 384x120
        // is measured, not XE's 150x120 - our wave field is an order of
        // magnitude finer than XE's (sim_water_displacement.py, WFR repo,
        // (5000u) is bounded by this mesh's measured carrying reach.
        mDisplacedGeometry = Settings::water().mDisplacedWaveGeometry && Settings::water().mShader;

        // The local map's simple water stays the flat stock sheet in either
        // mode, so build it from stock geometry unconditionally.
        osg::ref_ptr<osg::Geometry> flatGeom
            = SceneUtil::createWaterGeometry(Constants::CellSizeInUnits * 150, 40, 900);

        if (mDisplacedGeometry)
        {
            mWaterGeom = SceneUtil::createRadialWaterGeometry(384, 120, 9600.f, 500000.f);
            // height map over 12288 u around the camera, baked by the
            // renderer (it owns the terrain), sampled by water.vert to fade
            // displacement over shallow and dry ground. 12288/2 = 6144 u of
            // coverage radius > the 5000 u displacement window, so every
            // displaced vertex is always inside the map.
            mShoreImage = new osg::Image;
            mShoreImage->allocateImage(64, 64, 1, GL_RED, GL_FLOAT);
            std::fill_n(reinterpret_cast<float*>(mShoreImage->data()), 64 * 64, -2048.f);
            mShoreTex = new osg::Texture2D(mShoreImage);
            mShoreTex->setInternalFormat(GL_R32F);
            mShoreTex->setWrap(osg::Texture::WRAP_S, osg::Texture::CLAMP_TO_EDGE);
            mShoreTex->setWrap(osg::Texture::WRAP_T, osg::Texture::CLAMP_TO_EDGE);
            mShoreTex->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
            mShoreTex->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);
        }
        else
            mWaterGeom = flatGeom;
        mWaterGeom->setDrawCallback(new DepthClampCallback);
        mWaterGeom->setNodeMask(Mask_Water);
        mWaterGeom->setDataVariance(osg::Object::STATIC);
        mWaterGeom->setName("Water Geometry");

        mWaterNode = new osg::PositionAttitudeTransform;
        mWaterNode->setName("Water Root");
        mWaterNode->addChild(mWaterGeom);
        mWaterNode->addCullCallback(new FudgeCallback);

        // simple water fallback for the local map
        osg::ref_ptr<osg::Geometry> geom2(osg::clone(flatGeom.get(), osg::CopyOp::DEEP_COPY_NODES));
        createSimpleWaterStateSet(geom2, Fallback::Map::getFloat("Water_Map_Alpha"));
        geom2->setNodeMask(Mask_SimpleWater);
        geom2->setName("Simple Water Geometry");
        mWaterNode->addChild(geom2);

        mSceneRoot->addChild(mWaterNode);

        setHeight(mTop);

        updateWaterMaterial();

        if (ico)
            ico->add(mWaterNode);
    }

    void Water::setCullCallback(osg::Callback* callback)
    {
        if (mCullCallback)
        {
            mWaterNode->removeCullCallback(mCullCallback);
            if (mReflection)
                mReflection->removeCullCallback(mCullCallback);
            if (mRefraction)
                mRefraction->removeCullCallback(mCullCallback);
        }

        mCullCallback = callback;

        if (callback)
        {
            mWaterNode->addCullCallback(callback);
            if (mReflection)
                mReflection->addCullCallback(callback);
            if (mRefraction)
                mRefraction->addCullCallback(callback);
        }
    }

    void Water::updateWaterMaterial()
    {
        if (mShaderWaterStateSetUpdater)
        {
            mWaterNode->removeCullCallback(mShaderWaterStateSetUpdater);
            mShaderWaterStateSetUpdater = nullptr;
        }
        if (mReflection)
        {
            mParent->removeChild(mReflection);
            mReflection = nullptr;
        }
        if (mRefraction)
        {
            mParent->removeChild(mRefraction);
            mRefraction = nullptr;
        }
        if (mRipples)
        {
            mParent->removeChild(mRipples);
            mRipples = nullptr;
            mSimulation->setRipples(nullptr);
        }

        mWaterNode->setStateSet(nullptr);
        mWaterGeom->setStateSet(nullptr);
        mWaterGeom->setUpdateCallback(nullptr);

        if (Settings::water().mShader)
        {
            const unsigned int rttSize = Settings::water().mRttSize;

            mReflection = new Reflection(rttSize, mInterior);
            mReflection->setWaterLevel(mTop);
            if (mDisplacedGeometry)
            {
                // Keep reflected content down to a wave trough below the
                // plane. 25 = XE's exact allowance (0.5 x waveHeight at the
                // ini's 50). The first shipment used 55 (the procedural storm
                // half-extent) and the swim test showed why XE keeps
                // this tight: at grazing angles crest faces reflect whatever
                // the margin admits, and 55 u of below-surface content read
                mReflection->setClipMargin(25.f);
            }
            mReflection->setScene(mSceneRoot);
            if (mCullCallback)
                mReflection->addCullCallback(mCullCallback);
            mParent->addChild(mReflection);

            if (Settings::water().mRefraction)
            {
                mRefraction = new Refraction(rttSize);
                mRefraction->setWaterLevel(mTop);
                mRefraction->setScene(mSceneRoot);
                if (mCullCallback)
                    mRefraction->addCullCallback(mCullCallback);
                mParent->addChild(mRefraction);
            }

            mRipples = new Ripples(mResourceSystem);
            mSimulation->setRipples(mRipples);
            mParent->addChild(mRipples);

            showWorld(mShowWorld);

            createShaderWaterStateSet(mWaterNode);
        }
        else
            createSimpleWaterStateSet(mWaterGeom, Fallback::Map::getFloat("Water_World_Alpha"));

        mResourceSystem->getSceneManager()->setUpNormalsRTForStateSet(mWaterGeom->getOrCreateStateSet(), true);

        updateVisible();
    }

    osg::Vec3d Water::getPosition() const
    {
        return mWaterNode->getPosition();
    }

    void Water::createSimpleWaterStateSet(osg::Node* node, float alpha)
    {
        osg::ref_ptr<osg::StateSet> stateset = SceneUtil::createSimpleWaterStateSet(alpha, MWRender::RenderBin_Water);

        node->setStateSet(stateset);
        node->setUpdateCallback(nullptr);
        mRainSettingsUpdater = nullptr;

        // Add animated textures
        std::vector<osg::ref_ptr<osg::Texture2D>> textures;
        const int frameCount = std::clamp(Fallback::Map::getInt("Water_SurfaceFrameCount"), 0, 320);
        std::string_view texture = Fallback::Map::getString("Water_SurfaceTexture");
        for (int i = 0; i < frameCount; ++i)
        {
            std::ostringstream texname;
            texname << "textures/water/" << texture << std::setw(2) << std::setfill('0') << i << ".dds";
            const VFS::Path::Normalized path(texname.str());
            osg::ref_ptr<osg::Texture2D> tex(new osg::Texture2D(mResourceSystem->getImageManager()->getImage(path)));
            tex->setWrap(osg::Texture::WRAP_S, osg::Texture::REPEAT);
            tex->setWrap(osg::Texture::WRAP_T, osg::Texture::REPEAT);
            mResourceSystem->getSceneManager()->applyFilterSettings(tex);
            textures.push_back(tex);
        }

        if (textures.empty())
            return;

        float fps = Fallback::Map::getFloat("Water_SurfaceFPS");

        osg::ref_ptr<NifOsg::FlipController> controller(new NifOsg::FlipController(0, 1.f / fps, textures));
        controller->setSource(std::make_shared<SceneUtil::FrameTimeSource>());
        node->setUpdateCallback(controller);

        stateset->setTextureAttributeAndModes(0, textures[0], osg::StateAttribute::ON);

        // use a shader to render the simple water, ensuring that fog is applied per pixel as required.
        // this could be removed if a more detailed water mesh, using some sort of paging solution, is implemented.
        Resource::SceneManager* sceneManager = mResourceSystem->getSceneManager();
        sceneManager->recreateShaders(node);
    }

    class ShaderWaterStateSetUpdater : public SceneUtil::StateSetUpdater
    {
    public:
        ShaderWaterStateSetUpdater(Water* water, Reflection* reflection, Refraction* refraction, Ripples* ripples,
            osg::ref_ptr<osg::Program> program, osg::ref_ptr<osg::Texture2D> normalMap,
            osg::ref_ptr<osg::Texture3D> waveVolume)
            : mWater(water)
            , mReflection(reflection)
            , mRefraction(refraction)
            , mRipples(ripples)
            , mProgram(std::move(program))
            , mNormalMap(std::move(normalMap))
            , mWaveVolume(std::move(waveVolume))
        {
        }

        void setDefaults(osg::StateSet* stateset) override
        {
            stateset->addUniform(new osg::Uniform("normalMap", 0));
            stateset->setTextureAttributeAndModes(0, mNormalMap, osg::StateAttribute::ON);
            stateset->setMode(GL_CULL_FACE, osg::StateAttribute::OFF);
            stateset->setAttributeAndModes(mProgram, osg::StateAttribute::ON);

            stateset->addUniform(new osg::Uniform("reflectionMap", 1));
            if (mRefraction)
            {
                stateset->addUniform(new osg::Uniform("refractionMap", 2));
                stateset->addUniform(new osg::Uniform("refractionDepthMap", 3));
                stateset->setRenderBinDetails(MWRender::RenderBin_Default, "RenderBin");
            }
            else
            {
                stateset->setMode(GL_BLEND, osg::StateAttribute::ON);
                stateset->setRenderBinDetails(MWRender::RenderBin_Water, "RenderBin");
                osg::ref_ptr<osg::Depth> depth = new SceneUtil::AutoDepth;
                depth->setWriteMask(false);
                stateset->setAttributeAndModes(depth, osg::StateAttribute::ON);
            }
            if (mRipples)
            {
                stateset->addUniform(new osg::Uniform("rippleMap", 4));
            }
            stateset->addUniform(new osg::Uniform("nodePosition", osg::Vec3f(mWater->getPosition())));
            // Displaced wave geometry marker for the water shaders. Fed only
            // when the radial mesh is actually live, and only this fork has
            // the code to feed it - a stock exe never declares it, GLSL
            // reads 0, and water.vert's displacement multiplies out (the
            // mgeWeatherUniforms pattern; RP byte-identity rides this).
            stateset->addUniform(
                new osg::Uniform("mgeWaterDisplace", mWater->isDisplacedGeometry() ? 1.f : 0.f));
            // the displacement + shading field. 0 when the asset is absent -
            // the shader then runs the procedural field, never black water.
            stateset->addUniform(new osg::Uniform("mgeWaterXeField",
                (mWater->isDisplacedGeometry() && mWaveVolume) ? 1.f : 0.f));
            if (mWaveVolume)
            {
                stateset->addUniform(new osg::Uniform("mgeWave3d", 5));
                stateset->setTextureAttributeAndModes(5, mWaveVolume, osg::StateAttribute::ON);
            }
            if (mWater->getShoreImage())
            {
                stateset->addUniform(new osg::Uniform("mgeShoreMap", 6));
                stateset->addUniform(new osg::Uniform("mgeShoreParams", mWater->getShoreMapParams()));
                stateset->setTextureAttributeAndModes(6, mWater->getShoreTexture(),
                                                      osg::StateAttribute::ON);
            }
        }

        void apply(osg::StateSet* stateset, osg::NodeVisitor* nv) override
        {
            osgUtil::CullVisitor* cv = static_cast<osgUtil::CullVisitor*>(nv);
            stateset->setTextureAttributeAndModes(1, mReflection->getColorTexture(cv), osg::StateAttribute::ON);

            if (mRefraction)
            {
                stateset->setTextureAttributeAndModes(2, mRefraction->getColorTexture(cv), osg::StateAttribute::ON);
                stateset->setTextureAttributeAndModes(3, mRefraction->getDepthTexture(cv), osg::StateAttribute::ON);
            }
            if (mRipples)
            {
                stateset->setTextureAttributeAndModes(4, mRipples->getColorTexture(), osg::StateAttribute::ON);
            }
            stateset->getUniform("nodePosition")->set(osg::Vec3f(mWater->getPosition()));
            if (mWater->getShoreImage())
                stateset->getUniform("mgeShoreParams")->set(mWater->getShoreMapParams());
        }

    private:
        Water* mWater;
        Reflection* mReflection;
        Refraction* mRefraction;
        Ripples* mRipples;
        osg::ref_ptr<osg::Program> mProgram;
        osg::ref_ptr<osg::Texture2D> mNormalMap;
        osg::ref_ptr<osg::Texture3D> mWaveVolume;
    };

    void Water::createShaderWaterStateSet(osg::Node* node)
    {
        // use a define map to conditionally compile the shader
        std::map<std::string, std::string> defineMap;
        defineMap["waterRefraction"] = std::string(mRefraction ? "1" : "0");
        const int rippleDetail = Settings::water().mRainRippleDetail;
        defineMap["rainRippleDetail"] = std::to_string(rippleDetail);
        defineMap["rippleMapWorldScale"] = std::to_string(RipplesSurface::sWorldScaleFactor);
        defineMap["rippleMapSize"] = std::to_string(RipplesSurface::sRTTSize) + ".0";
        defineMap["sunlightScattering"] = Settings::water().mSunlightScattering ? "1" : "0";
        defineMap["wobblyShores"] = Settings::water().mWobblyShores ? "1" : "0";

        Stereo::shaderStereoDefines(defineMap);

        Shader::ShaderManager& shaderMgr = mResourceSystem->getSceneManager()->getShaderManager();
        osg::ref_ptr<osg::Program> program = shaderMgr.getProgram("water", defineMap);

        constexpr VFS::Path::NormalizedView waterImage("textures/omw/water_nm.png");
        osg::ref_ptr<osg::Texture2D> normalMap(
            new osg::Texture2D(mResourceSystem->getImageManager()->getImage(waterImage)));
        normalMap->setWrap(osg::Texture::WRAP_S, osg::Texture::REPEAT);
        normalMap->setWrap(osg::Texture::WRAP_T, osg::Texture::REPEAT);
        mResourceSystem->getSceneManager()->applyFilterSettings(normalMap);

        // XE's own water_NRM volume texture - a = the wave heights the
        // vertex stage displaces, rg = the baked shading normals (which
        // never scale with wave height; XE's storm trick). Loaded only in
        // displaced mode; if the asset is absent or not a volume, the
        // shader's mgeWaterXeField uniform stays 0 and the procedural
        // field serves instead - never a black-water fallback.
        osg::ref_ptr<osg::Texture3D> waveVolume;
        if (mDisplacedGeometry)
        {
            constexpr VFS::Path::NormalizedView waveImage("textures/mge/water_nrm.dds");
            try
            {
                osg::ref_ptr<osg::Image> img = mResourceSystem->getImageManager()->getImage(waveImage);
                if (img && img->r() > 1)
                {
                    waveVolume = new osg::Texture3D(img);
                    waveVolume->setWrap(osg::Texture::WRAP_S, osg::Texture::REPEAT);
                    waveVolume->setWrap(osg::Texture::WRAP_T, osg::Texture::REPEAT);
                    waveVolume->setWrap(osg::Texture::WRAP_R, osg::Texture::REPEAT);
                    // XE Common.fx sampWater3d: linear min/mag, NO mip
                    waveVolume->setFilter(osg::Texture::MIN_FILTER, osg::Texture::LINEAR);
                    waveVolume->setFilter(osg::Texture::MAG_FILTER, osg::Texture::LINEAR);
                }
                else
                    Log(Debug::Warning) << "Water: textures/mge/water_nrm.dds is not a volume; "
                                           "XE wave field disabled, procedural field in use";
            }
            catch (const std::exception& e)
            {
                Log(Debug::Warning) << "Water: XE wave volume not loaded (" << e.what()
                                    << "); procedural field in use";
            }
        }

        mRainSettingsUpdater = new RainSettingsUpdater();
        node->setUpdateCallback(mRainSettingsUpdater);

        mShaderWaterStateSetUpdater = new ShaderWaterStateSetUpdater(
            this, mReflection, mRefraction, mRipples, std::move(program), std::move(normalMap),
            std::move(waveVolume));
        node->addCullCallback(mShaderWaterStateSetUpdater);
    }

    void Water::processChangedSettings(const Settings::CategorySettingVector& settings)
    {
        updateWaterMaterial();
    }

    Water::~Water()
    {
        mParent->removeChild(mWaterNode);

        if (mReflection)
        {
            mParent->removeChild(mReflection);
            mReflection = nullptr;
        }
        if (mRefraction)
        {
            mParent->removeChild(mRefraction);
            mRefraction = nullptr;
        }
        if (mRipples)
        {
            mParent->removeChild(mRipples);
            mRipples = nullptr;
            mSimulation->setRipples(nullptr);
        }
    }

    void Water::listAssetsToPreload(std::vector<VFS::Path::Normalized>& textures)
    {
        const int frameCount = std::clamp(Fallback::Map::getInt("Water_SurfaceFrameCount"), 0, 320);
        std::string_view texture = Fallback::Map::getString("Water_SurfaceTexture");
        for (int i = 0; i < frameCount; ++i)
        {
            std::ostringstream texname;
            texname << "textures/water/" << texture << std::setw(2) << std::setfill('0') << i << ".dds";
            textures.emplace_back(texname.str());
        }
    }

    void Water::setEnabled(bool enabled)
    {
        mEnabled = enabled;
        updateVisible();
    }

    void Water::changeCell(const MWWorld::CellStore* store)
    {
        bool isInterior = !store->getCell()->isExterior();
        bool wasInterior = mInterior;
        if (!isInterior)
        {
            mWaterNode->setPosition(
                getSceneNodeCoordinates(store->getCell()->getGridX(), store->getCell()->getGridY()));
            mInterior = false;
        }
        else
        {
            mWaterNode->setPosition(osg::Vec3f(0, 0, mTop));
            mInterior = true;
        }
        if (mInterior != wasInterior && mReflection)
            mReflection->setInterior(mInterior);
    }

    void Water::setRefractionViewerFog(bool viewerUnderwater, float start, float end, const osg::Vec4f& color)
    {
        if (mRefraction)
            mRefraction->setViewerFog(viewerUnderwater, start, end, color);
    }

    void Water::setHeight(const float height)
    {
        mTop = height;

        mSimulation->setWaterHeight(height);

        osg::Vec3f pos = mWaterNode->getPosition();
        pos.z() = height;
        mWaterNode->setPosition(pos);

        if (mReflection)
            mReflection->setWaterLevel(mTop);
        if (mRefraction)
            mRefraction->setWaterLevel(mTop);
    }

    void Water::setRainIntensity(float rainIntensity)
    {
        if (mRainSettingsUpdater)
            mRainSettingsUpdater->setRainIntensity(rainIntensity);
    }

    void Water::setCameraPosition(const osg::Vec3f& cameraPos)
    {
        if (!mDisplacedGeometry)
            return;
        // XE recentres the radial mesh on the eye every frame via the world
        // transform (renderwater.cpp:441). The mesh is static in its own
        // frame; only this node position moves. The nodePosition uniform
        // tracks it per frame already (ShaderWaterStateSetUpdater::apply),
        // so worldPos in the shaders - and with it the world-anchored wave
        // field - stays correct with no shader-side change.
        osg::Vec3f pos = mWaterNode->getPosition();
        pos.x() = cameraPos.x();
        pos.y() = cameraPos.y();
        mWaterNode->setPosition(pos);
    }

    void Water::update(float dt, bool paused)
    {
        if (!paused)
        {
            mSimulation->update(dt);
        }

        if (mRipples)
        {
            mRipples->setPaused(paused);
        }
    }

    void Water::updateVisible()
    {
        bool visible = mEnabled && mToggled;
        mWaterNode->setNodeMask(visible ? ~0u : 0u);
        if (mRefraction)
            mRefraction->setNodeMask(visible ? Mask_RenderToTexture : 0u);
        if (mReflection)
            mReflection->setNodeMask(visible ? Mask_RenderToTexture : 0u);
        if (mRipples)
            mRipples->setNodeMask(visible ? Mask_RenderToTexture : 0u);
    }

    bool Water::toggle()
    {
        mToggled = !mToggled;
        updateVisible();
        return mToggled;
    }

    bool Water::isUnderwater(const osg::Vec3f& pos) const
    {
        return pos.z() < mTop && mToggled && mEnabled;
    }

    osg::Vec3f Water::getSceneNodeCoordinates(int gridX, int gridY)
    {
        return osg::Vec3f(static_cast<float>(gridX * Constants::CellSizeInUnits + (Constants::CellSizeInUnits / 2)),
            static_cast<float>(gridY * Constants::CellSizeInUnits + (Constants::CellSizeInUnits / 2)), mTop);
    }

    void Water::addEmitter(const MWWorld::Ptr& ptr, float scale, float force)
    {
        mSimulation->addEmitter(ptr, scale, force);
    }

    void Water::removeEmitter(const MWWorld::Ptr& ptr)
    {
        mSimulation->removeEmitter(ptr);
    }

    void Water::updateEmitterPtr(const MWWorld::Ptr& old, const MWWorld::Ptr& ptr)
    {
        mSimulation->updateEmitterPtr(old, ptr);
    }

    void Water::emitRipple(const osg::Vec3f& pos)
    {
        mSimulation->emitRipple(pos);
    }

    void Water::removeCell(const MWWorld::CellStore* store)
    {
        mSimulation->removeCell(store);
    }

    void Water::clearRipples()
    {
        mSimulation->clear();
    }

    void Water::showWorld(bool show)
    {
        if (mReflection)
            mReflection->showWorld(show);
        if (mRefraction)
            mRefraction->showWorld(show);
        mShowWorld = show;
    }

}
