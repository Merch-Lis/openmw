#ifndef OPENMW_COMPONENTS_RESOURCE_IMAGEMANAGER_H
#define OPENMW_COMPONENTS_RESOURCE_IMAGEMANAGER_H

#include <osg/Image>
#include <osg/Texture2D>
#include <osg/ref_ptr>

#include <components/vfs/pathutil.hpp>

#include "resourcemanager.hpp"

namespace osgDB
{
    class Options;
}

namespace Resource
{

    /// @brief Handles loading/caching of Images.
    /// @note May be used from any thread.
    class ImageManager : public ResourceManager
    {
    public:
        explicit ImageManager(const VFS::Manager* vfs, double expiryDelay);
        ~ImageManager();

        /// Create or retrieve an Image
        /// Returns the dummy image if the given image is not found.
        osg::ref_ptr<osg::Image> getImage(VFS::Path::NormalizedView path, bool disableFlip = false);

        /// The same image, but one that is not in the cache yet is loaded
        /// without entering it: the caller is then its only owner, and the
        /// pixels go when the caller lets go instead of staying for the cache's
        /// expiry delay. For a caller that keeps a reduced copy only (the
        /// distant layer's textures). An image the cache already holds is
        /// returned as it is and must not be modified.
        osg::ref_ptr<osg::Image> getImageUncached(VFS::Path::NormalizedView path, bool disableFlip = false);

        osg::Image* getWarningImage();

        void reportStats(unsigned int frameNumber, osg::Stats* stats) const override;

    private:
        osg::ref_ptr<osg::Image> loadImage(VFS::Path::NormalizedView path, bool disableFlip, bool cache);

        osg::ref_ptr<osg::Image> mWarningImage;
        osg::ref_ptr<osgDB::Options> mOptions;

        ImageManager(const ImageManager&);
        void operator=(const ImageManager&);
    };

}

#endif
