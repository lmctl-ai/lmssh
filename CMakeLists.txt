cmake_minimum_required(VERSION 3.24)
project(lmssh VERSION 0.1.0 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
option(LMSSH_FULL_STATIC "Link the complete executable statically" ON)
set(OPENSSL_DIR "/usr" CACHE PATH "Prefix with include/openssl and the static libcrypto.a")

# ---- DSL schema embedded into the executable (also what lmscript compiles against) ----
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(LMSSH_HOST_SCHEMA "${CMAKE_CURRENT_SOURCE_DIR}/schema/lmssh.host.json")
set(LMSSH_STD_SCHEMA "${CMAKE_CURRENT_SOURCE_DIR}/cpp/std/lmcode-std.schema.json")
set(LMSSH_STD_MERGER "${CMAKE_CURRENT_SOURCE_DIR}/scripts/merge-std.py")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${LMSSH_HOST_SCHEMA}" "${LMSSH_STD_SCHEMA}" "${LMSSH_STD_MERGER}")
execute_process(COMMAND "${Python3_EXECUTABLE}" "${LMSSH_STD_MERGER}" "${LMSSH_HOST_SCHEMA}"
  "${CMAKE_CURRENT_SOURCE_DIR}/schema/lmssh.dsl.json" RESULT_VARIABLE LMSSH_STD_RESULT ERROR_VARIABLE LMSSH_STD_ERROR)
if(NOT LMSSH_STD_RESULT EQUAL 0)
  message(FATAL_ERROR "Cannot merge built-in std: ${LMSSH_STD_ERROR}")
endif()
set(LMSSH_SCHEMA "${CMAKE_CURRENT_SOURCE_DIR}/schema/lmssh.dsl.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${LMSSH_SCHEMA}")
file(READ "${LMSSH_SCHEMA}" LMSSH_SCHEMA_HEX HEX)
string(LENGTH "${LMSSH_SCHEMA_HEX}" LMSSH_SCHEMA_HEX_LENGTH)
math(EXPR LMSSH_SCHEMA_LAST_BYTE "${LMSSH_SCHEMA_HEX_LENGTH} - 2")
set(LMSSH_SCHEMA_INITIALIZER "")
foreach(offset RANGE 0 ${LMSSH_SCHEMA_LAST_BYTE} 2)
  string(SUBSTRING "${LMSSH_SCHEMA_HEX}" ${offset} 2 byte)
  string(APPEND LMSSH_SCHEMA_INITIALIZER "0x${byte},")
endforeach()
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/generated/schema_embedded.hpp"
  "#pragma once\n#include <cstddef>\nnamespace lmssh { inline constexpr unsigned char embedded_schema[] = {${LMSSH_SCHEMA_INITIALIZER}}; inline constexpr std::size_t embedded_schema_size = sizeof(embedded_schema); }\n")

# ---- OpenSSH client objects (pinned openssh.lock), built by scripts/build-openssh.sh ----
set(OPENSSH_OUT "${CMAKE_CURRENT_BINARY_DIR}/openssh")
set(OPENSSH_LIBS "${OPENSSH_OUT}/lib/libsshtools.a" "${OPENSSH_OUT}/lib/libssh.a" "${OPENSSH_OUT}/lib/libopenbsd-compat.a")
add_custom_command(
  OUTPUT ${OPENSSH_LIBS}
  COMMAND ${CMAKE_COMMAND} -E env "OPENSSL_DIR=${OPENSSL_DIR}" "CC=${CMAKE_C_COMPILER}"
          bash "${CMAKE_CURRENT_SOURCE_DIR}/scripts/build-openssh.sh" "${OPENSSH_OUT}"
  DEPENDS scripts/build-openssh.sh openssh.lock
  COMMENT "Building OpenSSH client objects"
  VERBATIM)
add_custom_target(openssh_objects DEPENDS ${OPENSSH_LIBS})

find_library(CRYPTO_STATIC NAMES libcrypto.a HINTS "${OPENSSL_DIR}/lib" "${OPENSSL_DIR}/lib64" REQUIRED)
find_library(ZLIB_STATIC NAMES libz.a)
if(NOT ZLIB_STATIC)
  if(APPLE)
    set(ZLIB_STATIC z)  # macOS ships only the dynamic libz, part of the OS
  else()
    message(FATAL_ERROR "static libz.a not found (install zlib-static / zlib1g-dev)")
  endif()
endif()

add_executable(lmssh cpp/main.cpp cpp/host.cpp cpp/runner.cpp cpp/tools.c)
add_dependencies(lmssh openssh_objects)
target_compile_definitions(lmssh PRIVATE LMSSH_VERSION="${PROJECT_VERSION}")
target_include_directories(lmssh PRIVATE cpp "${CMAKE_CURRENT_BINARY_DIR}/generated" "${OPENSSL_DIR}/include")
# libsshtools.a first: its objects pull libssh.a / libopenbsd-compat.a members, which pull libcrypto.
target_link_libraries(lmssh PRIVATE ${OPENSSH_LIBS} ${OPENSSH_LIBS} "${CRYPTO_STATIC}" "${ZLIB_STATIC}" ${CMAKE_DL_LIBS})
if(UNIX AND NOT APPLE)
  target_link_libraries(lmssh PRIVATE pthread)
endif()
if(APPLE)
  target_link_libraries(lmssh PRIVATE resolv)  # openbsd-compat getrrsetbyname (res_query)
endif()
target_compile_options(lmssh PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-Wall -Wextra -Wpedantic>)
# "Clang" also matches AppleClang; macOS has no -static/-static-libstdc++.
if((CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang") AND NOT APPLE)
  target_link_options(lmssh PRIVATE -static-libstdc++ -static-libgcc -s)
  if(LMSSH_FULL_STATIC)
    target_link_options(lmssh PRIVATE -static)
  endif()
endif()
