#ifndef OPENMW_COMPONENTS_SETTINGS_CATEGORIES_WATER_H
#define OPENMW_COMPONENTS_SETTINGS_CATEGORIES_WATER_H

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
    struct WaterCategory : WithIndex
    {
        using WithIndex::WithIndex;

        SettingValue<bool> mShader{ mIndex, "Water", "shader" };
        SettingValue<int> mRttSize{ mIndex, "Water", "rtt size", makeMaxSanitizerInt(1) };
        SettingValue<bool> mRefraction{ mIndex, "Water", "refraction" };
        SettingValue<int> mReflectionDetail{ mIndex, "Water", "reflection detail", makeClampSanitizerInt(0, 5) };
        SettingValue<int> mRainRippleDetail{ mIndex, "Water", "rain ripple detail", makeClampSanitizerInt(0, 2) };
        SettingValue<float> mSmallFeatureCullingPixelSize{ mIndex, "Water", "small feature culling pixel size",
            makeMaxStrictSanitizerFloat(0) };
        SettingValue<float> mRefractionScale{ mIndex, "Water", "refraction scale", makeClampSanitizerFloat(0, 1) };
        SettingValue<bool> mSunlightScattering{ mIndex, "Water", "sunlight scattering" };
        SettingValue<bool> mWobblyShores{ mIndex, "Water", "wobbly shores" };
        // Full tier, Wonders of Water layer: replace the flat water sheet
        // with the camera-centred radial mesh and displace it in the vertex
        // stage (MGE XE's DYNAMIC_RIPPLES mechanic). Load-time. A stock exe
        // has no reader for this key; the water package's settings fragment
        // enables it. docs/full-water-geometry-design.md (WFR repo).
        SettingValue<bool> mDisplacedWaveGeometry{ mIndex, "Water", "displaced wave geometry" };
    };
}

#endif
