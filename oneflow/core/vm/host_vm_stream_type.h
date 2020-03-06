#ifndef ONEFLOW_CORE_VM_HOST_VM_STREAM_TYPE_H_
#define ONEFLOW_CORE_VM_HOST_VM_STREAM_TYPE_H_

#include "oneflow/core/vm/vm_stream_type.h"

namespace oneflow {

class VmScheduler;
class VmInstructionMsg;

class HostVmStreamType final : public VmStreamType {
 public:
  HostVmStreamType() = default;
  ~HostVmStreamType() = default;

  static const VmStreamTypeId kVmStreamTypeId = 2;

  ObjectMsgPtr<VmInstructionMsg> CudaMallocHost(uint64_t symbol, size_t size) const;
  ObjectMsgPtr<VmInstructionMsg> CudaFreeHost(uint64_t symbol) const;

  void InitVmInstructionStatus(const VmStream& vm_stream,
                               VmInstructionStatusBuffer* status_buffer) const override;
  void DeleteVmInstructionStatus(const VmStream& vm_stream,
                                 VmInstructionStatusBuffer* status_buffer) const override;
  bool QueryVmInstructionStatusDone(const VmStream& vm_stream,
                                    const VmInstructionStatusBuffer& status_buffer) const override;
  void Run(VmInstrChainPackage* vm_instr_chain_pkg) const override;
};

}  // namespace oneflow

#endif  // ONEFLOW_CORE_VM_HOST_VM_STREAM_TYPE_H_
