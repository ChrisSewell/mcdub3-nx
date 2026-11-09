# The native part of the iOS app (ADR 0011): SDL2 from source as a static
# library, then the game (the repo's own CMakeLists.txt) as lib<MC3_APP>.a.
# The Xcode app in this folder (project.yml) links both; tools/ios_build.sh
# runs this for the simulator or the device:
#
#   cmake -S ios -B work-dub/ios/<sdk> -G Ninja \
#         -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=<sdk> \
#         -DCMAKE_OSX_ARCHITECTURES=arm64 -DMC3_SDL_DIR=<SDL2 source>
cmake_minimum_required(VERSION 3.20)
# Optimised always: a Debug app differs in Xcode's side only. The runtime
# (renderer, kernel, audio) at -O0 is far too slow for a phone.
set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
project(mcdub3_ios C CXX)

if(NOT IOS)
    message(FATAL_ERROR "ios/CMakeLists.txt builds for iOS: pass -DCMAKE_SYSTEM_NAME=iOS")
endif()
if(NOT DEFINED MC3_SDL_DIR OR NOT EXISTS "${MC3_SDL_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "MC3_SDL_DIR must name the SDL2 source (SDL2-2.32.x)")
endif()
get_filename_component(MC3_REPO "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)

# SDL2, static, with SDL2main (UIApplicationMain and the call to SDL_main).
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST OFF CACHE BOOL "" FORCE)
add_subdirectory(${MC3_SDL_DIR} SDL2)
if(NOT TARGET SDL2::SDL2)
    add_library(SDL2::SDL2 ALIAS SDL2-static)
endif()
# find_package(SDL2) in the toolkit: the target above already is SDL2.
file(WRITE ${CMAKE_BINARY_DIR}/sdl2cfg/SDL2Config.cmake "set(SDL2_FOUND TRUE)\n")
set(SDL2_DIR ${CMAKE_BINARY_DIR}/sdl2cfg CACHE PATH "" FORCE)

add_subdirectory(${MC3_REPO} mcdub3)

# One folder of libraries for Xcode's LIBRARY_SEARCH_PATHS (project.yml).
set(MC3_LIB_DIR "${CMAKE_BINARY_DIR}/lib")
set_target_properties(SDL2-static SDL2main PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY "${MC3_LIB_DIR}")
if(TARGET mcdub3)
    # Xcode links one game library, lib<MC3_APP>.a: the game and the
    # toolkit's static libraries (which CMake links for the other hosts),
    # merged with libtool.
    set_target_properties(mcdub3 PROPERTIES ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/game")
    set(_mc3_archives "$<TARGET_FILE:mcdub3>")
    set(_mc3_deps mcdub3)
    foreach(_lib platform xbox_kernel xbox_devbus xbox_d3d8 xbox_dsound xbox_input
                 xbox_usb xbox_apu xbox_nv2a xbox_video xbox_nv2a_gl xbox_nv2a_vk)
        if(TARGET ${_lib})
            get_target_property(_type ${_lib} TYPE)
            if(_type STREQUAL "STATIC_LIBRARY")
                list(APPEND _mc3_archives "$<TARGET_FILE:${_lib}>")
                list(APPEND _mc3_deps ${_lib})
            endif()
        endif()
    endforeach()
    set(_mc3_lib "${MC3_LIB_DIR}/lib${MC3_APP}.a")
    add_custom_command(OUTPUT "${_mc3_lib}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${MC3_LIB_DIR}"
        COMMAND libtool -static -no_warning_for_no_symbols -o "${_mc3_lib}" ${_mc3_archives}
        DEPENDS ${_mc3_deps}
        COMMENT "Merging the game and the toolkit into lib${MC3_APP}.a")
    add_custom_target(mc3_ios_lib ALL DEPENDS "${_mc3_lib}")
endif()
