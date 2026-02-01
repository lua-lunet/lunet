rockspec_format = "3.0"
package = "lunet-udp"
version = "scm-1"

source = {
    url = "git://github.com/lua-lunet/lunet.git",
    branch = "main"
}

description = {
    summary = "UDP extension for lunet",
    homepage = "https://github.com/lua-lunet/lunet",
    license = "MIT"
}

dependencies = {
    "lua >= 5.1",
    "lunet >= scm-1",
    "luarocks-build-xmake"
}

external_dependencies = {
    LUAJIT = { header = "luajit.h" },
    LIBUV = { header = "uv.h" }
}

build = {
    type = "xmake",
    variables = { XMAKE_TARGET = "lunet-udp" },
    copy_directories = {}
}
