#ifndef HALO_LUA_SHIM_H
#define HALO_LUA_SHIM_H
#include "lua.h"
// The Lua C API exposes these as macros; Swift can't import C macros, so wrap them.
int halo_lua_registryindex(void);
int halo_lua_tfunction(void);
#endif
