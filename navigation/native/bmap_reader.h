// 职责：声明 BMAP V1 文件读取入口，将不可信文件校验后转换成 immutable GridMap。
// 边界：Server Asset Loader；仅在启动或显式资产加载阶段执行文件 I/O。
// 输入/输出：BMAP 文件路径 -> GridMap shared_ptr 或具体 NavError。
// 不负责：不注册地图、不执行运行时查询、不容忍未知尾部数据。
#pragma once

#include "grid_map.h"
#include "nav_result.h"

#include <memory>
#include <string>

namespace flywow_navigation
{

class BMapReader final
{
  public:
    // 完整读取并校验 path 指向的 BMAP V1。
    // 成功返回 immutable GridMap；I/O、Magic、版本、尺寸、CRC 等失败返回对应 NavError。
    // 本函数执行文件 I/O，分配完整文件缓冲和解码后的 Cell 数组，只应在资产加载阶段调用。
    // 成功地图独立拥有数据；前期缓冲分配等 C++ 异常可能传播，由调用边界处理。
    static NavResult<std::shared_ptr<const GridMap>> Read(const std::string &path);
};

} // namespace flywow_navigation
