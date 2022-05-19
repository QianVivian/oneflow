#include "oneflow/core/framework/framework.h"
#include "oneflow/core/device/cuda_util.h"
#include "oneflow/core/ep/cuda/cuda_stream.h"
#include <cuda.h>
#include "oneflow/core/kernel/cuda_graph_support.h"
#include "oneflow/core/cuda/elementwise.cuh"

namespace oneflow {

namespace {

constexpr int32_t kWarpSize = 32; 

template<typename T, int pack_size, bool tail>
__global__ void VectorizedReluDropoutBitmaskBackwardKernel(
    const int64_t elem_cnt, const int64_t cols, const int64_t aux_ld, 
    const float scale, const int64_t n_tail, const int64_t tail_offset, 
    const T* dy, const int32_t* mask, T* dx) {
  int32_t global_thread_id = blockIdx.x * blockDim.x + threadIdx.x;
  using LoadStoreType = cuda::elementwise::PackType<T, pack_size>;
  using LoadStorePack = cuda::elementwise::Pack<T, pack_size>;
  
  T t_scale = static_cast<T>(scale);
  for (int64_t linear_pack_index = global_thread_id * pack_size; linear_pack_index < elem_cnt;
    linear_pack_index += gridDim.x * blockDim.x * pack_size) {

    const LoadStoreType* dy_load = reinterpret_cast<const LoadStoreType*>(dy + linear_pack_index);
    LoadStorePack dy_vec;
    dy_vec.storage = *dy_load;

    LoadStorePack dx_vec;
#pragma unroll
    for (int i = 0; i < pack_size; i++) {
        const int64_t linear_index = (linear_pack_index + i); 
        const int64_t row = linear_index / cols; 
        const int64_t col = linear_index - row * cols; 
        const int32_t lane_id = col % kWarpSize; 
        const int64_t aux_idx = ((row * aux_ld) + col) / kWarpSize; 
        bool is_positive = mask[aux_idx] & (1 << lane_id);
        dx_vec.elem[i] = dy_vec.elem[i] * static_cast<T>(is_positive) * static_cast<T>(scale); 
    }
    *(reinterpret_cast<LoadStoreType*>(dx + linear_pack_index)) = dx_vec.storage;
  }

  if (tail && global_thread_id < n_tail) {
    const int64_t tail_index = tail_offset + global_thread_id; 
    const int64_t tail_row = tail_index / cols; 
    const int64_t tail_col = tail_index - tail_row * cols; 
    const int32_t tail_lane_id = tail_col % kWarpSize; 
    const int64_t tail_aux_idx = ((tail_row * aux_ld) + tail_col) / kWarpSize; 
    bool is_positive = mask[tail_aux_idx] & (1 << tail_lane_id);
    dx[tail_index] = dy[tail_index] * static_cast<T>(is_positive) * static_cast<T>(scale); 
  }
}

template<typename T>
void LaunchVectorizedReluDropoutBackwardKernel(ep::Stream* stream, 
                                                const int64_t elem_cnt, const int64_t cols, 
                                                const int64_t aux_ld, float scale, 
                                                const T* dy, const int32_t* mask,
                                                T* dx) {
  constexpr int pack_size = cuda::elementwise::PackSize<T>();
  const int64_t pack_num = elem_cnt / pack_size;
  const int64_t tail_offset = pack_num * pack_size;
  const int64_t n_tail = elem_cnt - tail_offset;
  const bool tail = n_tail > 0 ? true : false;
  if (tail) {
    stream->As<ep::CudaStream>()->LaunchKernelDefaultWaves(
        (VectorizedReluDropoutBitmaskBackwardKernel<T, pack_size, true>), 
        pack_num, elem_cnt, cols, aux_ld, scale, n_tail, tail_offset, 
        dy, mask, dx);
  } else {
    stream->As<ep::CudaStream>()->LaunchKernelDefaultWaves(
        (VectorizedReluDropoutBitmaskBackwardKernel<T, pack_size, true>), 
        pack_num, elem_cnt, cols, aux_ld, scale, /*n_tail=*/0, tail_offset, 
        dy, mask, dx);
  }
}

template<typename T>
class FusedReluDropoutGradKernel final : public user_op::OpKernel,
                                                    public user_op::CudaGraphSupport {
    public:
    FusedReluDropoutGradKernel() = default;
    ~FusedReluDropoutGradKernel() override = default;

    private:
    using user_op::OpKernel::Compute;
    void Compute(user_op::KernelComputeContext* ctx) const override {

    const user_op::Tensor* dy = ctx->Tensor4ArgNameAndIndex("dy", 0);
    const user_op::Tensor* mask = ctx->Tensor4ArgNameAndIndex("mask", 0);
    user_op::Tensor* dx = ctx->Tensor4ArgNameAndIndex("dx", 0);
    const float scale = ctx->Attr<float>("scale");

    const int64_t cols = dy->shape().At(1); 
    const int64_t aux_ld = mask->shape().At(1) * 32; 
    const int64_t elem_cnt = dy->shape().elem_cnt(); 
    LaunchVectorizedReluDropoutBackwardKernel<T>(ctx->stream(), 
                                                 elem_cnt, 
                                                 cols, aux_ld, scale, 
                                                 reinterpret_cast<const T*>(dy->dptr()), mask->dptr<int32_t>(), 
                                                 reinterpret_cast<T*>(dx->mut_dptr())); 
    }

    bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

#define REGISTER_FUSED_RELU_DROPOUT_GRAD_KERNEL_GPU(cpp_type, data_type)     \
    REGISTER_USER_KERNEL("fused_relu_dropout_grad")                            \
        .SetCreateFn<FusedReluDropoutGradKernel<cpp_type>>()                     \
        .SetIsMatchedHob((user_op::HobDeviceType() == DeviceType::kCUDA)                  \
                        && (user_op::HobDataType("dx", 0) == data_type));

REGISTER_FUSED_RELU_DROPOUT_GRAD_KERNEL_GPU(float, DataType::kFloat)


} // namespace 

} // namespace oneflow 
