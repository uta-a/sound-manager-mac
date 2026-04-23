cmake_minimum_required(VERSION 3.12.0)

project(SoundManagerDriver CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# set via `cmake -DCODESIGN_ID=-` for ad-hoc, or a Developer ID for distribution
set(CODESIGN_ID "" CACHE STRING "Codesign ID (use '-' for ad-hoc)")

set(DRIVER_NAME "SoundManagerDriver")
set(DRIVER_VERSION "0.0.1")
set(DRIVER_COPYRIGHT "Copyright (c) 2026 uta-a. Released under the MIT License.")
set(DRIVER_IDENTIFIER "io.github.uta-a.SoundManagerDriver")
# CFPlugInFactories に載せる UUID (driver bundle ごとに一意に固定)
set(DRIVER_UID "7D88C91A-ECDF-4552-A7EB-F7138090DC3E")
set(DRIVER_ENTRYPOINT "SoundManagerDriverEntryPoint")

message(STATUS "Driver name        : ${DRIVER_NAME}")
message(STATUS "Driver version     : ${DRIVER_VERSION}")
message(STATUS "Driver identifier  : ${DRIVER_IDENTIFIER}")
message(STATUS "Driver UID         : ${DRIVER_UID}")
message(STATUS "Driver codesign ID : ${CODESIGN_ID}")

# libASPL を同梱の submodule (../vendor/libASPL) から ExternalProject で内部ビルド
get_filename_component(LIBASPL_SOURCE_DIR
    ${CMAKE_CURRENT_LIST_DIR}/../vendor/libASPL
    ABSOLUTE)

set(LIBASPL_TARGET ${DRIVER_NAME}_libASPL)
include(ExternalProject)
ExternalProject_Add(${LIBASPL_TARGET}
    SOURCE_DIR ${LIBASPL_SOURCE_DIR}
    BINARY_DIR ${CMAKE_CURRENT_BINARY_DIR}/libASPL-build
    INSTALL_DIR ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix
    CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
    LOG_DOWNLOAD YES
    LOG_CONFIGURE YES
    LOG_BUILD YES
    LOG_INSTALL YES
)

# HAL plugin は .so (Mach-O loadable bundle) で作る
add_library(${DRIVER_NAME} MODULE
    Driver.cpp
)

add_dependencies(${DRIVER_NAME} ${LIBASPL_TARGET})
target_include_directories(${DRIVER_NAME}
    PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix/include)
target_link_libraries(${DRIVER_NAME}
    PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix/lib/libASPL.a)

find_library(LIB_CoreFoundation CoreFoundation REQUIRED)
target_link_libraries(${DRIVER_NAME} PRIVATE ${LIB_CoreFoundation})

# 出力を ${DRIVER_NAME}.driver bundle として pack する
set_target_properties(${DRIVER_NAME} PROPERTIES
    OUTPUT_NAME "${DRIVER_NAME}"
    BUNDLE true
    BUNDLE_EXTENSION "driver"
    PREFIX ""
    SUFFIX ""
    MACOSX_BUNDLE ON
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_BUNDLE_NAME "${DRIVER_NAME}"
    MACOSX_BUNDLE_BUNDLE_VERSION "${DRIVER_VERSION}"
    MACOSX_BUNDLE_COPYRIGHT "${DRIVER_COPYRIGHT}"
    MACOSX_BUNDLE_GUI_IDENTIFIER "${DRIVER_IDENTIFIER}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${DRIVER_VERSION}"
)

# CODESIGN_ID が空でない場合のみ署名ステップを挿入 (通常は '-' で ad-hoc)
if(NOT CODESIGN_ID STREQUAL "")
    add_custom_command(
        TARGET ${DRIVER_NAME}
        POST_BUILD
        COMMENT "Signing ${DRIVER_NAME}.driver with ID '${CODESIGN_ID}'"
        VERBATIM
        COMMAND codesign --force -s "${CODESIGN_ID}"
            "${CMAKE_CURRENT_BINARY_DIR}/${DRIVER_NAME}.driver"
    )
endif()
