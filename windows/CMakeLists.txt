# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(next_client LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "next_client")

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


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

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

# === MSVC runtime bundling ===
# The Windows artifact is a plain exe + DLLs folder that must run on machines
# that may have an old or missing Visual C++ runtime. Copy the build
# toolchain's own CRT DLLs (msvcp140/vcruntime140/concrt140/...) into the
# bundle so the app is self-contained: the exe's folder wins the DLL search
# order over any stale System32 copy, fixing the access-violation-in-
# MSVCP140.dll crash on machines with a 2019-era VC++ redistributable.
if(MSVC)
  # ---- Locate the MSVC redistributable. Several strategies so the DLLs are
  # found regardless of how/where Visual Studio was installed (and even when
  # the image is stripped of VC/Redist). ----
  set(_msvc_redist_dir "")
  # 1) VCToolsRedistDir: CMake variable set by the VS generator, environment
  #    variable set by vcvars.bat. Try both.
  set(_msvc_redist_dir "${VCToolsRedistDir}")
  if(NOT _msvc_redist_dir)
    set(_msvc_redist_dir "$ENV{VCToolsRedistDir}")
  endif()
  if(NOT _msvc_redist_dir OR NOT EXISTS "${_msvc_redist_dir}")
    # 2) vswhere: the official VS locator, layout-independent.
    set(_msvc_vs_path "")
    set(_msvc_vswhere "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe")
    if(NOT EXISTS "${_msvc_vswhere}")
      set(_msvc_vswhere "C:/Program Files/Microsoft Visual Studio/Installer/vswhere.exe")
    endif()
    if(EXISTS "${_msvc_vswhere}")
      execute_process(
        COMMAND "${_msvc_vswhere}" -latest -products "*"
                -requires Microsoft.VisualStudio.Component.VC.Redist.14.Latest
                -property installationPath
        OUTPUT_VARIABLE _msvc_vs_path OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
      if(NOT _msvc_vs_path)
        # Redist component not advertised; still use the plain install path.
        execute_process(
          COMMAND "${_msvc_vswhere}" -latest -products "*"
                  -property installationPath
          OUTPUT_VARIABLE _msvc_vs_path OUTPUT_STRIP_TRAILING_WHITESPACE
          ERROR_QUIET)
      endif()
      if(_msvc_vs_path)
        set(_msvc_redist_dir "${_msvc_vs_path}/VC/Redist/MSVC")
      endif()
    endif()
  endif()
  if(NOT _msvc_redist_dir OR NOT EXISTS "${_msvc_redist_dir}")
    # 3) Well-known install roots (any VS year/edition, x64 or x86 Program
    #    Files), newest wins.
    set(_msvc_redist_dir "")
    file(GLOB _msvc_redist_candidates
         "C:/Program Files*/Microsoft Visual Studio/*/*/VC/Redist/MSVC"
         "C:/Program Files*/Microsoft Visual Studio/*/VC/Redist/MSVC")
    list(SORT _msvc_redist_candidates ORDER DESCENDING)
    if(_msvc_redist_candidates)
      list(GET _msvc_redist_candidates 0 _msvc_redist_dir)
    endif()
  endif()

  # Normalize separators and strip trailing slashes so globs never see `//`.
  string(REPLACE "\\" "/" _msvc_redist_dir "${_msvc_redist_dir}")
  string(REGEX REPLACE "/+$" "" _msvc_redist_dir "${_msvc_redist_dir}")

  # ---- Pick the newest CRT folder ----
  set(_msvc_crt_dir "")
  if(_msvc_redist_dir AND EXISTS "${_msvc_redist_dir}")
    # Redist layout is either <redist>/<version>/x64/Microsoft.VC1*.CRT
    # (versioned) or <redist>/x64/Microsoft.VC1*.CRT (unversioned
    # VCToolsRedistDir). Note: only the x64 flavor is bundled today — the app
    # is x64-only (the plugin rejects 32-bit Windows).
    file(GLOB _msvc_crt_dirs
         "${_msvc_redist_dir}/*/x64/Microsoft.VC1*.CRT"
         "${_msvc_redist_dir}/x64/Microsoft.VC1*.CRT")
    list(SORT _msvc_crt_dirs ORDER DESCENDING)
    if(_msvc_crt_dirs)
      list(GET _msvc_crt_dirs 0 _msvc_crt_dir)
    endif()
  endif()
  if(NOT _msvc_crt_dir)
    # 4) Last resort: the CRT DLLs also ship inside the MSVC tools
    #    (VC/Tools/MSVC/<version>/bin/Hostx64/x64), identical binaries to the
    #    redistributable copies. VCToolsInstallDir is always set by the VS
    #    generator, so this can't miss when MSVC is compiling.
    set(_msvc_tools_dir "${VCToolsInstallDir}")
    if(NOT _msvc_tools_dir)
      set(_msvc_tools_dir "$ENV{VCToolsInstallDir}")
    endif()
    string(REPLACE "\\" "/" _msvc_tools_dir "${_msvc_tools_dir}")
    string(REGEX REPLACE "/+$" "" _msvc_tools_dir "${_msvc_tools_dir}")
    if(_msvc_tools_dir AND EXISTS "${_msvc_tools_dir}/bin/Hostx64/x64")
      set(_msvc_crt_dir "${_msvc_tools_dir}/bin/Hostx64/x64")
    elseif(_msvc_vs_path AND EXISTS "${_msvc_vs_path}/VC/Tools/MSVC")
      # vswhere gave us the install root; pick the newest toolset's bin dir.
      file(GLOB _msvc_tool_bins "${_msvc_vs_path}/VC/Tools/MSVC/*/bin/Hostx64/x64")
      list(SORT _msvc_tool_bins ORDER DESCENDING)
      if(_msvc_tool_bins)
        list(GET _msvc_tool_bins 0 _msvc_crt_dir)
      endif()
    endif()
  endif()

  if(_msvc_crt_dir AND EXISTS "${_msvc_crt_dir}")
    file(GLOB _msvc_runtime_dlls
         "${_msvc_crt_dir}/msvcp140*.dll"
         "${_msvc_crt_dir}/vcruntime140*.dll"
         "${_msvc_crt_dir}/concrt140.dll")
    if(_msvc_runtime_dlls)
      # Stage through install() so the bundle step places the DLLs next to
      # the exe. The Flutter template makes the install step part of the
      # default build (CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD), so the
      # release bundle at build/windows/x64/runner/Release is self-contained.
      # (A TARGET-scoped add_custom_command can't be used here: the runner
      # target is created in windows/runner/, a different directory scope.)
      install(FILES ${_msvc_runtime_dlls}
              DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
              COMPONENT Runtime)
      message(STATUS "Bundling MSVC runtime from ${_msvc_crt_dir}")
    endif()
  else()
    message(WARNING "MSVC runtime not found (VCToolsRedistDir, vswhere, "
                    "Program Files, VCToolsInstallDir) — the bundle will "
                    "require the VC++ 2015-2022 redistributable on target "
                    "machines")
  endif()
endif()
