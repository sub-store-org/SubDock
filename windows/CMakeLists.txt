# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(SubDock LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "SubDock")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(
    ${TARGET}
    PRIVATE "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

set(SUBDOCK_PROJECT_DIR "${CMAKE_CURRENT_LIST_DIR}/..")
set(SUBDOCK_RESOURCES_DIR "${SUBDOCK_PROJECT_DIR}/.subdock")
set(SUBDOCK_BACKEND_DIR "${SUBDOCK_RESOURCES_DIR}/backend")
set(SUBDOCK_FRONTEND_DIR "${SUBDOCK_RESOURCES_DIR}/frontend")
set(SUBDOCK_HTTP_META_DIR "${SUBDOCK_RESOURCES_DIR}/http-meta/windows-x64")
set(SUBDOCK_RUNTIME_DIR "${SUBDOCK_RESOURCES_DIR}/runtime/windows-x64")
foreach(backend_file sub-store.bundle.js runtime-manifest.json version)
  if(NOT EXISTS "${SUBDOCK_BACKEND_DIR}/${backend_file}")
    message(FATAL_ERROR "Missing ${backend_file}. Run tool/prepare_backend.sh before building Windows.")
  endif()
endforeach()
foreach(runtime_file node.exe bin/shoutrrr.exe)
  if(NOT EXISTS "${SUBDOCK_RUNTIME_DIR}/${runtime_file}")
    message(FATAL_ERROR
      "Missing ${runtime_file}. Run tool/prepare_runtime.sh windows-x64 before building Windows.")
  endif()
endforeach()
if(NOT EXISTS "${SUBDOCK_FRONTEND_DIR}/index.html")
  message(FATAL_ERROR "Missing frontend. Run tool/prepare_frontend.sh before building Windows.")
endif()
foreach(http_meta_file http-meta.bundle.js version meta/tpl.yaml meta/mihomo.exe meta/mihomo-version)
  if(NOT EXISTS "${SUBDOCK_HTTP_META_DIR}/${http_meta_file}")
    message(FATAL_ERROR "Missing http-meta resource ${http_meta_file}. Run tool/prepare_http_meta.sh windows-x64 before building Windows.")
  endif()
endforeach()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(PROGRAMS
  "${SUBDOCK_RUNTIME_DIR}/node.exe"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/runtime"
  COMPONENT Runtime)

install(PROGRAMS
  "${SUBDOCK_RUNTIME_DIR}/bin/shoutrrr.exe"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/runtime/bin"
  COMPONENT Runtime)

install(FILES
  "${SUBDOCK_BACKEND_DIR}/sub-store.bundle.js"
  "${SUBDOCK_BACKEND_DIR}/runtime-manifest.json"
  "${SUBDOCK_BACKEND_DIR}/version"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/backend"
  COMPONENT Runtime)

install(DIRECTORY "${SUBDOCK_FRONTEND_DIR}/"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/frontend"
  COMPONENT Runtime)

install(DIRECTORY "${SUBDOCK_HTTP_META_DIR}/"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/http-meta"
  COMPONENT Runtime)

install(FILES
  "${SUBDOCK_PROJECT_DIR}/windows/runner/resources/app_icon.ico"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  RENAME "tray_icon.ico"
  COMPONENT Runtime)

install(FILES
  "${SUBDOCK_PROJECT_DIR}/assets/icon/app_icon.png"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/icon"
  RENAME "app_icon.png"
  COMPONENT Runtime)

install(FILES "${SUBDOCK_PROJECT_DIR}/LICENSE"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licenses"
  RENAME "GPL-3.0-only.txt"
  COMPONENT Runtime)

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
