cmake_minimum_required(VERSION 3.18)
project(earmark-whisper-server C CXX)

# whisper.cpp source tree at the commit the Mac app is proven against (deploy.sh syncs it here).
set(WHISPER_SRC "$ENV{HOME}/earmark-server/src/whisper.cpp" CACHE PATH "whisper.cpp source tree")
# Blackwell (RTX 50xx, sm_120) needs CUDA >= 12.8. Override with -DCMAKE_CUDA_ARCHITECTURES=... for other GPUs.
set(CMAKE_CUDA_ARCHITECTURES 120a-real CACHE STRING "CUDA architectures")

if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_CUDA ON CACHE BOOL "" FORCE)
# OpenMP on purpose: with ggml's own threadpool (OFF) the CPU VAD is ~6x slower here, and threads > cores spins all
# cores for minutes. OpenMP's catch (a team per thread, kept until the thread exits) is handled by on_own_thread.
set(GGML_OPENMP ON CACHE BOOL "" FORCE)

execute_process(COMMAND git -C "${WHISPER_SRC}" rev-parse HEAD
    OUTPUT_VARIABLE WHISPER_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE git_rc)
if (NOT git_rc EQUAL 0)
    message(FATAL_ERROR "cannot read the whisper.cpp commit in ${WHISPER_SRC}")
endif()
message(STATUS "whisper.cpp commit: ${WHISPER_COMMIT}")

add_subdirectory("${WHISPER_SRC}" whisper.cpp EXCLUDE_FROM_ALL)

add_executable(earmark-whisper-server earmark-whisper-server.cpp)
target_compile_features(earmark-whisper-server PRIVATE cxx_std_17)
target_compile_definitions(earmark-whisper-server PRIVATE WHISPER_COMMIT="${WHISPER_COMMIT}")
# httplib and nlohmann json ship inside the whisper.cpp tree: no extra dependencies.
target_include_directories(earmark-whisper-server PRIVATE "${WHISPER_SRC}/examples/server" "${WHISPER_SRC}/examples")
target_link_libraries(earmark-whisper-server PRIVATE whisper)
