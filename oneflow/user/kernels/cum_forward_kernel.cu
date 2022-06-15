/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include <cub/cub.cuh>
#include <mutex>
#include "oneflow/core/framework/framework.h"
#include "oneflow/core/device/cuda_util.h"
#include "oneflow/core/ep/cuda/cuda_stream.h"
#include "oneflow/core/kernel/new_kernel_util.h"
#include "oneflow/core/ndarray/binary_func.h"

namespace oneflow {
// #ifdef WITH_CUDA
namespace {

template<typename T>
inline T CeilDiv(T n, T m) {
  return (n + m - 1) / m;
}

template<typename T>
struct SumFunctor {
  CUB_RUNTIME_FUNCTION __device__ __forceinline__ T operator()(const T a, const T b) const {
    return a + b;
  }
};
template<typename T>
struct ProdFunctor {
  CUB_RUNTIME_FUNCTION __device__ __forceinline__ T operator()(const T a, const T b) const {
    return a * b;
  }
};

template<typename T, template<typename> class BinaryFunc>
size_t InferTmpBufferSize(user_op::InferContext* ctx) {
  const Shape& in_shape = ctx->InputShape("x", 0);
  const int64_t dim = ctx->Attr<int64_t>("dim");
  const size_t dim_size = in_shape.At(dim);
  if (in_shape.elem_cnt() == dim_size) {
    size_t temp_storage_bytes = 0;
    OF_CUDA_CHECK(cub::DeviceScan::InclusiveScan(nullptr, temp_storage_bytes,
                                                 static_cast<T*>(nullptr), static_cast<T*>(nullptr),
                                                 BinaryFunc<T>(), dim_size));
    return GetCudaAlignedSize(temp_storage_bytes);
  }
  return 0;
}

// total thread number: cs_up_space * cs_down_space
// in cs_down_space part, use cs_down_space threads
// to calculate as follows(m=cs_down_space-1, n=cs_space-1, '|' stands for dependency):
template<typename T, template<typename> class BinaryFunc>
__global__ void CumForwardGpu(const T* in_ptr, T* out_ptr, int64_t cs_up_space, int64_t cs_space,
                              int64_t cs_down_space) {
  CUDA_1D_KERNEL_LOOP(i, cs_up_space * cs_down_space) {
    auto cs_up_space_id = i / cs_down_space;
    auto cs_down_space_id = i - (i / cs_down_space) * cs_down_space;

    auto* in_ptr_base = in_ptr + cs_up_space_id * cs_space * cs_down_space + cs_down_space_id;
    auto* out_ptr_base = out_ptr + cs_up_space_id * cs_space * cs_down_space + cs_down_space_id;

    // calculate cs_space data in one thread
    for (auto j = 0; j < cs_space; j++) {
      auto idx = j * cs_down_space;
      out_ptr_base[idx] = in_ptr_base[idx];
      if (j != 0) {
        out_ptr_base[idx] = BinaryFunc<T>()(out_ptr_base[idx], out_ptr_base[idx - cs_down_space]);
      }
    }
  }
}

template<typename T, template<typename> class BinaryFunc>
void ScanOuterDim(ep::Stream* ep_stream, const ShapeView& in_shape, const int64_t dim,
                  const T* in_ptr, T* out_ptr) {
  // data partition: up_space|space|down_space
  auto up_space = in_shape.elem_cnt() / in_shape.Count(dim);
  auto space = in_shape.At(dim);
  auto down_space = in_shape.Count(dim + 1);
  auto thread_num = up_space * down_space;
  RUN_CUDA_KERNEL((CumForwardGpu<T, BinaryFunc>), ep_stream, thread_num, in_ptr, out_ptr, up_space,
                  space, down_space);
}

template<typename T, int num_threads_x, template<typename> class BinaryFunc>
__inline__ __device__ void ParallelSweepScan(T* row_buf) {
  for (uint32_t s = num_threads_x, d = 1; s >= 1; s >>= 1, d <<= 1) {
    if (threadIdx.x < s) {
      uint32_t offset = (2 * threadIdx.x + 1) * d - 1;
      row_buf[offset + d] = BinaryFunc<T>()(row_buf[offset], row_buf[offset + d]);
    }
    __syncthreads();
  }
  for (uint32_t s = 2, d = num_threads_x / 2; d >= 1; s <<= 1, d >>= 1) {
    if (threadIdx.x < s - 1) {
      uint32_t offset = 2 * (threadIdx.x + 1) * d - 1;
      row_buf[offset + d] = BinaryFunc<T>()(row_buf[offset], row_buf[offset + d]);
    }
    __syncthreads();
  }
}

template<typename T, int num_threads_x, int num_threads_y, template<typename> class BinaryFunc>
__device__ void ScanOutHighDimofMatrixKernelImpl(T* row_buf, T* src_, T* tgt_,
                                                 const uint32_t num_cols, const uint32_t col_size,
                                                 T init) {
  for (uint32_t block_col = blockIdx.x * blockDim.y; block_col < num_cols;
       block_col += blockDim.y * gridDim.x) {
    const uint32_t col = block_col + threadIdx.y;
    T block_total = init;
    T* col_src = src_ + col;
    T* col_tgt = tgt_ + col;

    for (uint32_t block_row = 0; block_row < col_size; block_row += 2 * num_threads_x) {
      uint32_t row1 = block_row + threadIdx.x;
      uint32_t row2 = row1 + num_threads_x;
      uint32_t offset1 = row1 * num_cols;
      uint32_t offset2 = row2 * num_cols;
      if (col < num_cols) {
        if (row1 < col_size) {
          row_buf[threadIdx.x] = col_src[offset1];
        } else {
          row_buf[threadIdx.x] = init;
        }

        if (row2 < col_size) {
          row_buf[num_threads_x + threadIdx.x] = col_src[offset2];
        } else {
          row_buf[num_threads_x + threadIdx.x] = init;
        }
        if (threadIdx.x == 0) { row_buf[0] = BinaryFunc<T>()(row_buf[0], block_total); }
      }
      __syncthreads();
      
      if (col < num_cols) { ParallelSweepScan<T, num_threads_x, BinaryFunc>(row_buf); }

      if (col < num_cols) {
        if (row1 < col_size) { col_tgt[offset1] = row_buf[threadIdx.x]; };
        if (row2 < col_size) { col_tgt[offset2] = row_buf[threadIdx.x + num_threads_x]; };
      }
      block_total = row_buf[2 * num_threads_x - 1];
      __syncthreads();
    }
  }
}

template<typename T, int num_threads_x, int num_threads_y, template<typename> class BinaryFunc>
__global__ void ScanOutHighDimOfMatrixKernel(const T* in_ptr, T* out_ptr, const uint32_t num_cols,
                                             const uint32_t col_size, T init) {
  __shared__ T cols_buffer[num_threads_y][num_threads_x * 2];
  T* col_buf = cols_buffer[threadIdx.y];
  ScanOutHighDimofMatrixKernelImpl<T, num_threads_x, num_threads_y, BinaryFunc>(
      col_buf, const_cast<T*>(in_ptr), out_ptr, num_cols, col_size, init);
}

template<typename T, template<typename> class BinaryFunc>
void ScanOutDimOfMatrix(const T* in_ptr, T* out_ptr, const uint32_t num_cols,
                        const uint32_t cols_size, const ep::CudaStream* cuda_stream) {
  dim3 block(16, 32);
  const int64_t max_grid_dim = cuda_stream->device()->properties().maxGridSize[0];
  dim3 grid(std::min((uint32_t)max_grid_dim, CeilDiv(num_cols, (uint32_t)block.y)));
  ScanOutHighDimOfMatrixKernel<T, /*num_threads_x*/ 16, /*num_threads_y*/ 32, BinaryFunc>
      <<<grid, block, 0, cuda_stream->cuda_stream()>>>(in_ptr, out_ptr, num_cols, cols_size,
                                                       /*init*/ 0);
}

// Refer from
// https://github.com/pytorch/pytorch/blob/master/aten/src/ATen/native/cuda/ScanKernels.cu
template<typename T, int num_threads_x, int num_threads_y, template<typename> class BinaryFunc>
__device__ void ScanInnerMostDimKernelImpl(T* row_buf, T* src_, T* tgt_, const uint32_t num_rows,
                                           const uint32_t row_size, T init) {
  for (uint32_t block_row = blockIdx.x * blockDim.y; block_row < num_rows;
       block_row += blockDim.y * gridDim.x) {
    uint32_t row = block_row + threadIdx.y;
    T block_total = init;

    T* row_src = src_ + row * row_size;
    T* row_tgt = tgt_ + row * row_size;

    // Perform scan on one block at a time, keeping track of the total value of
    // all blocks processed so far.
    for (uint32_t block_col = 0; block_col < row_size; block_col += 2 * num_threads_x) {
      // Load data into shared memory (two values per thread).
      uint32_t col1 = block_col + threadIdx.x;
      uint32_t col2 = block_col + num_threads_x + threadIdx.x;
      if (row < num_rows) {
        if (col1 < row_size) {
          row_buf[threadIdx.x] = row_src[col1];
        } else {
          row_buf[threadIdx.x] = init;
        }

        if (col2 < row_size) {
          row_buf[num_threads_x + threadIdx.x] = row_src[col2];
        } else {
          row_buf[num_threads_x + threadIdx.x] = init;
        }

        // Add the total value of all previous blocks to the first value of this block.
        if (threadIdx.x == 0) { row_buf[0] = BinaryFunc<T>()(row_buf[0], block_total); }
      }
      __syncthreads();

      if (row < num_rows) { SweepScan<T, num_threads_x, BinaryFunc>(row_buf); }

      // Write back to output.
      if (row < num_rows) {
        if (col1 < row_size) row_tgt[col1] = row_buf[threadIdx.x];
        if (col2 < row_size) row_tgt[col2] = row_buf[num_threads_x + threadIdx.x];
      }
      block_total = row_buf[2 * num_threads_x - 1];
      __syncthreads();
    }
  }
}

template<typename T, int num_threads_x, int num_threads_y, template<typename> class BinaryFunc>
__global__ void ScanInnerMostDimKernel(const T* in_ptr, T* out_ptr, const int64_t num_rows,
                                       const int64_t row_size, T init) {
  __shared__ T sbuf[num_threads_y][2 * num_threads_x];
  T* row_buf = sbuf[threadIdx.y];
  ScanInnerMostDimKernelImpl<T, num_threads_x, num_threads_y, BinaryFunc>(
      row_buf, const_cast<T*>(in_ptr), out_ptr, num_rows, row_size, init);
}

template<typename T, template<typename> class BinaryFunctor>
void ScanInnerMostDim(const T* in_ptr, T* out_ptr, const int64_t num_rows, const int64_t row_size,
                      const ep::CudaStream* cuda_stream) {
  dim3 block(16, 32);
  const int64_t max_grid_dim = cuda_stream->device()->properties().maxGridSize[0];
  dim3 grid(std::min(max_grid_dim, CeilDiv(num_rows, (int64_t)block.y)));
  ScanInnerMostDimKernel<T, 16, 32, BinaryFunctor>
      <<<grid, block, 0, cuda_stream->cuda_stream()>>>(in_ptr, out_ptr, num_rows, row_size, 0);
}

template<typename T, template<typename> class BinaryFunc>
void CubInclusiveScan(user_op::Tensor* temp_buffer, const T* in_ptr, T* out_ptr,
                      const int64_t elem_cnt, const ep::CudaStream* cuda_stream) {
  auto* temp_storage = temp_buffer->mut_dptr<T>();
  size_t temp_storage_bytes = temp_buffer->shape().elem_cnt();
  OF_CUDA_CHECK(cub::DeviceScan::InclusiveScan(temp_storage, temp_storage_bytes, in_ptr, out_ptr,
                                               BinaryFunc<T>(), elem_cnt,
                                               cuda_stream->cuda_stream()));
}
}  // namespace

template<typename T, template<typename> class BinaryFunc>
class GpuCumKernel : public user_op::OpKernel {
 public:
  GpuCumKernel() = default;
  ~GpuCumKernel() = default;

 private:
  using user_op::OpKernel::Compute;
  void Compute(user_op::KernelComputeContext* ctx) const override {
    // Judge whether tensor has 0 size dimension first
    const auto* in = ctx->Tensor4ArgNameAndIndex("x", 0);
    auto* out = ctx->Tensor4ArgNameAndIndex("y", 0);
    const ShapeView& in_shape = in->shape();
    const int64_t dim = ctx->Attr<int64_t>("dim");
    const int64_t dim_size = in_shape.At(dim);

    auto elem_cnt = in_shape.elem_cnt();
    if (!elem_cnt) { return; }

    const auto* in_ptr = in->dptr<T>();
    auto* out_ptr = out->mut_dptr<T>();

    const auto* cuda_stream = ctx->stream()->As<ep::CudaStream>();

    if (elem_cnt == dim_size) {
      auto* temp_buffer = ctx->Tensor4ArgNameAndIndex("tmp_buffer", 0);
      CubInclusiveScan<T, BinaryFunc>(temp_buffer, in_ptr, out_ptr, elem_cnt, cuda_stream);
    } else if (dim == in_shape.NumAxes() - 1) {
      // Treat all outer dimension as a single dimension.
      const int64_t num_rows = elem_cnt / dim_size;
      ScanInnerMostDim<T, BinaryFunc>(in_ptr, out_ptr, num_rows, dim_size, cuda_stream);
    } else if (in_shape.NumAxes() == 2 && dim == 0) {
      const uint32_t cols_size = in_shape.At(0);
      const uint32_t num_cols = in_shape.At(1);
      ScanOutDimOfMatrix<T, BinaryFunc>(in_ptr, out_ptr, num_cols, cols_size, cuda_stream);
    } else {
      ScanOuterDim<T, BinaryFunc>(ctx->stream(), in_shape, dim, in_ptr, out_ptr);
    }
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

template<typename T>
class GpuCumSumKernel final : public GpuCumKernel<T, SumFunctor> {
 public:
  GpuCumSumKernel() = default;
  ~GpuCumSumKernel() = default;
};

#define REGISTER_CUDA_CUMSUM_KERNEL(dtype)                                             \
  REGISTER_USER_KERNEL("cumsum")                                                       \
      .SetCreateFn<GpuCumSumKernel<dtype>>()                                           \
      .SetIsMatchedHob((user_op::HobDeviceType() == DeviceType::kCUDA)                 \
                       && (user_op::HobDataType("y", 0) == GetDataType<dtype>::value)) \
      .SetInferTmpSizeFn(InferTmpBufferSize<dtype, SumFunctor>);

REGISTER_CUDA_CUMSUM_KERNEL(int32_t)
REGISTER_CUDA_CUMSUM_KERNEL(int64_t)
REGISTER_CUDA_CUMSUM_KERNEL(float)
REGISTER_CUDA_CUMSUM_KERNEL(double)
#undef REGISTER_CUDA_CUMSUM_KERNEL

template<typename T>
class GpuCumProdKernel final : public GpuCumKernel<T, ProdFunctor> {
 public:
  GpuCumProdKernel() = default;
  ~GpuCumProdKernel() = default;
};

#define REGISTER_CUDA_CUMPROD_KERNEL(dtype)                                            \
  REGISTER_USER_KERNEL("cumprod")                                                      \
      .SetCreateFn<GpuCumProdKernel<dtype>>()                                          \
      .SetIsMatchedHob((user_op::HobDeviceType() == DeviceType::kCUDA)                 \
                       && (user_op::HobDataType("y", 0) == GetDataType<dtype>::value)) \
      .SetInferTmpSizeFn(InferTmpBufferSize<dtype, ProdFunctor>);

REGISTER_CUDA_CUMPROD_KERNEL(int32_t)
REGISTER_CUDA_CUMPROD_KERNEL(int64_t)
REGISTER_CUDA_CUMPROD_KERNEL(float)
REGISTER_CUDA_CUMPROD_KERNEL(double)
#undef REGISTER_CUDA_CUMPROD_KERNEL
// #endif
}  // namespace oneflow
