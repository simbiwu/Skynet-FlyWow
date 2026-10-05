using System;

namespace FlyWow.Navigation.Editor
{
    /// <summary>
    /// 一次导出过程共用的内存地图数据，包含地图参数和按行排列的 Cell 数组。
    /// 后续检查、场景显示和文件写入都读取同一个实例。
    /// </summary>
    public sealed class NavigationMapSnapshot
    {
        // 文件元数据的来源；位置和尺寸按毫米/Cell 保存。
        // 地图 ID。
        public uint mapId;
        // BMAP Header 的地图资产版本。
        public uint mapVersion;
        // X 方向 Cell 数。
        public int width;
        // Z 方向 Cell 数。
        public int height;
        // Cell 边长，单位毫米。
        public int cellSizeMm;
        // Grid 左下角世界 X，单位毫米。
        public int originXMm;
        // Grid 左下角世界 Z，单位毫米。
        public int originZMm;
        // Row-major：index = z * width + x。长度必须等于 width * height。
        public NavCell[] cells = Array.Empty<NavCell>();

        /// <param name="x">Grid X 下标。</param>
        /// <param name="z">Grid Z 下标。</param>
        /// <returns>row-major Cell 数组下标。</returns>
        public int IndexOf(int x, int z)
        {
            // 显式范围错误比错误索引到另一行更容易定位资产问题。
            if (x < 0 || x >= width || z < 0 || z >= height)
            {
                throw new ArgumentOutOfRangeException(
                    string.Format("grid outside snapshot: ({0},{1})", x, z));
            }

            return checked(z * width + x);
        }

        /// <summary>按 Grid 坐标读取 Cell 值。</summary>
        /// <param name="x">Grid X 下标。</param>
        /// <param name="z">Grid Z 下标。</param>
        public NavCell CellAt(int x, int z)
        {
            return cells[IndexOf(x, z)];
        }
    }
}