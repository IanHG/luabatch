################################################################################
#
# Header
#
################################################################################
# Set CMake minimum version
cmake_minimum_required(VERSION 3.9)

# Describe project
project(luabatch VERSION 1.0.0 DESCRIPTION "Batching meta-language written in Lua.")
#project(luabatch LANGUAGES NONE VERSION 1.0.0 DESCRIPTION "Batching meta-language written in Lua.")
################################################################################
#
# Some setup
#
################################################################################
find_package(Lua REQUIRED)

################################################################################
#
# Install setup
#
################################################################################
# Install part
#include(GNUInstallDirs)
install(PROGRAMS  bin/luabatch DESTINATION bin)
install(PROGRAMS  bin/luawrap  DESTINATION bin)
install(DIRECTORY libexec      DESTINATION .)
install(DIRECTORY lib          DESTINATION .)

