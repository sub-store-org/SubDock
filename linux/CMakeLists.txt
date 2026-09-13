# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "SubDock")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "org.substore.subdock")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# tray_manager's Linux implementation currently calls a deprecated AppIndicator
# API. Keep warnings-as-errors for SubDock and all other diagnostics, but do not
# fail the build on this third-party deprecation. This lives here so Flutter's
# generated plugin symlinks can be regenerated safely.
if(TARGET tray_manager_plugin)
  if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(
      tray_manager_plugin
      PRIVATE -Wno-error=deprecated-declarations
    )
  endif()
endif()

set(SUBDOCK_PROJECT_DIR "${CMAKE_CURRENT_LIST_DIR}/..")
set(SUBDOCK_RESOURCES_DIR "${SUBDOCK_PROJECT_DIR}/.subdock")
set(SUBDOCK_BACKEND_DIR "${SUBDOCK_RESOURCES_DIR}/backend")
set(SUBDOCK_FRONTEND_DIR "${SUBDOCK_RESOURCES_DIR}/frontend")
set(SUBDOCK_HTTP_META_DIR "${SUBDOCK_RESOURCES_DIR}/http-meta/linux-x64")
set(SUBDOCK_RUNTIME_DIR "${SUBDOCK_RESOURCES_DIR}/runtime/linux-x64")
foreach(backend_file sub-store.bundle.js runtime-manifest.json version)
  if(NOT EXISTS "${SUBDOCK_BACKEND_DIR}/${backend_file}")
    message(FATAL_ERROR "Missing ${backend_file}. Run tool/prepare_backend.sh before building Linux.")
  endif()
endforeach()
foreach(runtime_file node bin/shoutrrr)
  if(NOT EXISTS "${SUBDOCK_RUNTIME_DIR}/${runtime_file}")
    message(FATAL_ERROR
      "Missing ${runtime_file}. Run tool/prepare_runtime.sh linux-x64 before building Linux.")
  endif()
endforeach()
if(NOT EXISTS "${SUBDOCK_FRONTEND_DIR}/index.html")
  message(FATAL_ERROR "Missing frontend. Run tool/prepare_frontend.sh before building Linux.")
endif()
foreach(http_meta_file http-meta.bundle.js version meta/tpl.yaml meta/mihomo meta/mihomo-version)
  if(NOT EXISTS "${SUBDOCK_HTTP_META_DIR}/${http_meta_file}")
    message(FATAL_ERROR "Missing http-meta resource ${http_meta_file}. Run tool/prepare_http_meta.sh linux-x64 before building Linux.")
  endif()
endforeach()


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(PROGRAMS
  "${SUBDOCK_RUNTIME_DIR}/node"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/runtime"
  COMPONENT Runtime)

install(PROGRAMS
  "${SUBDOCK_RUNTIME_DIR}/bin/shoutrrr"
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
  USE_SOURCE_PERMISSIONS
  COMPONENT Runtime)

install(FILES
  "${SUBDOCK_PROJECT_DIR}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  RENAME "tray_icon.png"
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

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
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
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
