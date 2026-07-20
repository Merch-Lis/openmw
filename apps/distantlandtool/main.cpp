// openmw-distantlandtool: standalone generator for distant-land (object
// paging) chunks. A pure batch tool with no game boot, window, or frame
// clock. It walks the same quadtree structure the game builds and produces
// chunks through the game's own ObjectPaging code, so the output is
// identical to what a live session would generate.

#include <components/debug/debugging.hpp>
#include <components/debug/debuglog.hpp>
#include <components/esm/refid.hpp>
#include <components/esm3/loadcell.hpp>
#include <components/esm3/loadland.hpp>
#include <components/esm3/readerscache.hpp>
#include <components/fallback/fallback.hpp>
#include <components/fallback/validate.hpp>
#include <components/files/collections.hpp>
#include <components/files/configurationmanager.hpp>
#include <components/files/conversion.hpp>
#include <components/misc/mathutil.hpp>
#include <components/misc/pathhelpers.hpp>
#include <components/misc/strings/algorithm.hpp>
#include <components/platform/platform.hpp>
#include <components/resource/bgsmfilemanager.hpp>
#include <components/resource/imagemanager.hpp>
#include <components/resource/niffilemanager.hpp>
#include <components/resource/scenemanager.hpp>
#include <components/sceneutil/lightmanager.hpp>
#include <components/sceneutil/shadow.hpp>
#include <components/settings/settings.hpp>
#include <components/settings/values.hpp>
#include <components/shader/shadermanager.hpp>
#include <components/toutf8/toutf8.hpp>
#include <components/version/version.hpp>
#include <components/vfs/manager.hpp>
#include <components/vfs/registerarchives.hpp>

#include "apps/openmw/mwbase/environment.hpp"
#include "apps/openmw/mwrender/objectpaging.hpp"
#include "apps/openmw/mwworld/esmloader.hpp"
#include "apps/openmw/mwworld/esmstore.hpp"

#include <boost/program_options.hpp>

#include <cmath>
#include <filesystem>
#include <iostream>
#include <set>
#include <vector>

namespace
{
    namespace bpo = boost::program_options;

    using StringsVector = std::vector<std::string>;

    constexpr std::string_view applicationName = "openmw-distantlandtool";

    bpo::options_description makeOptionsDescription()
    {
        bpo::options_description result;
        auto addOption = result.add_options();
        addOption("help", "print help message");
        addOption("distant-statics", "generate mge-exact single-layer distant statics instead of chunk cache");
        addOption("data",
            bpo::value<Files::MaybeQuotedPathContainer>()
                ->default_value(Files::MaybeQuotedPathContainer(), "data")
                ->multitoken()
                ->composing(),
            "set data directories (later directories have higher priority)");
        addOption("data-local",
            bpo::value<Files::MaybeQuotedPathContainer::value_type>()->default_value(
                Files::MaybeQuotedPathContainer::value_type(), ""),
            "set local data directory (highest priority)");
        addOption("fallback-archive",
            bpo::value<StringsVector>()->default_value(StringsVector(), "fallback-archive")->multitoken()->composing(),
            "set fallback BSA archives (later archives have higher priority)");
        addOption("content", bpo::value<StringsVector>()->default_value(StringsVector(), "")->multitoken()->composing(),
            "content file(s): esm/esp, or omwgame/omwaddon/omwscripts");
        addOption("encoding", bpo::value<std::string>()->default_value("win1252"), "character encoding");
        addOption("fallback",
            bpo::value<Fallback::FallbackMap>()->default_value(Fallback::FallbackMap(), "")->multitoken()->composing(),
            "fallback values");
        Files::ConfigurationManager::addCommonOptions(result);
        return result;
    }

    // Mirrors MGEgui's ContentLoader usage via World::loadContentFiles,
    // minus the game: fills the full MWWorld::ESMStore + per-content ESM
    // versions that ObjectPaging's LOD mesh-name selection needs.
    struct LoadedContent
    {
        MWWorld::ESMStore mStore;
        ESM::ReadersCache mReaders;
        std::vector<int> mESMVersions;
    };

    void loadContent(LoadedContent& out, const Files::Collections& fileCollections, const StringsVector& content,
        ToUTF8::Utf8Encoder* encoder)
    {
        out.mESMVersions.assign(content.size(), -1);
        MWWorld::EsmLoader esmLoader(out.mStore, out.mReaders, encoder, out.mESMVersions);
        int idx = 0;
        for (const std::string& file : content)
        {
            const auto extension = Misc::getFileExtension(file);
            if (extension == "omwscripts")
            {
                // scripts are irrelevant to statics; versions stay -1
                ++idx;
                continue;
            }
            const Files::MultiDirCollection& col = fileCollections.getCollection(Misc::getFileExtension(file));
            if (!col.doesExist(file))
                throw std::runtime_error("content file does not exist: " + file);
            esmLoader.load(col.getPath(file), idx, nullptr);
            ++idx;
        }
        out.mStore.setUp();
        out.mStore.validateRecords(out.mReaders);
    }

    // Exterior land bounds in cell units (replicates
    // MWRender::TerrainStorage::getBounds against the store).
    void getLandBounds(const MWWorld::ESMStore& store, float& minX, float& maxX, float& minY, float& maxY)
    {
        minX = 0.f;
        minY = 0.f;
        maxX = 0.f;
        maxY = 0.f;
        for (const ESM::Land& land : store.get<ESM::Land>())
        {
            minX = std::min(minX, static_cast<float>(land.mX));
            maxX = std::max(maxX, static_cast<float>(land.mX + 1));
            minY = std::min(minY, static_cast<float>(land.mY));
            maxY = std::max(maxY, static_cast<float>(land.mY + 1));
        }
    }

    // Replicates components/terrain/quadtreeworld.cpp: QuadTreeBuilder root
    // construction, DefaultLodCallback band selection, and getVertexLod.
    // Node coordinates follow the same arithmetic as the game's builder.
    // The walk is a superset of the game's (no land-validity pruning);
    // superfluous nodes produce empty chunks that are simply not written.
    struct NodeSelector
    {
        float mMinSize;
        float mLodFactor;
        float mViewDistance;
        float mCellWorldSize;
        int mVertexLodMod;

        static unsigned int log2u(unsigned int value)
        {
            unsigned int result = 0;
            while (value >> (result + 1))
                ++result;
            return result;
        }

        unsigned int nativeLodLevel(float size) const { return log2u(static_cast<unsigned int>(size / mMinSize)); }

        unsigned int distanceLodLevel(float dist) const
        {
            return log2u(static_cast<unsigned int>(dist / (mCellWorldSize * mMinSize * mLodFactor)));
        }

        unsigned int vertexLod(float size) const
        {
            unsigned int lod = log2u(static_cast<unsigned int>(size));
            if (mVertexLodMod > 0)
                lod = static_cast<unsigned int>(std::max(0, static_cast<int>(lod) - mVertexLodMod));
            else if (mVertexLodMod < 0)
            {
                int mod = mVertexLodMod;
                float s = size;
                while (s < 1)
                {
                    s *= 2;
                    mod = std::min(0, mod + 1);
                }
                lod += static_cast<unsigned int>(std::abs(mod));
            }
            return lod;
        }

        // distance from viewpoint to node rect (cell units -> world units)
        float nodeDistance(const osg::Vec3f& viewPoint, float centerX, float centerY, float size) const
        {
            const float half = size / 2.f * mCellWorldSize;
            const float cx = centerX * mCellWorldSize;
            const float cy = centerY * mCellWorldSize;
            const float dx = std::max(0.f, std::abs(viewPoint.x() - cx) - half);
            const float dy = std::max(0.f, std::abs(viewPoint.y() - cy) - half);
            return std::sqrt(dx * dx + dy * dy + viewPoint.z() * viewPoint.z());
        }

        template <class Fn>
        void select(const osg::Vec3f& viewPoint, float centerX, float centerY, float size, const Fn& fn) const
        {
            const float dist = nodeDistance(viewPoint, centerX, centerY, size);
            if (dist > mViewDistance)
                return;
            if (nativeLodLevel(size) <= distanceLodLevel(dist) || size <= mMinSize)
            {
                fn(centerX, centerY, size);
                return;
            }
            const float half = size / 4.f; // child offset
            const float childSize = size / 2.f;
            select(viewPoint, centerX - half, centerY - half, childSize, fn);
            select(viewPoint, centerX + half, centerY - half, childSize, fn);
            select(viewPoint, centerX - half, centerY + half, childSize, fn);
            select(viewPoint, centerX + half, centerY + half, childSize, fn);
        }
    };

    int runTool(int argc, char* argv[])
    {
        Platform::init();

        bpo::options_description desc = makeOptionsDescription();
        bpo::parsed_options options = bpo::command_line_parser(argc, argv).options(desc).allow_unregistered().run();
        bpo::variables_map variables;
        bpo::store(options, variables);
        bpo::notify(variables);

        if (variables.count("help"))
        {
            std::cout << desc << std::endl;
            return 0;
        }

        Files::ConfigurationManager config;
        config.processPaths(variables, std::filesystem::current_path());
        config.readConfiguration(variables, desc);

        Debug::setupLogging(config.getLogPath(), applicationName);
        Log(Debug::Info) << Version::getOpenmwVersionDescription();

        const std::string encoding(variables["encoding"].as<std::string>());
        ToUTF8::Utf8Encoder encoder(ToUTF8::calculateEncoding(encoding));

        Files::PathContainer dataDirs(asPathContainer(variables["data"].as<Files::MaybeQuotedPathContainer>()));
        auto local = variables["data-local"].as<Files::MaybeQuotedPathContainer::value_type>();
        if (!local.empty())
            dataDirs.push_back(std::move(local));
        config.filterOutNonExistingPaths(dataDirs);

        const auto& resDir = variables["resources"].as<Files::MaybeQuotedPath>();
        dataDirs.insert(dataDirs.begin(), resDir / "vfs");
        const Files::Collections fileCollections(dataDirs);
        const auto& archives = variables["fallback-archive"].as<StringsVector>();
        StringsVector contentFiles{ "builtin.omwscripts" };
        const auto& configContent = variables["content"].as<StringsVector>();
        contentFiles.insert(contentFiles.end(), configContent.begin(), configContent.end());

        Fallback::Map::init(variables["fallback"].as<Fallback::FallbackMap>().mMap);

        VFS::Manager vfs;
        VFS::registerArchives(&vfs, fileCollections, archives, true, &encoder.getStatelessEncoder());

        Settings::Manager::load(config);

        Log(Debug::Info) << "Loading " << contentFiles.size() << " content files...";
        LoadedContent content;
        loadContent(content, fileCollections, contentFiles, &encoder);

        // ObjectPaging reaches the store through the (game-optional)
        // Environment, and gets content list + ESM versions injected.
        MWBase::Environment environment;
        environment.setESMStore(content.mStore);
        MWRender::ObjectPaging::setStandaloneContext(contentFiles, content.mESMVersions);
        MWRender::ObjectPaging::setGenerationMode(true); // may supersede a mismatched manifest

        constexpr double expiryDelay = 0;
        Resource::ImageManager imageManager(&vfs, expiryDelay);
        Resource::NifFileManager nifFileManager(&vfs, &encoder.getStatelessEncoder());
        Resource::BgsmFileManager bgsmFileManager(&vfs, expiryDelay);
        Resource::SceneManager sceneManager(&vfs, &imageManager, &nifFileManager, &bgsmFileManager, expiryDelay);
        // Templates get the same shader treatment as in-game (so serialized
        // state matches game-built chunks); the shader sources live under
        // the resources dir, same as the engine wires it.
        sceneManager.setShaderPath(resDir / "shaders");
        // Seed the global shader defines the engine seeds (shader sources
        // reference them unconditionally; without a LightManager/Shadow
        // setup the map is empty and shader init fatals on e.g. useUBO).
        {
            osg::ref_ptr<SceneUtil::LightManager> lightDefineSource = new SceneUtil::LightManager;
            Shader::ShaderManager::DefineMap globalDefines = sceneManager.getShaderManager().getGlobalDefines();
            for (const auto& [k, v] : SceneUtil::ShadowManager::getShadowsDisabledDefines())
                globalDefines[k] = v;
            for (const auto& [k, v] : lightDefineSource->getLightDefines())
                globalDefines[k] = v;
            globalDefines["forcePPL"] = Settings::shaders().mForcePerPixelLighting ? "1" : "0";
            globalDefines["clamp"] = Settings::shaders().mClampLighting ? "1" : "0";
            globalDefines["preLightEnv"] = Settings::shaders().mApplyLightingToEnvironmentMaps ? "1" : "0";
            globalDefines["classicFalloff"] = Settings::shaders().mClassicFalloff ? "1" : "0";
            const bool exponentialFog = Settings::fog().mExponentialFog;
            globalDefines["radialFog"] = (exponentialFog || Settings::fog().mRadialFog) ? "1" : "0";
            globalDefines["exponentialFog"] = exponentialFog ? "1" : "0";
            globalDefines["skyBlending"] = Settings::fog().mSkyBlending ? "1" : "0";
            globalDefines["waterRefraction"] = "0";
            globalDefines["useGPUShader4"] = "0";
            globalDefines["reverseZ"] = "0"; // no GL context; value irrelevant, define must exist
            globalDefines["disableNormals"] = "1";
            globalDefines["numViews"] = "1";
            globalDefines["useOVR_multiview"] = "0";
            globalDefines["groundcoverFadeStart"] = "0.0";
            globalDefines["groundcoverFadeEnd"] = "0.0";
            globalDefines["groundcoverStompMode"] = "0";
            globalDefines["groundcoverStompIntensity"] = "0.0";
            globalDefines["distorionRTRatio"] = "0.5"; // postprocessor's (typo'd) define
            sceneManager.getShaderManager().setGlobalDefines(globalDefines);
        }

        MWRender::ObjectPaging paging(&sceneManager, ESM::Cell::sDefaultWorldspaceId);

        float minX, maxX, minY, maxY;
        getLandBounds(content.mStore, minX, maxX, minY, maxY);
        const int origSizeX = static_cast<int>(maxX - minX);
        const int origSizeY = static_cast<int>(maxY - minY);
        const int rootSize = Misc::nextPowerOfTwo(std::max(origSizeX, origSizeY));
        const float rootCenterX = (minX + maxX) / 2.f + (rootSize - origSizeX) / 2.f;
        const float rootCenterY = (minY + maxY) / 2.f + (rootSize - origSizeY) / 2.f;
        Log(Debug::Info) << "Land bounds [" << minX << "," << minY << "]..[" << maxX << "," << maxY
                         << "], quadtree root " << rootSize << " @ (" << rootCenterX << "," << rootCenterY << ")";

        NodeSelector selector;
        selector.mMinSize = Settings::terrain().mObjectPagingMinSize; // node granularity floor for object chunks
        selector.mLodFactor = Settings::terrain().mLodFactor;
        selector.mViewDistance = Settings::camera().mViewingDistance;
        selector.mCellWorldSize = static_cast<float>(ESM::getCellSize(ESM::Cell::sDefaultWorldspaceId));
        selector.mVertexLodMod = Settings::terrain().mVertexLodMod;
        // The game's quadtree leaves bottom out at [Terrain] "object paging
        // min size"-independent terrain minSize (0.25 default via lod
        // settings); object chunks are requested down to sub-cell sizes.
        // Use the same effective floor the engine's traversal produces:
        const float nodeMinSize = 0.125f;
        selector.mMinSize = nodeMinSize;

        // lattice of viewpoints, same spacing + ocean skip as the in-engine
        // generator
        constexpr int spacing = 4;
        constexpr int oceanMargin = 8;
        std::set<std::pair<int, int>> definedCells;
        for (auto it = content.mStore.get<ESM::Cell>().extBegin(); it != content.mStore.get<ESM::Cell>().extEnd(); ++it)
            definedCells.emplace(it->getGridX(), it->getGridY());

        struct BakeKey
        {
            float x, y, size;
            bool operator<(const BakeKey& o) const { return std::tie(x, y, size) < std::tie(o.x, o.y, o.size); }
        };
        std::set<BakeKey> baked;

        std::vector<osg::Vec3f> lattice;
        for (int y = static_cast<int>(minY); y <= static_cast<int>(maxY); y += spacing)
        {
            for (int x = static_cast<int>(minX); x <= static_cast<int>(maxX); x += spacing)
            {
                bool nearLand = false;
                for (int cy = y - oceanMargin; cy <= y + oceanMargin && !nearLand; ++cy)
                    for (int cx = x - oceanMargin; cx <= x + oceanMargin && !nearLand; ++cx)
                        if (definedCells.count({ cx, cy }))
                            nearLand = true;
                if (nearLand)
                    lattice.emplace_back(
                        (x + 0.5f) * selector.mCellWorldSize, (y + 0.5f) * selector.mCellWorldSize, 8192.f);
            }
        }
        Log(Debug::Info) << "Distant land generation: cells [" << minX << "," << minY << "]..[" << maxX << "," << maxY
                         << "], " << lattice.size() << " lattice points";

        if (variables.count("distant-statics"))
        {
            const std::filesystem::path outDir
                = std::filesystem::path(Settings::terrain().mObjectPagingDiskCacheDir.get()) / "distant-statics";
            const int S = MWRender::ObjectPaging::sSupercellSize;
            const int sx0 = static_cast<int>(std::floor(static_cast<float>(minX) / S)) * S;
            const int sy0 = static_cast<int>(std::floor(static_cast<float>(minY) / S)) * S;
            std::vector<osg::Vec2i> cells;
            for (int x = sx0; x <= maxX; x += S)
                for (int y = sy0; y <= maxY; y += S)
                    cells.emplace_back(x, y);
            Log(Debug::Info) << "Distant statics generation: " << cells.size() << " supercells (" << S << "x" << S
                             << " cells each) -> " << outDir;
            std::size_t sdone = 0, sbuilt = 0, sskipped = 0;
            for (const osg::Vec2i& c : cells)
            {
                bool written = false;
                paging.generateSupercell(c, outDir, {}, written);
                ++sdone;
                (written ? sbuilt : sskipped)++;
                paging.clearCache();
                sceneManager.clearCache();
                if (sdone % 5 == 0 || sdone == cells.size())
                    Log(Debug::Info) << "Distant land generation: " << sdone << "/" << cells.size() << " (built "
                                     << sbuilt << ", resumed-skip " << sskipped << ")";
                if (paging.getWriteFailureCount())
                    break;
            }
            paging.drainWriteQueue();
            if (const unsigned int failures = paging.getWriteFailureCount())
            {
                Log(Debug::Error) << "Distant statics generation FAILED: " << failures
                                  << " writes did not reach disk (out of disk space?).";
                return 1;
            }
            Log(Debug::Info) << "Distant land generation complete: " << sdone << "/" << cells.size() << " supercells, "
                             << sbuilt << " built, " << sskipped << " already current";
            return 0;
        }

        std::size_t done = 0;
        std::size_t built = 0;
        std::size_t skipped = 0;
        for (const osg::Vec3f& viewPoint : lattice)
        {
            selector.select(
                viewPoint, rootCenterX, rootCenterY, static_cast<float>(rootSize), [&](float cx, float cy, float size) {
                    if (!baked.insert(BakeKey{ cx, cy, size }).second)
                        return;
                    const MWRender::ChunkId id = std::make_tuple(osg::Vec2f(cx, cy), size, false);
                    const std::filesystem::path file = paging.diskCachePath(id);
                    if (file.empty())
                        throw std::runtime_error(
                            "no disk cache dir configured ([Terrain] 'object paging disk cache dir')");
                    std::error_code ec;
                    if (std::filesystem::exists(file, ec))
                    {
                        ++skipped; // resume: already baked
                        return;
                    }
                    const unsigned char lod = static_cast<unsigned char>(selector.vertexLod(size));
                    osg::ref_ptr<osg::Node> node
                        = paging.createChunk(size, osg::Vec2f(cx, cy), false, viewPoint, false, lod);
                    if (node && node->getBound().valid())
                    {
                        paging.writeCachedChunk(node.get(), file);
                        ++built;
                    }
                });
            ++done;
            paging.clearCache();
            sceneManager.clearCache();
            Log(Debug::Info) << "Distant land generation: " << done << "/" << lattice.size() << " (built " << built
                             << ", resumed-skip " << skipped << ")";
            // Abort at the first failed write: disk full is not transient,
            // and chunks that cannot be written are wasted work.
            if (paging.getWriteFailureCount())
                break;
        }
        paging.drainWriteQueue();
        if (const unsigned int failures = paging.getWriteFailureCount())
        {
            Log(Debug::Error) << "Distant land generation FAILED: " << failures << " of " << built
                              << " chunk writes did not reach disk (out of disk space?). Free up space and run "
                                 "generation again - existing chunks are kept and only the missing ones are rebuilt.";
            return 1;
        }
        Log(Debug::Info) << "Distant land generation complete: " << done << "/" << lattice.size() << " lattice points, "
                         << built << " chunks written, " << skipped << " already present";
        return 0;
    }
}

int main(int argc, char* argv[])
{
    return Debug::wrapApplication(runTool, argc, argv, applicationName);
}
