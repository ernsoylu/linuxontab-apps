# CMake toolchain for wasm32-unknown-linux-musl (LinuxOnTab 2.0 userland).
# Use inside the tombl/distro devShell; see wasm32-cc. Set LOT_DEPS_PREFIX to
# the prefix holding already cross-built libraries.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR wasm32)

set(CMAKE_FIND_ROOT_PATH $ENV{sysroot} $ENV{LOT_DEPS_PREFIX})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_C_COMPILER ${CMAKE_CURRENT_LIST_DIR}/wasm32-cc)
find_program(CMAKE_AR llvm-ar REQUIRED)
find_program(CMAKE_RANLIB llvm-ranlib REQUIRED)

# No dynamic loader: SHARED/MODULE libraries are built as static archives,
# and there is no RPATH to set (CMake would otherwise relink on install).
set_property(GLOBAL PROPERTY TARGET_SUPPORTS_SHARED_LIBS FALSE)
# A cache entry: CMakeGenericSystem resets a plain variable under CMP0126 OLD.
set(CMAKE_SKIP_RPATH ON CACHE BOOL "")
