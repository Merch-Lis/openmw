source_group(apps\\distantlandtool FILES main.cpp)

openmw_add_executable(openmw-distantlandtool main.cpp)

target_include_directories(openmw-distantlandtool PRIVATE ${CMAKE_SOURCE_DIR})

target_link_libraries(openmw-distantlandtool
    openmw-lib
    Boost::program_options
    components
)

if (WIN32)
    target_sources(openmw-distantlandtool PRIVATE ${CMAKE_SOURCE_DIR}/files/windows/other-apps.manifest)
    install(TARGETS openmw-distantlandtool RUNTIME DESTINATION ".")
endif()

if (MSVC AND PRECOMPILE_HEADERS_WITH_MSVC)
    target_precompile_headers(openmw-distantlandtool REUSE_FROM components)
endif()
