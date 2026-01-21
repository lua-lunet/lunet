cmake_minimum_required(VERSION 3.12)
project(lunet C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# === Dependencies ===

# Helper macro to find dependencies via Config, PkgConfig, or standard paths
macro(find_dependency_flexible NAME PKG_NAME HEADER LIB_NAMES)
    # 1. Try Config mode (vcpkg, etc.)
    find_package(${NAME} CONFIG QUIET)
    
    if(${NAME}_FOUND)
        message(STATUS "Found ${NAME} via Config")
    else()
        # 2. Try PkgConfig
        find_package(PkgConfig QUIET)
        if(PKG_CONFIG_FOUND)
            pkg_check_modules(${NAME}_PKG ${PKG_NAME} QUIET)
        endif()

        if(${NAME}_PKG_FOUND)
            message(STATUS "Found ${NAME} via PkgConfig")
            set(${NAME}_INCLUDE_DIRS ${${NAME}_PKG_INCLUDE_DIRS})
            set(${NAME}_LIBRARIES ${${NAME}_PKG_LIBRARIES})
            set(${NAME}_FOUND TRUE)
        else()
            # 3. Try standard paths
            find_path(${NAME}_INCLUDE_DIR ${HEADER}
                HINTS ENV ${NAME}_DIR
                PATH_SUFFIXES include
            )
            find_library(${NAME}_LIBRARY NAMES ${LIB_NAMES}
                HINTS ENV ${NAME}_DIR
                PATH_SUFFIXES lib
            )
            if(${NAME}_INCLUDE_DIR AND ${NAME}_LIBRARY)
                message(STATUS "Found ${NAME} via standard paths: ${${NAME}_LIBRARY}")
                set(${NAME}_INCLUDE_DIRS ${${NAME}_INCLUDE_DIR})
                set(${NAME}_LIBRARIES ${${NAME}_LIBRARY})
                set(${NAME}_FOUND TRUE)
            endif()
        endif()
    endif()

    if(NOT ${NAME}_FOUND)
        message(FATAL_ERROR "${NAME} not found. Please install it.")
    endif()
endmacro()

# LuaJIT
find_dependency_flexible(LUAJIT luajit luajit.h "luajit-5.1;luajit;lua51")

# libuv
find_package(libuv CONFIG QUIET)
if(NOT libuv_FOUND)
    find_dependency_flexible(LIBUV libuv uv.h "uv;libuv")
endif()

# libsodium
find_package(unofficial-sodium CONFIG QUIET)
if(NOT unofficial-sodium_FOUND)
    find_dependency_flexible(SODIUM libsodium sodium.h "sodium;libsodium")
endif()

# SQLite3
find_package(sqlite3 CONFIG QUIET)
if(NOT sqlite3_FOUND)
    find_dependency_flexible(SQLITE3 sqlite3 sqlite3.h "sqlite3")
endif()

# PostgreSQL
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
    set(LUNET_DB_DRIVER "mysql")
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
else()
    set(LUNET_DB_DRIVER "sqlite")
endif()

# Generate app/db_config.lua from app/db_config.lua.in
configure_file(app/db_config.lua.in ${CMAKE_SOURCE_DIR}/app/db_config.lua @ONLY)

# === Targets ===
include_directories(include)
include_directories(${LUAJIT_INCLUDE_DIRS})
include_directories(${LIBUV_INCLUDE_DIRS})
include_directories(${SODIUM_INCLUDE_DIRS})
include_directories(${SQLITE3_INCLUDE_DIRS})
include_directories(${PostgreSQL_INCLUDE_DIRS})

add_executable(lunet ${SOURCES})

# Link libraries
# Handle targets vs raw libraries
if(TARGET libuv::libuv)
    target_link_libraries(lunet PRIVATE libuv::libuv)
else()
    target_link_libraries(lunet PRIVATE ${LIBUV_LIBRARIES})
endif()

if(TARGET unofficial-sodium::sodium)
    target_link_libraries(lunet PRIVATE unofficial-sodium::sodium)
else()
    target_link_libraries(lunet PRIVATE ${SODIUM_LIBRARIES})
endif()

if(TARGET sqlite3::sqlite3)
    target_link_libraries(lunet PRIVATE sqlite3::sqlite3)
else()
    target_link_libraries(lunet PRIVATE ${SQLITE3_LIBRARIES})
endif()

target_link_libraries(lunet PRIVATE
    ${LUAJIT_LIBRARIES}
)

if(TARGET PostgreSQL::PQ)
    target_link_libraries(lunet PRIVATE PostgreSQL::PQ)
elseif(TARGET PostgreSQL::PostgreSQL)
    target_link_libraries(lunet PRIVATE PostgreSQL::PostgreSQL)
else()
    target_link_libraries(lunet PRIVATE ${PostgreSQL_LIBRARIES})
endif()

if(LUNET_ENABLE_MYSQL)
    target_link_libraries(lunet PRIVATE ${MYSQL_LIBRARY})
endif()

if(WIN32)
    target_link_libraries(lunet PRIVATE ws2_32 iphlpapi userenv psapi)
endif()

# === Installation / Post-build ===
# For Windows, we might need to copy DLLs to the output directory for FFI to work
if(WIN32)
    # Only copy if targets exist (vcpkg mode)
    if(TARGET unofficial-sodium::sodium)
        add_custom_command(TARGET lunet POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:unofficial-sodium::sodium>
            $<TARGET_FILE_DIR:lunet>
        )
    endif()
    if(TARGET sqlite3::sqlite3)
        add_custom_command(TARGET lunet POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:sqlite3::sqlite3>
            $<TARGET_FILE_DIR:lunet>
        )
    endif()
    
    # LuaJIT DLL might also need copying if it's dynamic
    # This is a best-effort attempt
    if(LUAJIT_LIBRARIES)
        foreach(LIB ${LUAJIT_LIBRARIES})
            if(LIB MATCHES "\.lib$")
                # Try to find corresponding DLL
                string(REPLACE ".lib" ".dll" DLL_PATH ${LIB})
                if(EXISTS ${DLL_PATH})
                    add_custom_command(TARGET lunet POST_BUILD
                        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                        ${DLL_PATH}
                        $<TARGET_FILE_DIR:lunet>
                    )
                endif()
            endif()
        endforeach()
    endif()
endif()
