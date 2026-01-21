cmake_minimum_required(VERSION 3.12)
project(lunet C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Option to enable/disable MySQL support.
# Default ON for non-Windows (existing behavior), OFF on Windows.
if(WIN32)
  option(LUNET_ENABLE_MYSQL "Enable MySQL support" OFF)
else()
  option(LUNET_ENABLE_MYSQL "Enable MySQL support" ON)
endif()

include_directories(include)

# === LuaJIT ===
# Try vcpkg paths first (Windows), then Homebrew/standard paths (macOS/Linux)
find_path(LUAJIT_INCLUDE_DIR luajit.h
  HINTS 
    ${LUAJIT_INCLUDE_DIR} 
    ENV LUAJIT_INCLUDE_DIR 
    "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/include"
    "${CMAKE_SOURCE_DIR}/../vcpkg/installed/x64-windows/include"
    "C:/vcpkg/installed/x64-windows/include"
    /opt/homebrew/include 
    /usr/local/include
  PATH_SUFFIXES luajit-2.1 luajit
)

# LuaJIT library names: lua51 on Windows (vcpkg), luajit-5.1 on Unix
find_library(LUAJIT_LIBRARY NAMES lua51 luajit-5.1 luajit
  HINTS 
    ${LUAJIT_LIBRARY} 
    ENV LUAJIT_LIBRARY 
    "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib"
    "${CMAKE_SOURCE_DIR}/../vcpkg/installed/x64-windows/lib"
    "C:/vcpkg/installed/x64-windows/lib"
    /opt/homebrew/lib 
    /usr/local/lib
)

if (NOT LUAJIT_INCLUDE_DIR OR NOT LUAJIT_LIBRARY)
  message(FATAL_ERROR "LuaJIT not found. Set -DLUAJIT_INCLUDE_DIR and -DLUAJIT_LIBRARY manually.")
endif()
include_directories(${LUAJIT_INCLUDE_DIR})
message(STATUS "Found LuaJIT include: ${LUAJIT_INCLUDE_DIR}")
message(STATUS "Found LuaJIT library: ${LUAJIT_LIBRARY}")

# === libuv ===
find_path(LIBUV_INCLUDE_DIR uv.h
  HINTS 
    ${LIBUV_INCLUDE_DIR} 
    ENV LIBUV_INCLUDE_DIR 
    "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/include"
    "${CMAKE_SOURCE_DIR}/../vcpkg/installed/x64-windows/include"
    "C:/vcpkg/installed/x64-windows/include"
    /opt/homebrew/include 
    /usr/local/include
)
find_library(LIBUV_LIBRARY NAMES uv libuv
  HINTS 
    ${LIBUV_LIBRARY} 
    ENV LIBUV_LIBRARY 
    "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/lib"
    "${CMAKE_SOURCE_DIR}/../vcpkg/installed/x64-windows/lib"
    "C:/vcpkg/installed/x64-windows/lib"
    /opt/homebrew/lib 
    /usr/local/lib
)

if (NOT LIBUV_INCLUDE_DIR OR NOT LIBUV_LIBRARY)
  message(FATAL_ERROR "libuv not found. Set -DLIBUV_INCLUDE_DIR and -DLIBUV_LIBRARY manually.")
endif()
include_directories(${LIBUV_INCLUDE_DIR})
message(STATUS "Found libuv include: ${LIBUV_INCLUDE_DIR}")
message(STATUS "Found libuv library: ${LIBUV_LIBRARY}")

# === MySQL Client (Optional) ===
if(LUNET_ENABLE_MYSQL)
  find_path(MYSQL_INCLUDE_DIR mysql.h
    HINTS ${MYSQL_INCLUDE_DIR} ENV MYSQL_INCLUDE_DIR /opt/homebrew/include /usr/local/include
    PATH_SUFFIXES mysql mysqlclient
  )
  find_library(MYSQL_LIBRARY NAMES mysqlclient
    HINTS ${MYSQL_LIBRARY} ENV MYSQL_LIBRARY /opt/homebrew/lib /usr/local/lib
  )

  if (NOT MYSQL_INCLUDE_DIR OR NOT MYSQL_LIBRARY)
    message(FATAL_ERROR "MySQL client not found. Set -DMYSQL_INCLUDE_DIR and -DMYSQL_LIBRARY manually, or disable with -DLUNET_ENABLE_MYSQL=OFF")
  endif()
  include_directories(${MYSQL_INCLUDE_DIR})
  message(STATUS "Found MySQL: ${MYSQL_LIBRARY}")
  # Define for conditional compilation in C sources.
  add_compile_definitions(LUNET_ENABLE_MYSQL)
else()
  message(STATUS "MySQL support disabled")
endif()

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

# Only include mysql.c if MySQL is enabled
if(LUNET_ENABLE_MYSQL)
  list(APPEND SOURCES src/mysql.c)
endif()

file(GLOB_RECURSE HEADERS include/*.h)

add_executable(lunet ${SOURCES} ${HEADERS})

# Link libraries
target_link_libraries(lunet
  ${LUAJIT_LIBRARY}
  ${LIBUV_LIBRARY}
)

if(LUNET_ENABLE_MYSQL)
  target_link_libraries(lunet ${MYSQL_LIBRARY})
endif()

# Windows-specific: link ws2_32, iphlpapi, userenv, psapi for libuv
if(WIN32)
  target_link_libraries(lunet ws2_32 iphlpapi userenv psapi)
endif()
