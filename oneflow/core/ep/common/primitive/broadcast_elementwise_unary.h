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
#ifndef ONEFLOW_CORE_PRIMITIVE_COMMON_BROADCAST_ELEMENTWISE_UNARY
#define ONEFLOW_CORE_PRIMITIVE_COMMON_BROADCAST_ELEMENTWISE_UNARY

#include "oneflow/core/ep/include/primitive/broadcast_elementwise_unary.h"
#include "oneflow/core/ep/include/primitive/fast_integer_math.h"
#include "oneflow/core/ep/common/primitive/util.h"

namespace oneflow {

namespace ep {
namespace primitive {

namespace broadcast_elementwise_unary {

constexpr size_t kMaxNumDims = 8;

inline void CheckInplace(size_t num_dims, const int64_t* src0_dims, const void* src0,
                         const int64_t* src1_dims, const void* src1, const int64_t* dst_dims,
                         const void* dst) {
  for (int64_t i = 0; i < num_dims; ++i) {
    if (src0 == dst) { CHECK_EQ(src0_dims[i], dst_dims[i]); }
    if (src1 == dst) { CHECK_EQ(src1_dims[i], dst_dims[i]); }
  }
}

inline bool IsDimsEquals(size_t num_src0_dims, const int64_t* src0_dims, size_t num_src1_dims,
                         const int64_t* src1_dims) {
  if (num_src0_dims != num_src1_dims) { return false; }
  for (size_t i = 0; i < num_src1_dims; ++i) {
    if (src0_dims[i] != src1_dims[i]) { return false; }
  }
  return true;
}

template<typename T, int N>
class IndexToOffsetWithStrideCalculator {
 public:
  IndexToOffsetWithStrideCalculator() {}

  OF_DEVICE_FUNC explicit IndexToOffsetWithStrideCalculator(const T* dims, const T* strides) {
    InitStrides(dims, strides, N);
  }

  OF_DEVICE_FUNC explicit IndexToOffsetWithStrideCalculator(const T* dims, const T* strides,
                                                            int n) {
    InitStrides(dims, strides, n);
  }

  ~IndexToOffsetWithStrideCalculator() = default;

  OF_DEVICE_FUNC T NdIndexToOffset(const T* index) const {
    T offset = 0;
#ifdef __CUDA_ARCH__
#pragma unroll
#endif
    for (int i = 0; i < N - 1; ++i) { offset += index[i] * stride_[i]; }
    offset += index[N - 1];
    return offset;
  }

  OF_DEVICE_FUNC T NdIndexToOffset(const T* index, int n) const {
    assert(n <= N);
    T offset = 0;
#ifdef __CUDA_ARCH__
#pragma unroll
#endif
    for (int i = 0; i < N; ++i) {
      if (i < n) { offset += index[i] * stride_[i]; }
    }
    return offset;
  }

  OF_DEVICE_FUNC constexpr int Size() const { return N; }

 private:
  OF_DEVICE_FUNC void InitStrides(const T* dims, const T* strides, const int n) {
    for (int i = n; i < N; ++i) { stride_[i] = 1; }
    for (int i = n - 1; i >= 0; --i) { stride_[i] = strides[i]; }
  }

  T stride_[N];
};

template<typename T, int N>
class OffsetToIndexWithStrideCalculator {
 public:
  OffsetToIndexWithStrideCalculator() {}

  OF_DEVICE_FUNC explicit OffsetToIndexWithStrideCalculator(const T* dims) {
    InitFastIntegerMath(dims, N);
  }

  OF_DEVICE_FUNC explicit OffsetToIndexWithStrideCalculator(const T* dims, int n) {
    InitFastIntegerMath(dims, n);
  }

  ~OffsetToIndexWithStrideCalculator() = default;

  OF_DEVICE_FUNC void OffsetToNdIndex(T offset, T* index) const {
    T remaining = offset;
#ifdef __CUDA_ARCH__
#pragma unroll
#endif
    for (int i = 0; i < N - 1; ++i) {
      const T idx = math_helper_[i].divides(remaining);
      index[i] = idx;
      remaining = remaining - math_helper_[i].mul(idx);
    }
    index[N - 1] = remaining;
  }

  OF_DEVICE_FUNC void OffsetToNdIndex(T offset, T* index, int n) const {
    assert(n <= N);
    T remaining = offset;
#ifdef __CUDA_ARCH__
#pragma unroll
#endif
    for (int i = 0; i < N; ++i) {
      if (i == n - 1) { break; }
      if (i < n - 1) {
        const T idx = math_helper_[i].divides(remaining);
        index[i] = idx;
        remaining = remaining - math_helper_[i].mul(idx);
      }
    }
    index[n - 1] = remaining;
  }

  OF_DEVICE_FUNC constexpr int Size() const { return N; }

 private:
  OF_DEVICE_FUNC void InitFastIntegerMath(const T* dims, const int n) {
    T stride_arr[N];
    for (int i = n - 1; i < N; ++i) {
      stride_arr[i] = 1;
      math_helper_[i] = FastIntegerMath<T>(1);
    }
    for (int i = n - 2; i >= 0; --i) {
      stride_arr[i] = dims[i + 1] * stride_arr[i + 1];
      math_helper_[i] = FastIntegerMath<T>(stride_arr[i]);
    }
  }
  FastIntegerMath<T> math_helper_[N];
};

#define UNARY_BROADCAST_OP_SEQ OF_PP_MAKE_TUPLE_SEQ(UnaryOp::kIdentity)

}  // namespace broadcast_elementwise_unary
}  // namespace primitive
}  // namespace ep

}  // namespace oneflow

#endif  // ONEFLOW_CORE_PRIMITIVE_COMMON_BROADCAST_ELEMENTWISE_UNARY
