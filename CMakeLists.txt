cmake_minimum_required(VERSION 3.10)
project(lunet C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include_directories(include)

# LuaJIT
set(LUAJIT_INCLUDE_DIR "/opt/homebrew/include/luajit-2.1")
set(LUAJIT_LIBRARY_DIR "/opt/homebrew/lib")
set(LUAJIT_LIBRARY "luajit-5.1")
include_directories(${LUAJIT_INCLUDE_DIR})
link_directories(${LUAJIT_LIBRARY_DIR})

# libuv
set(LIBUV_INCLUDE_DIR "/opt/homebrew/include")
set(LIBUV_LIBRARY_DIR "/opt/homebrew/lib")
set(LIBUV_LIBRARY "uv")
include_directories(${LIBUV_INCLUDE_DIR})
link_directories(${LIBUV_LIBRARY_DIR})

# mysql
set(MYSQL_INCLUDE_DIR "/opt/homebrew/Cellar/mysql@8.4/8.4.4/include")
set(MYSQL_LIBRARY_DIR "/opt/homebrew/Cellar/mysql@8.4/8.4.4/lib")
set(MYSQL_LIBRARY "mysqlclient")
include_directories(${MYSQL_INCLUDE_DIR})
link_directories(${MYSQL_LIBRARY_DIR})

# source
file(GLOB_RECURSE SOURCES src/*.c)
file(GLOB_RECURSE HEADERS include/*.h)

add_executable(lunet
    ${SOURCES}
    ${HEADERS}
)

target_link_libraries(lunet ${LUAJIT_LIBRARY} ${LIBUV_LIBRARY} ${MYSQL_LIBRARY})
