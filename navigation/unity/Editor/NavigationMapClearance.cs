// 职责：计算每个可走 Cell 到静态障碍或地图边界的保守距离。
// 边界：Unity Editor Asset Pipeline；只修改 Snapshot 的 clearance 字段。
// 输入/输出：已完成 Walkable 采样的 Grid -> clearance_cells。
// 不负责：不考虑动态单位，不替代 Agent 的 footprint 与通行查询规则。
using System;
using System.Collections.Generic;

namespace FlyWow.Navigation.Editor
{
    /// <summary>
    /// 从所有静态障碍同时传播 8 邻域距离，结果写回 Snapshot.clearanceCells。
    /// 结果单位为 Cell，是保守距离，不是连续空间欧氏距离。
    /// </summary>
    public static class NavigationMapClearance
    {
        private struct Node
        {
            // 队列节点的 Grid X 下标。
            public int x;
            // 队列节点的 Grid Z 下标。
            public int z;

            public Node(int xValue, int zValue)
            {
                x = xValue;
                z = zValue;
            }
        }

        // 8 邻域每个方向的 X 偏移；与 NeighborZ 同下标配对。
        private static readonly int[] NeighborX = {
            -1, 0, 1, -1, 1, -1, 0, 1,
        };

        // 8 邻域每个方向的 Z 偏移；与 NeighborX 同下标配对。
        private static readonly int[] NeighborZ = {
            -1, -1, -1, 0, 0, 1, 1, 1,
        };

        /// <param name="snapshot">待原地写入 clearanceCells 的基础 Snapshot。</param>
        public static void Compute(NavigationMapSnapshot snapshot)
        {
            if (snapshot == null)
            {
                throw new ArgumentNullException(nameof(snapshot));
            }

            // Snapshot 期望的总 Cell 数；checked 防止错误尺寸溢出。
            int cellCount = checked(snapshot.width * snapshot.height);
            if (snapshot.cells == null || snapshot.cells.Length != cellCount)
            {
                throw new InvalidOperationException("CLEARANCE_CELL_COUNT_MISMATCH");
            }

            // 每个 Cell 到最近静态障碍/地图外的暂存距离，单位 Cell。
            var distance = new int[cellCount];
            Array.Fill(distance, int.MaxValue);
            // 多源 BFS 队列；所有障碍和地图边缘一起作为起点。
            var queue = new Queue<Node>(cellCount);

            // z/x 是当前初始化 Cell 的 Grid 行列下标。
            for (int z = 0; z < snapshot.height; ++z)
            {
                // x 是当前初始化 Cell 的 Grid 列下标。
                for (int x = 0; x < snapshot.width; ++x)
                {
                    // 当前 Grid 坐标对应的 row-major 数组下标。
                    int index = snapshot.IndexOf(x, z);
                    // 边缘外侧没有 Cell，因此按距离外部障碍 1 格处理。
                    bool boundary =
                        x == 0 || z == 0 || x == snapshot.width - 1 || z == snapshot.height - 1;

                    if (!snapshot.cells[index].IsWalkable)
                    {
                        distance[index] = 0;
                        queue.Enqueue(new Node(x, z));
                    }
                    else if (boundary)
                    {
                        // 地图外视为静态不可走；边缘可走格离外部障碍一格。
                        distance[index] = 1;
                        queue.Enqueue(new Node(x, z));
                    }
                }
            }

            // 队列非空表示仍有更远的 Cell 需要传播最近障碍距离。
            while (queue.Count > 0)
            {
                // current 是本轮向邻居传播距离的 Grid 节点。
                Node current = queue.Dequeue();
                // currentIndex 是 current 在 Snapshot.cells/distance 中的下标。
                int currentIndex = snapshot.IndexOf(current.x, current.z);
                // 所有 8 邻域边权统一为 1，结果有意保持保守而非欧氏精确。
                int nextDistance = distance[currentIndex] + 1;

                // direction 同时索引 NeighborX 和 NeighborZ。
                for (int direction = 0; direction < NeighborX.Length; ++direction)
                {
                    // nextX 是待松弛邻居的 Grid X。
                    int nextX = current.x + NeighborX[direction];
                    // nextZ 是待松弛邻居的 Grid Z。
                    int nextZ = current.z + NeighborZ[direction];
                    if (nextX < 0 || nextX >= snapshot.width || nextZ < 0 ||
                        nextZ >= snapshot.height)
                    {
                        continue;
                    }

                    // nextIndex 是邻居对应的 row-major 数组下标。
                    int nextIndex = snapshot.IndexOf(nextX, nextZ);
                    if (nextDistance >= distance[nextIndex])
                    {
                        continue;
                    }

                    distance[nextIndex] = nextDistance;
                    queue.Enqueue(new Node(nextX, nextZ));
                }
            }

            // index 遍历所有 Cell，把临时 int 距离饱和写入 BMAP 的单字节字段。
            for (int index = 0; index < cellCount; ++index)
            {
                // struct 是值类型，修改后必须显式写回数组。
                NavCell cell = snapshot.cells[index];
                cell.clearanceCells =
                    cell.IsWalkable ? (byte)Math.Min(distance[index], byte.MaxValue) : (byte)0;
                snapshot.cells[index] = cell;
            }
        }
    }
}
