include (ExternalProject)
include(GNUInstallDirs)

set(ONEDNN_INSTALL_DIR ${THIRD_PARTY_DIR}/onednn)
set(ONEDNN_INCLUDE_DIR ${ONEDNN_INSTALL_DIR}/include)
set(ONEDNN_LIBRARY_DIR ${ONEDNN_INSTALL_DIR}/${CMAKE_INSTALL_LIBDIR})

set(ONEDNN_URL https://github.com/oneapi-src/oneDNN/archive/refs/tags/v2.4.3.tar.gz)
use_mirror(VARIABLE ONEDNN_URL URL ${ONEDNN_URL})

if(WIN32)
    message(FATAL_ERROR "Windows system does not support onednn")
else()
    if(BUILD_SHARED_LIBS)
      if("${CMAKE_SHARED_LIBRARY_SUFFIX}" STREQUAL ".dylib")
        set(ONEDNN_LIBRARY_NAMES libdnnl.dylib)
      elseif("${CMAKE_SHARED_LIBRARY_SUFFIX}" STREQUAL ".so")
        set(ONEDNN_LIBRARY_NAMES libdnnl.so)
        set(DNNL_LIBRARY_TYPE SHARED)
      else()
        message(FATAL_ERROR "${CMAKE_SHARED_LIBRARY_SUFFIX} not support for onednn")
      endif()
    else()
      set(ONEDNN_LIBRARY_NAMES libdnnl.a )
      set(DNNL_LIBRARY_TYPE STATIC)
    endif()
endif()

foreach(LIBRARY_NAME ${ONEDNN_LIBRARY_NAMES})
    list(APPEND ONEDNN_STATIC_LIBRARIES ${ONEDNN_LIBRARY_DIR}/${LIBRARY_NAME})
endforeach()


if(THIRD_PARTY)

ExternalProject_Add(onednn
    PREFIX onednn
    URL ${ONEDNN_URL}
    URL_MD5 c60ea96acbaccec053be7e3fa81c6184
    UPDATE_COMMAND ""
    BUILD_IN_SOURCE 1
    BUILD_BYPRODUCTS ${ONEDNN_STATIC_LIBRARIES}
    CMAKE_CACHE_ARGS
        -DCMAKE_INSTALL_PREFIX:STRING=${ONEDNN_INSTALL_DIR}
        -DCMAKE_C_COMPILER_LAUNCHER:STRING=${CMAKE_C_COMPILER_LAUNCHER}
        -DCMAKE_CXX_COMPILER_LAUNCHER:STRING=${CMAKE_CXX_COMPILER_LAUNCHER}
        -DCMAKE_POLICY_DEFAULT_CMP0074:STRING=NEW
        -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
        -DCMAKE_CXX_FLAGS_DEBUG:STRING=${CMAKE_CXX_FLAGS_DEBUG}
        -DCMAKE_CXX_FLAGS_RELEASE:STRING=${CMAKE_CXX_FLAGS_RELEASE}
        -DCMAKE_C_FLAGS_DEBUG:STRING=${CMAKE_C_FLAGS_DEBUG}
        -DCMAKE_C_FLAGS_RELEASE:STRING=${CMAKE_C_FLAGS_RELEASE}
        -DDNNL_IS_MAIN_PROJECT:BOOL=OFF
        -DDNNL_BUILD_EXAMPLES:BOOL=OFF
        -DDNNL_BUILD_TESTS:BOOL=OFF
        -DDNNL_LIBRARY_TYPE:STRING=${DNNL_LIBRARY_TYPE}
        -DDNNL_CPU_RUNTIME:STRING=OMP
)

endif(THIRD_PARTY)
add_library(onednn_imported UNKNOWN IMPORTED)
set_property(TARGET onednn_imported PROPERTY IMPORTED_LOCATION "${ONEDNN_STATIC_LIBRARIES}")
