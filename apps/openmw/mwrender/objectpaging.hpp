#ifndef OPENMW_MWRENDER_OBJECTPAGING_H
#define OPENMW_MWRENDER_OBJECTPAGING_H

#include <atomic>
#include <chrono>
#include <climits>
#include <components/esm3/refnum.hpp>
#include <components/resource/resourcemanager.hpp>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <map>
#include <thread>

#include <components/terrain/quadtreeworld.hpp>

#include <osg/LOD>
#include <osg/ref_ptr>

#include <mutex>

namespace Resource
{
    class SceneManager;
    class TemplateMultiRef;
}

namespace SceneUtil
{
    class OcclusionCuller;
}

namespace MWRender
{

    typedef std::tuple<osg::Vec2f, float, bool> ChunkId; // Center, Size, ActiveGrid

    class ObjectPaging : public Resource::GenericResourceManager<ChunkId>, public Terrain::QuadTreeWorld::ChunkManager
    {
    public:
        ObjectPaging(Resource::SceneManager* sceneManager, ESM::RefId worldspace);
        ~ObjectPaging();

        osg::ref_ptr<osg::Node> getChunk(float size, const osg::Vec2f& center, unsigned char lod, unsigned int lodFlags,
            bool activeGrid, const osg::Vec3f& viewPoint, bool compile) override;

        osg::ref_ptr<osg::Node> createChunk(float size, const osg::Vec2f& center, bool activeGrid,
            const osg::Vec3f& viewPoint, bool compile, unsigned char lod);

        unsigned int getNodeMask() override;

        /// @return true if view needs rebuild
        bool enableObject(int type, ESM::RefNum refnum, const osg::Vec3f& pos, const osg::Vec2i& cell, bool enabled);

        /// @return true if view needs rebuild
        bool blacklistObject(int type, ESM::RefNum refnum, const osg::Vec3f& pos, const osg::Vec2i& cell);

        void clear();

        /// Must be called after clear() before rendering starts.
        /// @return true if view needs rebuild
        bool unlockCache();

        void reportStats(unsigned int frameNumber, osg::Stats* stats) const override;

        void getPagedRefnums(const osg::Vec4i& activeGrid, std::vector<ESM::RefNum>& out);

        void setOcclusionCuller(SceneUtil::OcclusionCuller* culler, unsigned int maxTriangles);

        // Chunk disk cache
        std::filesystem::path diskCachePath(const ChunkId& id);
        osg::ref_ptr<osg::Node> readCachedChunk(
            const std::filesystem::path& file, bool compile, bool raw = false, bool attachOcclusion = true);
        void writeCachedChunk(osg::Node* node, const std::filesystem::path& file, bool pruneSiblingVariants = true);
        // Deferred coalescing background writes: a chunk rebuilt repeatedly
        // during script disable-storms produces one final write, off the
        // chunk-delivery path.
        void enqueueCachedChunkWrite(osg::Node* node, const std::filesystem::path& file);
        // Block until every queued chunk write has hit disk (generation
        // mode calls this between lattice points and before exiting).
        void drainWriteQueue();
        // --generate-distant-land runs may supersede a mismatched generation
        // (MGE regenerate semantics); normal sessions go read-only.
        static void setGenerationMode(bool enabled) { sGenerationMode = enabled; }
        // The standalone generator tool injects content files + ESM
        // versions (no MWBase::World exists there).
        static void setStandaloneContext(std::vector<std::string> contentFiles, std::vector<int> esmVersions);
        // Chunk-write failures (disk full etc.) are counted, not swallowed;
        // generation must not report success when writes failed.
        unsigned int getWriteFailureCount() const { return mWriteFailures.load(); }

        // mge-exact: single-layer distant statics. One merged, class-grouped
        // (near/far/very far) LOD node per SIZExSIZE-cell supercell, written
        // once and loaded resident for the whole session. refStates carries a
        // save's enabled/moved overrides (empty = pure ESM world).
        struct RefStateOverride
        {
            bool mEnabled = true;
            bool mMoved = false;
            osg::Vec3f mPosition;
        };
        using RefStateMap = std::map<ESM::RefNum, RefStateOverride>;
        static constexpr int sSupercellSize = 4; // cells per side
        // returns the state hash of the supercell's refs; writes the mesh
        // file + .state sidecar unless the existing sidecar already matches
        // (that skip is the tier-2 incremental refresh).
        std::uint64_t generateSupercell(const osg::Vec2i& startCell, const std::filesystem::path& outDir,
            const RefStateMap& refStates, bool& outWritten);
        // phase 2: load every supercell once, attach progressively under
        // root (update-thread-safe), suppress paged distant chunks. Returns
        // the number of mesh files scheduled.
        /// MWDS flat supercell format: memcpy-speed reads, no osgDB
        bool writeSupercellFlat(const osg::Vec3f& worldCenter,
            const std::vector<std::pair<osg::ref_ptr<osg::Group>, int>>& blocks, const std::filesystem::path& file);
        osg::ref_ptr<osg::Node> readSupercellFlat(const std::filesystem::path& file);
        unsigned int loadDistantStaticsResident(const std::filesystem::path& dir, osg::Group* root);
        /// Tier-2 reactivity: recompute every supercell's state hash against the
        /// given save state, regenerate stale ones in the background and hot-swap
        /// them into the resident root. No-op while a previous refresh runs.
        void refreshResidentSupercells(
            const RefStateMap& refStates, const std::filesystem::path& dir, osg::Group* root);
        std::atomic<bool> mResidentDistantStatics{ false };
        std::atomic<bool> mResidentLoadActive{ false };
        std::atomic<bool> mResidentShutdown{ false };
        std::thread mResidentLoadThread;
        std::thread mResidentRefreshThread;

        /// Residency rings: near/far class files are held in memory only
        /// within a ring of cells around the player (MGE only ever rendered
        /// them close by); very-far landmarks stay globally resident.
        void updateResidentRings(const osg::Vec3f& eye);
        void drainRingSwaps(osg::Group* root);
        void queueRingSwap(const std::string& name, osg::ref_ptr<osg::Node> node);
        bool isRingLoaded(const std::string& name);
        std::thread mRingThread;
        std::mutex mRingMutex;
        std::condition_variable mRingCv;
        std::deque<std::pair<osg::Vec2i, int>> mRingLoadQueue;
        std::map<std::string, std::pair<osg::Vec2i, int>> mRingLoaded;
        std::vector<std::pair<std::string, osg::ref_ptr<osg::Node>>> mRingSwaps;
        osg::Vec2i mRingCenter{ INT_MAX, INT_MAX };
        std::filesystem::path mResidentDir;
        std::atomic<bool> mResidentRefreshActive{ false };

        // All non-activeGrid chunk production (disk read or live build) is
        // asynchronous: requesters get an instant placeholder Group whose
        // content swaps in via update callback when a producer thread
        // finishes. The render path never does IO or merging, and the
        // loading screen does not gate on distant object chunks.
        class ChunkSwapCallback;
        struct PendingChunkLoad
        {
            ChunkId mId;
            std::filesystem::path mFile; // empty = no disk cache
            float mSize;
            osg::Vec2f mCenter;
            osg::Vec3f mViewPoint;
            unsigned char mLod;
            osg::ref_ptr<osg::Group> mPlaceholder;
        };

    private:
        Resource::SceneManager* mSceneManager;
        std::filesystem::path mDiskCacheDir;
        std::once_flag mDiskCacheInit;
        // set when the generation manifest mismatches: serve but never write
        bool mDiskCacheReadOnly = false;
        static inline bool sGenerationMode = false;

        // Write queue: keyed by chunk coordinate prefix (filename minus
        // disabled-state salt) so a newer state variant supersedes a queued
        // older one. Guarded by mWriteQueueMutex.
        struct PendingChunkWrite
        {
            osg::ref_ptr<osg::Node> mNode;
            std::filesystem::path mFile;
            std::chrono::steady_clock::time_point mDue;
        };
        std::mutex mWriteQueueMutex;
        std::condition_variable mWriteQueueCv;
        std::condition_variable mWriteQueueDrainCv;
        std::map<std::string, PendingChunkWrite> mWriteQueue;
        std::thread mWriteThread;
        bool mWriteThreadStop = false;
        bool mWriteBusy = false;
        std::atomic<unsigned int> mWriteFailures{ 0 };

        // Template-level distant mesh simplification cache. One decimated
        // variant per (template, ratio), shared by every chunk that merges
        // the template. The entry pins the original template alongside the
        // simplified copy, so pointer identity stays valid and unique
        // across resource-cache clears.
        std::mutex mSimplifiedTemplatesMutex;
        std::map<std::pair<const osg::Node*, float>, std::pair<osg::ref_ptr<const osg::Node>, osg::ref_ptr<osg::Node>>>
            mSimplifiedTemplates;
        const osg::Node* getSimplifiedTemplate(
            const osg::Node* node, float ratio, Resource::TemplateMultiRef& templateRefs);

        // async chunk production
        void enqueueChunkLoad(PendingChunkLoad&& job);
        void chunkLoadWorker();
        std::mutex mLoadQueueMutex;
        std::condition_variable mLoadQueueCv;
        std::condition_variable mLoadQueueDrainCv;
        std::multimap<float, PendingChunkLoad> mLoadQueue; // key: distance (nearest first)
        std::vector<std::thread> mLoadThreads;
        unsigned int mLoadBusy = 0;
        bool mLoadThreadsStop = false;
        osg::ref_ptr<SceneUtil::OcclusionCuller> mOcclusionCuller;
        unsigned int mMaxTriangles = 30000;
        bool mActiveGrid;
        bool mDebugBatches;
        float mMergeFactor;
        float mMinSize;
        float mMinSizeMergeFactor;
        float mMinSizeCostMultiplier;

        std::mutex mRefTrackerMutex;
        struct RefTracker
        {
            // value = cell index: lets the disk cache salt chunk filenames
            // with the disabled-state relevant to that chunk's bounds
            std::map<ESM::RefNum, osg::Vec2i> mDisabled;
            std::set<ESM::RefNum> mBlacklist;
            bool operator==(const RefTracker& other) const
            {
                return mDisabled == other.mDisabled && mBlacklist == other.mBlacklist;
            }
        };
        RefTracker mRefTracker;
        RefTracker mRefTrackerNew;
        bool mRefTrackerLocked;

        const RefTracker& getRefTracker() const { return mRefTracker; }
        RefTracker& getWritableRefTracker() { return mRefTrackerLocked ? mRefTrackerNew : mRefTracker; }

        std::mutex mSizeCacheMutex;
        typedef std::map<ESM::RefNum, float> SizeCache;
        SizeCache mSizeCache;

        std::mutex mLODNameCacheMutex;
        typedef std::pair<std::string, unsigned char> LODNameCacheKey; // Key: mesh name, lod level
        using LODNameCache = std::map<LODNameCacheKey, VFS::Path::Normalized>; // Cache: key, mesh name to use
        LODNameCache mLODNameCache;
    };

    class RefnumMarker : public osg::Object
    {
    public:
        RefnumMarker()
            : mNumVertices(0)
        {
        }
        RefnumMarker(const RefnumMarker& copy, osg::CopyOp co)
            : mRefnum(copy.mRefnum)
            , mNumVertices(copy.mNumVertices)
        {
        }
        META_Object(MWRender, RefnumMarker)

        ESM::RefNum mRefnum;
        unsigned int mNumVertices;
    };
}

#endif
