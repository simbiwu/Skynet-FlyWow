---@meta

--- Navigation 入口、样例和测试共同引用的坐标及错误合同。

---@class FlyWowNavigationPosition
---@field x_mm integer 世界 X，整数毫米；调用方持有的纯数据。
---@field y_mm integer 世界高度 Y，整数毫米；地面移动由地图归一化，空中由调用方指定。
---@field z_mm integer 世界 Z，整数毫米；不是 Grid 下标。

---@class FlyWowNavigationError
---@field code string 稳定机器错误码；按此字段分支，不解析文案。
---@field position? FlyWowNavigationPosition 空中推进预算失败时最后提交位置；其它错误可无此字段。
---@field message string 诊断上下文；只用于日志，不进入业务判断。
