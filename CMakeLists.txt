cmake_minimum_required(VERSION 3.10)
project(lunet C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include_directories(include)

# === Database Backend Option ===
set(LUNET_DB "mysql" CACHE STRING "Database backend: none, mysql, postgres, sqlite3")
set_property(CACHE LUNET_DB PROPERTY STRINGS none mysql postgres sqlite3)
message(STATUS "Database backend: ${LUNET_DB}")

# === LuaJIT ===
find_path(LUAJIT_INCLUDE_DIR luajit.h
  HINTS ${LUAJIT_INCLUDE_DIR} ENV LUAJIT_INCLUDE_DIR /opt/homebrew/include /usr/local/include
  PATH_SUFFIXES luajit-2.1
)
find_library(LUAJIT_LIBRARY NAMES luajit-5.1
  HINTS ${LUAJIT_LIBRARY} ENV LUAJIT_LIBRARY /opt/homebrew/lib /usr/local/lib
)

if (NOT LUAJIT_INCLUDE_DIR OR NOT LUAJIT_LIBRARY)
  message(FATAL_ERROR "LuaJIT not found. Set -DLUAJIT_INCLUDE_DIR and -DLUAJIT_LIBRARY manually.")
endif()
include_directories(${LUAJIT_INCLUDE_DIR})
message(STATUS "Found LuaJIT: ${LUAJIT_LIBRARY}")

# === libuv ===
find_path(LIBUV_INCLUDE_DIR uv.h
  HINTS ${LIBUV_INCLUDE_DIR} ENV LIBUV_INCLUDE_DIR /opt/homebrew/include /usr/local/include
)
find_library(LIBUV_LIBRARY NAMES uv
  HINTS ${LIBUV_LIBRARY} ENV LIBUV_LIBRARY /opt/homebrew/lib /usr/local/lib
)

if (NOT LIBUV_INCLUDE_DIR OR NOT LIBUV_LIBRARY)
  message(FATAL_ERROR "libuv not found. Set -DLIBUV_INCLUDE_DIR and -DLIBUV_LIBRARY manually.")
endif()
include_directories(${LIBUV_INCLUDE_DIR})
message(STATUS "Found libuv: ${LIBUV_LIBRARY}")

# === Source files ===
file(GLOB CORE_SOURCES src/*.c)
file(GLOB CORE_HEADERS include/*.h)

set(SOURCES ${CORE_SOURCES})
set(HEADERS ${CORE_HEADERS})
set(DB_LIBRARY "")

# === Database Backend Configuration ===
if(LUNET_DB STREQUAL "mysql")
  list(REMOVE_ITEM SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/src/mysql.c)
  find_path(MYSQL_INCLUDE_DIR mysql.h
    HINTS ${MYSQL_INCLUDE_DIR} ENV MYSQL_INCLUDE_DIR /opt/homebrew/include /usr/local/include
    PATH_SUFFIXES mysql mysqlclient
  )
  find_library(MYSQL_LIBRARY NAMES mysqlclient
    HINTS ${MYSQL_LIBRARY} ENV MYSQL_LIBRARY /opt/homebrew/lib /usr/local/lib
  )
  if (NOT MYSQL_INCLUDE_DIR OR NOT MYSQL_LIBRARY)
    message(FATAL_ERROR "MySQL client not found. Set -DMYSQL_INCLUDE_DIR and -DMYSQL_LIBRARY manually.")
  endif()
  include_directories(ext/mysql)
  include_directories(${MYSQL_INCLUDE_DIR})
  message(STATUS "Found MySQL: ${MYSQL_LIBRARY}")
  list(APPEND SOURCES ext/mysql/mysql.c)
  list(APPEND HEADERS ext/mysql/mysql.h)
  set(DB_LIBRARY ${MYSQL_LIBRARY})
  add_definitions(-DLUNET_HAS_DB)

elseif(LUNET_DB STREQUAL "postgres")
  list(REMOVE_ITEM SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/src/mysql.c)
  find_path(PQ_INCLUDE_DIR libpq-fe.h
    HINTS ${PQ_INCLUDE_DIR} ENV PQ_INCLUDE_DIR /opt/homebrew/include /usr/local/include /opt/homebrew/opt/libpq/include
    PATH_SUFFIXES postgresql
  )
  find_library(PQ_LIBRARY NAMES pq
    HINTS ${PQ_LIBRARY} ENV PQ_LIBRARY /opt/homebrew/lib /usr/local/lib /opt/homebrew/opt/libpq/lib
  )
  if (NOT PQ_INCLUDE_DIR OR NOT PQ_LIBRARY)
    message(FATAL_ERROR "PostgreSQL client (libpq) not found. Set -DPQ_INCLUDE_DIR and -DPQ_LIBRARY manually.")
  endif()
  include_directories(${PQ_INCLUDE_DIR})
  include_directories(ext/postgres)
  message(STATUS "Found PostgreSQL: ${PQ_LIBRARY}")
  list(APPEND SOURCES ext/postgres/postgres.c)
  list(APPEND HEADERS ext/postgres/postgres.h)
  set(DB_LIBRARY ${PQ_LIBRARY})
  add_definitions(-DLUNET_HAS_DB)

elseif(LUNET_DB STREQUAL "sqlite3")
  list(REMOVE_ITEM SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/src/mysql.c)
  find_path(SQLITE3_INCLUDE_DIR sqlite3.h
    HINTS ${SQLITE3_INCLUDE_DIR} ENV SQLITE3_INCLUDE_DIR /opt/homebrew/include /usr/local/include /opt/homebrew/opt/sqlite/include
  )
  find_library(SQLITE3_LIBRARY NAMES sqlite3
    HINTS ${SQLITE3_LIBRARY} ENV SQLITE3_LIBRARY /opt/homebrew/lib /usr/local/lib /opt/homebrew/opt/sqlite/lib
  )
  if (NOT SQLITE3_INCLUDE_DIR OR NOT SQLITE3_LIBRARY)
    message(FATAL_ERROR "SQLite3 not found. Set -DSQLITE3_INCLUDE_DIR and -DSQLITE3_LIBRARY manually.")
  endif()
  include_directories(${SQLITE3_INCLUDE_DIR})
  include_directories(ext/sqlite3)
  message(STATUS "Found SQLite3: ${SQLITE3_LIBRARY}")
  list(APPEND SOURCES ext/sqlite3/sqlite3.c)
  list(APPEND HEADERS ext/sqlite3/sqlite3.h)
  set(DB_LIBRARY ${SQLITE3_LIBRARY})
  add_definitions(-DLUNET_HAS_DB)

elseif(LUNET_DB STREQUAL "none")
  message(STATUS "Building without database support")

else()
  message(FATAL_ERROR "Invalid LUNET_DB value: ${LUNET_DB}. Must be one of: none, mysql, postgres, sqlite3")
endif()

add_executable(lunet ${SOURCES} ${HEADERS})

target_link_libraries(lunet
  ${LUAJIT_LIBRARY}
  ${LIBUV_LIBRARY}
  ${DB_LIBRARY}
)
