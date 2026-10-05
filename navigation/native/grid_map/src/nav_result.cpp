// 职责：实现 NavError 到稳定日志名称的一对一映射。
// 边界：Server Runtime 错误展示层；不包含 Reader 或查询业务逻辑。
// 输入/输出：NavError -> 生命周期覆盖整个进程的只读字符串。
// 不负责：不本地化文案，不拼接文件路径或调用上下文。
#include "nav_result.h"

namespace flywow_navigation
{

const char *NavErrorName(NavError error) noexcept
{
    // switch 保持穷举可审查；新增 NavError 时必须同步增加对应名称。
    switch (error)
    {
    case NavError::kOk:
        return "OK";
    case NavError::kIoError:
        return "IO_ERROR";
    case NavError::kBadMagic:
        return "BMAP_BAD_MAGIC";
    case NavError::kUnsupportedVersion:
        return "BMAP_UNSUPPORTED_VERSION";
    case NavError::kInvalidHeaderSize:
        return "BMAP_INVALID_HEADER_SIZE";
    case NavError::kInvalidDimensions:
        return "BMAP_INVALID_DIMENSIONS";
    case NavError::kSizeOverflow:
        return "BMAP_SIZE_OVERFLOW";
    case NavError::kInvalidStride:
        return "BMAP_INVALID_CELL_STRIDE";
    case NavError::kPayloadSizeMismatch:
        return "BMAP_PAYLOAD_SIZE_MISMATCH";
    case NavError::kHeaderCrcMismatch:
        return "BMAP_HEADER_CRC_MISMATCH";
    case NavError::kPayloadCrcMismatch:
        return "BMAP_PAYLOAD_CRC_MISMATCH";
    case NavError::kTruncated:
        return "BMAP_TRUNCATED";
    case NavError::kTrailingBytes:
        return "BMAP_TRAILING_BYTES";
    case NavError::kDuplicateMap:
        return "DUPLICATE_MAP_VERSION";
    case NavError::kRegistryFrozen:
        return "REGISTRY_FROZEN";
    case NavError::kMapNotFound:
        return "MAP_NOT_FOUND";
    case NavError::kOutOfBounds:
        return "OUT_OF_BOUNDS";
    case NavError::kInvalidArgument:
        return "INVALID_ARGUMENT";
    case NavError::kInvalidAgent:
        return "INVALID_AGENT";
    case NavError::kStartNotNavigable:
        return "START_NOT_NAVIGABLE";
    case NavError::kEndNotNavigable:
        return "END_NOT_NAVIGABLE";
    case NavError::kNoPath:
        return "NO_PATH";
    case NavError::kContextClosed:
        return "CONTEXT_CLOSED";
    case NavError::kPathTooLong:
        return "PATH_TOO_LONG";
    case NavError::kDynamicOccupied:
        return "DYNAMIC_OCCUPIED";
    case NavError::kMoveBlocked:
        return "MOVE_BLOCKED";
    case NavError::kInternalError:
        return "INTERNAL_ERROR";
    }
    return "UNKNOWN_NAV_ERROR"; // 防御非法强制转换得到的未知枚举值。
}

} // namespace flywow_navigation
