#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "SDL2_ttf::SDL2_ttf-static" for configuration "Release"
set_property(TARGET SDL2_ttf::SDL2_ttf-static APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(SDL2_ttf::SDL2_ttf-static PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "C"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libSDL2_ttf.a"
  )

list(APPEND _cmake_import_check_targets SDL2_ttf::SDL2_ttf-static )
list(APPEND _cmake_import_check_files_for_SDL2_ttf::SDL2_ttf-static "${_IMPORT_PREFIX}/lib/libSDL2_ttf.a" )

# Import target "SDL2_ttf::harfbuzz" for configuration "Release"
set_property(TARGET SDL2_ttf::harfbuzz APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(SDL2_ttf::harfbuzz PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libharfbuzz.a"
  )

list(APPEND _cmake_import_check_targets SDL2_ttf::harfbuzz )
list(APPEND _cmake_import_check_files_for_SDL2_ttf::harfbuzz "${_IMPORT_PREFIX}/lib/libharfbuzz.a" )

# Import target "SDL2_ttf::freetype" for configuration "Release"
set_property(TARGET SDL2_ttf::freetype APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(SDL2_ttf::freetype PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "C"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libfreetype.a"
  )

list(APPEND _cmake_import_check_targets SDL2_ttf::freetype )
list(APPEND _cmake_import_check_files_for_SDL2_ttf::freetype "${_IMPORT_PREFIX}/lib/libfreetype.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
