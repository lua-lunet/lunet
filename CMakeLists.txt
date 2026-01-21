cmake_minimum_required(VERSION 3.12)
project(lunet C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# === Dependencies ===

# LuaJIT
# Try to find LuaJIT via pkg-config or standard paths first
find_package(PkgConfig QUIET)
if(PKG_CONFIG_FOUND)
    pkg_check_modules(LUAJIT luajit)
endif()

if(NOT LUAJIT_FOUND)
    find_path(LUAJIT_INCLUDE_DIR luajit.h
        HINTS
            ENV LUAJIT_DIR
            ${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/include/luajit
            PATH_SUFFIXES include/luajit-2.1 include/luajit-2.0 include/luajit
    )
    find_library(LUAJIT_LIBRARY NAMES luajit-5.1 luajit lua51
        HINTS
            ENV LUAJIT_DIR
            ${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib
            PATH_SUFFIXES lib
    )
    if(LUAJIT_INCLUDE_DIR AND LUAJIT_LIBRARY)
        set(LUAJIT_FOUND TRUE)
        message(STATUS "Found LuaJIT: ${LUAJIT_LIBRARY}")
    endif()
endif()

if(NOT LUAJIT_FOUND)
    message(FATAL_ERROR "LuaJIT not found. Please set LUAJIT_DIR or install it.")
endif()

# libuv
find_package(libuv CONFIG REQUIRED)

# libsodium (Required for crypto.lua)
find_package(unofficial-sodium CONFIG REQUIRED)

# SQLite3 (Required for db.lua)
find_package(sqlite3 CONFIG REQUIRED)

# PostgreSQL (Required by spec)
find_package(PostgreSQL REQUIRED)

# === Source files ===
set(SOURCES
    src/main.c
    src/co.c
    src/fs.c
    src/rt.c
    src/signal.c
    src/socket.c
    src/stl.c
    src/timer.c
)

# Optional MySQL support
option(LUNET_ENABLE_MYSQL "Enable MySQL support" OFF)
if(LUNET_ENABLE_MYSQL)
    list(APPEND SOURCES src/mysql.c)
    add_definitions(-DLUNET_ENABLE_MYSQL)
    # Find MySQL (simplified)
    find_path(MYSQL_INCLUDE_DIR mysql.h PATH_SUFFIXES mysql mysqlclient)
    find_library(MYSQL_LIBRARY NAMES mysqlclient)
    if(MYSQL_INCLUDE_DIR AND MYSQL_LIBRARY)
        include_directories(${MYSQL_INCLUDE_DIR})
    else()
        message(FATAL_ERROR "MySQL not found but LUNET_ENABLE_MYSQL is ON")
    endif()
endif()

# === Targets ===
include_directories(include)
include_directories(${LUAJIT_INCLUDE_DIR})
include_directories(${PostgreSQL_INCLUDE_DIRS})

add_executable(lunet ${SOURCES})

target_link_libraries(lunet PRIVATE
    ${LUAJIT_LIBRARY}
    libuv::libuv
    unofficial-sodium::sodium
    sqlite3::sqlite3
    PostgreSQL::PQ
)

if(LUNET_ENABLE_MYSQL)
    target_link_libraries(lunet PRIVATE ${MYSQL_LIBRARY})
endif()

if(WIN32)
    target_link_libraries(lunet PRIVATE ws2_32 iphlpapi userenv psapi)
endif()

# === Installation / Post-build ===
# For Windows, we might need to copy DLLs to the output directory for FFI to work
if(WIN32)
    add_custom_command(TARGET lunet POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:unofficial-sodium::sodium>
        $<TARGET_FILE:sqlite3::sqlite3>
        $<TARGET_FILE_DIR:lunet>
        COMMENT "Copying DLLs to output directory"
    )
    # LuaJIT DLL might also need copying if it's dynamic
    get_filename_component(LUAJIT_LIB_DIR ${LUAJIT_LIBRARY} DIRECTORY)
    file(GLOB LUAJIT_DLLS "${LUAJIT_LIB_DIR}/*.dll")
    if(LUAJIT_DLLS)
        add_custom_command(TARGET lunet POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${LUAJIT_DLLS}
            $<TARGET_FILE_DIR:lunet>
        )
    endif()
endif()
