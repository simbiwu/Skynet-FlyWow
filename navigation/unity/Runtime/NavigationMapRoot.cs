// 职责：声明一张导航场景 导出 BMAP 所需的唯一地图级 Authoring 参数。
// 边界：Unity Authoring；参数进入导出资产，Server 不加载本组件。
// 输入/输出：Inspector 米制配置 -> Sampler、Validator 和 Writer 使用的地图合同。
// 生命周期：每张导航场景 恰好一个；随 Scene 保存。
// 不负责：不 Bake NavMesh、不采样 Cell、不执行运行时寻路。
using System;
using UnityEngine;

namespace FlyWow.Navigation
{
    /// <summary>
    /// Unity 场景中的唯一地图 Authoring Contract。
    /// Inspector 使用米，导出边界统一转换为整数毫米。
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class NavigationMapRoot : MonoBehaviour
    {
        // mapVersion 必须在任何影响导航语义的修改后递增。
        // 本场景候选资产输出目录；相对 Unity 工程根，不是 Server Runtime 路径。
        [Header("Export")]
        public string exportDirectory = "NavigationExports";

        [Header("Identity")]
        // BMAP Header 的无符号数值地图 ID；0 保留为非法值。
        [Min(1)]
        public uint mapId = 1;
        // 当前地图资产版本；用于拒绝客户端/服务端资产错配。
        [Min(1)]
        public uint mapVersion = 1;

        // 明确配置 Server Grid，禁止从 Renderer/NavMesh Bounds 猜测。
        // originMeters 是 XZ 左下角；sizeX/sizeZ 必须能被 cellSize 整除。
        [Header("Grid in Unity meters")]
        // Grid 左下角世界坐标：(Unity world X, Unity world Z)，单位米。
        public Vector2 originMeters = Vector2.zero;
        // Grid 沿世界 X 轴覆盖的物理长度，单位米。
        [Min(0.1f)]
        public float sizeXMeters = 30f;
        // Grid 沿世界 Z 轴覆盖的物理长度，单位米。
        [Min(0.1f)]
        public float sizeZMeters = 20f;
        // 正方形 Cell 的边长，单位米；导出时转换成 cell_size_mm。
        [Min(0.01f)]
        public float cellSizeMeters = 0.5f;

        // 分层阈值只合并同一表面的浮点误差，不能吞掉真实楼层。
        [Header("Sampling")]
        // 两个候选高度差不超过该值时视为同一层，单位米。
        [Min(0.01f)]
        public float multiLayerSeparationMeters = 0.25f;

        // Grid 沿世界 X 的 Cell 数，由 sizeXMeters / cellSizeMeters 严格计算。
        public int Width
        {
            get {
                return CheckedCellCount(sizeXMeters, cellSizeMeters, "sizeX");
            }
        }

        // Grid 沿世界 Z 的 Cell 数，由 sizeZMeters / cellSizeMeters 严格计算。
        public int Height
        {
            get {
                return CheckedCellCount(sizeZMeters, cellSizeMeters, "sizeZ");
            }
        }

        // 导出到 BMAP Header 的 Cell 边长，单位毫米。
        public int CellSizeMm
        {
            get {
                return MetersToMillimeters(cellSizeMeters, "cellSize");
            }
        }

        // 导出到 BMAP Header 的 Grid 左下角世界 X，单位毫米。
        public int OriginXMm
        {
            get {
                return MetersToMillimeters(originMeters.x, "originX");
            }
        }

        // 导出到 BMAP Header 的 Grid 左下角世界 Z，单位毫米。
        public int OriginZMm
        {
            get {
                return MetersToMillimeters(originMeters.y, "originZ");
            }
        }

        /// <summary>把合法 Grid 下标转换成 Unity 世界空间的 Cell Center。</summary>
        /// <param name="x">Grid X 下标。</param>
        /// <param name="z">Grid Z 下标。</param>
        /// <returns>Cell 中心的世界 XZ；Y 固定为 0 且不参与采样。</returns>
        public Vector3 GridToWorldCenter(int x, int z)
        {
            // Grid 坐标只允许落在当前地图内；调用者不能依赖数组越界异常碰巧兜底。
            if (x < 0 || x >= Width || z < 0 || z >= Height)
            {
                throw new ArgumentOutOfRangeException(
                    string.Format("grid outside map: ({0},{1})", x, z));
            }

            // 先找到第 x 格左边界：origin + x * cellSize，再向右移动半格到中心。
            // 因此 center = origin + x * cellSize + cellSize / 2。
            // 后两项都有 cellSize，提出公因子得到 origin + (x + 0.5) * cellSize。
            // 例如原点 -15、边长 0.5、第 3 格：左边界 -13.5，再加 0.25 得 -13.25 米。
            // 下标从 0 开始；Z 轴同理，Unity Sampler 与 C++ 查询使用同一约定。
            return new Vector3(originMeters.x + (x + 0.5f) * cellSizeMeters, 0f,
                               originMeters.y + (z + 0.5f) * cellSizeMeters);
        }

        /// <summary>在采样或分配数组前验证地图合同；失败时抛出明确异常。</summary>
        public void ValidateOrThrow()
        {
            // 资产身份为 0 没有业务含义，禁止生成“匿名可加载”地图。
            if (mapId == 0 || mapVersion == 0)
            {
                throw new InvalidOperationException("mapId/mapVersion must be non-zero");
            }

            if (!float.IsFinite(originMeters.x) || !float.IsFinite(originMeters.y))
            {
                throw new InvalidOperationException("originMeters contains invalid number");
            }

            // 在分配数组前显式检查 Cell 数量乘法溢出。
            // 当前 Grid 的 X 方向 Cell 数。
            int width = Width;
            // 当前 Grid 的 Z 方向 Cell 数。
            int height = Height;
            checked
            {
                _ = width * height;
            }
        }

        /// <param name="size">某一世界轴的地图长度，单位米。</param>
        /// <param name="cellSize">Cell 边长，单位米。</param>
        /// <param name="field">用于错误信息的字段名。</param>
        /// <returns>该轴严格整除得到的 Cell 数。</returns>
        private static int CheckedCellCount(float size, float cellSize, string field)
        {
            // NaN/Infinity 会破坏比较和序列化，必须在 Authoring 阶段拒绝。
            if (!float.IsFinite(size) || !float.IsFinite(cellSize) || size <= 0f || cellSize <= 0f)
            {
                throw new InvalidOperationException(field + " contains invalid number");
            }

            // 不允许截断半格，否则 Unity 边界与 Server width/height 会产生不同解释。
            // 未取整的 Cell 数，用 double 降低 float 除法误差对整除判断的影响。
            double cells = size / cellSize;
            // 按固定规则得到最近整数，用于与原值比较而不是静默截断。
            double rounded = Math.Round(cells, MidpointRounding.AwayFromZero);
            if (Math.Abs(cells - rounded) > 0.000001)
            {
                throw new InvalidOperationException(field +
                                                    " must be an integer multiple of cellSize");
            }

            return checked((int)rounded);
        }

        /// <param name="meters">待转换的 Unity 米制数值。</param>
        /// <param name="field">用于错误信息的字段名。</param>
        /// <returns>使用固定舍入规则得到的毫米整数。</returns>
        public static int MetersToMillimeters(float meters, string field)
        {
            if (!float.IsFinite(meters))
            {
                throw new InvalidOperationException(field + " is not finite");
            }

            // AwayFromZero 固定 .5 的舍入规则，负坐标不能依赖默认银行家舍入。
            return checked((int)Math.Round(meters * 1000.0, MidpointRounding.AwayFromZero));
        }
    }
}
