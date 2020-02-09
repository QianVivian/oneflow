#ifndef ONEFLOW_CORE_VM_LOGICAL_OBJECT_ID_MSG_H_
#define ONEFLOW_CORE_VM_LOGICAL_OBJECT_ID_MSG_H_

#include "oneflow/core/common/flat_msg.h"

namespace oneflow {

// clang-format off
BEGIN_FLAT_MSG(LogicalObjectId);
  // fields
  FLAT_MSG_DEFINE_ONEOF(ptr_type,
    FLAT_MSG_ONEOF_FIELD(uint64_t, remote_value)
    FLAT_MSG_ONEOF_FIELD(uint64_t, local_value));

  // methods
  FLAT_MSG_DEFINE_COMPARE_OPERATORS_BY_MEMCMP();
END_FLAT_MSG(LogicalObjectId);
// clang-format on

}  // namespace oneflow

#endif  // ONEFLOW_CORE_VM_LOGICAL_OBJECT_ID_MSG_H_
