// 职责：在写盘前验证 Snapshot 与地图合同是否满足导出约束。
// 边界：Unity Editor Asset Pipeline Gate；失败即阻止生成 BMAP。
// 输入/输出：NavigationMapRoot + Snapshot -> 成功或明确异常。
// 不负责：不修复 Scene、不重新 Bake、不静默忽略坏数据。
using System;
using System.Collections.Generic;
using UnityEngine;

namespace FlyWow.Navigation.Editor
{
    /// <summary>
    /// 在写盘前验证 Snapshot 与 Scene Authoring 的一致性。
    /// 发现错误只抛出明确异常，不静默修复地图或 Cell。
    /// </summary>
    public static class NavigationMapValidator
    {
        /// <param name="root">当前 Scene 的地图合同。</param>
        /// <param name="snapshot">已经完成 Sampling 和 Clearance 的待验证快照。</param>
        public static void ValidateSnapshot(NavigationMapRoot root, NavigationMapSnapshot snapshot)
        {
            if (root == null || snapshot == null)
            {
                throw new ArgumentNullException("root/snapshot");
            }

            if (snapshot.mapId != root.mapId || snapshot.mapVersion != root.mapVersion ||
                snapshot.width != root.Width || snapshot.height != root.Height ||
                snapshot.cellSizeMm != root.CellSizeMm)
            {
                throw new InvalidOperationException("SNAPSHOT_METADATA_MISMATCH");
            }

            // 由 Header 尺寸推导的唯一合法 Cell 数量。
            int expectedCount = checked(snapshot.width * snapshot.height);
            if (snapshot.cells == null || snapshot.cells.Length != expectedCount)
            {
                throw new InvalidOperationException("SNAPSHOT_CELL_COUNT_MISMATCH");
            }

            // 可走格统计用于拒绝空地图并输出可观察日志。
            int walkableCount = 0;
            // 可走表面的最小世界 Y，单位毫米。
            int minHeight = int.MaxValue;
            // 可走表面的最大世界 Y，单位毫米。
            int maxHeight = int.MinValue;
            // i 是 Snapshot.cells 的 row-major 数组下标。
            for (int i = 0; i < snapshot.cells.Length; ++i)
            {
                // 当前待验证 Cell 的值拷贝。
                NavCell cell = snapshot.cells[i];
                if (!cell.IsWalkable)
                {
                    continue;
                }

                ++walkableCount;
                minHeight = Math.Min(minHeight, cell.heightMm);
                maxHeight = Math.Max(maxHeight, cell.heightMm);
                if (cell.clearanceCells == 0)
                {
                    throw new InvalidOperationException("WALKABLE_CELL_WITH_ZERO_CLEARANCE index=" +
                                                        i);
                }
            }

            if (walkableCount == 0)
            {
                throw new InvalidOperationException("MAP_HAS_NO_WALKABLE_CELL");
            }

            // 可走格占比只用于可疑地图告警，不作为通用硬阈值拒绝资产。
            float walkableRatio = (float)walkableCount / expectedCount;
            if (walkableRatio < 0.05f || walkableRatio > 0.99f)
            {
                Debug.LogWarning(string.Format("Suspicious walkable ratio: {0:P2}", walkableRatio));
            }

            Debug.Log(string.Format("MAP_VALIDATE_OK map={0} version={1} size={2}x{3} " +
                                        "walkable={4} min_height_mm={5} max_height_mm={6}",
                                    snapshot.mapId, snapshot.mapVersion, snapshot.width,
                                    snapshot.height, walkableCount, minHeight, maxHeight));
        }

        /// <param name="value">相对 Grid 原点的毫米坐标，可为负数。</param>
        /// <param name="divisor">正的 Cell 边长，单位毫米。</param>
        /// <returns>向负无穷取整的 Grid 下标。</returns>
        public static int FloorDiv(int value, int divisor)
        {
            if (divisor <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(divisor));
            }

            // quotient 是 C# 向 0 截断的原始商，负非整除值还需向下修正。
            int quotient = value / divisor;
            // remainder 用于判断 value 是否可以整除 divisor。
            int remainder = value % divisor;
            if (remainder != 0 && value < 0)
            {
                --quotient;
            }
            return quotient;
        }
    }
}
