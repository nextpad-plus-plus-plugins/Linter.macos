cmake_minimum_required(VERSION 3.20)
project(Linter VERSION 1.0.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Host plugin interface + Scintilla (read-only; NO host changes)
set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")
set(SCINTILLA_INCLUDE  "${NPP_MACOS_DIR}/scintilla/include")

add_library(Linter SHARED src/Linter.mm)
target_include_directories(Linter PRIVATE ${NPP_PLUGIN_INCLUDE} ${SCINTILLA_INCLUDE})
target_link_libraries(Linter PRIVATE "-framework Cocoa")
target_compile_options(Linter PRIVATE
    -Wall -Wno-unused-parameter -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(Linter PROPERTIES PREFIX "" SUFFIX ".dylib")
target_link_options(Linter PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")

# Install (real plugins dir). The plugin has no bundled resources and registers
# no toolbar icon (the original Windows plugin ships none); linter.xml is created
# on first run inside the host plugins config dir.
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/Linter")
install(TARGETS Linter DESTINATION "${PLUGIN_INSTALL_DIR}")
