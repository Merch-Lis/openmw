#ifndef OPENMW_COMPONENTS_SETTINGS_CATEGORIES_TERRAIN_H
#define OPENMW_COMPONENTS_SETTINGS_CATEGORIES_TERRAIN_H

#include <components/settings/sanitizerimpl.hpp>
#include <components/settings/settingvalue.hpp>

#include <osg/Math>
#include <osg/Vec2f>
#include <osg/Vec3f>

#include <cstdint>
#include <string>
#include <string_view>

namespace Settings
{
    struct TerrainCategory : WithIndex
    {
        using WithIndex::WithIndex;

        SettingValue<bool> mDistantTerrain{ mIndex, "Terrain", "distant terrain" };
        SettingValue<float> mLodFactor{ mIndex, "Terrain", "lod factor", makeMaxStrictSanitizerFloat(0) };
        SettingValue<int> mVertexLodMod{ mIndex, "Terrain", "vertex lod mod" };
        SettingValue<int> mCompositeMapLevel{ mIndex, "Terrain", "composite map level", makeMaxSanitizerInt(-3) };
        SettingValue<int> mCompositeMapResolution{ mIndex, "Terrain", "composite map resolution",
            makeMaxSanitizerInt(1) };
        SettingValue<float> mMaxCompositeGeometrySize{ mIndex, "Terrain", "max composite geometry size",
            makeMaxSanitizerFloat(1) };
        SettingValue<bool> mDebugChunks{ mIndex, "Terrain", "debug chunks" };
        SettingValue<bool> mObjectPaging{ mIndex, "Terrain", "object paging" };
        SettingValue<bool> mObjectPagingActiveGrid{ mIndex, "Terrain", "object paging active grid" };
        SettingValue<float> mObjectPagingMergeFactor{ mIndex, "Terrain", "object paging merge factor",
            makeMaxStrictSanitizerFloat(0) };
        SettingValue<float> mObjectPagingMinSize{ mIndex, "Terrain", "object paging min size",
            makeMaxStrictSanitizerFloat(0) };
        SettingValue<float> mObjectPagingMinSizeMergeFactor{ mIndex, "Terrain", "object paging min size merge factor",
            makeMaxStrictSanitizerFloat(0) };
        SettingValue<float> mObjectPagingMinSizeCostMultiplier{ mIndex, "Terrain",
            "object paging min size cost multiplier", makeMaxStrictSanitizerFloat(0) };
        SettingValue<float> mObjectPagingLandmarkSize{ mIndex, "Terrain", "object paging landmark size",
            makeMaxSanitizerFloat(0) };
        SettingValue<float> mObjectPagingLandmarkRangeFactor{ mIndex, "Terrain", "object paging landmark range factor",
            makeMaxSanitizerFloat(1) };
        SettingValue<float> mObjectPagingSimplifyStrength{ mIndex, "Terrain", "object paging simplify strength",
            makeMaxSanitizerFloat(0) };
        SettingValue<bool> mObjectPagingCacheCompression{ mIndex, "Terrain", "object paging cache compression" };
        SettingValue<int> mObjectPagingReadThreads{ mIndex, "Terrain", "object paging read threads",
            makeClampSanitizerInt(1, 16) };
        SettingValue<std::string> mObjectPagingDiskCacheDir{ mIndex, "Terrain", "object paging disk cache dir" };
        SettingValue<bool> mWaterCulling{ mIndex, "Terrain", "water culling" };

        // mge-exact distant statics: three size classes, MGEXEgui model
        SettingValue<float> mDistantStaticsMinNear{ mIndex, "Terrain", "distant statics min size near",
            makeMaxSanitizerFloat(0) };
        SettingValue<float> mDistantStaticsEndNear{ mIndex, "Terrain", "distant statics end near",
            makeMaxSanitizerFloat(0) };
        SettingValue<float> mDistantStaticsMinFar{ mIndex, "Terrain", "distant statics min size far",
            makeMaxSanitizerFloat(0) };
        SettingValue<float> mDistantStaticsEndFar{ mIndex, "Terrain", "distant statics end far",
            makeMaxSanitizerFloat(0) };
        SettingValue<float> mDistantStaticsMinVeryFar{ mIndex, "Terrain", "distant statics min size very far",
            makeMaxSanitizerFloat(0) };
        SettingValue<float> mDistantStaticsEndVeryFar{ mIndex, "Terrain", "distant statics end very far",
            makeMaxSanitizerFloat(0) };
        SettingValue<int> mDistantStaticsNearRingCells{ mIndex, "Terrain", "distant statics near ring cells" };
        SettingValue<int> mDistantStaticsFarRingCells{ mIndex, "Terrain", "distant statics far ring cells" };
        SettingValue<int> mDistantStaticsVeryFarRingCells{ mIndex, "Terrain", "distant statics very far ring cells" };
    };
}

#endif
