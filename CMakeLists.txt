cmake_minimum_required(VERSION 3.12)
project(lunet C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# === Tracing Option ===
# Enable with: cmake -DLUNET_TRACE=ON ..
# This adds coroutine reference tracking for debugging.
# When OFF, all tracing code is eliminated by the compiler (zero overhead).
option(LUNET_TRACE "Enable coroutine reference tracing for debugging" OFF)

if(LUNET_TRACE)
  message(STATUS "LUNET_TRACE enabled - coroutine reference tracing active")
  add_compile_definitions(LUNET_TRACE)
else()
  message(STATUS "LUNET_TRACE disabled - zero overhead release build")
endif()

# Helper macro to find dependencies via Config, PkgConfig, or standard paths
macro(find_dependency_flexible NAME PKG_NAME HEADER LIB_NAMES)
    if(${NAME}_INCLUDE_DIR AND ${NAME}_LIBRARY)
        message(STATUS "Using manually specified ${NAME}")
        set(${NAME}_INCLUDE_DIRS ${${NAME}_INCLUDE_DIR})
        set(${NAME}_LIBRARIES ${${NAME}_LIBRARY})
        set(${NAME}_FOUND TRUE)
    else()
        # 1. Try Config mode (vcpkg, etc.)
        find_package(${NAME} CONFIG QUIET)
    
        if(${NAME}_FOUND)
            message(STATUS "Found ${NAME} via Config")
            # Handle imported targets from Config packages
            if(TARGET ${PKG_NAME}::${PKG_NAME})
                set(${NAME}_LIBRARIES ${PKG_NAME}::${PKG_NAME})
            elseif(TARGET libuv::uv_a)
                set(${NAME}_LIBRARIES libuv::uv_a)
            elseif(TARGET libuv::uv)
                set(${NAME}_LIBRARIES libuv::uv)
            elseif(TARGET unofficial-sodium::sodium)
                set(${NAME}_LIBRARIES unofficial-sodium::sodium)
            elseif(TARGET unofficial::sqlite3::sqlite3)
                set(${NAME}_LIBRARIES unofficial::sqlite3::sqlite3)
            endif()
            set(${NAME}_INCLUDE_DIRS "")
        else()
            # 2. Try vcpkg-specific unofficial packages
            if("${NAME}" STREQUAL "SODIUM")
                find_package(unofficial-sodium CONFIG QUIET)
                if(unofficial-sodium_FOUND AND TARGET unofficial-sodium::sodium)
                    message(STATUS "Found ${NAME} via unofficial-sodium Config")
                    set(${NAME}_LIBRARIES unofficial-sodium::sodium)
                    set(${NAME}_INCLUDE_DIRS "")
                    set(${NAME}_FOUND TRUE)
                endif()
            elseif("${NAME}" STREQUAL "SQLITE3")
                find_package(unofficial-sqlite3 CONFIG QUIET)
                if(unofficial-sqlite3_FOUND AND TARGET unofficial::sqlite3::sqlite3)
                    message(STATUS "Found ${NAME} via unofficial-sqlite3 Config")
                    set(${NAME}_LIBRARIES unofficial::sqlite3::sqlite3)
                    set(${NAME}_INCLUDE_DIRS "")
                    set(${NAME}_FOUND TRUE)
                endif()
            elseif("${NAME}" STREQUAL "LUAJIT")
                # LuaJIT has no CMake config in vcpkg, use find_library directly
                # On Windows vcpkg, the library is named lua51.lib
                # On Unix, it's libluajit-5.1.a or libluajit-5.1.so
                find_library(LUAJIT_LIBRARY_FOUND NAMES lua51 luajit-5.1 luajit luajit-5.1.2
                    HINTS ${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib
                    PATHS ${CMAKE_PREFIX_PATH}/lib /opt/homebrew/opt/luajit/lib /opt/homebrew/lib
                )
                find_path(LUAJIT_INCLUDE_FOUND NAMES lua.h
                    HINTS ${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/include/luajit
                          ${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/include
                    PATHS ${CMAKE_PREFIX_PATH}/include /opt/homebrew/opt/luajit/include/luajit-2.1 /opt/homebrew/include
                    PATH_SUFFIXES luajit luajit-2.1
                )
                if(LUAJIT_LIBRARY_FOUND AND LUAJIT_INCLUDE_FOUND)
                    message(STATUS "Found ${NAME} via find_library: ${LUAJIT_LIBRARY_FOUND}")
                    set(${NAME}_LIBRARIES ${LUAJIT_LIBRARY_FOUND})
                    set(${NAME}_INCLUDE_DIRS ${LUAJIT_INCLUDE_FOUND})
                    set(${NAME}_FOUND TRUE)
                endif()
            elseif("${NAME}" STREQUAL "SODIUM")
                # Try find_library for libsodium (needed on macOS where pkg-config
                # returns just library name without full path)
                find_library(SODIUM_LIBRARY_FOUND NAMES sodium libsodium
                    HINTS ${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib
                    PATHS ${CMAKE_PREFIX_PATH}/lib /opt/homebrew/opt/libsodium/lib /opt/homebrew/lib
                )
                find_path(SODIUM_INCLUDE_FOUND NAMES sodium.h
                    HINTS ${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/include
                    PATHS ${CMAKE_PREFIX_PATH}/include /opt/homebrew/opt/libsodium/include /opt/homebrew/include
                )
                if(SODIUM_LIBRARY_FOUND AND SODIUM_INCLUDE_FOUND)
                    message(STATUS "Found ${NAME} via find_library: ${SODIUM_LIBRARY_FOUND}")
                    set(${NAME}_LIBRARIES ${SODIUM_LIBRARY_FOUND})
                    set(${NAME}_INCLUDE_DIRS ${SODIUM_INCLUDE_FOUND})
                    set(${NAME}_FOUND TRUE)
                endif()
            endif()
        
            if(NOT ${NAME}_FOUND)
                # 3. Try PkgConfig
                find_package(PkgConfig QUIET)
                if(PKG_CONFIG_FOUND)
                    pkg_check_modules(${NAME}_PKG ${PKG_NAME} QUIET)
                endif()

                if(${NAME}_PKG_FOUND)
                    message(STATUS "Found ${NAME} via PkgConfig")
                    set(${NAME}_INCLUDE_DIRS ${${NAME}_PKG_INCLUDE_DIRS})
                    # Use LINK_LIBRARIES which includes full paths, fallback to LDFLAGS if needed
                    if(${NAME}_PKG_LINK_LIBRARIES)
                        set(${NAME}_LIBRARIES ${${NAME}_PKG_LINK_LIBRARIES})
                    else()
                        # Fallback: combine library dirs and libraries
                        set(${NAME}_LIBRARIES "")
                        foreach(_dir ${${NAME}_PKG_LIBRARY_DIRS})
                            list(APPEND ${NAME}_LIBRARIES "-L${_dir}")
                        endforeach()
                        foreach(_lib ${${NAME}_PKG_LIBRARIES})
                            list(APPEND ${NAME}_LIBRARIES "-l${_lib}")
                        endforeach()
                    endif()
                    set(${NAME}_FOUND TRUE)
                else()
                    # 4. Try standard paths including Homebrew
                    find_path(${NAME}_INCLUDE_DIR ${HEADER}
                        HINTS ENV ${NAME}_DIR
                        PATHS /opt/homebrew/include /opt/homebrew/opt/luajit/include/luajit-2.1
                              /opt/homebrew/opt/libuv/include /opt/homebrew/opt/libsodium/include
                              /opt/homebrew/opt/sqlite/include /opt/homebrew/opt/libpq/include
                              /opt/homebrew/opt/mysql/include
                              /usr/local/include /usr/include
                        PATH_SUFFIXES include luajit-2.1 mysql
                    )
                    find_library(${NAME}_LIBRARY NAMES ${LIB_NAMES}
                        HINTS ENV ${NAME}_DIR
                        PATHS /opt/homebrew/lib /opt/homebrew/opt/luajit/lib
                              /opt/homebrew/opt/libuv/lib /opt/homebrew/opt/libsodium/lib
                              /opt/homebrew/opt/sqlite/lib /opt/homebrew/opt/libpq/lib
                              /opt/homebrew/opt/mysql/lib
                              /usr/local/lib /usr/lib
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
        endif()
    endif()

    if(NOT ${NAME}_FOUND)
        message(FATAL_ERROR "${NAME} not found. Please install it.")
    endif()
endmacro()

# === Dependencies ===

# LuaJIT
find_dependency_flexible(LUAJIT luajit luajit.h "luajit-5.1;luajit;lua51")

# libuv
find_dependency_flexible(LIBUV libuv uv.h "uv;libuv")

# libsodium
find_dependency_flexible(SODIUM libsodium sodium.h "sodium;libsodium")

# === Database Backend Option ===
set(LUNET_DB "mysql" CACHE STRING "Database backend: none, mysql, postgres, sqlite3")
set_property(CACHE LUNET_DB PROPERTY STRINGS none mysql postgres sqlite3)
message(STATUS "Database backend: ${LUNET_DB}")

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
    src/trace.c
)

set(DB_LIBRARY "")

# === Database Backend Configuration ===
if(LUNET_DB STREQUAL "mysql")
  find_dependency_flexible(MYSQL mysql mysql.h "mysqlclient;mysql")
  
  include_directories(ext/mysql)
  include_directories(${MYSQL_INCLUDE_DIRS})
  message(STATUS "Found MySQL: ${MYSQL_LIBRARIES}")
  list(APPEND SOURCES ext/mysql/mysql.c)
  # list(APPEND HEADERS ext/mysql/mysql.h)
  set(DB_LIBRARY ${MYSQL_LIBRARIES})
  add_definitions(-DLUNET_HAS_DB)
  set(LUNET_DB_DRIVER "mysql")

elseif(LUNET_DB STREQUAL "postgres")
  find_dependency_flexible(PostgreSQL libpq libpq-fe.h "pq;libpq")
  
  include_directories(${PostgreSQL_INCLUDE_DIRS})
  include_directories(ext/postgres)
  message(STATUS "Found PostgreSQL: ${PostgreSQL_LIBRARIES}")
  list(APPEND SOURCES ext/postgres/postgres.c)
  # list(APPEND HEADERS ext/postgres/postgres.h)
  set(DB_LIBRARY ${PostgreSQL_LIBRARIES})
  add_definitions(-DLUNET_HAS_DB)
  set(LUNET_DB_DRIVER "postgres")

elseif(LUNET_DB STREQUAL "sqlite3")
  find_dependency_flexible(SQLITE3 sqlite3 sqlite3.h "sqlite3")
  
  include_directories(${SQLITE3_INCLUDE_DIRS})
  include_directories(ext/sqlite3)
  message(STATUS "Found SQLite3: ${SQLITE3_LIBRARIES}")
  list(APPEND SOURCES ext/sqlite3/sqlite3.c)
  # list(APPEND HEADERS ext/sqlite3/sqlite3.h)
  set(DB_LIBRARY ${SQLITE3_LIBRARIES})
  add_definitions(-DLUNET_HAS_DB)
  set(LUNET_DB_DRIVER "sqlite")

elseif(LUNET_DB STREQUAL "none")
  message(STATUS "Building without database support")
  set(LUNET_DB_DRIVER "none")

else()
  message(FATAL_ERROR "Invalid LUNET_DB value: ${LUNET_DB}. Must be one of: none, mysql, postgres, sqlite3")
endif()

# Generate app/db_config.lua from app/db_config.lua.in
configure_file(app/db_config.lua.in ${CMAKE_SOURCE_DIR}/app/db_config.lua @ONLY)

# === Targets ===
include_directories(include)
include_directories(${LUAJIT_INCLUDE_DIRS})
include_directories(${LIBUV_INCLUDE_DIRS})
include_directories(${SODIUM_INCLUDE_DIRS})

add_executable(lunet ${SOURCES})

target_link_libraries(lunet PRIVATE
  ${LUAJIT_LIBRARIES}
  ${LIBUV_LIBRARIES}
  ${SODIUM_LIBRARIES}
  ${DB_LIBRARY}
)

if(WIN32)
    target_link_libraries(lunet PRIVATE ws2_32 iphlpapi userenv psapi)
endif()

# === Installation / Post-build ===
if(WIN32)
    # Only copy if targets exist (vcpkg mode)
    if(TARGET unofficial-sodium::sodium)
        add_custom_command(TARGET lunet POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:unofficial-sodium::sodium>
            $<TARGET_FILE_DIR:lunet>
        )
    endif()
    if(TARGET unofficial::sqlite3::sqlite3 AND LUNET_DB STREQUAL "sqlite3")
        add_custom_command(TARGET lunet POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:unofficial::sqlite3::sqlite3>
            $<TARGET_FILE_DIR:lunet>
        )
    endif()
endif()