#include "objectpaging.hpp"

#include "occlusionculling.hpp"

#include <components/sceneutil/occlusionculling.hpp>

#include <shared_mutex>
#include <unordered_map>
#include <vector>

#include <cstring>
#include <osg/AlphaFunc>
#include <osg/BlendFunc>
#include <osg/CullFace>
#include <osg/FrontFace>
#include <osg/Geode>
#include <osg/LOD>
#include <osg/Material>
#include <osg/MatrixTransform>
#include <osg/Sequence>
#include <osg/Switch>
#include <osg/TriangleIndexFunctor>
#include <osgAnimation/BasicAnimationManager>
#include <osgParticle/ParticleProcessor>
#include <osgParticle/ParticleSystemUpdater>
#include <osgUtil/IncrementalCompileOperation>
#include <osgUtil/Simplifier>
#include <set>
#include <type_traits>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <mutex>

#include <osg/Depth>

#include <components/nifosg/matrixtransform.hpp>
#include <components/resource/imagemanager.hpp>
#include <components/sceneutil/depth.hpp>
#include <components/sceneutil/texturetype.hpp>
#include <components/shader/removedalphafunc.hpp>

#include <osgDB/ObjectWrapper>
#include <osgDB/Options>
#include <osgDB/ReadFile>
#include <osgDB/Registry>
#include <osgDB/WriteFile>

#include <components/esm3/esmreader.hpp>
#include <components/esm3/loadacti.hpp>
#include <components/esm3/loadcell.hpp>
#include <components/esm3/loadcont.hpp>
#include <components/esm3/loaddoor.hpp>
#include <components/esm3/loadstat.hpp>
#include <components/esm3/readerscache.hpp>
#include <components/esm4/loadacti.hpp>
#include <components/esm4/loadcont.hpp>
#include <components/esm4/loaddoor.hpp>
#include <components/esm4/loadfurn.hpp>
#include <components/esm4/loadstat.hpp>
#include <components/esm4/loadtree.hpp>
#include <components/misc/pathhelpers.hpp>
#include <components/misc/resourcehelpers.hpp>
#include <components/misc/rng.hpp>
#include <components/resource/scenemanager.hpp>
#include <components/sceneutil/lightmanager.hpp>
#include <components/sceneutil/morphgeometry.hpp>
#include <components/sceneutil/optimizer.hpp>
#include <components/sceneutil/positionattitudetransform.hpp>
#include <components/sceneutil/riggeometry.hpp>
#include <components/sceneutil/riggeometryosgaextension.hpp>
#include <components/sceneutil/util.hpp>
#include <components/settings/values.hpp>
#include <components/vfs/manager.hpp>

#include "apps/openmw/mwbase/environment.hpp"
#include "apps/openmw/mwbase/world.hpp"
#include "apps/openmw/mwclass/esm4base.hpp"
#include "apps/openmw/mwworld/esmstore.hpp"

#include "vismask.hpp"

namespace MWRender
{

    namespace
    {
        bool typeFilter(int type, bool far)
        {
            switch (type)
            {
                case ESM::REC_STAT:
                case ESM::REC_ACTI:
                case ESM::REC_DOOR:
                case ESM::REC_STAT4:
                case ESM::REC_DOOR4:
                case ESM::REC_TREE4:
                    return true;
                case ESM::REC_CONT:
                case ESM::REC_ACTI4:
                case ESM::REC_CONT4:
                case ESM::REC_FURN4:
                    return !far;

                default:
                    return false;
            }
        }

        template <typename Record>
        std::string_view getEsm4Model(const Record& record)
        {
            if (MWClass::ESM4Impl::isMarkerModel(record->mModel))
                return {};
            else
                return record->mModel;
        }

        std::string_view getModel(int type, ESM::RefId id, const MWWorld::ESMStore& store)
        {
            switch (type)
            {
                case ESM::REC_STAT:
                    return store.get<ESM::Static>().searchStatic(id)->mModel;
                case ESM::REC_ACTI:
                    return store.get<ESM::Activator>().searchStatic(id)->mModel;
                case ESM::REC_DOOR:
                    return store.get<ESM::Door>().searchStatic(id)->mModel;
                case ESM::REC_CONT:
                    return store.get<ESM::Container>().searchStatic(id)->mModel;
                case ESM::REC_STAT4:
                    return getEsm4Model(store.get<ESM4::Static>().searchStatic(id));
                case ESM::REC_DOOR4:
                    return getEsm4Model(store.get<ESM4::Door>().searchStatic(id));
                case ESM::REC_TREE4:
                    return getEsm4Model(store.get<ESM4::Tree>().searchStatic(id));
                case ESM::REC_ACTI4:
                    return getEsm4Model(store.get<ESM4::Activator>().searchStatic(id));
                case ESM::REC_CONT4:
                    return getEsm4Model(store.get<ESM4::Container>().searchStatic(id));
                case ESM::REC_FURN4:
                    return getEsm4Model(store.get<ESM4::Furniture>().searchStatic(id));
                default:
                    return {};
            }
        }
    }

    namespace
    {
        // ==== MGE-style distant-land precompute: chunk disk cache ====
        // Serializes merged paged chunks (.osgb) so later sessions stream
        // pre-built geometry instead of re-merging. Enabled by setting
        // [Terrain] "object paging disk cache dir" to a writable directory.

        // TextureType wrapper: the ShaderVisitor needs this attribute to
        // assign texture semantics; without a wrapper osgDB drops it.
        // Deliberately not using SceneUtil::registerSerializers(): its
        // osg::Geometry stub discards vertex data, it is built for debug
        // dumps.
        class ChunkCacheTextureTypeSerializer : public osgDB::ObjectWrapper
        {
        public:
            ChunkCacheTextureTypeSerializer()
                : osgDB::ObjectWrapper([]() -> osg::Object* { return new SceneUtil::TextureType; },
                      "SceneUtil::TextureType", "osg::Object osg::StateAttribute SceneUtil::TextureType")
            {
            }
        };

        // SceneUtil::PositionAttitudeTransform wrapper: OpenMW's custom
        // single-precision PAT positions sub-groups inside merged chunks.
        // Without a wrapper osgDB degrades it to osg::Group, silently
        // dropping the placement, which displaces the geometry.
        class ChunkCachePATSerializer : public osgDB::ObjectWrapper
        {
        public:
            ChunkCachePATSerializer()
                : osgDB::ObjectWrapper([]() -> osg::Object* { return new SceneUtil::PositionAttitudeTransform; },
                      "SceneUtil::PositionAttitudeTransform",
                      "osg::Object osg::Node osg::Group osg::Transform SceneUtil::PositionAttitudeTransform")
            {
                using PAT = SceneUtil::PositionAttitudeTransform;
                using Vec3fSer = osgDB::PropByRefSerializer<PAT, osg::Vec3f>;
                using QuatSer = osgDB::PropByRefSerializer<PAT, osg::Quat>;
                addSerializer(new Vec3fSer("Position", osg::Vec3f(), &PAT::getPosition, &PAT::setPosition),
                    osgDB::BaseSerializer::RW_VEC3F);
                addSerializer(new QuatSer("Attitude", osg::Quat(), &PAT::getAttitude, &PAT::setAttitude),
                    osgDB::BaseSerializer::RW_QUAT);
                addSerializer(new Vec3fSer("Scale", osg::Vec3f(1.f, 1.f, 1.f), &PAT::getScale, &PAT::setScale),
                    osgDB::BaseSerializer::RW_VEC3F);
            }
        };

        // MWRender::RefnumMarker wrapper: rides in child UserDataContainers
        // (degraded to osg::DummyObject junk without one). Needed for
        // getPagedRefnums() to work on cache-served chunks.
        bool checkRefnumMarker(const MWRender::RefnumMarker&)
        {
            return true;
        }
        bool readRefnumMarker(osgDB::InputStream& is, MWRender::RefnumMarker& m)
        {
            unsigned int index = 0, numVerts = 0;
            int contentFile = 0;
            is >> index >> contentFile >> numVerts;
            m.mRefnum.mIndex = index;
            m.mRefnum.mContentFile = contentFile;
            m.mNumVertices = numVerts;
            return true;
        }
        bool writeRefnumMarker(osgDB::OutputStream& os, const MWRender::RefnumMarker& m)
        {
            os << m.mRefnum.mIndex << static_cast<int>(m.mRefnum.mContentFile) << m.mNumVertices << std::endl;
            return true;
        }
        class ChunkCacheRefnumMarkerSerializer : public osgDB::ObjectWrapper
        {
        public:
            ChunkCacheRefnumMarkerSerializer()
                : osgDB::ObjectWrapper([]() -> osg::Object* { return new MWRender::RefnumMarker; },
                      "MWRender::RefnumMarker", "osg::Object MWRender::RefnumMarker")
            {
                addSerializer(new osgDB::UserSerializer<MWRender::RefnumMarker>(
                                  "Refnum", checkRefnumMarker, readRefnumMarker, writeRefnumMarker),
                    osgDB::BaseSerializer::RW_USER);
            }
        };

        // NifOsg::MatrixTransform: positions animated-mesh subtrees (banners,
        // waterfalls) that the optimizer cannot flatten (dynamic variance).
        // Static pose lives in the osg::MatrixTransform base, so an
        // associate-chain wrapper round-trips it; the custom controller
        // members (mScale/mRotationScale) only matter for runtime animation,
        // which cached distant chunks deliberately freeze.
        class ChunkCacheNifMatrixTransformSerializer : public osgDB::ObjectWrapper
        {
        public:
            ChunkCacheNifMatrixTransformSerializer()
                : osgDB::ObjectWrapper([]() -> osg::Object* { return new NifOsg::MatrixTransform; },
                      "NifOsg::MatrixTransform",
                      "osg::Object osg::Node osg::Group osg::Transform osg::MatrixTransform NifOsg::MatrixTransform")
            {
            }
        };

        // Shader::RemovedAlphaFunc: ShaderVisitor's record of the replaced
        // alpha test (func + ref in the osg::AlphaFunc base). Without it the
        // reread graph loses alpha-test semantics and foliage/banners render
        // as stippled translucency on cache-served chunks.
        class ChunkCacheRemovedAlphaFuncSerializer : public osgDB::ObjectWrapper
        {
        public:
            ChunkCacheRemovedAlphaFuncSerializer()
                : osgDB::ObjectWrapper([]() -> osg::Object* { return new Shader::RemovedAlphaFunc; },
                      "Shader::RemovedAlphaFunc",
                      "osg::Object osg::StateAttribute osg::AlphaFunc Shader::RemovedAlphaFunc")
            {
            }
        };

        // MWRender::PagedOccluderData: pre-clustered building occluder
        // meshes for MSOC, serialized with the chunk so cache-served
        // chunks participate in occlusion culling like live-built ones.
        bool checkPagedOccluderData(const MWRender::PagedOccluderData&)
        {
            return true;
        }
        bool readPagedOccluderData(osgDB::InputStream& is, MWRender::PagedOccluderData& d)
        {
            unsigned int numMeshes = 0;
            is >> numMeshes;
            d.mOccluderMeshes.resize(numMeshes);
            for (auto& mesh : d.mOccluderMeshes)
            {
                osg::Vec3f bbMin, bbMax;
                unsigned int nv = 0, ni = 0;
                is >> bbMin >> bbMax >> nv >> ni;
                mesh.aabb = osg::BoundingBox(bbMin, bbMax);
                mesh.vertices.resize(nv);
                mesh.indices.resize(ni);
                for (auto& v : mesh.vertices)
                    is >> v;
                for (auto& i : mesh.indices)
                    is >> i;
            }
            return true;
        }
        bool writePagedOccluderData(osgDB::OutputStream& os, const MWRender::PagedOccluderData& d)
        {
            os << static_cast<unsigned int>(d.mOccluderMeshes.size()) << std::endl;
            for (const auto& mesh : d.mOccluderMeshes)
            {
                os << osg::Vec3f(mesh.aabb._min) << osg::Vec3f(mesh.aabb._max)
                   << static_cast<unsigned int>(mesh.vertices.size()) << static_cast<unsigned int>(mesh.indices.size())
                   << std::endl;
                for (const auto& v : mesh.vertices)
                    os << v;
                os << std::endl;
                for (const unsigned int i : mesh.indices)
                    os << i;
                os << std::endl;
            }
            return true;
        }
        class ChunkCachePagedOccluderDataSerializer : public osgDB::ObjectWrapper
        {
        public:
            ChunkCachePagedOccluderDataSerializer()
                : osgDB::ObjectWrapper([]() -> osg::Object* { return new MWRender::PagedOccluderData; },
                      "MWRender::PagedOccluderData", "osg::Object MWRender::PagedOccluderData")
            {
                addSerializer(new osgDB::UserSerializer<MWRender::PagedOccluderData>("OccluderMeshes",
                                  checkPagedOccluderData, readPagedOccluderData, writePagedOccluderData),
                    osgDB::BaseSerializer::RW_USER);
            }
        };

        void registerChunkCacheSerializers()
        {
            static bool done = false;
            if (!done)
            {
                auto* wrapperManager = osgDB::Registry::instance()->getObjectWrapperManager();
                wrapperManager->addWrapper(new ChunkCacheTextureTypeSerializer);
                wrapperManager->addWrapper(new ChunkCachePATSerializer);
                wrapperManager->addWrapper(new ChunkCacheRefnumMarkerSerializer);
                wrapperManager->addWrapper(new ChunkCacheNifMatrixTransformSerializer);
                wrapperManager->addWrapper(new ChunkCacheRemovedAlphaFuncSerializer);
                wrapperManager->addWrapper(new ChunkCachePagedOccluderDataSerializer);
                done = true;
            }
        }

        // Routes external image references (VFS paths) through OpenMW's
        // ImageManager on load; osgDB cannot read from BSAs itself.
        class VfsImageReadCallback : public osgDB::ReadFileCallback
        {
        public:
            VfsImageReadCallback(Resource::ImageManager* imageManager)
                : mImageManager(imageManager)
            {
            }

            osgDB::ReaderWriter::ReadResult readImage(const std::string& file, const osgDB::Options* options) override
            {
                const auto t0 = std::chrono::steady_clock::now();
                try
                {
                    osg::ref_ptr<osg::Image> image
                        = mImageManager->getImage(VFS::Path::Normalized(std::string_view(file)));
                    if (image)
                    {
                        const double ms
                            = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
                        if (ms > 1.0)
                            Log(Debug::Verbose) << "Chunk cache image load " << std::fixed << std::setprecision(1) << ms
                                                << "ms: " << file;
                        return osgDB::ReaderWriter::ReadResult(image, osgDB::ReaderWriter::ReadResult::FILE_LOADED);
                    }
                }
                catch (...)
                {
                }
                return osgDB::ReaderWriter::ReadResult::FILE_NOT_FOUND;
            }

        private:
            Resource::ImageManager* mImageManager;
        };

        constexpr unsigned int sChunkCacheVersion = 6; // 6: occluder data in chunk files

        // serializes osgDB node read/write (process-global registry).
        std::shared_mutex sOsgdbNodeIoMutex;
        // osgb lazy-loads serializer wrappers on first encounters (registry
        // mutation); the first reads run exclusive to warm it, then reads
        // share the lock and only writes are exclusive.
        std::atomic<unsigned int> sOsgdbWarmupReads{ 0 };
        std::mutex sChunkBuildMutex;

        // The standalone generator tool has no MWBase::World. It injects
        // the two things ObjectPaging needs from one; the game path falls
        // back to World when nothing is injected.
        std::vector<std::string> sStandaloneContentFiles;
        std::vector<int> sStandaloneEsmVersions;

        const std::vector<std::string>& contentFiles()
        {
            if (!sStandaloneContentFiles.empty())
                return sStandaloneContentFiles;
            return MWBase::Environment::get().getWorld()->getContentFiles();
        }

        const std::vector<int>& esmVersions()
        {
            if (!sStandaloneEsmVersions.empty())
                return sStandaloneEsmVersions;
            return MWBase::Environment::get().getWorld()->getESMVersions();
        }

        std::uint64_t chunkCacheFnv1a(std::uint64_t h, const void* data, size_t len)
        {
            const unsigned char* p = static_cast<const unsigned char*>(data);
            for (size_t i = 0; i < len; ++i)
            {
                h ^= p[i];
                h *= 0x100000001b3ull;
            }
            return h;
        }
    }

    // Fills a placeholder Group with the produced chunk on the update
    // traversal (main thread); producer threads never touch the live graph.
    class ObjectPaging::ChunkSwapCallback : public osg::NodeCallback
    {
    public:
        void setReady(osg::Node* node)
        {
            std::lock_guard<std::mutex> lock(mMutex);
            mReady = node;
        }

        void operator()(osg::Node* node, osg::NodeVisitor* nv) override
        {
            osg::ref_ptr<osg::Node> ready;
            {
                std::lock_guard<std::mutex> lock(mMutex);
                ready.swap(mReady);
            }
            if (ready)
            {
                static_cast<osg::Group*>(node)->addChild(ready);
                node->removeUpdateCallback(this);
                return;
            }
            traverse(node, nv);
        }

    private:
        std::mutex mMutex;
        osg::ref_ptr<osg::Node> mReady;
    };

    osg::ref_ptr<osg::Node> ObjectPaging::getChunk(float size, const osg::Vec2f& center, unsigned char /*lod*/,
        unsigned int lodFlags, bool activeGrid, const osg::Vec3f& viewPoint, bool compile)
    {
        if (activeGrid && !mActiveGrid)
            return nullptr;

        const ChunkId id = std::make_tuple(center, size, activeGrid);

        if (const osg::ref_ptr<osg::Object> obj = mCache->getRefFromObjectCache(id))
            return static_cast<osg::Node*>(obj.get());

        const unsigned char lod = static_cast<unsigned char>(lodFlags >> (4 * 4));

        // Synchronous production for the active grid and the preload path
        // (compile==true: loading screen, background preloader, generation).
        // Those callers wait for a complete chunk, and an async placeholder
        // that fills on another thread deadlocks that wait. These paths
        // already run off the render thread, so synchronous production costs
        // no frame stutter. Only the cull path (compile==false, which does
        // not wait: it uses the placeholder as-is and lets it fill later)
        // gets the async treatment, which is the stutter fix.
        // Generation mode is also fully synchronous: the async system exists
        // to fix gameplay stutter and buys generation nothing, and
        // synchronous bakes complete reliably.
        if (activeGrid || compile || sGenerationMode)
        {
            const std::filesystem::path cacheFile = activeGrid ? std::filesystem::path() : diskCachePath(id);
            osg::ref_ptr<osg::Node> node;
            if (!cacheFile.empty())
                node = readCachedChunk(cacheFile, compile);
            const bool fromDisk = node != nullptr;
            if (!node)
                node = createChunk(size, center, activeGrid, viewPoint, compile, lod);
            if (!cacheFile.empty() && node && !fromDisk && !mDiskCacheReadOnly)
                enqueueCachedChunkWrite(node.get(), cacheFile);
            mCache->addEntryToObjectCache(id, node.get());
            return node;
        }

        // Cull path (compile==false): async placeholder that fills itself.
        // The placeholder is RAM-cached immediately, so every subsequent
        // request for this id shares it.
        osg::ref_ptr<osg::Group> placeholder = new osg::Group;
        placeholder->setNodeMask(Mask_Static);
        placeholder->addUpdateCallback(new ChunkSwapCallback);

        PendingChunkLoad job;
        job.mId = id;
        job.mFile = diskCachePath(id);
        job.mSize = size;
        job.mCenter = center;
        job.mViewPoint = viewPoint;
        job.mLod = lod;
        job.mPlaceholder = placeholder;
        enqueueChunkLoad(std::move(job));

        mCache->addEntryToObjectCache(id, placeholder.get());
        return placeholder;
    }

    void ObjectPaging::enqueueChunkLoad(PendingChunkLoad&& job)
    {
        const float cellSize = static_cast<float>(ESM::getCellSize(mWorldspace));
        const osg::Vec2f worldCenter = job.mCenter * cellSize;
        const float distance = (osg::Vec2f(job.mViewPoint.x(), job.mViewPoint.y()) - worldCenter).length();

        std::lock_guard<std::mutex> lock(mLoadQueueMutex);
        mLoadQueue.emplace(distance, std::move(job));
        if (mLoadThreads.empty())
        {
            // A pool of workers so cache reads parallelize (decompression +
            // parse across cores). Builds are different: createChunk races
            // shared SceneManager state, so builds still run one-at-a-time
            // under sChunkBuildMutex regardless of pool size. At most one
            // build + main thread, which is what stock assumes.
            const unsigned int threadCount = std::clamp(Settings::terrain().mObjectPagingReadThreads.get(), 1, 8);
            for (unsigned int i = 0; i < threadCount; ++i)
                mLoadThreads.emplace_back([this] { chunkLoadWorker(); });
        }
        mLoadQueueCv.notify_one();
    }

    void ObjectPaging::chunkLoadWorker()
    {
        std::unique_lock<std::mutex> lock(mLoadQueueMutex);
        while (true)
        {
            if (mLoadThreadsStop)
                return;
            if (mLoadQueue.empty())
            {
                mLoadQueueCv.wait(lock);
                continue;
            }
            PendingChunkLoad job = std::move(mLoadQueue.begin()->second);
            mLoadQueue.erase(mLoadQueue.begin());
            ++mLoadBusy;
            lock.unlock();

            osg::ref_ptr<osg::Node> node;
            bool fromDisk = false;
            if (!job.mFile.empty())
            {
                node = readCachedChunk(job.mFile, true);
                fromDisk = node != nullptr;
            }
            if (!node)
            {
                std::lock_guard<std::mutex> buildLock(sChunkBuildMutex);
                node = createChunk(job.mSize, job.mCenter, false, job.mViewPoint, true, job.mLod);
            }
            if (node)
            {
                if (!job.mFile.empty() && !fromDisk && !mDiskCacheReadOnly)
                    enqueueCachedChunkWrite(node.get(), job.mFile);
                if (auto* callback = dynamic_cast<ChunkSwapCallback*>(job.mPlaceholder->getUpdateCallback()))
                    callback->setReady(node.get());
            }

            lock.lock();
            --mLoadBusy;
            mLoadQueueDrainCv.notify_all();
        }
    }

    void ObjectPaging::enqueueCachedChunkWrite(osg::Node* node, const std::filesystem::path& file)
    {
        // Deferral absorbs load-time disable storms: a chunk that gets
        // rebuilt several times in quick succession serializes once, with
        // the final state. The coalescing key is the filename minus the
        // disabled-state salt, so newer variants supersede queued ones.
        constexpr std::chrono::seconds writeDelay(5);

        // Bounds are computed here (build thread) so the worker's traversal
        // is pure reads on a live node.
        node->getBound();

        std::string key = file.filename().string();
        if (const auto sep = key.rfind('_'); sep != std::string::npos)
            key.resize(sep);

        {
            std::lock_guard<std::mutex> lock(mWriteQueueMutex);
            mWriteQueue[key] = PendingChunkWrite{ node, file, std::chrono::steady_clock::now() + writeDelay };
            if (!mWriteThread.joinable())
            {
                mWriteThread = std::thread([this] {
                    std::unique_lock<std::mutex> lock(mWriteQueueMutex);
                    while (true)
                    {
                        if (mWriteThreadStop)
                            return;
                        if (mWriteQueue.empty())
                        {
                            mWriteQueueCv.wait(lock);
                            continue;
                        }
                        auto next = std::min_element(mWriteQueue.begin(), mWriteQueue.end(),
                            [](const auto& a, const auto& b) { return a.second.mDue < b.second.mDue; });
                        const auto now = std::chrono::steady_clock::now();
                        if (next->second.mDue > now)
                        {
                            mWriteQueueCv.wait_until(lock, next->second.mDue);
                            continue;
                        }
                        PendingChunkWrite job = std::move(next->second);
                        mWriteQueue.erase(next);
                        mWriteBusy = true;
                        lock.unlock();
                        writeCachedChunk(job.mNode.get(), job.mFile);
                        lock.lock();
                        mWriteBusy = false;
                        mWriteQueueDrainCv.notify_all();
                    }
                });
            }
        }
        mWriteQueueCv.notify_one();
    }

    void ObjectPaging::setStandaloneContext(std::vector<std::string> files, std::vector<int> versions)
    {
        sStandaloneContentFiles = std::move(files);
        sStandaloneEsmVersions = std::move(versions);
    }

    void ObjectPaging::drainWriteQueue()
    {
        // Loads produce writes, so drain the load queue first.
        {
            std::unique_lock<std::mutex> lock(mLoadQueueMutex);
            mLoadQueueDrainCv.wait(lock, [this] { return mLoadQueue.empty() && mLoadBusy == 0; });
        }
        std::unique_lock<std::mutex> lock(mWriteQueueMutex);
        const auto now = std::chrono::steady_clock::now();
        for (auto& job : mWriteQueue)
            job.second.mDue = now;
        mWriteQueueCv.notify_all();
        mWriteQueueDrainCv.wait(lock, [this] { return mWriteQueue.empty() && !mWriteBusy; });
    }

    ObjectPaging::~ObjectPaging()
    {
        // resident-layer threads read chunks and build supercells; they must
        // be gone before the rest of the engine (SceneManager, osgDB state)
        // tears down, or quitting mid-stream crashes on exit
        mResidentShutdown = true;
        mRingCv.notify_all();
        if (mRingThread.joinable())
            mRingThread.join();
        if (mResidentLoadThread.joinable())
            mResidentLoadThread.join();
        if (mResidentRefreshThread.joinable())
            mResidentRefreshThread.join();
        {
            std::lock_guard<std::mutex> lock(mLoadQueueMutex);
            mLoadThreadsStop = true;
        }
        mLoadQueueCv.notify_all();
        for (std::thread& thread : mLoadThreads)
            if (thread.joinable())
                thread.join();
        {
            std::lock_guard<std::mutex> lock(mWriteQueueMutex);
            mWriteThreadStop = true;
        }
        mWriteQueueCv.notify_all();
        if (mWriteThread.joinable())
            mWriteThread.join();
    }

    std::filesystem::path ObjectPaging::diskCachePath(const ChunkId& id)
    {
        // resident-backdrop mode: paged chunks build in memory like stock
        // OpenMW (full-precision normals, no retired streaming cache on disk)
        if (mResidentDistantStatics.load())
            return {};
        const std::string& dir = Settings::terrain().mObjectPagingDiskCacheDir;
        if (dir.empty())
            return {};

        std::call_once(mDiskCacheInit, [this, &dir] {
            // Manifest-authoritative model (MGE semantics): one named
            // generation per worldspace, with a manifest recording what it
            // was generated from (format version, geometry settings, content
            // list). The game uses the generation unconditionally, so
            // externally generated caches built from hand-picked plugin
            // lists are first-class; on content/settings mismatch it warns
            // and goes read-only (stale-but-consistent distant land, like
            // outdated MGE distant land; regenerate to update).
            // Format-version mismatch is the exception: files would be
            // wrong/unreadable, so the generation is wiped and restarted.
            std::string ws = mWorldspace.serializeText();
            for (char& c : ws)
                if (!std::isalnum(static_cast<unsigned char>(c)))
                    c = '_';

            std::error_code ec;
            const std::filesystem::path wsBase = std::filesystem::path(dir) / ws;
            mDiskCacheDir = wsBase / "current";
            std::filesystem::create_directories(mDiskCacheDir, ec);

            std::string manifest = "format " + std::to_string(sChunkCacheVersion) + "\n";
            {
                char buf[160];
                std::snprintf(buf, sizeof(buf), "settings %.6g %.6g %.6g %.6g %.6g %.6g %.6g %d\n", mMinSize,
                    mMergeFactor, mMinSizeMergeFactor, mMinSizeCostMultiplier,
                    static_cast<float>(Settings::terrain().mObjectPagingLandmarkSize),
                    static_cast<float>(Settings::terrain().mObjectPagingLandmarkRangeFactor),
                    static_cast<float>(Settings::terrain().mObjectPagingSimplifyStrength),
                    Settings::camera().mOcclusionCulling && Settings::camera().mOcclusionCullingStatics ? 1 : 0);
                manifest += buf;
            }
            for (const std::string& f : contentFiles())
                manifest += "content " + f + "\n";

            const std::filesystem::path manifestPath = mDiskCacheDir / "manifest.txt";
            std::string existing;
            if (std::ifstream in{ manifestPath, std::ios::binary }; in)
                existing.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());

            if (existing == manifest)
                return; // generation matches the live session

            unsigned int existingFormat = 0;
            std::sscanf(existing.c_str(), "format %u", &existingFormat);

            if (!existing.empty() && existingFormat == sChunkCacheVersion && !sGenerationMode)
            {
                // Same file format, different content/settings: the
                // generation is authoritative. Serve it, don't write it.
                Log(Debug::Warning)
                    << "Distant-land cache was generated from a different content list or settings; using it "
                       "anyway (read-only). Regenerate to update: "
                    << manifestPath;
                mDiskCacheReadOnly = true;
                return;
            }

            if (!existing.empty())
                Log(Debug::Warning) << "Distant-land cache format v" << existingFormat << " superseded by v"
                                    << sChunkCacheVersion << ": regenerating " << mDiskCacheDir;
            std::filesystem::remove_all(mDiskCacheDir, ec);
            // prune legacy hash-named generations from older cache layouts
            for (const auto& entry : std::filesystem::directory_iterator(wsBase, ec))
            {
                if (entry.is_directory(ec) && entry.path() != mDiskCacheDir)
                {
                    std::error_code ec2;
                    std::filesystem::remove_all(entry.path(), ec2);
                }
            }
            std::filesystem::create_directories(mDiskCacheDir, ec);
            if (std::ofstream out{ manifestPath, std::ios::binary })
                out << manifest;
        });

        if (mDiskCacheDir.empty())
            return {};

        const osg::Vec2f& center = std::get<0>(id);
        const float size = std::get<1>(id);

        // Salt with the disabled-refs state relevant to this chunk: a chunk
        // built while a quest script had an object disabled must not be
        // served once the object is re-enabled (and vice versa). A different
        // state gives a different filename and a live rebuild; the write
        // path prunes superseded state-variants.
        std::uint64_t salt = 0xcbf29ce484222325ull;
        {
            const osg::Vec2f minBound = center - osg::Vec2f(size / 2.f, size / 2.f);
            const osg::Vec2f maxBound = center + osg::Vec2f(size / 2.f, size / 2.f);
            std::lock_guard<std::mutex> lock(mRefTrackerMutex);
            for (const auto& [refnum, cell] : getRefTracker().mDisabled)
            {
                if (cell.x() + 1 > minBound.x() && cell.x() < maxBound.x() && cell.y() + 1 > minBound.y()
                    && cell.y() < maxBound.y())
                    salt = chunkCacheFnv1a(salt, &refnum, sizeof(refnum));
            }
        }

        char name[160];
        std::snprintf(name, sizeof(name), "%.4f_%.4f_%.4f_%016llx.osgb", center.x(), center.y(), size,
            static_cast<unsigned long long>(salt));
        return mDiskCacheDir / name;
    }

    namespace
    {
        // Read-path timing: per-read at Verbose, rolling summary at Info.
        // Diagnoses render-path hitches from synchronous chunk reads.
        struct ChunkReadStats
        {
            std::mutex mMutex;
            unsigned int mCount = 0;
            double mTotalMs = 0.0;
            double mMaxMs = 0.0;

            void add(double ms, std::uintmax_t bytes, const std::filesystem::path& file)
            {
                Log(Debug::Verbose) << "Chunk cache read " << std::fixed << std::setprecision(1) << ms << "ms "
                                    << (bytes / 1024) << "KB: " << file.filename();
                std::lock_guard<std::mutex> lock(mMutex);
                ++mCount;
                mTotalMs += ms;
                mMaxMs = std::max(mMaxMs, ms);
                if (mCount % 50 == 0)
                {
                    Log(Debug::Info) << "Chunk cache reads: " << mCount << " total, avg " << std::fixed
                                     << std::setprecision(1) << (mTotalMs / mCount) << "ms, max " << mMaxMs << "ms";
                }
            }
        };
        ChunkReadStats sChunkReadStats;
    }

    osg::ref_ptr<osg::Node> ObjectPaging::readCachedChunk(
        const std::filesystem::path& file, bool compile, bool raw, bool attachOcclusion)
    {
        std::error_code ec;
        if (!std::filesystem::exists(file, ec))
            return nullptr;

        const auto readStart = std::chrono::steady_clock::now();
        const std::uintmax_t fileBytes = std::filesystem::file_size(file, ec);
        struct StatsGuard
        {
            std::chrono::steady_clock::time_point mStart;
            std::uintmax_t mBytes = 0;
            const std::filesystem::path& mFile;
            ~StatsGuard()
            {
                sChunkReadStats.add(
                    std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - mStart).count(),
                    mBytes, mFile);
            }
        } statsGuard{ readStart, fileBytes, file };

        registerChunkCacheSerializers();
        osg::ref_ptr<osgDB::Options> options = new osgDB::Options;
        options->setReadFileCallback(new VfsImageReadCallback(mSceneManager->getImageManager()));
        const auto tParse0 = std::chrono::steady_clock::now();
        // osgDB serialization touches a process-global registry; a concurrent
        // read (this) + write (writeCachedChunk on another thread) races on
        // it. Serialize all osgDB node I/O under one mutex, scoped tightly.
        osg::ref_ptr<osg::Node> node;
        if (sOsgdbWarmupReads.load() < 4)
        {
            std::unique_lock<std::shared_mutex> osgdbLock(sOsgdbNodeIoMutex);
            node = osgDB::readRefNodeFile(file.string(), options);
            ++sOsgdbWarmupReads;
        }
        else
        {
            std::shared_lock<std::shared_mutex> osgdbLock(sOsgdbNodeIoMutex);
            node = osgDB::readRefNodeFile(file.string(), options);
        }
        const auto tParse1 = std::chrono::steady_clock::now();
        if (!node)
            return nullptr;

        // Verify mode returns the raw deserialized graph, so the
        // write-verify diff measures pure file fidelity, unpolluted by the
        // read path's own shader regeneration below.
        if (raw)
            return node;

        // Serialized osg::Programs are dead weight: deserialized copies lose
        // the engine-side wiring (shared ShaderManager programs, light-buffer
        // bindings) and render as untextured translucent garbage. Strip them
        // and let the engine regenerate shaders exactly as a live build gets
        // them from its templates.
        {
            class ReadRepairVisitor : public osg::NodeVisitor
            {
            public:
                ReadRepairVisitor()
                    : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                {
                }
                void apply(osg::Node& node) override
                {
                    if (osg::StateSet* ss = node.getStateSet())
                    {
                        ss->removeAttribute(osg::StateAttribute::PROGRAM);

                        // SceneUtil::AutoDepth masquerades as osg::Depth
                        // (same class name, same values) but its apply()
                        // flips the depth function under reversed-Z. A
                        // deserialized plain osg::Depth applies its function
                        // literally, inverting the depth test so geometry
                        // renders through occluders. Restore AutoDepth.
                        const auto& attrs = ss->getAttributeList();
                        const auto it = attrs.find(std::make_pair(osg::StateAttribute::DEPTH, 0u));
                        if (it != attrs.end())
                        {
                            const osg::Depth* depth = static_cast<const osg::Depth*>(it->second.first.get());
                            const unsigned int flags = it->second.second;
                            ss->setAttribute(new SceneUtil::AutoDepth(*depth), flags);
                        }
                    }
                    traverse(node);
                }
            };
            ReadRepairVisitor strip;
            node->accept(strip);
            const auto tRepair = std::chrono::steady_clock::now();
            mSceneManager->recreateShaders(node);
            const auto tShaders = std::chrono::steady_clock::now();
            const auto phaseMs
                = [](auto a, auto b) { return std::chrono::duration<double, std::milli>(b - a).count(); };
            Log(Debug::Verbose) << "Chunk cache read phases: parse " << std::fixed << std::setprecision(1)
                                << phaseMs(tParse0, tParse1) << "ms, repair " << phaseMs(tParse1, tRepair)
                                << "ms, shaders " << phaseMs(tRepair, tShaders) << "ms: " << file.filename();
        }

        node->getBound();
        node->setNodeMask(Mask_Static);

        // MSOC participation is a runtime attachment (stripped at
        // write), so re-attach on read. The callback culls the whole chunk
        // when fully occluded even without occluder data; deserialized
        // PagedOccluderData (if any) additionally makes the chunk's
        // buildings occlude what's behind them.
        if (mOcclusionCuller && attachOcclusion)
            node->addCullCallback(new PagedOccluderCallback(
                mOcclusionCuller, Settings::camera().mOcclusionOccluderMaxDistance, mMaxTriangles));

        if (compile)
        {
            if (osgUtil::IncrementalCompileOperation* const ico = mSceneManager->getIncrementalCompileOperation())
            {
                osgUtil::StateToCompile stateToCompile(0, nullptr);
                stateToCompile._mode = osgUtil::GLObjectsVisitor::COMPILE_DISPLAY_LISTS;
                node->accept(stateToCompile);
                if (!stateToCompile.empty())
                {
                    auto compileSet = new osgUtil::IncrementalCompileOperation::CompileSet(node);
                    compileSet->buildCompileMap(ico->getContextSet(), stateToCompile);
                    ico->add(compileSet, false);
                }
            }
        }
        return node;
    }

    namespace
    {
        // Write-verify instrumentation (env OPENMW_CHUNK_CACHE_VERIFY):
        // deterministic per-node description lines, content-hashing all
        // vertex/index arrays, so an original chunk and its disk round-trip
        // can be diffed structurally. Program attributes are excluded (the
        // read path strips and regenerates them by design).
        class ChunkStatsVisitor : public osg::NodeVisitor
        {
        public:
            std::vector<std::string> mLines;

            ChunkStatsVisitor()
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
            {
            }

            static std::uint64_t hashBytes(const void* data, size_t len)
            {
                return data ? chunkCacheFnv1a(0xcbf29ce484222325ull, data, len) : 0;
            }

            void describeStateSet(const osg::StateSet* ss, std::string& line)
            {
                if (!ss)
                {
                    line += " ss=none";
                    return;
                }
                line += " attrs[";
                for (const auto& attrPair : ss->getAttributeList())
                {
                    if (attrPair.first.first == osg::StateAttribute::PROGRAM)
                        continue;
                    line += std::to_string(attrPair.first.first) + ",";
                }
                line += "] tex[";
                const auto& tal = ss->getTextureAttributeList();
                for (unsigned int unit = 0; unit < tal.size(); ++unit)
                {
                    for (const auto& attrPair : tal[unit])
                    {
                        line += std::to_string(unit) + ":" + std::to_string(attrPair.first.first);
                        if (const osg::Texture* t = attrPair.second.first->asTexture())
                            if (t->getNumImages() > 0 && t->getImage(0))
                                line += "=" + t->getImage(0)->getFileName();
                        line += ",";
                    }
                }
                line += "] modes=" + std::to_string(ss->getModeList().size())
                    + " rbin=" + std::to_string(ss->getBinNumber()) + "/" + ss->getBinName();
            }

            void apply(osg::Node& node) override
            {
                std::string line = node.className();
                describeStateSet(node.getStateSet(), line);
                mLines.push_back(std::move(line));
                traverse(node);
            }

            void apply(osg::Transform& transform) override
            {
                std::string line = transform.className();
                osg::Matrix m;
                transform.computeLocalToWorldMatrix(m, nullptr);
                char buf[32];
                std::snprintf(buf, sizeof(buf), " m=%016llx",
                    static_cast<unsigned long long>(hashBytes(m.ptr(), sizeof(osg::Matrix::value_type) * 16)));
                line += buf;
                describeStateSet(transform.getStateSet(), line);
                mLines.push_back(std::move(line));
                traverse(transform);
            }

            void apply(osg::Drawable& drawable) override
            {
                std::string line = drawable.className();
                if (const osg::Geometry* g = drawable.asGeometry())
                {
                    char buf[64];
                    const auto add = [&](const char* tag, const osg::Array* a) {
                        std::snprintf(buf, sizeof(buf), " %s:%u/%016llx", tag,
                            a ? static_cast<unsigned int>(a->getNumElements()) : 0u,
                            static_cast<unsigned long long>(
                                a ? hashBytes(a->getDataPointer(), a->getTotalDataSize()) : 0));
                        line += buf;
                    };
                    add("v", g->getVertexArray());
                    add("n", g->getNormalArray());
                    add("c", g->getColorArray());
                    add("t0", g->getTexCoordArray(0));
                    add("t1", g->getTexCoordArray(1));
                    line += " prims:";
                    for (unsigned int i = 0; i < g->getNumPrimitiveSets(); ++i)
                    {
                        const osg::PrimitiveSet* ps = g->getPrimitiveSet(i);
                        std::snprintf(
                            buf, sizeof(buf), "%d/%u/", ps->getMode(), static_cast<unsigned int>(ps->getNumIndices()));
                        line += buf;
                        if (const osg::DrawElements* de = ps->getDrawElements())
                        {
                            std::snprintf(buf, sizeof(buf), "%016llx,",
                                static_cast<unsigned long long>(
                                    hashBytes(de->getDataPointer(), de->getTotalDataSize())));
                            line += buf;
                        }
                        else
                            line += "-,";
                    }
                }
                describeStateSet(drawable.getStateSet(), line);
                mLines.push_back(std::move(line));
            }
        };
    }

    namespace
    {
        // Verify-mode wrapper inventory: every osg::Object class present in
        // a chunk graph that lacks a registered osgDB wrapper degrades
        // silently on write. Enumerate them all at once.
        class WrapperInventoryVisitor : public osg::NodeVisitor
        {
        public:
            std::set<std::string> mMissing;

            WrapperInventoryVisitor()
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
            {
            }

            void check(const osg::Object* obj)
            {
                if (!obj)
                    return;
                const std::string name = std::string(obj->libraryName()) + "::" + obj->className();
                if (!osgDB::Registry::instance()->getObjectWrapperManager()->findWrapper(name))
                    mMissing.insert(name);
            }

            void checkCallbacks(const osg::Callback* cb)
            {
                for (; cb; cb = cb->getNestedCallback())
                    check(cb);
            }

            void checkStateSet(const osg::StateSet* ss)
            {
                if (!ss)
                    return;
                check(ss);
                for (const auto& attrPair : ss->getAttributeList())
                    check(attrPair.second.first.get());
                for (const auto& unit : ss->getTextureAttributeList())
                    for (const auto& attrPair : unit)
                        check(attrPair.second.first.get());
                checkCallbacks(ss->getUpdateCallback());
                checkCallbacks(ss->getEventCallback());
            }

            void checkObject(const osg::Node& node)
            {
                check(&node);
                checkStateSet(node.getStateSet());
                checkCallbacks(node.getUpdateCallback());
                checkCallbacks(node.getEventCallback());
                checkCallbacks(node.getCullCallback());
                if (const osg::UserDataContainer* udc = node.getUserDataContainer())
                    for (unsigned int i = 0; i < udc->getNumUserObjects(); ++i)
                        check(udc->getUserObject(i));
            }

            void apply(osg::Node& node) override
            {
                checkObject(node);
                traverse(node);
            }

            void apply(osg::Drawable& drawable) override
            {
                checkObject(drawable);
                if (const osg::Geometry* g = drawable.asGeometry())
                {
                    check(g->getVertexArray());
                    check(g->getNormalArray());
                    check(g->getColorArray());
                }
            }
        };
    }

    namespace
    {
        template <class ArrayT>
        osg::Array* compactArrayT(const ArrayT* src, const std::vector<unsigned int>& oldOfNew)
        {
            ArrayT* dst = new ArrayT();
            dst->reserve(oldOfNew.size());
            for (const unsigned int old : oldOfNew)
                dst->push_back((*src)[old]);
            dst->setBinding(src->getBinding());
            dst->setNormalize(src->getNormalize());
            return dst;
        }

        osg::Array* compactArray(const osg::Array* src, const std::vector<unsigned int>& oldOfNew)
        {
            if (!src)
                return nullptr;
            if (const auto* a = dynamic_cast<const osg::Vec2Array*>(src))
                return compactArrayT(a, oldOfNew);
            if (const auto* a = dynamic_cast<const osg::Vec3Array*>(src))
                return compactArrayT(a, oldOfNew);
            if (const auto* a = dynamic_cast<const osg::Vec4Array*>(src))
                return compactArrayT(a, oldOfNew);
            if (const auto* a = dynamic_cast<const osg::Vec4ubArray*>(src))
                return compactArrayT(a, oldOfNew);
            if (const auto* a = dynamic_cast<const osg::FloatArray*>(src))
                return compactArrayT(a, oldOfNew);
            return nullptr; // exotic type: caller keeps the geometry as-is
        }

        // Edge collapse cannot reduce disconnected card soups (tree canopies
        // and bushes, where every edge is a boundary). MGE-style fallback:
        // keep a deterministic, evenly-spread stride of whole quads (triangle
        // pairs) and compact the vertex arrays down to what the kept cards
        // use.
        bool dropCards(osg::Geometry& geom, float ratio, const char** whyNot = nullptr)
        {
            const auto fail = [&](const char* why) {
                if (whyNot)
                    *whyNot = why;
                return false;
            };
            if (geom.getNumPrimitiveSets() != 1)
                return fail("multi-primset");
            osg::DrawElementsUInt* de = dynamic_cast<osg::DrawElementsUInt*>(geom.getPrimitiveSet(0));
            if (!de || de->getMode() != GL_TRIANGLES)
                return fail("not-uint-triangles");
            const size_t nTri = de->size() / 3;
            if (nTri < 8)
                return fail("tiny");
            const size_t nPair = nTri / 2;
            std::vector<unsigned int> keptIdx;
            keptIdx.reserve(static_cast<size_t>(de->size() * ratio) + 6);
            for (size_t pair = 0; pair < nPair; ++pair)
            {
                if (static_cast<size_t>(static_cast<float>(pair + 1) * ratio)
                    == static_cast<size_t>(static_cast<float>(pair) * ratio))
                    continue; // dropped
                for (size_t k = pair * 6; k < pair * 6 + 6; ++k)
                    keptIdx.push_back((*de)[k]);
            }
            if (keptIdx.empty() || keptIdx.size() >= de->size())
                return fail("kept-all");

            std::unordered_map<unsigned int, unsigned int> remap;
            std::vector<unsigned int> oldOfNew;
            osg::ref_ptr<osg::DrawElementsUInt> newDe = new osg::DrawElementsUInt(GL_TRIANGLES);
            newDe->reserve(keptIdx.size());
            for (const unsigned int old : keptIdx)
            {
                auto [it, inserted] = remap.emplace(old, static_cast<unsigned int>(oldOfNew.size()));
                if (inserted)
                    oldOfNew.push_back(old);
                newDe->push_back(it->second);
            }

            osg::ref_ptr<osg::Array> verts = compactArray(geom.getVertexArray(), oldOfNew);
            if (!verts)
                return fail("vertex-array-type");
            std::vector<osg::ref_ptr<osg::Array>> tex(geom.getNumTexCoordArrays());
            for (unsigned int i = 0; i < geom.getNumTexCoordArrays(); ++i)
            {
                tex[i] = compactArray(geom.getTexCoordArray(i), oldOfNew);
                if (geom.getTexCoordArray(i) && !tex[i])
                    return fail("texcoord-array-type");
            }
            osg::ref_ptr<osg::Array> normals;
            if (const osg::Array* src = geom.getNormalArray())
            {
                if (src->getBinding() == osg::Array::BIND_PER_VERTEX && !(normals = compactArray(src, oldOfNew)))
                    return fail("normal-array-type");
            }
            osg::ref_ptr<osg::Array> colors;
            if (const osg::Array* src = geom.getColorArray())
            {
                if (src->getBinding() == osg::Array::BIND_PER_VERTEX && !(colors = compactArray(src, oldOfNew)))
                    return fail("color-array-type");
            }

            geom.setVertexArray(verts);
            if (normals)
                geom.setNormalArray(normals);
            if (colors)
                geom.setColorArray(colors);
            for (unsigned int i = 0; i < tex.size(); ++i)
                if (tex[i])
                    geom.setTexCoordArray(i, tex[i]);
            geom.getPrimitiveSetList().clear();
            geom.addPrimitiveSet(newDe);
            geom.dirtyBound();
            return true;
        }
    }

    const osg::Node* ObjectPaging::getSimplifiedTemplate(
        const osg::Node* node, float ratio, Resource::TemplateMultiRef& templateRefs)
    {
        const std::pair<const osg::Node*, float> key{ node, ratio };
        std::lock_guard<std::mutex> lock(mSimplifiedTemplatesMutex);
        auto it = mSimplifiedTemplates.find(key);
        if (it == mSimplifiedTemplates.end())
        {
            if (mSimplifiedTemplates.size() > 4096) // bound memory on huge mod lists
                mSimplifiedTemplates.clear();
            osg::ref_ptr<osg::Node> copy
                = static_cast<osg::Node*>(node->clone(osg::CopyOp::DEEP_COPY_NODES | osg::CopyOp::DEEP_COPY_DRAWABLES
                    | osg::CopyOp::DEEP_COPY_ARRAYS | osg::CopyOp::DEEP_COPY_PRIMITIVES));
            struct CollectGeometryVisitor : public osg::NodeVisitor
            {
                std::vector<osg::Geometry*> mHits;
                CollectGeometryVisitor()
                    : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                {
                }
                size_t mSkippedVerts = 0;
                std::map<std::string, size_t> mSkipReasons;
                void apply(osg::Drawable& d) override
                {
                    osg::Geometry* geom = d.asGeometry();
                    const size_t nv = geom && geom->getVertexArray() ? geom->getVertexArray()->getNumElements() : 0;
                    // plain static Geometry only: rigged/morphing/custom
                    // drawables are handled (or skipped) by the chunk CopyOp
                    const char* skip = nullptr;
                    if (!geom)
                        skip = "not-geometry";
                    else if (std::strcmp(geom->className(), "Geometry") != 0)
                        skip = geom->className();
                    else if (geom->getDataVariance() == osg::Object::DYNAMIC)
                        skip = "dynamic";
                    else if (nv < 96)
                        skip = "small";
                    if (!skip)
                        for (unsigned int i = 0; i < geom->getNumPrimitiveSets(); ++i)
                        {
                            const GLenum mode = geom->getPrimitiveSet(i)->getMode();
                            if (mode != GL_TRIANGLES && mode != GL_TRIANGLE_STRIP && mode != GL_TRIANGLE_FAN)
                            {
                                skip = "non-triangle";
                                break;
                            }
                        }
                    if (skip)
                    {
                        mSkippedVerts += nv;
                        ++mSkipReasons[skip];
                        return;
                    }
                    mHits.push_back(geom);
                }
            } collector;
            copy->accept(collector);
            osgUtil::Simplifier simplifier(ratio);
            simplifier.setDoTriStrip(false);
            simplifier.setSmoothing(false);
            size_t before = 0, after = 0;
            for (osg::Geometry* geom : collector.mHits)
            {
                // Simplifier's edge-collapse ingests only GL_TRIANGLES primitive
                // sets and silently skips strips/fans (NiTriStrips meshes came
                // through untouched). Rebuild as one indexed triangle list first.
                bool needsConversion = geom->getNumPrimitiveSets() > 1
                    || !dynamic_cast<osg::DrawElementsUInt*>(geom->getPrimitiveSet(0));
                for (unsigned int i = 0; !needsConversion && i < geom->getNumPrimitiveSets(); ++i)
                    needsConversion = geom->getPrimitiveSet(i)->getMode() != GL_TRIANGLES;
                if (needsConversion)
                {
                    struct TriangleCollector
                    {
                        osg::ref_ptr<osg::DrawElementsUInt> mElements = new osg::DrawElementsUInt(GL_TRIANGLES);
                        void operator()(unsigned int a, unsigned int b, unsigned int c)
                        {
                            mElements->push_back(a);
                            mElements->push_back(b);
                            mElements->push_back(c);
                        }
                    };
                    osg::TriangleIndexFunctor<TriangleCollector> functor;
                    geom->accept(functor);
                    geom->getPrimitiveSetList().clear();
                    geom->addPrimitiveSet(functor.mElements);
                }
                const size_t nb = geom->getVertexArray()->getNumElements();
                before += nb;
                simplifier.simplify(*geom); // in place; the clone owns its arrays
                // Edge collapse runs out of collapsible edges long before
                // the target on card-heavy geometry (foliage, where every
                // edge is a boundary). Finish the job MGE-style: drop whole
                // quads at a deterministic stride until the residual budget
                // is met.
                const size_t nSimp = geom->getVertexArray()->getNumElements();
                const size_t target = static_cast<size_t>(static_cast<float>(nb) * ratio);
                if (nSimp * 100 > target * 115)
                    dropCards(*geom, static_cast<float>(target) / static_cast<float>(nSimp));
                after += geom->getVertexArray()->getNumElements();
            }
            std::string reasons;
            for (const auto& [why, cnt] : collector.mSkipReasons)
                reasons += " " + why + ":" + std::to_string(cnt);
            Log(Debug::Verbose) << "Simplified template " << node->getName() << " ratio " << ratio << ": verts "
                                << before << " -> " << after << ", skipped-verts " << collector.mSkippedVerts
                                << (reasons.empty() ? "" : " (" + reasons + ")");
            it = mSimplifiedTemplates.emplace(key, std::make_pair(osg::ref_ptr<const osg::Node>(node), copy)).first;
        }
        // the chunk must pin the simplified template like any other template
        templateRefs.addRef(it->second.second.get());
        return it->second.second.get();
    }

    void ObjectPaging::writeCachedChunk(osg::Node* node, const std::filesystem::path& file, bool pruneSiblingVariants)
    {
        registerChunkCacheSerializers();
        std::error_code ec;
        std::filesystem::create_directories(file.parent_path(), ec);

        if (std::getenv("OPENMW_CHUNK_CACHE_VERIFY"))
        {
            WrapperInventoryVisitor inventory;
            node->accept(inventory);
            for (const std::string& name : inventory.mMissing)
            {
                // Known-inert degradations: animation controllers (cached
                // distant chunks freeze animation by design) and template
                // lifetime pins (meaningless outside the live process).
                const bool inert = name.ends_with("Controller") || name == "Resource::TemplateMultiRef";
                Log(inert ? Debug::Verbose : Debug::Error)
                    << "Chunk cache: NO WRAPPER for " << name << " (will degrade): " << file.filename();
            }
        }

        // The node may be live in the scene (background writes), so never
        // mutate it: serialize a structural clone (node/drawable/stateset
        // shells copied; geometry arrays, textures and images shared
        // read-only). Owning the stateset shells lets us strip the
        // osg::Program attributes before writing: serialized programs are
        // 90+% of file size (full GLSL text per stateset) and dominate the
        // read-path parse cost, only to be discarded by the read repair.
        osg::ref_ptr<osg::Node> toWrite = static_cast<osg::Node*>(node->clone(osg::CopyOp(
            osg::CopyOp::DEEP_COPY_NODES | osg::CopyOp::DEEP_COPY_DRAWABLES | osg::CopyOp::DEEP_COPY_STATESETS)));
        toWrite->setUserDataContainer(nullptr);
        toWrite->setCullCallback(nullptr);
        // Occluder meshes are chunk content, not runtime state: carry
        // them into the file (everything else in the UDC stays stripped).
        if (const osg::UserDataContainer* udc = node->getUserDataContainer())
            for (unsigned int i = 0; i < udc->getNumUserObjects(); ++i)
                if (auto* pod = dynamic_cast<const MWRender::PagedOccluderData*>(udc->getUserObject(i)))
                {
                    toWrite->getOrCreateUserDataContainer()->addUserObject(
                        const_cast<MWRender::PagedOccluderData*>(pod));
                    break;
                }
        {
            class StripForWriteVisitor : public osg::NodeVisitor
            {
            public:
                StripForWriteVisitor()
                    : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                {
                }
                void apply(osg::Node& n) override
                {
                    if (osg::StateSet* ss = n.getStateSet())
                        ss->removeAttribute(osg::StateAttribute::PROGRAM);
                    traverse(n);
                }
            };
            StripForWriteVisitor stripPrograms;
            toWrite->accept(stripPrograms);
        }

        // External image refs need filenames. NIF-embedded textures (pixel
        // data inside the mesh, e.g. some coral glow maps) have none, so mark
        // exactly those images STORE_INLINE (the per-image hint overrides the
        // global option). A whole-file IncludeData fallback would inline
        // every texture of any chunk containing one nameless image and
        // balloon the bake size.
        class MarkNamelessImageVisitor : public osg::NodeVisitor
        {
        public:
            MarkNamelessImageVisitor()
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
            {
            }

            void checkStateSet(const osg::StateSet* ss)
            {
                if (!ss)
                    return;
                for (const auto& unit : ss->getTextureAttributeList())
                    for (const auto& attrPair : unit)
                        if (const osg::Texture* t = attrPair.second.first->asTexture())
                            for (unsigned int i = 0; i < t->getNumImages(); ++i)
                                if (t->getImage(i) && t->getImage(i)->getFileName().empty()
                                    && t->getImage(i)->getWriteHint() != osg::Image::STORE_INLINE)
                                    const_cast<osg::Image*>(t->getImage(i))->setWriteHint(osg::Image::STORE_INLINE);
            }

            void apply(osg::Node& node) override
            {
                checkStateSet(node.getStateSet());
                traverse(node);
            }
            void apply(osg::Drawable& d) override { checkStateSet(d.getStateSet()); }
        };
        MarkNamelessImageVisitor nameless;
        node->accept(nameless);

        osg::ref_ptr<osgDB::Options> options = new osgDB::Options("WriteImageHint=UseExternal");
        // osgDB picks the writer by the last extension, so the temp name must
        // still end in .osgb ("X.osgb.tmp" fails with "not implemented").
        // Thread-unique counter: concurrent preload threads writing the same
        // chunk would interleave into one temp file and corrupt it.
        static std::atomic<unsigned int> sTmpCounter{ 0 };
        const std::filesystem::path tmp = file.string() + "." + std::to_string(sTmpCounter.fetch_add(1)) + ".tmp.osgb";
        // Attribute slimming: byte normals (12 -> 4 bytes/vert, normalized),
        // compact ub colors (16 -> 4), ushort indices where they fit.
        // Smaller files and faster parses. Operates on new arrays set on
        // the cloned drawables; the originals are shared with the live scene
        // and must never be touched. Skipped under write-verify (the verify
        // diff compares array types against the in-memory original).
        if (!std::getenv("OPENMW_CHUNK_CACHE_VERIFY"))
        {
            class SlimVisitor : public osg::NodeVisitor
            {
            public:
                SlimVisitor()
                    : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                {
                }
                void apply(osg::Drawable& d) override
                {
                    osg::Geometry* geom = d.asGeometry();
                    if (!geom || std::strcmp(geom->className(), "Geometry") != 0)
                        return;
                    if (const auto* n = dynamic_cast<const osg::Vec3Array*>(geom->getNormalArray()))
                    {
                        osg::ref_ptr<osg::Vec3bArray> nb = new osg::Vec3bArray();
                        nb->reserve(n->size());
                        for (const osg::Vec3f& v : *n)
                            nb->push_back(osg::Vec3b(static_cast<signed char>(osg::round(v.x() * 127.f)),
                                static_cast<signed char>(osg::round(v.y() * 127.f)),
                                static_cast<signed char>(osg::round(v.z() * 127.f))));
                        nb->setBinding(n->getBinding());
                        nb->setNormalize(true);
                        geom->setNormalArray(nb);
                    }
                    if (const auto* c = dynamic_cast<const osg::Vec4Array*>(geom->getColorArray()))
                    {
                        osg::ref_ptr<osg::Vec4ubArray> cb = new osg::Vec4ubArray();
                        cb->reserve(c->size());
                        for (const osg::Vec4f& v : *c)
                            cb->push_back(osg::Vec4ub(
                                static_cast<unsigned char>(osg::round(osg::clampBetween(v.x(), 0.f, 1.f) * 255.f)),
                                static_cast<unsigned char>(osg::round(osg::clampBetween(v.y(), 0.f, 1.f) * 255.f)),
                                static_cast<unsigned char>(osg::round(osg::clampBetween(v.z(), 0.f, 1.f) * 255.f)),
                                static_cast<unsigned char>(osg::round(osg::clampBetween(v.w(), 0.f, 1.f) * 255.f))));
                        cb->setBinding(c->getBinding());
                        cb->setNormalize(true);
                        geom->setColorArray(cb);
                    }
                    const unsigned int nVerts = geom->getVertexArray() ? geom->getVertexArray()->getNumElements() : 0;
                    if (nVerts && nVerts <= 0xffffu)
                        for (unsigned int i = 0; i < geom->getNumPrimitiveSets(); ++i)
                            if (const auto* deu = dynamic_cast<const osg::DrawElementsUInt*>(geom->getPrimitiveSet(i)))
                            {
                                osg::ref_ptr<osg::DrawElementsUShort> des = new osg::DrawElementsUShort(deu->getMode());
                                des->reserve(deu->size());
                                for (const unsigned int idx : *deu)
                                    des->push_back(static_cast<unsigned short>(idx));
                                geom->setPrimitiveSet(i, des);
                            }
                }
            } slim;
            toWrite->accept(slim);
        }

        // Experiment (OPENMW_CHUNK_CACHE_COMPRESS=1): zlib-compress chunk
        // files via the osgb serializer; the reader auto-detects, so
        // compressed and raw chunks can coexist in one cache.
        if (Settings::terrain().mObjectPagingCacheCompression || std::getenv("OPENMW_CHUNK_CACHE_COMPRESS"))
            options->setOptionString(options->getOptionString() + " Compressor=zlib");
        bool ok;
        {
            std::unique_lock<std::shared_mutex> osgdbLock(sOsgdbNodeIoMutex); // see readCachedChunk
            ok = osgDB::writeNodeFile(*toWrite, tmp.string(), options);
        }

        if (ok)
        {
            std::filesystem::rename(tmp, file, ec);
            if (ec)
            {
                ++mWriteFailures;
                Log(Debug::Error) << "Failed to store paged chunk " << file << ": " << ec.message();
                std::error_code ec2;
                std::filesystem::remove(tmp, ec2);
                return;
            }

            // Prune superseded disabled-state variants of this chunk
            // (same "cx_cy_size_" prefix, different salt). Not for supercell
            // files: their names prefix-match their column siblings and the
            // pruner would delete them.
            const std::string fname = pruneSiblingVariants ? file.filename().string() : std::string();
            if (pruneSiblingVariants)
            {
                const std::string::size_type lastSep = fname.rfind('_');
                if (lastSep != std::string::npos)
                {
                    const std::string prefix = fname.substr(0, lastSep + 1);
                    for (const auto& entry : std::filesystem::directory_iterator(file.parent_path(), ec))
                    {
                        const std::string other = entry.path().filename().string();
                        if (other.size() > prefix.size() && other.compare(0, prefix.size(), prefix) == 0
                            && other.find(".tmp.") == std::string::npos && entry.path() != file)
                        {
                            std::error_code ec2;
                            std::filesystem::remove(entry.path(), ec2);
                        }
                    }
                }
            }

            // Write-verify mode: two-stage value-level diff against the
            // in-memory original. Stage FILE: the raw deserialized graph
            // (pure file fidelity). Stage READPATH: the graph after the real
            // read path's shader regeneration (what actually renders).
            // Attribute values compare via osg's own compare() machinery;
            // a presence-only comparison would pass wrong BlendFunc/Material
            // values straight through to the renderer.
            if (std::getenv("OPENMW_CHUNK_CACHE_VERIFY"))
            {
                const auto collect = [](osg::Node* root) {
                    struct CollectVisitor : osg::NodeVisitor
                    {
                        std::vector<osg::Node*> mNodes;
                        CollectVisitor()
                            : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                        {
                        }
                        void apply(osg::Node& n) override
                        {
                            mNodes.push_back(&n);
                            traverse(n);
                        }
                        void apply(osg::Drawable& d) override { mNodes.push_back(&d); }
                    } v;
                    root->accept(v);
                    return std::move(v.mNodes);
                };

                const auto compareStateSets = [](const osg::StateSet* a, const osg::StateSet* b, std::string& out) {
                    if (!a || !b)
                    {
                        if (!a != !b)
                            out += " ss-presence";
                        return;
                    }
                    if (a->getModeList() != b->getModeList())
                        out += " modes";
                    if (a->getRenderingHint() != b->getRenderingHint())
                        out += " hint";
                    if (a->getBinNumber() != b->getBinNumber() || a->getBinName() != b->getBinName()
                        || a->getRenderBinMode() != b->getRenderBinMode())
                        out += " renderbin";
                    const auto& la = a->getAttributeList();
                    const auto& lb = b->getAttributeList();
                    // PROGRAM is stripped/regenerated by design, so exclude it
                    const auto countNonProgram = [](const osg::StateSet::AttributeList& l) {
                        size_t n = 0;
                        for (const auto& p : l)
                            if (p.first.first != osg::StateAttribute::PROGRAM)
                                ++n;
                        return n;
                    };
                    if (countNonProgram(la) != countNonProgram(lb))
                        out += " attr-count";
                    else
                    {
                        auto ia = la.begin();
                        auto ib = lb.begin();
                        while (ia != la.end() && ib != lb.end())
                        {
                            if (ia->first.first == osg::StateAttribute::PROGRAM)
                            {
                                ++ia;
                                continue;
                            }
                            if (ib->first.first == osg::StateAttribute::PROGRAM)
                            {
                                ++ib;
                                continue;
                            }
                            if (ia->first != ib->first)
                            {
                                out += " attr-key";
                                break;
                            }
                            if (ia->second.second != ib->second.second)
                                out += std::string(" attr-override:") + ia->second.first->className();
                            else if (ia->second.first->compare(*ib->second.first) != 0)
                            {
                                // Depth family: an AutoDepth <-> osg::Depth typeid
                                // mismatch with identical values is expected in the raw
                                // file (repaired by ReadRepairVisitor); compare by value.
                                const auto* da = dynamic_cast<const osg::Depth*>(ia->second.first.get());
                                const auto* db = dynamic_cast<const osg::Depth*>(ib->second.first.get());
                                if (da && db && da->getFunction() == db->getFunction()
                                    && da->getWriteMask() == db->getWriteMask() && da->getZNear() == db->getZNear()
                                    && da->getZFar() == db->getZFar())
                                    ; // value-equal depth
                                else
                                    out += std::string(" attr-value:") + ia->second.first->className();
                            }
                            ++ia;
                            ++ib;
                        }
                    }
                    const auto& ta = a->getTextureAttributeList();
                    const auto& tb = b->getTextureAttributeList();
                    if (ta.size() != tb.size())
                        out += " texunit-count";
                    else
                        for (unsigned int u = 0; u < ta.size(); ++u)
                        {
                            if (ta[u].size() != tb[u].size())
                            {
                                out += " texattr-count@" + std::to_string(u);
                                continue;
                            }
                            auto ia = ta[u].begin();
                            auto ib = tb[u].begin();
                            for (; ia != ta[u].end(); ++ia, ++ib)
                            {
                                const osg::StateAttribute* sa = ia->second.first.get();
                                const osg::StateAttribute* sb = ib->second.first.get();
                                if (std::string(sa->className()) != sb->className())
                                {
                                    out += " texattr-class@" + std::to_string(u);
                                    continue;
                                }
                                if (const osg::Texture* txa = sa->asTexture())
                                {
                                    // Texture::compare() pointer-compares images; compare
                                    // by filename + sampler params instead.
                                    const osg::Texture* txb = sb->asTexture();
                                    const auto imgName = [](const osg::Texture* t) {
                                        return (t->getNumImages() > 0 && t->getImage(0)) ? t->getImage(0)->getFileName()
                                                                                         : std::string("<none>");
                                    };
                                    if (imgName(txa) != imgName(txb))
                                        out += " tex-image@" + std::to_string(u) + ":" + imgName(txa) + "|"
                                            + imgName(txb);
                                    if (txa->getWrap(osg::Texture::WRAP_S) != txb->getWrap(osg::Texture::WRAP_S)
                                        || txa->getWrap(osg::Texture::WRAP_T) != txb->getWrap(osg::Texture::WRAP_T)
                                        || txa->getFilter(osg::Texture::MIN_FILTER)
                                            != txb->getFilter(osg::Texture::MIN_FILTER)
                                        || txa->getFilter(osg::Texture::MAG_FILTER)
                                            != txb->getFilter(osg::Texture::MAG_FILTER))
                                        out += " tex-params@" + std::to_string(u);
                                }
                                else if (sa->compare(*sb) != 0)
                                    out += std::string(" texattr-value:") + sa->className();
                            }
                        }
                };

                const auto compareGraphs = [&](osg::Node* rootA, osg::Node* rootB, const char* stage) {
                    std::vector<osg::Node*> na = collect(rootA);
                    std::vector<osg::Node*> nb = collect(rootB);
                    size_t issues = 0;
                    if (na.size() != nb.size())
                    {
                        Log(Debug::Error) << "Chunk cache verify[" << stage << "] node count " << na.size() << " vs "
                                          << nb.size() << ": " << file.filename();
                        ++issues;
                    }
                    const size_t n = std::min(na.size(), nb.size());
                    for (size_t i = 0; i < n && issues < 10; ++i)
                    {
                        std::string out;
                        if (std::string(na[i]->className()) != nb[i]->className())
                            out += std::string(" class:") + na[i]->className() + "|" + nb[i]->className();
                        else
                        {
                            if (const auto* mta = dynamic_cast<const osg::MatrixTransform*>(na[i]))
                                if (mta->getMatrix() != static_cast<const osg::MatrixTransform*>(nb[i])->getMatrix())
                                    out += " matrix";
                            if (const auto* pata = dynamic_cast<const SceneUtil::PositionAttitudeTransform*>(na[i]))
                            {
                                const auto* patb = static_cast<const SceneUtil::PositionAttitudeTransform*>(nb[i]);
                                if (pata->getPosition() != patb->getPosition()
                                    || !(pata->getAttitude() == patb->getAttitude())
                                    || pata->getScale() != patb->getScale())
                                    out += " pat";
                            }
                            if (const osg::Geometry* ga = na[i]->asGeometry())
                            {
                                const osg::Geometry* gb = nb[i]->asGeometry();
                                const auto ah = [](const osg::Array* arr) {
                                    return arr
                                        ? ChunkStatsVisitor::hashBytes(arr->getDataPointer(), arr->getTotalDataSize())
                                        : 0;
                                };
                                if (ah(ga->getVertexArray()) != ah(gb->getVertexArray())
                                    || ah(ga->getNormalArray()) != ah(gb->getNormalArray())
                                    || ah(ga->getColorArray()) != ah(gb->getColorArray())
                                    || ah(ga->getTexCoordArray(0)) != ah(gb->getTexCoordArray(0)))
                                    out += " geometry-arrays";
                                if (ga->getNumPrimitiveSets() != gb->getNumPrimitiveSets())
                                    out += " primset-count";
                            }
                        }
                        compareStateSets(na[i]->getStateSet(), nb[i]->getStateSet(), out);
                        if (!out.empty())
                        {
                            Log(Debug::Error) << "Chunk cache verify[" << stage << "] " << file.filename() << " node "
                                              << i << " (" << na[i]->className() << "):" << out;
                            ++issues;
                        }
                    }
                    return issues;
                };

                osg::ref_ptr<osg::Node> raw = readCachedChunk(file, false, /*raw=*/true);
                osg::ref_ptr<osg::Node> processed = readCachedChunk(file, false);
                if (!raw || !processed)
                    Log(Debug::Error) << "Chunk cache verify: reread FAILED: " << file;
                else
                {
                    const size_t fileIssues = compareGraphs(node, raw.get(), "FILE");
                    const size_t pathIssues = compareGraphs(node, processed.get(), "READPATH");
                    if (fileIssues == 0 && pathIssues == 0)
                        Log(Debug::Info) << "Chunk cache verify OK: " << file.filename();
                }
            }
        }
        else
        {
            ++mWriteFailures;
            Log(Debug::Error) << "Failed to store paged chunk " << file << " (write error - disk full?)";
            std::filesystem::remove(tmp, ec);
        }
    }

    namespace
    {
        class CanOptimizeCallback : public SceneUtil::Optimizer::IsOperationPermissibleForObjectCallback
        {
        public:
            bool isOperationPermissibleForObjectImplementation(
                const SceneUtil::Optimizer* optimizer, const osg::Drawable* node, unsigned int option) const override
            {
                return true;
            }
            bool isOperationPermissibleForObjectImplementation(
                const SceneUtil::Optimizer* optimizer, const osg::Node* node, unsigned int option) const override
            {
                return (node->getDataVariance() != osg::Object::DYNAMIC);
            }
        };

        using LODRange = osg::LOD::MinMaxPair;

        LODRange intersection(const LODRange& left, const LODRange& right)
        {
            return { std::max(left.first, right.first), std::min(left.second, right.second) };
        }

        bool empty(const LODRange& r)
        {
            return r.first >= r.second;
        }

        LODRange operator/(const LODRange& r, float div)
        {
            return { r.first / div, r.second / div };
        }

        class CopyOp : public osg::CopyOp
        {
        public:
            bool mOptimizeBillboards = true;
            bool mActiveGrid = false;
            LODRange mDistances = { 0.f, 0.f };
            osg::Vec3f mViewVector;
            osg::Node::NodeMask mCopyMask = ~0u;
            mutable std::vector<const osg::Node*> mNodePath;

            CopyOp(bool activeGrid, osg::Node::NodeMask copyMask)
                : mActiveGrid(activeGrid)
                , mCopyMask(copyMask)
            {
            }

            void copy(const osg::Node* toCopy, osg::Group* attachTo)
            {
                const osg::Group* groupToCopy = toCopy->asGroup();
                if (toCopy->getStateSet() || toCopy->asTransform() || !groupToCopy)
                    attachTo->addChild(operator()(toCopy));
                else
                {
                    for (unsigned int i = 0; i < groupToCopy->getNumChildren(); ++i)
                        attachTo->addChild(operator()(groupToCopy->getChild(i)));
                }
            }

            osg::Node* operator()(const osg::Node* node) const override
            {
                if (!(node->getNodeMask() & mCopyMask))
                    return nullptr;

                if (const osg::Drawable* d = node->asDrawable())
                    return operator()(d);

                if (dynamic_cast<const osgParticle::ParticleProcessor*>(node))
                    return nullptr;
                if (dynamic_cast<const osgParticle::ParticleSystemUpdater*>(node))
                    return nullptr;

                if (const osg::Switch* sw = node->asSwitch())
                {
                    osg::Group* n = new osg::Group;
                    for (unsigned int i = 0; i < sw->getNumChildren(); ++i)
                        if (sw->getValue(i))
                            n->addChild(operator()(sw->getChild(i)));
                    n->setDataVariance(osg::Object::STATIC);
                    return n;
                }
                if (const osg::LOD* lod = dynamic_cast<const osg::LOD*>(node))
                {
                    std::vector<std::pair<osg::ref_ptr<osg::Node>, LODRange>> children;
                    for (unsigned int i = 0; i < lod->getNumChildren(); ++i)
                        if (const auto r = intersection(lod->getRangeList()[i], mDistances); !empty(r))
                            children.emplace_back(operator()(lod->getChild(i)), lod->getRangeList()[i]);
                    if (children.empty())
                        return nullptr;

                    if (children.size() == 1)
                        return children.front().first.release();
                    else
                    {
                        osg::LOD* n = new osg::LOD;
                        for (const auto& [child, range] : children)
                            n->addChild(child, range.first, range.second);
                        n->setRangeMode(lod->getRangeMode());
                        n->setCenterMode(lod->getCenterMode());
                        n->setCenter(lod->getCenter());
                        n->setRadius(lod->getRadius());
                        n->setDataVariance(osg::Object::STATIC);
                        return n;
                    }
                }
                if (const osg::Sequence* sq = dynamic_cast<const osg::Sequence*>(node))
                {
                    osg::Group* n = new osg::Group;
                    n->addChild(operator()(sq->getChild(sq->getValue() != -1 ? sq->getValue() : 0)));
                    n->setDataVariance(osg::Object::STATIC);
                    return n;
                }

                mNodePath.push_back(node);

                osg::Node* cloned = static_cast<osg::Node*>(node->clone(*this));
                if (!mActiveGrid)
                    cloned->setDataVariance(osg::Object::STATIC);
                cloned->setUserDataContainer(nullptr);
                cloned->setName("");

                mNodePath.pop_back();

                handleCallbacks(node, cloned);

                return cloned;
            }
            void handleCallbacks(const osg::Node* node, osg::Node* cloned) const
            {
                for (const osg::Callback* callback = node->getCullCallback(); callback != nullptr;
                    callback = callback->getNestedCallback())
                {
                    if (callback->className() == std::string_view("BillboardCallback"))
                    {
                        if (mOptimizeBillboards)
                        {
                            handleBillboard(cloned);
                            continue;
                        }
                        else
                            cloned->setDataVariance(osg::Object::DYNAMIC);
                    }

                    if (node->getCullCallback()->getNestedCallback())
                    {
                        osg::Callback* clonedCallback = osg::clone(callback, osg::CopyOp::SHALLOW_COPY);
                        clonedCallback->setNestedCallback(nullptr);
                        cloned->addCullCallback(clonedCallback);
                    }
                    else
                        cloned->addCullCallback(const_cast<osg::Callback*>(callback));
                }
            }
            void handleBillboard(osg::Node* node) const
            {
                osg::Transform* transform = node->asTransform();
                if (!transform)
                    return;
                osg::MatrixTransform* matrixTransform = transform->asMatrixTransform();
                if (!matrixTransform)
                    return;

                osg::Matrix worldToLocal = osg::Matrix::identity();
                for (auto pathNode : mNodePath)
                    if (const osg::Transform* t = pathNode->asTransform())
                        t->computeWorldToLocalMatrix(worldToLocal, nullptr);
                worldToLocal = osg::Matrix::orthoNormal(worldToLocal);

                osg::Matrix billboardMatrix;
                osg::Vec3f viewVector = -(mViewVector + worldToLocal.getTrans());
                viewVector.normalize();
                osg::Vec3f right = viewVector ^ osg::Vec3f(0, 0, 1);
                right.normalize();
                osg::Vec3f up = right ^ viewVector;
                up.normalize();
                billboardMatrix.makeLookAt(osg::Vec3f(0, 0, 0), viewVector, up);
                billboardMatrix.invert(billboardMatrix);

                const osg::Matrix& oldMatrix = matrixTransform->getMatrix();
                float mag[3]; // attempt to preserve scale
                for (int i = 0; i < 3; ++i)
                    mag[i] = static_cast<float>(std::sqrt(oldMatrix(0, i) * oldMatrix(0, i)
                        + oldMatrix(1, i) * oldMatrix(1, i) + oldMatrix(2, i) * oldMatrix(2, i)));
                osg::Matrix newMatrix;
                worldToLocal.setTrans(0, 0, 0);
                newMatrix *= worldToLocal;
                newMatrix.preMult(billboardMatrix);
                newMatrix.preMultScale(osg::Vec3f(mag[0], mag[1], mag[2]));
                newMatrix.setTrans(oldMatrix.getTrans());

                matrixTransform->setMatrix(newMatrix);
            }
            osg::Drawable* operator()(const osg::Drawable* drawable) const override
            {
                if (!(drawable->getNodeMask() & mCopyMask))
                    return nullptr;

                if (dynamic_cast<const osgParticle::ParticleSystem*>(drawable))
                    return nullptr;

                if (dynamic_cast<const SceneUtil::OsgaRigGeometry*>(drawable))
                    return nullptr;
                if (const SceneUtil::RigGeometry* rig = dynamic_cast<const SceneUtil::RigGeometry*>(drawable))
                    return operator()(rig->getSourceGeometry());
                if (const SceneUtil::MorphGeometry* morph = dynamic_cast<const SceneUtil::MorphGeometry*>(drawable))
                    return operator()(morph->getSourceGeometry());

                if (getCopyFlags() & DEEP_COPY_DRAWABLES)
                {
                    osg::Drawable* d = static_cast<osg::Drawable*>(drawable->clone(*this));
                    d->setDataVariance(osg::Object::STATIC);
                    d->setUserDataContainer(nullptr);
                    d->setName("");
                    return d;
                }
                else
                    return const_cast<osg::Drawable*>(drawable);
            }
            osg::Callback* operator()(const osg::Callback* callback) const override { return nullptr; }
        };

        class RefnumSet : public osg::Object
        {
        public:
            RefnumSet() {}
            RefnumSet(const RefnumSet& copy, const osg::CopyOp&)
                : mRefnums(copy.mRefnums)
            {
            }
            META_Object(MWRender, RefnumSet)
            std::vector<ESM::RefNum> mRefnums;
        };

        class AnalyzeVisitor : public osg::NodeVisitor
        {
        public:
            AnalyzeVisitor(osg::Node::NodeMask analyzeMask)
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                , mCurrentStateSet(nullptr)
            {
                setTraversalMask(analyzeMask);
            }

            typedef std::unordered_map<osg::StateSet*, unsigned int> StateSetCounter;
            struct Result
            {
                StateSetCounter mStateSetCounter;
                unsigned int mNumVerts = 0;
            };

            void apply(osg::Node& node) override
            {
                if (node.getStateSet())
                    mCurrentStateSet = node.getStateSet();

                if (osg::Switch* sw = node.asSwitch())
                {
                    for (unsigned int i = 0; i < sw->getNumChildren(); ++i)
                        if (sw->getValue(i))
                            traverse(*sw->getChild(i));
                    return;
                }
                if (osg::LOD* lod = dynamic_cast<osg::LOD*>(&node))
                {
                    for (unsigned int i = 0; i < lod->getNumChildren(); ++i)
                        if (const auto r = intersection(lod->getRangeList()[i], mDistances); !empty(r))
                            traverse(*lod->getChild(i));
                    return;
                }
                if (osg::Sequence* sq = dynamic_cast<osg::Sequence*>(&node))
                {
                    traverse(*sq->getChild(sq->getValue() != -1 ? sq->getValue() : 0));
                    return;
                }

                traverse(node);
            }
            void apply(osg::Geometry& geom) override
            {
                if (osg::Array* array = geom.getVertexArray())
                    mResult.mNumVerts += array->getNumElements();

                ++mResult.mStateSetCounter[mCurrentStateSet];
                ++mGlobalStateSetCounter[mCurrentStateSet];
            }
            Result retrieveResult()
            {
                Result result = mResult;
                mResult = Result();
                mCurrentStateSet = nullptr;
                return result;
            }
            void addInstance(const Result& result)
            {
                for (auto pair : result.mStateSetCounter)
                    mGlobalStateSetCounter[pair.first] += pair.second;
            }
            float getMergeBenefit(const Result& result)
            {
                if (result.mStateSetCounter.empty())
                    return 1;
                float mergeBenefit = 0;
                for (auto pair : result.mStateSetCounter)
                {
                    mergeBenefit += mGlobalStateSetCounter[pair.first];
                }
                mergeBenefit /= result.mStateSetCounter.size();
                return mergeBenefit;
            }

            Result mResult;
            osg::StateSet* mCurrentStateSet;
            StateSetCounter mGlobalStateSetCounter;
            LODRange mDistances = { 0.f, 0.f };
        };

        class DebugVisitor : public osg::NodeVisitor
        {
        public:
            DebugVisitor()
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
            {
            }
            void apply(osg::Drawable& node) override
            {
                osg::ref_ptr<osg::Material> m(new osg::Material);
                osg::Vec4f color(
                    Misc::Rng::rollProbability(), Misc::Rng::rollProbability(), Misc::Rng::rollProbability(), 0.f);
                color.normalize();
                m->setDiffuse(osg::Material::FRONT_AND_BACK, osg::Vec4f(0.1f, 0.1f, 0.1f, 1.f));
                m->setAmbient(osg::Material::FRONT_AND_BACK, osg::Vec4f(0.1f, 0.1f, 0.1f, 1.f));
                m->setColorMode(osg::Material::OFF);
                m->setEmission(osg::Material::FRONT_AND_BACK, osg::Vec4f(color));
                osg::ref_ptr<osg::StateSet> stateset = node.getStateSet()
                    ? osg::clone(node.getStateSet(), osg::CopyOp::SHALLOW_COPY)
                    : new osg::StateSet;
                stateset->setAttribute(m);
                stateset->addUniform(new osg::Uniform("colorMode", 0));
                stateset->addUniform(new osg::Uniform("emissiveMult", 1.f));
                stateset->addUniform(new osg::Uniform("specStrength", 1.f));
                node.setStateSet(stateset);
            }
        };

        class AddRefnumMarkerVisitor : public osg::NodeVisitor
        {
        public:
            AddRefnumMarkerVisitor(ESM::RefNum refnum)
                : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                , mRefnum(refnum)
            {
            }
            ESM::RefNum mRefnum;
            void apply(osg::Geometry& node) override
            {
                osg::ref_ptr<RefnumMarker> marker(new RefnumMarker);
                marker->mRefnum = mRefnum;
                if (osg::Array* array = node.getVertexArray())
                    marker->mNumVertices = array->getNumElements();
                node.getOrCreateUserDataContainer()->addUserObject(marker);
            }
        };
    }

    ObjectPaging::ObjectPaging(Resource::SceneManager* sceneManager, ESM::RefId worldspace)
        : GenericResourceManager<ChunkId>(nullptr, Settings::cells().mCacheExpiryDelay)
        , Terrain::QuadTreeWorld::ChunkManager(worldspace)
        , mSceneManager(sceneManager)
        , mActiveGrid(Settings::terrain().mObjectPagingActiveGrid)
        , mDebugBatches(Settings::terrain().mDebugChunks)
        , mMergeFactor(Settings::terrain().mObjectPagingMergeFactor)
        , mMinSize(Settings::terrain().mObjectPagingMinSize)
        , mMinSizeMergeFactor(Settings::terrain().mObjectPagingMinSizeMergeFactor)
        , mMinSizeCostMultiplier(Settings::terrain().mObjectPagingMinSizeCostMultiplier)
        , mRefTrackerLocked(false)
    {
    }

    void ObjectPaging::setOcclusionCuller(SceneUtil::OcclusionCuller* culler, unsigned int maxTriangles)
    {
        mOcclusionCuller = culler;
        mMaxTriangles = maxTriangles;
    }

    namespace
    {
        struct PagedCellRef
        {
            ESM::RefId mRefId;
            ESM::RefNum mRefNum;
            osg::Vec3f mPosition;
            osg::Vec3f mRotation;
            float mScale = 0.f;
        };

        PagedCellRef makePagedCellRef(const ESM::CellRef& value)
        {
            return PagedCellRef{
                .mRefId = value.mRefID,
                .mRefNum = value.mRefNum,
                .mPosition = value.mPos.asVec3(),
                .mRotation = value.mPos.asRotationVec3(),
                .mScale = value.mScale,
            };
        }

        PagedCellRef makePagedCellRef(const ESM4::Reference& value)
        {
            return PagedCellRef{
                .mRefId = value.mBaseObj,
                .mRefNum = value.mId,
                .mPosition = value.mPos.asVec3(),
                .mRotation = value.mPos.asRotationVec3(),
                .mScale = value.mScale,
            };
        }

        std::map<ESM::RefNum, PagedCellRef> collectESM3References(
            float size, const osg::Vec2i& startCell, const MWWorld::ESMStore& store)
        {
            std::map<ESM::RefNum, PagedCellRef> refs;
            ESM::ReadersCache readers;
            for (int cellX = startCell.x(); cellX < startCell.x() + size; ++cellX)
            {
                for (int cellY = startCell.y(); cellY < startCell.y() + size; ++cellY)
                {
                    const ESM::Cell* cell = store.get<ESM::Cell>().searchStatic(cellX, cellY);
                    if (!cell)
                        continue;
                    for (size_t i = 0; i < cell->mContextList.size(); ++i)
                    {
                        try
                        {
                            const std::size_t index = static_cast<std::size_t>(cell->mContextList[i].index);
                            const ESM::ReadersCache::BusyItem reader = readers.get(index);
                            cell->restore(*reader, i);
                            ESM::CellRef ref;
                            ESM::MovedCellRef cMRef;
                            bool deleted = false;
                            bool moved = false;
                            while (ESM::Cell::getNextRef(
                                *reader, ref, deleted, cMRef, moved, ESM::Cell::GetNextRefMode::LoadOnlyNotMoved))
                            {
                                if (moved)
                                    continue;

                                if (std::find(cell->mMovedRefs.begin(), cell->mMovedRefs.end(), ref.mRefNum)
                                    != cell->mMovedRefs.end())
                                    continue;

                                int type = store.findStatic(ref.mRefID);
                                if (!typeFilter(type, size >= 2))
                                    continue;
                                if (deleted)
                                {
                                    refs.erase(ref.mRefNum);
                                    continue;
                                }
                                refs.insert_or_assign(ref.mRefNum, makePagedCellRef(ref));
                            }
                        }
                        catch (const std::exception& e)
                        {
                            Log(Debug::Warning) << "Failed to collect references from cell \"" << cell->getDescription()
                                                << "\": " << e.what();
                            continue;
                        }
                    }
                    for (const auto& [ref, deleted] : cell->mLeasedRefs)
                    {
                        if (deleted)
                        {
                            refs.erase(ref.mRefNum);
                            continue;
                        }
                        int type = store.findStatic(ref.mRefID);
                        if (!typeFilter(type, size >= 2))
                            continue;
                        refs.insert_or_assign(ref.mRefNum, makePagedCellRef(ref));
                    }
                }
            }
            return refs;
        }

        std::map<ESM::RefNum, PagedCellRef> collectESM4References(
            float size, const osg::Vec2i& startCell, ESM::RefId worldspace)
        {
            std::map<ESM::RefNum, PagedCellRef> refs;
            const auto& store = *MWBase::Environment::get().getESMStore();
            for (int cellX = startCell.x(); cellX < startCell.x() + size; ++cellX)
            {
                for (int cellY = startCell.y(); cellY < startCell.y() + size; ++cellY)
                {
                    const ESM4::Cell* cell
                        = store.get<ESM4::Cell>().searchExterior(ESM::ExteriorCellLocation(cellX, cellY, worldspace));
                    if (!cell)
                        continue;
                    for (const ESM4::Reference* ref4 : store.get<ESM4::Reference>().getByCell(cell->mId))
                    {
                        if (ref4->mFlags & ESM4::Rec_Disabled)
                            continue;
                        int type = store.findStatic(ref4->mBaseObj);
                        if (!typeFilter(type, size >= 2))
                            continue;
                        if (!ref4->mEsp.parent.isZeroOrUnset())
                        {
                            const ESM4::Reference* parentRef
                                = store.get<ESM4::Reference>().searchStatic(ref4->mEsp.parent);
                            if (parentRef)
                            {
                                bool parentDisabled = parentRef->mFlags & ESM4::Rec_Disabled;
                                bool inversed = ref4->mEsp.flags & ESM4::EnableParent::Flag_Inversed;
                                if (parentDisabled != inversed)
                                    continue;
                            }
                        }
                        refs.insert_or_assign(ref4->mId, makePagedCellRef(*ref4));
                    }
                }
            }
            return refs;
        }
    }

    osg::ref_ptr<osg::Node> ObjectPaging::createChunk(float size, const osg::Vec2f& center, bool activeGrid,
        const osg::Vec3f& viewPointIn, bool compile, unsigned char lod)
    {
        // Deterministic content: the builder's viewpoint must not decide
        // what a chunk contains, or a chunk built from far away permanently
        // excludes mid-size objects once cached. Substitute the nearest
        // position any legitimate viewer of this node can occupy: the LOD
        // band minimum (DefaultLodCallback selects a size-S node from
        // dist >= S * cellSize * lodFactor). Every build of a chunk is then
        // identical regardless of who requested it, and includes everything
        // any viewer of this band could see.
        osg::Vec3f viewPoint = viewPointIn;
        float deterministicDistSqr = 0.f;
        if (!activeGrid)
        {
            const float cellSizeUnits = static_cast<float>(getCellSize(mWorldspace));
            const float bandMinDist = std::max(1.f, size * cellSizeUnits * Settings::terrain().mLodFactor);
            deterministicDistSqr = bandMinDist * bandMinDist;
            const osg::Vec3f worldCenterPos(center.x() * cellSizeUnits, center.y() * cellSizeUnits, 0.f);
            // vector-valued uses (billboard orientation etc.) get a fixed-axis
            // deterministic viewer; the scalar size filters below use the
            // uniform band-min distance for every ref.
            viewPoint = worldCenterPos + osg::Vec3f(bandMinDist, 0.f, 0.f);
        }

        const osg::Vec2i startCell(static_cast<int>(std::floor(center.x() - size / 2.f)),
            static_cast<int>(std::floor(center.y() - size / 2.f)));
        const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();

        std::map<ESM::RefNum, PagedCellRef> refs;

        if (mWorldspace == ESM::Cell::sDefaultWorldspaceId)
        {
            refs = collectESM3References(size, startCell, store);
        }
        else
        {
            refs = collectESM4References(size, startCell, mWorldspace);
        }

        if (activeGrid && !refs.empty())
        {
            std::lock_guard<std::mutex> lock(mRefTrackerMutex);
            const std::set<ESM::RefNum>& blacklist = getRefTracker().mBlacklist;
            if (blacklist.size() < refs.size())
            {
                for (ESM::RefNum ref : blacklist)
                    refs.erase(ref);
            }
            else
            {
                std::erase_if(refs, [&](const auto& ref) { return blacklist.contains(ref.first); });
            }
        }

        const osg::Vec2f minBound = (center - osg::Vec2f(size / 2.f, size / 2.f));
        const osg::Vec2f maxBound = (center + osg::Vec2f(size / 2.f, size / 2.f));
        const osg::Vec2i floorMinBound(
            static_cast<int>(std::floor(minBound.x())), static_cast<int>(std::floor(minBound.y())));
        const osg::Vec2i ceilMaxBound(
            static_cast<int>(std::ceil(maxBound.x())), static_cast<int>(std::ceil(maxBound.y())));
        struct InstanceList
        {
            std::vector<const PagedCellRef*> mInstances;
            AnalyzeVisitor::Result mAnalyzeResult;
            bool mNeedCompile = false;
        };
        typedef std::map<osg::ref_ptr<const osg::Node>, InstanceList> NodeMap;
        NodeMap nodes;
        const osg::ref_ptr<RefnumSet> refnumSet = activeGrid ? new RefnumSet : nullptr;

        // Mask_UpdateVisitor is used in such cases in NIF loader:
        // 1. For collision nodes, which is not supposed to be rendered.
        // 2. For nodes masked via Flag_Hidden (VisController can change this flag value at runtime).
        // Since ObjectPaging does not handle VisController, we can just ignore both types of nodes.
        constexpr auto copyMask = ~Mask_UpdateVisitor;

        const int cellSize = getCellSize(mWorldspace);
        const float smallestDistanceToChunk = (size > 1 / 8.f) ? (size * cellSize) : 0.f;
        const float higherDistanceToChunk
            = activeGrid ? ((size < 1) ? 5 : 3) * cellSize * size + 1 : smallestDistanceToChunk + 1;

        AnalyzeVisitor analyzeVisitor(copyMask);
        const float minSize = mMinSizeMergeFactor ? mMinSize * mMinSizeMergeFactor : mMinSize;
        // Landmark rule: objects whose scaled radius exceeds landmarkSize keep
        // their distant-chunk inclusion 'landmark range factor' times farther
        // than the normal min-size cutoff, so large low-poly landmarks survive
        // far beyond the active-grid seam without accumulating forever.
        // landmarkSize 0 = disabled (stock behaviour).
        const float landmarkSize = Settings::terrain().mObjectPagingLandmarkSize;
        const float landmarkSize2 = landmarkSize * landmarkSize;
        const float landmarkRangeFactor = Settings::terrain().mObjectPagingLandmarkRangeFactor;
        const float landmarkInvFactor2 = 1.f / (landmarkRangeFactor * landmarkRangeFactor);
        const float simplifyStrength = Settings::terrain().mObjectPagingSimplifyStrength;
        for (const auto& [refNum, ref] : refs)
        {
            if (size < 1.f)
            {
                const osg::Vec3f cellPos = ref.mPosition / static_cast<float>(cellSize);
                if ((minBound.x() > floorMinBound.x() && cellPos.x() < minBound.x())
                    || (minBound.y() > floorMinBound.y() && cellPos.y() < minBound.y())
                    || (maxBound.x() < ceilMaxBound.x() && cellPos.x() >= maxBound.x())
                    || (maxBound.y() < ceilMaxBound.y() && cellPos.y() >= maxBound.y()))
                    continue;
            }

            const float dSqr = activeGrid ? (viewPoint - ref.mPosition).length2() : deterministicDistSqr;
            if (!activeGrid)
            {
                std::lock_guard<std::mutex> lock(mSizeCacheMutex);
                SizeCache::iterator found = mSizeCache.find(refNum);
                if (found != mSizeCache.end() && found->second < dSqr * minSize * minSize
                    && (landmarkSize <= 0.f || found->second < landmarkSize2
                        || found->second < dSqr * minSize * minSize * landmarkInvFactor2))
                    continue;
            }

            if (Misc::ResourceHelpers::isHiddenMarker(ref.mRefId))
                continue;

            const int type = store.findStatic(ref.mRefId);
            VFS::Path::Normalized model(getModel(type, ref.mRefId, store));
            if (model.empty())
                continue;
            model = Misc::ResourceHelpers::correctMeshPath(model);

            if (activeGrid && type != ESM::REC_STAT && type != ESM::REC_STAT4)
            {
                model = Misc::ResourceHelpers::correctActorModelPath(model, mSceneManager->getVFS());
                constexpr VFS::Path::ExtensionView nif("nif");
                if (model.extension() == nif)
                {
                    VFS::Path::Normalized kfname = model;
                    constexpr VFS::Path::ExtensionView kf("kf");
                    kfname.changeExtension(kf);
                    if (mSceneManager->getVFS()->exists(kfname))
                        continue;
                }
            }

            if (!activeGrid)
            {
                std::lock_guard<std::mutex> lock(mLODNameCacheMutex);
                LODNameCacheKey key{ model, lod };
                LODNameCache::const_iterator found = mLODNameCache.lower_bound(key);
                if (found != mLODNameCache.end() && found->first == key)
                    model = found->second;
                else
                    model = mLODNameCache
                                .emplace_hint(found, std::move(key),
                                    Misc::ResourceHelpers::getLODMeshName(
                                        esmVersions()[refNum.mContentFile], model, *mSceneManager->getVFS(), lod))
                                ->second;
            }

            osg::ref_ptr<const osg::Node> cnode = mSceneManager->getTemplate(model, false);

            if (activeGrid)
            {
                if (cnode->getNumChildrenRequiringUpdateTraversal() > 0
                    || SceneUtil::hasUserDescription(cnode, Constants::NightDayLabel)
                    || SceneUtil::hasUserDescription(cnode, Constants::HerbalismLabel)
                    || (cnode->getName() == "Collada visual scene group"
                        && dynamic_cast<const osgAnimation::BasicAnimationManager*>(cnode->getUpdateCallback())))
                    continue;
                else
                    refnumSet->mRefnums.push_back(refNum);
            }

            {
                std::lock_guard<std::mutex> lock(mRefTrackerMutex);
                if (getRefTracker().mDisabled.contains(refNum))
                    continue;
            }

            const float radius2 = cnode->getBound().radius2() * ref.mScale * ref.mScale;
            if (radius2 < dSqr * minSize * minSize && !activeGrid
                && (landmarkSize <= 0.f || radius2 < landmarkSize2
                    || radius2 < dSqr * minSize * minSize * landmarkInvFactor2))
            {
                std::lock_guard<std::mutex> lock(mSizeCacheMutex);
                mSizeCache[refNum] = radius2;
                continue;
            }

            const auto emplaced = nodes.emplace(std::move(cnode), InstanceList());
            if (emplaced.second)
            {
                analyzeVisitor.mDistances = LODRange{ smallestDistanceToChunk, higherDistanceToChunk } / ref.mScale;
                const osg::Node* const nodePtr = emplaced.first->first.get();
                // const-trickery required because there is no const version of NodeVisitor
                const_cast<osg::Node*>(nodePtr)->accept(analyzeVisitor);
                emplaced.first->second.mAnalyzeResult = analyzeVisitor.retrieveResult();
                emplaced.first->second.mNeedCompile = compile && nodePtr->referenceCount() <= 2;
            }
            else
                analyzeVisitor.addInstance(emplaced.first->second.mAnalyzeResult);
            emplaced.first->second.mInstances.push_back(&ref);
        }

        const osg::Vec3f worldCenter
            = osg::Vec3f(center.x(), center.y(), 0) * static_cast<float>(getCellSize(mWorldspace));
        osg::ref_ptr<osg::Group> group = new osg::Group;
        osg::ref_ptr<osg::Group> mergeGroup = new osg::Group;
        osg::ref_ptr<Resource::TemplateMultiRef> templateRefs = new Resource::TemplateMultiRef;
        osgUtil::StateToCompile stateToCompile(0, nullptr);
        CopyOp copyop(activeGrid, copyMask);

        const bool buildOccluders = Settings::camera().mOcclusionCulling && Settings::camera().mOcclusionCullingStatics;
        osg::ref_ptr<PagedOccluderData> pagedOccluderData;
        float occluderMinRadius = 0;
        int occluderMeshRes = 6;
        int occluderMaxMeshRes = 24;
        float occluderShrinkFactor = 0.9f;
        if (buildOccluders)
        {
            pagedOccluderData = new PagedOccluderData;
            occluderMinRadius = Settings::camera().mOcclusionOccluderMinRadius;
            occluderMeshRes = Settings::camera().mOcclusionOccluderMeshResolution;
            occluderMaxMeshRes = Settings::camera().mOcclusionOccluderMaxMeshResolution;
            occluderShrinkFactor = Settings::camera().mOcclusionOccluderShrinkFactor;
        }

        for (const auto& pair : nodes)
        {
            const osg::Node* cnode = pair.first;

            const AnalyzeVisitor::Result& analyzeResult = pair.second.mAnalyzeResult;

            const float mergeCost = analyzeResult.mNumVerts * size;
            const float mergeBenefit = analyzeVisitor.getMergeBenefit(analyzeResult) * mMergeFactor;
            const bool merge = mergeBenefit > mergeCost;

            // MGE-style distant mesh simplification: merged instances in
            // far chunks come from a decimated template variant (ratio =
            // size^-strength), built once per (template, ratio) and reused by
            // every chunk. This changes bake content, so the strength is
            // recorded in the manifest.
            const osg::Node* mergeSource = cnode;
            if (merge && !activeGrid && simplifyStrength > 0.f && size > 1.f)
            {
                const float ratio = std::pow(size, -simplifyStrength);
                if (ratio < 1.f)
                    mergeSource = getSimplifiedTemplate(cnode, ratio, *templateRefs);
            }

            const float factor2
                = mergeBenefit > 0 ? std::min(1.f, mergeCost * mMinSizeCostMultiplier / mergeBenefit) : 1;
            const float minSizeMergeFactor2 = (1 - factor2) * mMinSizeMergeFactor + factor2;
            const float minSizeMerged = minSizeMergeFactor2 > 0 ? mMinSize * minSizeMergeFactor2 : mMinSize;

            unsigned int numinstances = 0;
            for (const PagedCellRef* refPtr : pair.second.mInstances)
            {
                const PagedCellRef& ref = *refPtr;

                if (!activeGrid && minSizeMerged != minSize
                    && cnode->getBound().radius2() * ref.mScale * ref.mScale
                        < deterministicDistSqr * minSizeMerged * minSizeMerged
                    && (landmarkSize <= 0.f || cnode->getBound().radius2() * ref.mScale * ref.mScale < landmarkSize2
                        || cnode->getBound().radius2() * ref.mScale * ref.mScale
                            < deterministicDistSqr * minSizeMerged * minSizeMerged * landmarkInvFactor2))
                    continue;

                const osg::Vec3f nodePos = ref.mPosition - worldCenter;
                const osg::Quat nodeAttitude = osg::Quat(ref.mRotation.z(), osg::Vec3f(0, 0, -1))
                    * osg::Quat(ref.mRotation.y(), osg::Vec3f(0, -1, 0))
                    * osg::Quat(ref.mRotation.x(), osg::Vec3f(-1, 0, 0));
                const osg::Vec3f nodeScale(ref.mScale, ref.mScale, ref.mScale);

                osg::ref_ptr<osg::Group> trans;
                if (merge)
                {
                    // Optimizer currently supports only MatrixTransforms.
                    osg::Matrixf matrix;
                    matrix.preMultTranslate(nodePos);
                    matrix.preMultRotate(nodeAttitude);
                    matrix.preMultScale(nodeScale);
                    trans = new osg::MatrixTransform(matrix);
                    trans->setDataVariance(osg::Object::STATIC);
                }
                else
                {
                    trans = new SceneUtil::PositionAttitudeTransform;
                    SceneUtil::PositionAttitudeTransform* pat
                        = static_cast<SceneUtil::PositionAttitudeTransform*>(trans.get());
                    pat->setPosition(nodePos);
                    pat->setScale(nodeScale);
                    pat->setAttitude(nodeAttitude);
                }

                // DO NOT COPY AND PASTE THIS CODE. Cloning osg::Geometry without also cloning its contained Arrays is
                // generally unsafe. In this specific case the operation is safe under the following two assumptions:
                // - When Arrays are removed or replaced in the cloned geometry, the original Arrays in their place must
                // outlive the cloned geometry regardless. (ensured by TemplateMultiRef)
                // - Arrays that we add or replace in the cloned geometry must be explicitely forbidden from reusing
                // BufferObjects of the original geometry. (ensured by needvbo() in optimizer.cpp)
                copyop.setCopyFlags(merge ? osg::CopyOp::DEEP_COPY_NODES | osg::CopyOp::DEEP_COPY_DRAWABLES
                                          : osg::CopyOp::DEEP_COPY_NODES);
                copyop.mOptimizeBillboards = (size > 1 / 4.f);
                copyop.mNodePath.push_back(trans);
                copyop.mDistances = LODRange{ smallestDistanceToChunk, higherDistanceToChunk } / ref.mScale;
                copyop.mViewVector = (viewPoint - worldCenter);
                copyop.copy(merge ? mergeSource : cnode, trans);
                copyop.mNodePath.pop_back();

                // Build occluder mesh for building-sized objects
                if (buildOccluders)
                {
                    float scaledRadius = cnode->getBound().radius() * ref.mScale;
                    if (scaledRadius >= occluderMinRadius)
                    {
                        // Scale grid resolution with object size so grid cell size stays ~constant.
                        // A small building (radius 300) uses base resolution, a canton (radius 3000+)
                        // gets proportionally higher resolution to preserve shape detail.
                        int adaptiveRes = occluderMeshRes;
                        if (scaledRadius > occluderMinRadius)
                        {
                            float scale = scaledRadius / occluderMinRadius;
                            adaptiveRes = std::clamp(
                                static_cast<int>(occluderMeshRes * scale), occluderMeshRes, occluderMaxMeshRes);
                        }
                        auto occMesh = buildSimplifiedMesh(trans, adaptiveRes, occluderShrinkFactor);
                        if (!occMesh.indices.empty())
                        {
                            // Offset from chunk-relative to world-space
                            for (auto& v : occMesh.vertices)
                                v += worldCenter;
                            occMesh.aabb = osg::BoundingBox();
                            for (const auto& v : occMesh.vertices)
                                occMesh.aabb.expandBy(v);
                            pagedOccluderData->mOccluderMeshes.push_back(std::move(occMesh));
                        }
                    }
                }

                if (activeGrid)
                {
                    if (merge)
                    {
                        AddRefnumMarkerVisitor visitor(ref.mRefNum);
                        trans->accept(visitor);
                    }
                    else
                    {
                        osg::ref_ptr<RefnumMarker> marker = new RefnumMarker;
                        marker->mRefnum = ref.mRefNum;
                        trans->getOrCreateUserDataContainer()->addUserObject(marker);
                    }
                }

                osg::Group* const attachTo = merge ? mergeGroup : group;
                attachTo->addChild(trans);
                ++numinstances;
            }
            if (numinstances > 0)
            {
                // add a ref to the original template to help verify the safety of shallow cloning operations
                // in addition, we hint to the cache that it's still being used and should be kept in cache
                templateRefs->addRef(cnode);

                if (pair.second.mNeedCompile)
                {
                    int mode = osgUtil::GLObjectsVisitor::COMPILE_STATE_ATTRIBUTES;
                    if (!merge)
                        mode |= osgUtil::GLObjectsVisitor::COMPILE_DISPLAY_LISTS;
                    stateToCompile._mode = mode;
                    const_cast<osg::Node*>(cnode)->accept(stateToCompile);
                }
            }
        }

        const osg::Vec3f relativeViewPoint = viewPoint - worldCenter;

        if (mergeGroup->getNumChildren())
        {
            SceneUtil::Optimizer optimizer;
            if (size > 1 / 8.f)
            {
                optimizer.setViewPoint(relativeViewPoint);
                optimizer.setMergeAlphaBlending(true);
            }
            optimizer.setIsOperationPermissibleForObjectCallback(new CanOptimizeCallback);
            const unsigned int options = SceneUtil::Optimizer::FLATTEN_STATIC_TRANSFORMS
                | SceneUtil::Optimizer::REMOVE_REDUNDANT_NODES | SceneUtil::Optimizer::MERGE_GEOMETRY;

            optimizer.optimize(mergeGroup, options);

            {
                struct CountVertsVisitor : public osg::NodeVisitor
                {
                    size_t mVerts = 0;
                    CountVertsVisitor()
                        : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                    {
                    }
                    void apply(osg::Drawable& d) override
                    {
                        if (const osg::Geometry* g = d.asGeometry())
                            if (g->getVertexArray())
                                mVerts += g->getVertexArray()->getNumElements();
                    }
                };
                CountVertsVisitor mergedCount, plainCount;
                mergeGroup->accept(mergedCount);
                group->accept(plainCount);
                Log(Debug::Verbose) << "Chunk " << center.x() << "," << center.y() << " size " << size
                                    << ": merged-verts " << mergedCount.mVerts << " unmerged-verts "
                                    << plainCount.mVerts;
            }
            group->addChild(mergeGroup);

            if (mDebugBatches)
            {
                DebugVisitor dv;
                mergeGroup->accept(dv);
            }
            if (compile)
            {
                stateToCompile._mode = osgUtil::GLObjectsVisitor::COMPILE_DISPLAY_LISTS;
                mergeGroup->accept(stateToCompile);
            }
        }

        osgUtil::IncrementalCompileOperation* const ico = mSceneManager->getIncrementalCompileOperation();
        if (!stateToCompile.empty() && ico)
        {
            auto compileSet = new osgUtil::IncrementalCompileOperation::CompileSet(group);
            compileSet->buildCompileMap(ico->getContextSet(), stateToCompile);
            ico->add(compileSet, false);
        }

        group->getBound();
        group->setNodeMask(Mask_Static);
        osg::UserDataContainer* udc = group->getOrCreateUserDataContainer();
        if (activeGrid)
        {
            std::sort(refnumSet->mRefnums.begin(), refnumSet->mRefnums.end());
            refnumSet->mRefnums.erase(
                std::unique(refnumSet->mRefnums.begin(), refnumSet->mRefnums.end()), refnumSet->mRefnums.end());
            udc->addUserObject(refnumSet);
            group->addCullCallback(new SceneUtil::LightListCallback);
        }
        udc->addUserObject(templateRefs);
        if (pagedOccluderData && !pagedOccluderData->mOccluderMeshes.empty())
            udc->addUserObject(pagedOccluderData);
        // Attach the occlusion callback to every distant chunk: the
        // whole-chunk visibility test needs no occluder data, so even
        // building-less chunks get culled when fully hidden.
        if (mOcclusionCuller && !activeGrid && !mResidentDistantStatics.load())
        {
            float maxDist = Settings::camera().mOcclusionOccluderMaxDistance;
            group->addCullCallback(new PagedOccluderCallback(mOcclusionCuller, maxDist, mMaxTriangles));
        }

        return group;
    }

    namespace
    {
        // ==== MWDS: flat binary supercell format ====
        // The osgb path parses resident supercells at ~5 MB/s/thread and
        // serializes every reader on osgDB's global wrapper registry, so a
        // multi-GB world takes many minutes to stream in. This format is
        // plain tables (statesets, then per-class geometry arrays) parsed
        // with bounds-checked memcpy and no osgDB involvement, so reads
        // scale with the thread pool and the whole world loads in seconds.
        // The writer fails loudly on anything it cannot represent; silent
        // substitution hides bake corruption.
        constexpr std::uint32_t sMwdsMagic = 0x5344574Du; // "MWDS"
        constexpr std::uint32_t sMwdsVersion = 3; // 3: material color mode stored as an index (a raw
                                                  // GL-enum osg ColorMode does not fit a byte)

        struct MwdsOut
        {
            std::vector<char> mBuf;
            template <typename T>
            void put(const T& v)
            {
                static_assert(std::is_trivially_copyable_v<T>);
                const char* p = reinterpret_cast<const char*>(&v);
                mBuf.insert(mBuf.end(), p, p + sizeof(T));
            }
            void putStr(const std::string& s)
            {
                put(static_cast<std::uint32_t>(s.size()));
                mBuf.insert(mBuf.end(), s.begin(), s.end());
            }
            void putBytes(const void* data, std::size_t len)
            {
                const char* p = static_cast<const char*>(data);
                mBuf.insert(mBuf.end(), p, p + len);
            }
        };

        struct MwdsIn
        {
            const char* mPtr = nullptr;
            const char* mEnd = nullptr;
            bool mFail = false;
            template <typename T>
            T get()
            {
                T v{};
                if (mPtr + sizeof(T) > mEnd)
                {
                    mFail = true;
                    return v;
                }
                std::memcpy(&v, mPtr, sizeof(T));
                mPtr += sizeof(T);
                return v;
            }
            std::string getStr()
            {
                const std::uint32_t n = get<std::uint32_t>();
                if (mFail || mPtr + n > mEnd)
                {
                    mFail = true;
                    return {};
                }
                std::string s(mPtr, mPtr + n);
                mPtr += n;
                return s;
            }
            const char* getBytes(std::size_t len)
            {
                if (mPtr + len > mEnd)
                {
                    mFail = true;
                    return nullptr;
                }
                const char* p = mPtr;
                mPtr += len;
                return p;
            }
        };

        // one serialized stateset record
        void mwdsWriteStateSet(MwdsOut& out, const osg::StateSet* ss, const std::filesystem::path& file)
        {
            // modes
            const auto& modes = ss->getModeList();
            out.put(static_cast<std::uint32_t>(modes.size()));
            for (const auto& [mode, value] : modes)
            {
                out.put(static_cast<std::uint32_t>(mode));
                out.put(static_cast<std::uint32_t>(value));
            }
            // render bin
            out.put(static_cast<std::int32_t>(ss->getBinNumber()));
            out.putStr(ss->getBinName());
            out.put(static_cast<std::uint8_t>(ss->getRenderBinMode()));
            out.put(static_cast<std::int32_t>(ss->getRenderingHint()));

            // attributes: each tagged with a kind byte; unknown kinds are a
            // loud write error, not silent degradation
            std::vector<char> attrBuf;
            std::uint32_t attrCount = 0;
            MwdsOut attrs;
            for (const auto& attrPair : ss->getAttributeList())
            {
                const osg::StateAttribute* a = attrPair.second.first.get();
                const unsigned int flags = attrPair.second.second;
                switch (attrPair.first.first)
                {
                    case osg::StateAttribute::PROGRAM:
                        continue; // regenerated by recreateShaders
                    case osg::StateAttribute::COLORMASK:
                        // engine-injected (normals-RT setup) into the live
                        // templates the save-state refresh reads; never NIF
                        // data. Reapplied by the engine at load, so skip
                        // silently instead of flooding the log.
                        continue;
                    case osg::StateAttribute::MATERIAL:
                    {
                        const osg::Material* m = static_cast<const osg::Material*>(a);
                        attrs.put(static_cast<std::uint8_t>(1));
                        attrs.put(static_cast<std::uint32_t>(flags));
                        // osg::Material::ColorMode values are GL enums (GL_AMBIENT
                        // 0x1200 ... off 0x1603); truncating one to a byte gives
                        // garbage modes and a per-frame GL_INVALID_ENUM at draw.
                        // Serialize a compact index instead.
                        std::uint8_t cmIndex;
                        switch (m->getColorMode())
                        {
                            case osg::Material::AMBIENT:
                                cmIndex = 0;
                                break;
                            case osg::Material::DIFFUSE:
                                cmIndex = 1;
                                break;
                            case osg::Material::SPECULAR:
                                cmIndex = 2;
                                break;
                            case osg::Material::EMISSION:
                                cmIndex = 3;
                                break;
                            case osg::Material::AMBIENT_AND_DIFFUSE:
                                cmIndex = 4;
                                break;
                            case osg::Material::OFF:
                            default:
                                cmIndex = 5;
                                break;
                        }
                        attrs.put(cmIndex);
                        for (const osg::Vec4& c : { m->getAmbient(osg::Material::FRONT_AND_BACK),
                                 m->getDiffuse(osg::Material::FRONT_AND_BACK),
                                 m->getSpecular(osg::Material::FRONT_AND_BACK),
                                 m->getEmission(osg::Material::FRONT_AND_BACK) })
                            attrs.put(c);
                        attrs.put(m->getShininess(osg::Material::FRONT_AND_BACK));
                        ++attrCount;
                        break;
                    }
                    case osg::StateAttribute::BLENDFUNC:
                    {
                        const osg::BlendFunc* b = static_cast<const osg::BlendFunc*>(a);
                        attrs.put(static_cast<std::uint8_t>(2));
                        attrs.put(static_cast<std::uint32_t>(flags));
                        attrs.put(static_cast<std::uint32_t>(b->getSource()));
                        attrs.put(static_cast<std::uint32_t>(b->getDestination()));
                        attrs.put(static_cast<std::uint32_t>(b->getSourceAlpha()));
                        attrs.put(static_cast<std::uint32_t>(b->getDestinationAlpha()));
                        ++attrCount;
                        break;
                    }
                    case osg::StateAttribute::DEPTH:
                    {
                        const osg::Depth* d = static_cast<const osg::Depth*>(a);
                        attrs.put(static_cast<std::uint8_t>(3));
                        attrs.put(static_cast<std::uint32_t>(flags));
                        attrs.put(static_cast<std::uint32_t>(d->getFunction()));
                        attrs.put(static_cast<std::uint8_t>(d->getWriteMask() ? 1 : 0));
                        ++attrCount;
                        break;
                    }
                    case osg::StateAttribute::ALPHAFUNC:
                    {
                        const osg::AlphaFunc* f = static_cast<const osg::AlphaFunc*>(a);
                        const bool removed = dynamic_cast<const Shader::RemovedAlphaFunc*>(a) != nullptr;
                        attrs.put(static_cast<std::uint8_t>(4));
                        attrs.put(static_cast<std::uint32_t>(flags));
                        attrs.put(static_cast<std::uint8_t>(removed ? 1 : 0));
                        attrs.put(static_cast<std::uint32_t>(f->getFunction()));
                        attrs.put(f->getReferenceValue());
                        ++attrCount;
                        break;
                    }
                    case osg::StateAttribute::FRONTFACE:
                    {
                        const osg::FrontFace* ff = static_cast<const osg::FrontFace*>(a);
                        attrs.put(static_cast<std::uint8_t>(5));
                        attrs.put(static_cast<std::uint32_t>(flags));
                        attrs.put(static_cast<std::uint32_t>(ff->getMode()));
                        ++attrCount;
                        break;
                    }
                    case osg::StateAttribute::CULLFACE:
                    {
                        const osg::CullFace* cf = static_cast<const osg::CullFace*>(a);
                        attrs.put(static_cast<std::uint8_t>(6));
                        attrs.put(static_cast<std::uint32_t>(flags));
                        attrs.put(static_cast<std::uint32_t>(cf->getMode()));
                        ++attrCount;
                        break;
                    }
                    default:
                        Log(Debug::Error) << "MWDS: unserialized stateset attribute type " << attrPair.first.first
                                          << " (" << a->className() << ") in " << file.filename();
                        break;
                }
            }
            out.put(attrCount);
            out.putBytes(attrs.mBuf.data(), attrs.mBuf.size());

            // texture units: Texture2D (named external ref or inline pixels)
            // + optional TextureType semantic per unit
            const auto& tal = ss->getTextureAttributeList();
            std::uint32_t unitCount = 0;
            MwdsOut units;
            for (unsigned int unit = 0; unit < tal.size(); ++unit)
            {
                const osg::Texture2D* tex = nullptr;
                std::string texType;
                for (const auto& attrPair : tal[unit])
                {
                    const osg::StateAttribute* a = attrPair.second.first.get();
                    if (const osg::Texture* t = a->asTexture())
                    {
                        tex = dynamic_cast<const osg::Texture2D*>(t);
                        if (!tex)
                            Log(Debug::Error)
                                << "MWDS: non-2D texture (" << t->className() << ") in " << file.filename();
                    }
                    else if (dynamic_cast<const SceneUtil::TextureType*>(a))
                        texType = a->getName();
                    else
                        Log(Debug::Error)
                            << "MWDS: unserialized texture attribute (" << a->className() << ") in " << file.filename();
                }
                if (!tex)
                    continue;
                units.put(static_cast<std::uint32_t>(unit));
                units.putStr(texType);
                units.put(static_cast<std::uint32_t>(tex->getWrap(osg::Texture::WRAP_S)));
                units.put(static_cast<std::uint32_t>(tex->getWrap(osg::Texture::WRAP_T)));
                units.put(static_cast<std::uint32_t>(tex->getFilter(osg::Texture::MIN_FILTER)));
                units.put(static_cast<std::uint32_t>(tex->getFilter(osg::Texture::MAG_FILTER)));
                units.put(tex->getMaxAnisotropy());
                const osg::Image* img = tex->getImage();
                const std::string name = img ? img->getFileName() : std::string();
                units.putStr(name);
                if (name.empty())
                {
                    // NIF-embedded image: inline level-0 pixels
                    if (!img || !img->data())
                    {
                        Log(Debug::Error) << "MWDS: nameless texture without pixel data in " << file.filename();
                        units.put(static_cast<std::uint32_t>(0)); // s
                        units.put(static_cast<std::uint32_t>(0)); // t
                    }
                    else
                    {
                        units.put(static_cast<std::uint32_t>(img->s()));
                        units.put(static_cast<std::uint32_t>(img->t()));
                        units.put(static_cast<std::uint32_t>(img->getPixelFormat()));
                        units.put(static_cast<std::uint32_t>(img->getDataType()));
                        units.put(static_cast<std::int32_t>(img->getInternalTextureFormat()));
                        const std::uint32_t bytes = static_cast<std::uint32_t>(img->getImageSizeInBytes());
                        units.put(bytes);
                        units.putBytes(img->data(), bytes);
                    }
                }
                ++unitCount;
            }
            out.put(unitCount);
            out.putBytes(units.mBuf.data(), units.mBuf.size());
            (void)attrBuf;
        }

        // shared texture objects: every stateset that binds the same image
        // with the same sampling params must reference one osg::Texture2D,
        // or state sorting degenerates to per-drawable rebinds
        std::mutex sMwdsTexCacheMutex;
        std::map<std::string, osg::ref_ptr<osg::Texture2D>> sMwdsTexCache;

        osg::ref_ptr<osg::StateSet> mwdsReadStateSet(MwdsIn& in, Resource::ImageManager* imageManager)
        {
            osg::ref_ptr<osg::StateSet> ss = new osg::StateSet;
            const std::uint32_t nModes = in.get<std::uint32_t>();
            for (std::uint32_t i = 0; i < nModes && !in.mFail; ++i)
            {
                const std::uint32_t mode = in.get<std::uint32_t>();
                const std::uint32_t value = in.get<std::uint32_t>();
                ss->setMode(mode, value);
            }
            const std::int32_t binNum = in.get<std::int32_t>();
            const std::string binName = in.getStr();
            const std::uint8_t binMode = in.get<std::uint8_t>();
            const std::int32_t hint = in.get<std::int32_t>();
            if (binMode != osg::StateSet::INHERIT_RENDERBIN_DETAILS)
                ss->setRenderBinDetails(binNum, binName, static_cast<osg::StateSet::RenderBinMode>(binMode));
            ss->setRenderingHint(hint);

            const std::uint32_t nAttrs = in.get<std::uint32_t>();
            for (std::uint32_t i = 0; i < nAttrs && !in.mFail; ++i)
            {
                const std::uint8_t kind = in.get<std::uint8_t>();
                const std::uint32_t flags = in.get<std::uint32_t>();
                switch (kind)
                {
                    case 1:
                    {
                        osg::ref_ptr<osg::Material> m = new osg::Material;
                        static const osg::Material::ColorMode cmModes[6]
                            = { osg::Material::AMBIENT, osg::Material::DIFFUSE, osg::Material::SPECULAR,
                                  osg::Material::EMISSION, osg::Material::AMBIENT_AND_DIFFUSE, osg::Material::OFF };
                        m->setColorMode(cmModes[std::min<std::uint8_t>(in.get<std::uint8_t>(), 5)]);
                        m->setAmbient(osg::Material::FRONT_AND_BACK, in.get<osg::Vec4>());
                        m->setDiffuse(osg::Material::FRONT_AND_BACK, in.get<osg::Vec4>());
                        m->setSpecular(osg::Material::FRONT_AND_BACK, in.get<osg::Vec4>());
                        m->setEmission(osg::Material::FRONT_AND_BACK, in.get<osg::Vec4>());
                        m->setShininess(osg::Material::FRONT_AND_BACK, in.get<float>());
                        ss->setAttribute(m, flags);
                        break;
                    }
                    case 2:
                    {
                        const std::uint32_t src = in.get<std::uint32_t>();
                        const std::uint32_t dst = in.get<std::uint32_t>();
                        const std::uint32_t srcA = in.get<std::uint32_t>();
                        const std::uint32_t dstA = in.get<std::uint32_t>();
                        ss->setAttribute(new osg::BlendFunc(src, dst, srcA, dstA), flags);
                        break;
                    }
                    case 3:
                    {
                        const auto func = static_cast<osg::Depth::Function>(in.get<std::uint32_t>());
                        const bool writeMask = in.get<std::uint8_t>() != 0;
                        ss->setAttribute(new SceneUtil::AutoDepth(func, 0.0, 1.0, writeMask), flags);
                        break;
                    }
                    case 4:
                    {
                        const bool removed = in.get<std::uint8_t>() != 0;
                        const auto func = static_cast<osg::AlphaFunc::ComparisonFunction>(in.get<std::uint32_t>());
                        const float ref = in.get<float>();
                        if (removed)
                            ss->setAttribute(new Shader::RemovedAlphaFunc(func, ref), flags);
                        else
                            ss->setAttribute(new osg::AlphaFunc(func, ref), flags);
                        break;
                    }
                    case 5:
                        ss->setAttribute(
                            new osg::FrontFace(static_cast<osg::FrontFace::Mode>(in.get<std::uint32_t>())), flags);
                        break;
                    case 6:
                        ss->setAttribute(
                            new osg::CullFace(static_cast<osg::CullFace::Mode>(in.get<std::uint32_t>())), flags);
                        break;
                    default:
                        in.mFail = true;
                        break;
                }
            }

            const std::uint32_t nUnits = in.get<std::uint32_t>();
            for (std::uint32_t i = 0; i < nUnits && !in.mFail; ++i)
            {
                const std::uint32_t unit = in.get<std::uint32_t>();
                const std::string texType = in.getStr();
                const auto wrapS = static_cast<osg::Texture::WrapMode>(in.get<std::uint32_t>());
                const auto wrapT = static_cast<osg::Texture::WrapMode>(in.get<std::uint32_t>());
                const auto minF = static_cast<osg::Texture::FilterMode>(in.get<std::uint32_t>());
                const auto magF = static_cast<osg::Texture::FilterMode>(in.get<std::uint32_t>());
                const float aniso = in.get<float>();
                const std::string name = in.getStr();
                osg::ref_ptr<osg::Image> image;
                std::string texKey;
                if (!name.empty())
                {
                    texKey = name + "|" + std::to_string(wrapS) + "|" + std::to_string(wrapT) + "|"
                        + std::to_string(minF) + "|" + std::to_string(magF) + "|"
                        + std::to_string(static_cast<int>(aniso * 16.f));
                    {
                        std::lock_guard<std::mutex> lock(sMwdsTexCacheMutex);
                        const auto found = sMwdsTexCache.find(texKey);
                        if (found != sMwdsTexCache.end())
                        {
                            ss->setTextureAttributeAndModes(unit, found->second, osg::StateAttribute::ON);
                            if (!texType.empty())
                                ss->setTextureAttributeAndModes(
                                    unit, new SceneUtil::TextureType(texType), osg::StateAttribute::ON);
                            continue;
                        }
                    }
                    try
                    {
                        image = imageManager->getImage(VFS::Path::Normalized(std::string_view(name)));
                    }
                    catch (const std::exception& e)
                    {
                        Log(Debug::Error) << "MWDS: image '" << name << "' failed: " << e.what();
                    }
                }
                else
                {
                    const std::uint32_t s = in.get<std::uint32_t>();
                    const std::uint32_t t = in.get<std::uint32_t>();
                    if (s && t)
                    {
                        const std::uint32_t pixelFormat = in.get<std::uint32_t>();
                        const std::uint32_t dataType = in.get<std::uint32_t>();
                        const std::int32_t internalFormat = in.get<std::int32_t>();
                        const std::uint32_t bytes = in.get<std::uint32_t>();
                        const char* data = in.getBytes(bytes);
                        if (data)
                        {
                            image = new osg::Image;
                            unsigned char* copy = new unsigned char[bytes];
                            std::memcpy(copy, data, bytes);
                            image->setImage(
                                s, t, 1, internalFormat, pixelFormat, dataType, copy, osg::Image::USE_NEW_DELETE);
                        }
                    }
                }
                osg::ref_ptr<osg::Texture2D> tex = new osg::Texture2D(image);
                tex->setWrap(osg::Texture::WRAP_S, wrapS);
                tex->setWrap(osg::Texture::WRAP_T, wrapT);
                tex->setFilter(osg::Texture::MIN_FILTER, minF);
                tex->setFilter(osg::Texture::MAG_FILTER, magF);
                tex->setMaxAnisotropy(aniso);
                if (!texKey.empty())
                {
                    std::lock_guard<std::mutex> lock(sMwdsTexCacheMutex);
                    const auto emplaced = sMwdsTexCache.emplace(texKey, tex);
                    tex = emplaced.first->second; // racer's copy wins, all share one
                }
                ss->setTextureAttributeAndModes(unit, tex, osg::StateAttribute::ON);
                if (!texType.empty())
                    ss->setTextureAttributeAndModes(unit, new SceneUtil::TextureType(texType), osg::StateAttribute::ON);
            }
            return ss;
        }

        // collects (geometry, accumulated matrix, effective stateset chain)
        // from one optimized class group; errors loudly on unexpected nodes
        struct MwdsGeom
        {
            const osg::Geometry* mGeom = nullptr;
            osg::Matrixf mMatrix;
            std::vector<const osg::StateSet*> mChain;
        };
        void mwdsCollect(const osg::Node* node, osg::Matrixf matrix, std::vector<const osg::StateSet*>& chain,
            std::vector<MwdsGeom>& out, const std::filesystem::path& file)
        {
            const bool pushed = node->getStateSet() != nullptr;
            if (pushed)
                chain.push_back(node->getStateSet());
            if (const osg::Geometry* geom = dynamic_cast<const osg::Geometry*>(node))
            {
                out.push_back({ geom, matrix, chain });
            }
            else if (const osg::Group* group = node->asGroup())
            {
                if (const osg::Transform* t = node->asTransform())
                {
                    osg::Matrix m; // handles MatrixTransform and both PAT flavors
                    t->computeLocalToWorldMatrix(m, nullptr);
                    matrix = osg::Matrixf(m) * matrix;
                }
                for (unsigned int i = 0; i < group->getNumChildren(); ++i)
                    mwdsCollect(group->getChild(i), matrix, chain, out, file);
            }
            else if (const osg::Geode* geode = dynamic_cast<const osg::Geode*>(node))
            {
                for (unsigned int i = 0; i < geode->getNumDrawables(); ++i)
                    mwdsCollect(geode->getDrawable(i), matrix, chain, out, file);
            }
            else
                Log(Debug::Error) << "MWDS: unhandled node " << node->className() << " in " << file.filename();
            if (pushed)
                chain.pop_back();
        }

        template <typename ArrayT>
        void mwdsPutArray(MwdsOut& out, const ArrayT* arr)
        {
            out.put(static_cast<std::uint32_t>(arr->size()));
            out.putBytes(arr->getDataPointer(), arr->getTotalDataSize());
        }

        bool mwdsWriteGeometry(MwdsOut& out, const osg::Geometry* geom, const std::filesystem::path& file)
        {
            const osg::Vec3Array* verts = dynamic_cast<const osg::Vec3Array*>(geom->getVertexArray());
            if (!verts)
            {
                Log(Debug::Error) << "MWDS: unsupported vertex array "
                                  << (geom->getVertexArray() ? geom->getVertexArray()->className() : "null") << " in "
                                  << file.filename();
                return false;
            }
            mwdsPutArray(out, verts);

            const osg::Array* normals = geom->getNormalArray();
            if (const auto* nb = dynamic_cast<const osg::Vec3bArray*>(normals))
            {
                out.put(static_cast<std::uint8_t>(1));
                mwdsPutArray(out, nb);
            }
            else if (const auto* nf = dynamic_cast<const osg::Vec3Array*>(normals))
            {
                out.put(static_cast<std::uint8_t>(2));
                mwdsPutArray(out, nf);
            }
            else
            {
                if (normals)
                    Log(Debug::Error) << "MWDS: unsupported normal array " << normals->className() << " in "
                                      << file.filename();
                out.put(static_cast<std::uint8_t>(0));
            }

            const osg::Array* colors = geom->getColorArray();
            if (const auto* cb = dynamic_cast<const osg::Vec4ubArray*>(colors))
            {
                out.put(static_cast<std::uint8_t>(1));
                mwdsPutArray(out, cb);
            }
            else if (const auto* cf = dynamic_cast<const osg::Vec4Array*>(colors))
            {
                out.put(static_cast<std::uint8_t>(2));
                mwdsPutArray(out, cf);
            }
            else
            {
                if (colors)
                    Log(Debug::Error) << "MWDS: unsupported color array " << colors->className() << " in "
                                      << file.filename();
                out.put(static_cast<std::uint8_t>(0));
            }

            std::uint8_t nUV = 0;
            for (unsigned int i = 0; i < geom->getNumTexCoordArrays(); ++i)
                if (geom->getTexCoordArray(i))
                    nUV = static_cast<std::uint8_t>(i + 1);
            out.put(nUV);
            for (std::uint8_t i = 0; i < nUV; ++i)
            {
                const auto* uv = dynamic_cast<const osg::Vec2Array*>(geom->getTexCoordArray(i));
                const auto* uv4 = dynamic_cast<const osg::Vec4Array*>(geom->getTexCoordArray(i));
                if (uv)
                {
                    out.put(static_cast<std::uint8_t>(1));
                    mwdsPutArray(out, uv);
                }
                else if (uv4)
                {
                    out.put(static_cast<std::uint8_t>(2));
                    mwdsPutArray(out, uv4);
                }
                else
                {
                    if (geom->getTexCoordArray(i))
                        Log(Debug::Error) << "MWDS: unsupported texcoord array "
                                          << geom->getTexCoordArray(i)->className() << " in " << file.filename();
                    out.put(static_cast<std::uint8_t>(0));
                }
            }

            std::uint32_t nPrims = 0;
            MwdsOut prims;
            for (unsigned int i = 0; i < geom->getNumPrimitiveSets(); ++i)
            {
                const osg::PrimitiveSet* ps = geom->getPrimitiveSet(i);
                if (const auto* des = dynamic_cast<const osg::DrawElementsUShort*>(ps))
                {
                    prims.put(static_cast<std::uint8_t>(1));
                    prims.put(static_cast<std::uint32_t>(des->getMode()));
                    prims.put(static_cast<std::uint32_t>(des->size()));
                    prims.putBytes(des->getDataPointer(), des->size() * sizeof(unsigned short));
                    ++nPrims;
                }
                else if (const auto* dei = dynamic_cast<const osg::DrawElementsUInt*>(ps))
                {
                    prims.put(static_cast<std::uint8_t>(2));
                    prims.put(static_cast<std::uint32_t>(dei->getMode()));
                    prims.put(static_cast<std::uint32_t>(dei->size()));
                    prims.putBytes(dei->getDataPointer(), dei->size() * sizeof(unsigned int));
                    ++nPrims;
                }
                else if (const auto* da = dynamic_cast<const osg::DrawArrays*>(ps))
                {
                    prims.put(static_cast<std::uint8_t>(3));
                    prims.put(static_cast<std::uint32_t>(da->getMode()));
                    prims.put(static_cast<std::uint32_t>(da->getFirst()));
                    prims.put(static_cast<std::uint32_t>(da->getCount()));
                    ++nPrims;
                }
                else
                    Log(Debug::Error) << "MWDS: unsupported primitive set " << ps->className() << " in "
                                      << file.filename();
            }
            out.put(nPrims);
            out.putBytes(prims.mBuf.data(), prims.mBuf.size());
            return true;
        }

        osg::ref_ptr<osg::Geometry> mwdsReadGeometry(MwdsIn& in)
        {
            osg::ref_ptr<osg::Geometry> geom = new osg::Geometry;
            geom->setDataVariance(osg::Object::STATIC);
            geom->setUseDisplayList(false);
            geom->setUseVertexBufferObjects(true);

            const std::uint32_t nVerts = in.get<std::uint32_t>();
            const char* vdata = in.getBytes(static_cast<std::size_t>(nVerts) * 12);
            if (in.mFail)
                return nullptr;
            if (!nVerts)
                return nullptr;
            osg::ref_ptr<osg::Vec3Array> verts = new osg::Vec3Array(nVerts);
            std::memcpy(&(*verts)[0], vdata, static_cast<std::size_t>(nVerts) * 12);
            geom->setVertexArray(verts);

            const std::uint8_t normType = in.get<std::uint8_t>();
            if (normType == 1)
            {
                const std::uint32_t n = in.get<std::uint32_t>();
                const char* data = in.getBytes(static_cast<std::size_t>(n) * 3);
                if (in.mFail)
                    return nullptr;
                osg::ref_ptr<osg::Vec3bArray> arr = new osg::Vec3bArray(n);
                if (n)
                    std::memcpy(&(*arr)[0], data, static_cast<std::size_t>(n) * 3);
                arr->setBinding(osg::Array::BIND_PER_VERTEX);
                arr->setNormalize(true);
                geom->setNormalArray(arr);
            }
            else if (normType == 2)
            {
                const std::uint32_t n = in.get<std::uint32_t>();
                const char* data = in.getBytes(static_cast<std::size_t>(n) * 12);
                if (in.mFail)
                    return nullptr;
                osg::ref_ptr<osg::Vec3Array> arr = new osg::Vec3Array(n);
                if (n)
                    std::memcpy(&(*arr)[0], data, static_cast<std::size_t>(n) * 12);
                geom->setNormalArray(arr, osg::Array::BIND_PER_VERTEX);
            }

            const std::uint8_t colType = in.get<std::uint8_t>();
            if (colType == 1)
            {
                const std::uint32_t n = in.get<std::uint32_t>();
                const char* data = in.getBytes(static_cast<std::size_t>(n) * 4);
                if (in.mFail)
                    return nullptr;
                osg::ref_ptr<osg::Vec4ubArray> arr = new osg::Vec4ubArray(n);
                if (n)
                    std::memcpy(&(*arr)[0], data, static_cast<std::size_t>(n) * 4);
                arr->setBinding(osg::Array::BIND_PER_VERTEX);
                arr->setNormalize(true);
                geom->setColorArray(arr);
            }
            else if (colType == 2)
            {
                const std::uint32_t n = in.get<std::uint32_t>();
                const char* data = in.getBytes(static_cast<std::size_t>(n) * 16);
                if (in.mFail)
                    return nullptr;
                osg::ref_ptr<osg::Vec4Array> arr = new osg::Vec4Array(n);
                if (n)
                    std::memcpy(&(*arr)[0], data, static_cast<std::size_t>(n) * 16);
                geom->setColorArray(arr, osg::Array::BIND_PER_VERTEX);
            }

            const std::uint8_t nUV = in.get<std::uint8_t>();
            for (std::uint8_t i = 0; i < nUV && !in.mFail; ++i)
            {
                const std::uint8_t present = in.get<std::uint8_t>();
                if (!present)
                    continue;
                const std::uint32_t n = in.get<std::uint32_t>();
                if (present == 1)
                {
                    const char* data = in.getBytes(static_cast<std::size_t>(n) * 8);
                    if (in.mFail)
                        return nullptr;
                    osg::ref_ptr<osg::Vec2Array> arr = new osg::Vec2Array(n);
                    if (n)
                        std::memcpy(&(*arr)[0], data, static_cast<std::size_t>(n) * 8);
                    geom->setTexCoordArray(i, arr);
                }
                else
                {
                    const char* data = in.getBytes(static_cast<std::size_t>(n) * 16);
                    if (in.mFail)
                        return nullptr;
                    osg::ref_ptr<osg::Vec4Array> arr = new osg::Vec4Array(n);
                    if (n)
                        std::memcpy(&(*arr)[0], data, static_cast<std::size_t>(n) * 16);
                    geom->setTexCoordArray(i, arr);
                }
            }

            const std::uint32_t nPrims = in.get<std::uint32_t>();
            for (std::uint32_t i = 0; i < nPrims && !in.mFail; ++i)
            {
                const std::uint8_t kind = in.get<std::uint8_t>();
                const std::uint32_t mode = in.get<std::uint32_t>();
                if (kind == 1)
                {
                    const std::uint32_t n = in.get<std::uint32_t>();
                    const char* data = in.getBytes(static_cast<std::size_t>(n) * 2);
                    if (in.mFail)
                        return nullptr;
                    osg::ref_ptr<osg::DrawElementsUShort> des = new osg::DrawElementsUShort(mode, n);
                    if (n)
                        std::memcpy(&(*des)[0], data, static_cast<std::size_t>(n) * 2);
                    geom->addPrimitiveSet(des);
                }
                else if (kind == 2)
                {
                    const std::uint32_t n = in.get<std::uint32_t>();
                    const char* data = in.getBytes(static_cast<std::size_t>(n) * 4);
                    if (in.mFail)
                        return nullptr;
                    osg::ref_ptr<osg::DrawElementsUInt> dei = new osg::DrawElementsUInt(mode, n);
                    if (n)
                        std::memcpy(&(*dei)[0], data, static_cast<std::size_t>(n) * 4);
                    geom->addPrimitiveSet(dei);
                }
                else if (kind == 3)
                {
                    const std::uint32_t first = in.get<std::uint32_t>();
                    const std::uint32_t count = in.get<std::uint32_t>();
                    geom->addPrimitiveSet(new osg::DrawArrays(mode, first, count));
                }
                else
                {
                    in.mFail = true;
                    return nullptr;
                }
            }
            return geom;
        }
    }

    namespace
    {
        // residency-class file suffixes, indexed by class (near/far/very far)
        const char* const sClassSuffix[3] = { ".near.mwds", ".far.mwds", ".vf.mwds" };
        const char* const sClassName[3] = { ".near", ".far", ".vf" };

        // MGE-style band separation, evaluated live per frame: a resident
        // block renders only when it is (a) not already covered by stock
        // rendering (which reaches the viewing distance) and (b) inside its
        // class's end distance ('distant statics end *', 0 = horizon). Both
        // read current settings, so the in-game viewing-distance slider and
        // the class ends apply instantly; nothing is baked into the data.
        class DistantBandCullCallback
            : public SceneUtil::NodeCallback<DistantBandCullCallback, osg::Node*, osgUtil::CullVisitor*>
        {
        public:
            DistantBandCullCallback(const osg::Vec3f& centerLocal, float radius, int cls)
                : mCenterLocal(centerLocal)
                , mRadius(radius)
                , mClass(cls)
            {
            }
            void operator()(osg::Node* node, osgUtil::CullVisitor* cv)
            {
                const float d = (cv->getViewPointLocal() - mCenterLocal).length();
                const float viewDist = Settings::camera().mViewingDistance;
                if (d + mRadius < viewDist * 0.9f)
                    return; // stock rendering covers this block completely
                float end = 0.f;
                switch (mClass)
                {
                    case 0:
                        end = Settings::terrain().mDistantStaticsEndNear;
                        break;
                    case 1:
                        end = Settings::terrain().mDistantStaticsEndFar;
                        break;
                    default:
                        end = Settings::terrain().mDistantStaticsEndVeryFar;
                        break;
                }
                if (end > 0.f && d - mRadius > end)
                    return; // beyond this size class's visible range
                traverse(node, cv);
            }

        private:
            osg::Vec3f mCenterLocal;
            float mRadius;
            int mClass;
        };

        // persistent update callback: applies queued ring/refresh swaps on the
        // update traversal (scene-graph mutation must stay off worker threads)
        class RingDrainCallback : public SceneUtil::NodeCallback<RingDrainCallback, osg::Group*>
        {
        public:
            explicit RingDrainCallback(ObjectPaging* paging)
                : mPaging(paging)
            {
            }
            void operator()(osg::Group* node, osg::NodeVisitor* nv)
            {
                mPaging->drainRingSwaps(node);
                traverse(node, nv);
            }

        private:
            ObjectPaging* mPaging; // lifetimes colocated: root and paging die with RenderingManager
        };
    }

    bool ObjectPaging::writeSupercellFlat(const osg::Vec3f& worldCenter,
        const std::vector<std::pair<osg::ref_ptr<osg::Group>, int>>& blocks, const std::filesystem::path& file)
    {
        MwdsOut out;
        out.put(sMwdsMagic);
        out.put(sMwdsVersion);
        out.put(worldCenter);

        // collect all blocks first so statesets can be deduplicated
        struct ClassData
        {
            osg::Vec3f mCenterLocal;
            float mRadius = 0.f;
            int mClass = 0;
            std::vector<MwdsGeom> mGeoms;
        };
        std::vector<ClassData> classes;
        for (const auto& [group, cls] : blocks)
        {
            ClassData cd;
            const osg::BoundingSphere bound = group->getBound();
            cd.mCenterLocal = bound.center();
            cd.mRadius = bound.radius();
            cd.mClass = cls;
            std::vector<const osg::StateSet*> chain;
            mwdsCollect(group.get(), osg::Matrixf::identity(), chain, cd.mGeoms, file);
            classes.push_back(std::move(cd));
        }

        // dedup statesets by serialized value: after the optimizer most
        // geometries carry pointer-distinct but byte-identical state, and
        // pointer-keyed dedup ships thousands of duplicate state records
        // per city supercell (state-sort collapse at render time)
        std::map<std::vector<const osg::StateSet*>, std::uint32_t> chainToRecord;
        std::map<std::vector<char>, std::uint32_t> bytesToRecord;
        std::vector<std::vector<char>> records;
        for (const ClassData& cd : classes)
            for (const MwdsGeom& g : cd.mGeoms)
            {
                if (chainToRecord.find(g.mChain) != chainToRecord.end())
                    continue;
                osg::ref_ptr<osg::StateSet> effective = new osg::StateSet;
                for (const osg::StateSet* ss : g.mChain)
                    effective->merge(*ss);
                MwdsOut ssOut;
                mwdsWriteStateSet(ssOut, effective.get(), file);
                const auto emplaced = bytesToRecord.emplace(ssOut.mBuf, static_cast<std::uint32_t>(records.size()));
                if (emplaced.second)
                    records.push_back(std::move(ssOut.mBuf));
                chainToRecord.emplace(g.mChain, emplaced.first->second);
            }

        out.put(static_cast<std::uint32_t>(records.size()));
        for (const std::vector<char>& rec : records)
            out.putBytes(rec.data(), rec.size());

        out.put(static_cast<std::uint32_t>(classes.size()));
        for (const ClassData& cd : classes)
        {
            out.put(cd.mCenterLocal);
            out.put(cd.mRadius);
            out.put(static_cast<std::uint32_t>(cd.mClass));
            out.put(static_cast<std::uint32_t>(cd.mGeoms.size()));
            for (const MwdsGeom& g : cd.mGeoms)
            {
                out.put(chainToRecord.at(g.mChain));
                const bool identity = g.mMatrix.isIdentity();
                out.put(static_cast<std::uint8_t>(identity ? 0 : 1));
                if (!identity)
                    out.putBytes(g.mMatrix.ptr(), 16 * sizeof(float));
                if (!mwdsWriteGeometry(out, g.mGeom, file))
                    return false;
            }
        }

        // atomic write via temp file, same discipline as the osgb path
        const std::filesystem::path tmp = file.string() + ".tmp";
        {
            std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
            f.write(out.mBuf.data(), static_cast<std::streamsize>(out.mBuf.size()));
            if (!f.good())
            {
                std::error_code ec;
                std::filesystem::remove(tmp, ec);
                return false;
            }
        }
        std::error_code ec;
        std::filesystem::rename(tmp, file, ec);
        if (ec)
        {
            std::filesystem::remove(file, ec);
            std::filesystem::rename(tmp, file, ec);
        }
        return !ec;
    }

    osg::ref_ptr<osg::Node> ObjectPaging::readSupercellFlat(const std::filesystem::path& file)
    {
        std::vector<char> buf;
        {
            std::ifstream f(file, std::ios::binary | std::ios::ate);
            if (!f.is_open())
                return nullptr;
            const std::streamsize size = f.tellg();
            f.seekg(0);
            buf.resize(static_cast<std::size_t>(size));
            if (!f.read(buf.data(), size))
                return nullptr;
        }
        MwdsIn in{ buf.data(), buf.data() + buf.size() };
        if (in.get<std::uint32_t>() != sMwdsMagic || in.get<std::uint32_t>() != sMwdsVersion)
        {
            Log(Debug::Error) << "MWDS: bad magic/version: " << file.filename();
            return nullptr;
        }
        const osg::Vec3f worldCenter = in.get<osg::Vec3f>();

        const std::uint32_t nStateSets = in.get<std::uint32_t>();
        std::vector<osg::ref_ptr<osg::StateSet>> stateSets;
        stateSets.reserve(nStateSets);
        Resource::ImageManager* imageManager = mSceneManager->getImageManager();
        for (std::uint32_t i = 0; i < nStateSets && !in.mFail; ++i)
            stateSets.push_back(mwdsReadStateSet(in, imageManager));

        osg::ref_ptr<osg::Group> lodNode = new osg::Group; // block container
        const std::uint32_t nClasses = in.get<std::uint32_t>();
        for (std::uint32_t c = 0; c < nClasses && !in.mFail; ++c)
        {
            const osg::Vec3f centerLocal = in.get<osg::Vec3f>();
            const float radius = in.get<float>();
            const std::uint32_t cls = in.get<std::uint32_t>();
            const std::uint32_t nGeoms = in.get<std::uint32_t>();
            osg::ref_ptr<osg::Group> classGroup = new osg::Group;
            classGroup->setDataVariance(osg::Object::STATIC);
            classGroup->addCullCallback(
                new DistantBandCullCallback(centerLocal, radius, static_cast<int>(std::min(cls, 2u))));
            for (std::uint32_t g = 0; g < nGeoms && !in.mFail; ++g)
            {
                const std::uint32_t ssIdx = in.get<std::uint32_t>();
                const std::uint8_t hasMatrix = in.get<std::uint8_t>();
                osg::Matrixf matrix;
                if (hasMatrix)
                {
                    const char* mdata = in.getBytes(16 * sizeof(float));
                    if (in.mFail)
                        break;
                    std::memcpy(matrix.ptr(), mdata, 16 * sizeof(float));
                }
                osg::ref_ptr<osg::Geometry> geom = mwdsReadGeometry(in);
                if (!geom)
                    break;
                if (ssIdx < stateSets.size())
                    geom->setStateSet(stateSets[ssIdx]);
                if (hasMatrix)
                {
                    osg::ref_ptr<osg::MatrixTransform> mt = new osg::MatrixTransform(matrix);
                    mt->setDataVariance(osg::Object::STATIC);
                    mt->addChild(geom);
                    classGroup->addChild(mt);
                }
                else
                    classGroup->addChild(geom);
            }
            lodNode->addChild(classGroup);
        }
        if (in.mFail)
        {
            Log(Debug::Error) << "MWDS: truncated/corrupt file: " << file.filename();
            return nullptr;
        }

        osg::ref_ptr<osg::MatrixTransform> root = new osg::MatrixTransform(osg::Matrixf::translate(worldCenter));
        root->setDataVariance(osg::Object::STATIC);
        root->addChild(lodNode);
        mSceneManager->recreateShaders(root);
        root->getBound();
        root->setNodeMask(Mask_Static);
        return root;
    }

    std::uint64_t ObjectPaging::generateSupercell(const osg::Vec2i& startCell, const std::filesystem::path& outDir,
        const RefStateMap& refStates, bool& outWritten)
    {
        outWritten = false;
        const MWWorld::ESMStore& store = *MWBase::Environment::get().getESMStore();
        const float cellSizeUnits = static_cast<float>(getCellSize(mWorldspace));

        std::map<ESM::RefNum, PagedCellRef> refs
            = collectESM3References(static_cast<float>(sSupercellSize), startCell, store);

        // apply the save's world state (tier-2 reactivity): disabled refs
        // drop out, script-moved refs relocate
        for (auto it = refs.begin(); it != refs.end();)
        {
            const auto state = refStates.find(it->first);
            if (state != refStates.end())
            {
                if (!state->second.mEnabled)
                {
                    it = refs.erase(it);
                    continue;
                }
                if (state->second.mMoved)
                    it->second.mPosition = state->second.mPosition;
            }
            ++it;
        }

        // state hash over the effective ref set: identical world state =>
        // identical hash => the sidecar check below skips the rebuild
        std::uint64_t hash = 0xcbf29ce484222325ull;
        {
            // generator version: bump to invalidate every sidecar when the
            // bake output changes without its inputs changing
            constexpr std::uint32_t genVersion = 8; // 8: per-cell blocks, runtime band/end culling
            hash = chunkCacheFnv1a(hash, &genVersion, sizeof(genVersion));
        }
        {
            // class min sizes are part of supercell identity (they gate what
            // is baked); end distances are runtime cull settings and are
            // deliberately not hashed, changing them needs no rebake
            const float classSettings[3] = { Settings::terrain().mDistantStaticsMinNear,
                Settings::terrain().mDistantStaticsMinFar, Settings::terrain().mDistantStaticsMinVeryFar };
            hash = chunkCacheFnv1a(hash, classSettings, sizeof(classSettings));
        }
        for (const auto& [refNum, ref] : refs)
        {
            hash = chunkCacheFnv1a(hash, &refNum.mIndex, sizeof(refNum.mIndex));
            hash = chunkCacheFnv1a(hash, &refNum.mContentFile, sizeof(refNum.mContentFile));
            hash = chunkCacheFnv1a(hash, &ref.mPosition, sizeof(ref.mPosition));
            hash = chunkCacheFnv1a(hash, &ref.mScale, sizeof(ref.mScale));
        }

        char namebuf[64];
        std::snprintf(namebuf, sizeof(namebuf), "dl_%d_%d", startCell.x(), startCell.y());
        std::filesystem::path classFiles[3];
        for (int k = 0; k < 3; ++k)
            classFiles[k] = outDir / (std::string(namebuf) + sClassSuffix[k]);
        const std::filesystem::path legacyFiles[2]
            = { outDir / (std::string(namebuf) + ".mwds"), outDir / (std::string(namebuf) + ".osgb") };
        const std::filesystem::path stateFile = outDir / (std::string(namebuf) + ".state");
        {
            std::ifstream in(stateFile);
            std::uint64_t existing = 0;
            if (in >> existing && existing == hash)
                return hash; // up to date, the incremental-refresh skip
        }

        const float minSize[3] = { Settings::terrain().mDistantStaticsMinNear,
            Settings::terrain().mDistantStaticsMinFar, Settings::terrain().mDistantStaticsMinVeryFar };

        const osg::Vec3f worldCenter((startCell.x() + sSupercellSize / 2.f) * cellSizeUnits,
            (startCell.y() + sSupercellSize / 2.f) * cellSizeUnits, 0.f);

        unsigned int dbgExceptions = 0;
        std::string dbgFirstError;
        constexpr auto copyMask = ~Mask_UpdateVisitor;
        // one group per (class, cell): fine-grained blocks so the runtime
        // band boundary doesn't operate at whole-supercell granularity and
        // cull whole city blocks at once
        osg::ref_ptr<osg::Group> blockGroup[3][sSupercellSize * sSupercellSize];
        for (int k = 0; k < 3; ++k)
            for (int b = 0; b < sSupercellSize * sSupercellSize; ++b)
                blockGroup[k][b] = new osg::Group;
        CopyOp copyop(false, copyMask);
        copyop.mOptimizeBillboards = true;

        std::map<const osg::Node*, float> geomRadiusCache;
        unsigned int instances = 0;
        for (const auto& [refNum, ref] : refs)
        {
            const int type = store.findStatic(ref.mRefId);
            VFS::Path::Normalized model(getModel(type, ref.mRefId, store));
            if (model.empty())
                continue;
            // ESM model strings are relative to meshes/; without this the
            // VFS lookup fails and getTemplate substitutes marker_error for
            // every static (an all-placeholder distant layer)
            model = Misc::ResourceHelpers::correctMeshPath(model);
            osg::ref_ptr<const osg::Node> cnode;
            try
            {
                cnode = mSceneManager->getTemplate(model, false);
            }
            catch (const std::exception& e)
            {
                ++dbgExceptions;
                if (dbgFirstError.empty())
                    dbgFirstError = e.what();
                continue;
            }
            // classify by geometry bounds only: the node bound also spans glow
            // billboards and particle emitters, inflating a 30-unit lantern to
            // a 300-unit "landmark" and flooding the near class with clutter
            float geomRadius;
            {
                const auto cached = geomRadiusCache.find(cnode.get());
                if (cached != geomRadiusCache.end())
                    geomRadius = cached->second;
                else
                {
                    class GeomBoundVisitor : public osg::NodeVisitor
                    {
                    public:
                        osg::BoundingBox mBox;
                        std::vector<osg::Matrix> mStack{ osg::Matrix::identity() };
                        GeomBoundVisitor()
                            : osg::NodeVisitor(TRAVERSE_ALL_CHILDREN)
                        {
                        }
                        void apply(osg::Transform& t) override
                        {
                            osg::Matrix m = mStack.back();
                            t.computeLocalToWorldMatrix(m, this);
                            mStack.push_back(m);
                            traverse(t);
                            mStack.pop_back();
                        }
                        void apply(osg::Node& n) override
                        {
                            // billboarded glow planes distort bounds the same
                            // way at bake time as they do at render time
                            for (const osg::Callback* cb = n.getCullCallback(); cb; cb = cb->getNestedCallback())
                                if (cb->className() == std::string_view("BillboardCallback"))
                                    return;
                            traverse(n);
                        }
                        void apply(osg::Drawable& d) override
                        {
                            if (dynamic_cast<const osgParticle::ParticleSystem*>(&d))
                                return;
                            const osg::BoundingBox b = d.getBoundingBox();
                            if (!b.valid())
                                return;
                            for (unsigned int i = 0; i < 8; ++i)
                                mBox.expandBy(b.corner(i) * mStack.back());
                        }
                    } v;
                    const_cast<osg::Node*>(cnode.get())->accept(v);
                    geomRadius = v.mBox.valid() ? v.mBox.radius() : cnode->getBound().radius();
                    geomRadiusCache.emplace(cnode.get(), geomRadius);
                }
            }
            const float radius = geomRadius * ref.mScale;
            int cls = -1;
            if (minSize[2] > 0.f && radius >= minSize[2])
                cls = 2;
            else if (minSize[1] > 0.f && radius >= minSize[1])
                cls = 1;
            else if (minSize[0] > 0.f && radius >= minSize[0])
                cls = 0;
            if (cls < 0)
                continue;

            osg::Matrixf matrix;
            matrix.preMultTranslate(ref.mPosition - worldCenter);
            matrix.preMultRotate(osg::Quat(ref.mRotation.z(), osg::Vec3f(0, 0, -1))
                * osg::Quat(ref.mRotation.y(), osg::Vec3f(0, -1, 0))
                * osg::Quat(ref.mRotation.x(), osg::Vec3f(-1, 0, 0)));
            matrix.preMultScale(osg::Vec3f(ref.mScale, ref.mScale, ref.mScale));
            osg::ref_ptr<osg::MatrixTransform> trans = new osg::MatrixTransform(matrix);
            trans->setDataVariance(osg::Object::STATIC);
            copyop.mNodePath.push_back(trans);
            copyop.mViewVector = osg::Vec3f(0.f, 0.f, 1.f);
            // full distance range: a resident supercell serves every distance,
            // so keep every LOD child ({0,0} makes every intersection empty
            // and silently drops whole NiLODNode subtrees)
            copyop.mDistances = LODRange{ 0.f, std::numeric_limits<float>::max() };
            copyop.setCopyFlags(osg::CopyOp::DEEP_COPY_NODES | osg::CopyOp::DEEP_COPY_DRAWABLES);
            copyop.copy(cnode, trans);
            copyop.mNodePath.pop_back();
            const int bx = std::clamp(
                static_cast<int>(std::floor(ref.mPosition.x() / cellSizeUnits)) - startCell.x(), 0, sSupercellSize - 1);
            const int by = std::clamp(
                static_cast<int>(std::floor(ref.mPosition.y() / cellSizeUnits)) - startCell.y(), 0, sSupercellSize - 1);
            blockGroup[cls][by * sSupercellSize + bx]->addChild(trans);
            ++instances;
        }

        std::vector<std::pair<osg::ref_ptr<osg::Group>, int>> classBlocks[3];
        for (int k = 0; k < 3; ++k)
            for (int b = 0; b < sSupercellSize * sSupercellSize; ++b)
            {
                if (!blockGroup[k][b]->getNumChildren())
                    continue;
                SceneUtil::Optimizer optimizer;
                optimizer.setMergeAlphaBlending(true);
                optimizer.setIsOperationPermissibleForObjectCallback(new CanOptimizeCallback);
                optimizer.optimize(blockGroup[k][b],
                    SceneUtil::Optimizer::FLATTEN_STATIC_TRANSFORMS | SceneUtil::Optimizer::REMOVE_REDUNDANT_NODES
                        | SceneUtil::Optimizer::MERGE_GEOMETRY);
                classBlocks[k].emplace_back(blockGroup[k][b], k);
            }

        std::error_code ec;
        std::filesystem::create_directories(outDir, ec);
        // one file per residency class; empty classes leave no file
        for (int k = 0; k < 3; ++k)
        {
            if (!classBlocks[k].empty())
            {
                if (!writeSupercellFlat(worldCenter, classBlocks[k], classFiles[k]))
                {
                    ++mWriteFailures;
                    Log(Debug::Error) << "Failed to store supercell " << classFiles[k] << " (write error - disk full?)";
                }
            }
            else
                std::filesystem::remove(classFiles[k], ec);
        }
        for (const std::filesystem::path& legacy : legacyFiles)
            std::filesystem::remove(legacy, ec);
        bool sideOk;
        {
            std::ofstream out(stateFile, std::ios::trunc);
            out << hash;
            out.flush();
            sideOk = out.good();
        }
        Log(Debug::Verbose) << "Supercell " << startCell.x() << "," << startCell.y() << ": refs " << refs.size()
                            << " instances " << instances << " exceptions " << dbgExceptions
                            << (dbgFirstError.empty() ? "" : (" first=" + dbgFirstError)) << " sidecar "
                            << (sideOk ? "ok" : "WRITE FAILED");
        outWritten = true;
        return hash;
    }

    namespace
    {
        // Drains supercells parsed by loader threads into the resident root
        // on the update traversal (scene-graph mutation must not happen on
        // arbitrary threads).
        class ResidentAttachCallback : public SceneUtil::NodeCallback<ResidentAttachCallback, osg::Group*>
        {
        public:
            std::mutex mMutex;
            std::vector<osg::ref_ptr<osg::Node>> mPending;
            std::atomic<bool> mDone{ false };

            void operator()(osg::Group* node, osg::NodeVisitor* nv)
            {
                {
                    std::lock_guard<std::mutex> lock(mMutex);
                    for (const auto& n : mPending)
                        node->addChild(n);
                    mPending.clear();
                }
                if (mDone.load() && node->getUpdateCallback() == this)
                    node->removeUpdateCallback(this);
                traverse(node, nv);
            }
        };
    }

    unsigned int ObjectPaging::loadDistantStaticsResident(const std::filesystem::path& dir, osg::Group* root)
    {
        const int ringCells[3] = { Settings::terrain().mDistantStaticsNearRingCells,
            Settings::terrain().mDistantStaticsFarRingCells, Settings::terrain().mDistantStaticsVeryFarRingCells };
        std::vector<std::filesystem::path> files;
        std::error_code ec;
        for (const auto& entry : std::filesystem::directory_iterator(dir, ec))
        {
            const std::string name = entry.path().filename().string();
            for (int k = 0; k < 3; ++k)
                if (ringCells[k] <= 0 && name.size() > std::strlen(sClassSuffix[k])
                    && name.compare(name.size() - std::strlen(sClassSuffix[k]), std::string::npos, sClassSuffix[k])
                        == 0)
                    files.push_back(entry.path());
        }
        if (files.empty())
        {
            Log(Debug::Warning) << "Distant statics: no globally-resident class files in " << dir << " (bake needed?)";
            return 0;
        }
        mResidentDir = dir;
        root->addUpdateCallback(new RingDrainCallback(this));

        mResidentDistantStatics = true;
        mResidentLoadActive = true;
        osg::ref_ptr<ResidentAttachCallback> attach = new ResidentAttachCallback;
        root->addUpdateCallback(attach);

        const int threads = std::clamp(Settings::terrain().mObjectPagingReadThreads.get(), 1, 16);
        auto worker = [this, files, attach, threads](int offset) {
            for (std::size_t i = offset; i < files.size(); i += threads)
            {
                if (mResidentShutdown.load())
                    return;
                osg::ref_ptr<osg::Node> node = readSupercellFlat(files[i]);
                if (node)
                {
                    // named per supercell so a save-state refresh can swap it
                    // (names are plain ASCII "dl_x_y", .string() is safe)
                    node->setName(files[i].stem().string());
                    std::lock_guard<std::mutex> lock(attach->mMutex);
                    attach->mPending.push_back(node);
                }
            }
        };
        mResidentLoadThread = std::thread([this, worker, attach, threads, count = files.size()] {
            const auto t0 = std::chrono::steady_clock::now();
            std::vector<std::thread> pool;
            for (int t = 0; t < threads; ++t)
                pool.emplace_back(worker, t);
            for (std::thread& t : pool)
                t.join();
            attach->mDone = true;
            mResidentLoadActive = false;
            Log(Debug::Info) << "Distant statics resident: " << count << " supercells loaded in "
                             << std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() << "s";
        });
        Log(Debug::Info) << "Distant statics: loading " << files.size() << " supercells in the background (" << threads
                         << " threads)";
        return static_cast<unsigned int>(files.size());
    }

    namespace
    {
        // Swaps regenerated supercells into the resident root on the update
        // traversal: the old child of the same name is dropped, the new node
        // (null when the supercell became empty) is added.
        class ResidentSwapCallback : public SceneUtil::NodeCallback<ResidentSwapCallback, osg::Group*>
        {
        public:
            std::mutex mMutex;
            std::vector<std::pair<std::string, osg::ref_ptr<osg::Node>>> mPending;
            std::atomic<bool> mDone{ false };

            void operator()(osg::Group* node, osg::NodeVisitor* nv)
            {
                {
                    std::lock_guard<std::mutex> lock(mMutex);
                    for (const auto& [name, replacement] : mPending)
                    {
                        for (unsigned int i = node->getNumChildren(); i > 0; --i)
                            if (node->getChild(i - 1)->getName() == name)
                                node->removeChild(i - 1);
                        if (replacement)
                            node->addChild(replacement);
                    }
                    mPending.clear();
                }
                if (mDone.load() && node->getUpdateCallback() == this)
                    node->removeUpdateCallback(this);
                traverse(node, nv);
            }
        };
    }

    void ObjectPaging::refreshResidentSupercells(
        const RefStateMap& refStates, const std::filesystem::path& dir, osg::Group* root)
    {
        if (!mResidentDistantStatics.load())
            return;
        if (mResidentRefreshActive.exchange(true))
        {
            Log(Debug::Warning) << "Distant statics: save-state refresh already running, skipping";
            return;
        }
        if (mResidentRefreshThread.joinable())
            mResidentRefreshThread.join(); // previous refresh fully retired

        // supercell list = the sidecars the bake produced (empty ones included,
        // so a save re-enabling refs in a bare supercell still gets caught)
        std::vector<osg::Vec2i> cells;
        std::error_code ec;
        for (const auto& entry : std::filesystem::directory_iterator(dir, ec))
        {
            int x, y;
            if (entry.path().extension() == ".state"
                && std::sscanf(entry.path().stem().string().c_str(), "dl_%d_%d", &x, &y) == 2)
                cells.emplace_back(x, y);
        }
        if (cells.empty())
        {
            mResidentRefreshActive = false;
            return;
        }

        Log(Debug::Info) << "Distant statics: save-state refresh over " << cells.size() << " supercells ("
                         << refStates.size() << " save-touched refs)";

        mResidentRefreshThread = std::thread([this, refStates, dir, cells = std::move(cells)] {
            // the initial resident load and this refresh contend for the
            // osgDB registry lock and the same cores, so let the load finish
            // first (it is the user-visible one)
            while (mResidentLoadActive.load() && !mResidentShutdown.load())
                std::this_thread::sleep_for(std::chrono::milliseconds(500));
            const auto t0 = std::chrono::steady_clock::now();
            unsigned int rebuilt = 0;
            for (const osg::Vec2i& cell : cells)
            {
                if (mResidentShutdown.load())
                    break;
                bool written = false;
                try
                {
                    generateSupercell(cell, dir, refStates, written);
                }
                catch (const std::exception& e)
                {
                    Log(Debug::Error) << "Distant statics refresh: supercell " << cell.x() << "," << cell.y()
                                      << " failed: " << e.what();
                    continue;
                }
                if (!written)
                    continue; // hash matched the sidecar, supercell unaffected by this save
                ++rebuilt;
                const int ringCells[3] = { Settings::terrain().mDistantStaticsNearRingCells,
                    Settings::terrain().mDistantStaticsFarRingCells,
                    Settings::terrain().mDistantStaticsVeryFarRingCells };
                for (int k = 0; k < 3; ++k)
                {
                    char namebuf[64];
                    std::snprintf(namebuf, sizeof(namebuf), "dl_%d_%d%s", cell.x(), cell.y(), sClassName[k]);
                    // swap only what is attached: globally-resident classes
                    // always, ring classes only while inside the ring
                    if (ringCells[k] > 0 && !isRingLoaded(namebuf))
                        continue;
                    const std::filesystem::path file = dir
                        / (std::string("dl_") + std::to_string(cell.x()) + "_" + std::to_string(cell.y())
                            + sClassSuffix[k]);
                    osg::ref_ptr<osg::Node> node;
                    std::error_code fec;
                    if (std::filesystem::exists(file, fec))
                    {
                        node = readSupercellFlat(file);
                        if (node)
                            node->setName(namebuf);
                    }
                    queueRingSwap(namebuf, node);
                }
            }
            mResidentRefreshActive = false;
            Log(Debug::Info) << "Distant statics: save-state refresh done, " << rebuilt << " supercells rebuilt in "
                             << std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() << "s";
        });
    }

    void ObjectPaging::queueRingSwap(const std::string& name, osg::ref_ptr<osg::Node> node)
    {
        std::lock_guard<std::mutex> lock(mRingMutex);
        mRingSwaps.emplace_back(name, std::move(node));
    }

    bool ObjectPaging::isRingLoaded(const std::string& name)
    {
        std::lock_guard<std::mutex> lock(mRingMutex);
        return mRingLoaded.find(name) != mRingLoaded.end();
    }

    void ObjectPaging::drainRingSwaps(osg::Group* root)
    {
        std::vector<std::pair<std::string, osg::ref_ptr<osg::Node>>> swaps;
        {
            std::lock_guard<std::mutex> lock(mRingMutex);
            swaps.swap(mRingSwaps);
        }
        for (const auto& [name, replacement] : swaps)
        {
            for (unsigned int i = root->getNumChildren(); i > 0; --i)
                if (root->getChild(i - 1)->getName() == name)
                    root->removeChild(i - 1);
            if (replacement)
                root->addChild(replacement);
        }
    }

    void ObjectPaging::updateResidentRings(const osg::Vec3f& eye)
    {
        if (!mResidentDistantStatics.load() || mResidentDir.empty())
            return;
        const float cellSize = static_cast<float>(getCellSize(mWorldspace));
        const int superSize = sSupercellSize;
        const int pcx = static_cast<int>(std::floor(eye.x() / cellSize));
        const int pcy = static_cast<int>(std::floor(eye.y() / cellSize));
        const osg::Vec2i playerCell(pcx, pcy);
        if (playerCell == mRingCenter)
            return;
        mRingCenter = playerCell;

        const int ringCells[3] = { Settings::terrain().mDistantStaticsNearRingCells,
            Settings::terrain().mDistantStaticsFarRingCells, Settings::terrain().mDistantStaticsVeryFarRingCells };
        char namebuf[64];
        bool queued = false;
        std::lock_guard<std::mutex> lock(mRingMutex);
        // rings must never be outrun by the live viewing distance
        const int viewCells = static_cast<int>(std::ceil(Settings::camera().mViewingDistance / cellSize)) + superSize;
        for (int k = 0; k < 3; ++k)
        {
            const int r = ringCells[k] <= 0 ? 0 : std::max(ringCells[k], viewCells);
            if (r <= 0)
                continue; // globally resident, not ring-managed
            // load pass: supercells whose cell interval overlaps the ring
            const int sx0 = static_cast<int>(std::floor(static_cast<float>(pcx - r) / superSize)) * superSize;
            const int sy0 = static_cast<int>(std::floor(static_cast<float>(pcy - r) / superSize)) * superSize;
            for (int sx = sx0; sx <= pcx + r; sx += superSize)
                for (int sy = sy0; sy <= pcy + r; sy += superSize)
                {
                    std::snprintf(namebuf, sizeof(namebuf), "dl_%d_%d%s", sx, sy, sClassName[k]);
                    if (mRingLoaded.emplace(namebuf, std::make_pair(osg::Vec2i(sx, sy), k)).second)
                    {
                        mRingLoadQueue.emplace_back(osg::Vec2i(sx, sy), k);
                        queued = true;
                    }
                }
        }
        // unload pass: one supercell of hysteresis so cell-boundary dithering
        // does not thrash loads
        for (auto it = mRingLoaded.begin(); it != mRingLoaded.end();)
        {
            const auto& [cell, k] = it->second;
            const int r = (ringCells[k] <= 0 ? 0 : std::max(ringCells[k], viewCells)) + superSize;
            if (cell.x() + superSize - 1 < pcx - r || cell.x() > pcx + r || cell.y() + superSize - 1 < pcy - r || cell.y() > pcy + r)
            {
                mRingSwaps.emplace_back(it->first, nullptr);
                it = mRingLoaded.erase(it);
            }
            else
                ++it;
        }
        if (!queued)
            return;
        Log(Debug::Verbose) << "Distant statics rings: " << mRingLoadQueue.size() << " class files queued around cell "
                            << pcx << "," << pcy << " (" << mRingLoaded.size() << " resident)";
        if (!mRingThread.joinable())
        {
            mRingThread = std::thread([this] {
                std::unique_lock<std::mutex> lock(mRingMutex);
                while (!mResidentShutdown.load())
                {
                    if (mRingLoadQueue.empty())
                    {
                        mRingCv.wait(lock);
                        continue;
                    }
                    const auto [cell, k] = mRingLoadQueue.front();
                    mRingLoadQueue.pop_front();
                    char name[64];
                    std::snprintf(name, sizeof(name), "dl_%d_%d%s", cell.x(), cell.y(), sClassName[k]);
                    if (mRingLoaded.find(name) == mRingLoaded.end())
                        continue; // unloaded while queued
                    lock.unlock();
                    const std::filesystem::path file = mResidentDir
                        / ("dl_" + std::to_string(cell.x()) + "_" + std::to_string(cell.y()) + sClassSuffix[k]);
                    osg::ref_ptr<osg::Node> node;
                    std::error_code fec;
                    if (std::filesystem::exists(file, fec))
                    {
                        node = readSupercellFlat(file);
                        if (node)
                            node->setName(name);
                    }
                    lock.lock();
                    // re-check: may have left the ring during the read
                    if (node && mRingLoaded.find(name) != mRingLoaded.end())
                        mRingSwaps.emplace_back(name, node);
                }
            });
        }
        mRingCv.notify_one();
    }

    unsigned int ObjectPaging::getNodeMask()
    {
        return Mask_Static;
    }

    namespace
    {
        osg::Vec2f clampToCell(const osg::Vec3f& cellPos, const osg::Vec2i& cell)
        {
            return osg::Vec2f(std::clamp(cellPos.x(), static_cast<float>(cell.x()), cell.x() + 1.f),
                std::clamp(cellPos.y(), static_cast<float>(cell.y()), cell.y() + 1.f));
        }

        class CollectIntersecting
        {
        public:
            explicit CollectIntersecting(
                bool activeGridOnly, const osg::Vec3f& position, const osg::Vec2i& cell, ESM::RefId worldspace)
                : mActiveGridOnly(activeGridOnly)
                , mPosition(clampToCell(position / static_cast<float>(getCellSize(worldspace)), cell))
            {
            }

            void operator()(const ChunkId& id, osg::Object* /*obj*/)
            {
                if (mActiveGridOnly && !std::get<2>(id))
                    return;
                if (intersects(id))
                    mCollected.push_back(id);
            }

            const std::vector<ChunkId>& getCollected() const { return mCollected; }

        private:
            bool intersects(ChunkId id) const
            {
                const osg::Vec2f center = std::get<0>(id);
                const float halfSize = std::get<1>(id) / 2;
                return mPosition.x() >= center.x() - halfSize && mPosition.y() >= center.y() - halfSize
                    && mPosition.x() <= center.x() + halfSize && mPosition.y() <= center.y() + halfSize;
            }

            bool mActiveGridOnly;
            osg::Vec2f mPosition;
            std::vector<ChunkId> mCollected;
        };
    }

    bool ObjectPaging::enableObject(
        int type, ESM::RefNum refnum, const osg::Vec3f& pos, const osg::Vec2i& cell, bool enabled)
    {
        if (!typeFilter(type, false))
            return false;

        {
            std::lock_guard<std::mutex> lock(mRefTrackerMutex);
            if (enabled && !getWritableRefTracker().mDisabled.erase(refnum))
                return false;
            if (!enabled && !getWritableRefTracker().mDisabled.emplace(refnum, cell).second)
                return false;
            if (mRefTrackerLocked)
                return false;
        }

        CollectIntersecting ccf(false, pos, cell, mWorldspace);
        mCache->call(ccf);
        if (ccf.getCollected().empty())
            return false;
        for (const ChunkId& chunk : ccf.getCollected())
            mCache->removeFromObjectCache(chunk);
        return true;
    }

    bool ObjectPaging::blacklistObject(int type, ESM::RefNum refnum, const osg::Vec3f& pos, const osg::Vec2i& cell)
    {
        if (!typeFilter(type, false))
            return false;

        {
            std::lock_guard<std::mutex> lock(mRefTrackerMutex);
            if (!getWritableRefTracker().mBlacklist.insert(refnum).second)
                return false;
            if (mRefTrackerLocked)
                return false;
        }

        CollectIntersecting ccf(true, pos, cell, mWorldspace);
        mCache->call(ccf);
        if (ccf.getCollected().empty())
            return false;
        for (const ChunkId& chunk : ccf.getCollected())
            mCache->removeFromObjectCache(chunk);
        return true;
    }

    void ObjectPaging::clear()
    {
        std::lock_guard<std::mutex> lock(mRefTrackerMutex);
        mRefTrackerNew.mDisabled.clear();
        mRefTrackerNew.mBlacklist.clear();
        mRefTrackerLocked = true;
    }

    bool ObjectPaging::unlockCache()
    {
        if (!mRefTrackerLocked)
            return false;
        {
            std::lock_guard<std::mutex> lock(mRefTrackerMutex);
            mRefTrackerLocked = false;
            if (mRefTracker == mRefTrackerNew)
                return false;
            else
                mRefTracker = mRefTrackerNew;
        }
        mCache->clear();
        return true;
    }

    namespace
    {
        struct GetRefnumsFunctor
        {
            GetRefnumsFunctor(std::vector<ESM::RefNum>& output)
                : mOutput(output)
            {
            }
            void operator()(MWRender::ChunkId chunkId, osg::Object* obj)
            {
                if (!std::get<2>(chunkId))
                    return;
                const osg::Vec2f& center = std::get<0>(chunkId);
                const bool activeGrid = (center.x() > mActiveGrid.x() || center.y() > mActiveGrid.y()
                    || center.x() < mActiveGrid.z() || center.y() < mActiveGrid.w());
                if (!activeGrid)
                    return;

                osg::UserDataContainer* udc = obj->getUserDataContainer();
                if (udc && udc->getNumUserObjects())
                {
                    RefnumSet* refnums = dynamic_cast<RefnumSet*>(udc->getUserObject(0));
                    if (!refnums)
                        return;
                    mOutput.insert(mOutput.end(), refnums->mRefnums.begin(), refnums->mRefnums.end());
                }
            }
            osg::Vec4i mActiveGrid;
            std::vector<ESM::RefNum>& mOutput;
        };
    }

    void ObjectPaging::getPagedRefnums(const osg::Vec4i& activeGrid, std::vector<ESM::RefNum>& out)
    {
        GetRefnumsFunctor grf(out);
        grf.mActiveGrid = activeGrid;
        mCache->call(grf);
        std::sort(out.begin(), out.end());
        out.erase(std::unique(out.begin(), out.end()), out.end());
    }

    void ObjectPaging::reportStats(unsigned int frameNumber, osg::Stats* stats) const
    {
        Resource::reportStats("Object Chunk", frameNumber, mCache->getStats(), *stats);
    }

}
