// 职责：按 NavigationMapRoot 的 Cell Center 从已 Bake NavMesh 生成 Snapshot。
// 边界：Unity Editor Authoring -> Asset Pipeline。
// 输入/输出：Scene、NavMesh、地图参数 -> 高度/可走/Area 已填写的 Snapshot。
// 失败条件：NavMesh 为空、2.5D 多层歧义、Area 映射缺失或采样不一致。
using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.AI;

namespace FlyWow.Navigation.Editor
{
    public static class NavigationMapSampler
    {
#if UNITY_EDITOR
        [UnityEditor.MenuItem("Tools/FlyWow/Navigation/调试/10 仅采样当前 Snapshot", false, 110)]
        private static void DebugSampleSnapshot()
        {
            // 当前 Scene 中唯一的地图合同；缺失时 Sample 会明确失败。
            NavigationMapRoot root = UnityEngine.Object.FindObjectOfType<NavigationMapRoot>();
            // 仅驻留内存的本次采样结果，不写 BMAP。
            NavigationMapSnapshot snapshot = Sample(root);
            // 用于确认采样不是全阻挡或空结果的可走格计数。
            int walkable = 0;
            // cell 是当前参与可走格计数的 Snapshot 值。
            foreach (NavCell cell in snapshot.cells)
            {
                if (cell.IsWalkable)
                    ++walkable;
            }

            Debug.Log(string.Format("GRID_SAMPLE_OK map={0} size={1}x{2} walkable={3}",
                                    snapshot.mapId, snapshot.width, snapshot.height, walkable));
        }
#endif

        // 同一 Cell Center XZ 上的一个 NavMesh 表面候选。
        private struct HeightCandidate
        {
            // 候选表面的 Unity world Y，单位米。
            public float y;
            // 候选表面的 Unity NavMesh Area 编号。
            public int areaIndex;

            public HeightCandidate(float yValue, int candidateAreaIndex)
            {
                y         = yValue;
                areaIndex = candidateAreaIndex;
            }
        }

        /// <summary>把已经 Bake 的 Unity NavMesh 采样成单层基础 Snapshot。</summary>
        /// <param name="root">当前 Scene 唯一的地图合同与采样参数。</param>
        /// <returns>尚未计算 Clearance、尚未写盘的内存 Snapshot。</returns>
        public static NavigationMapSnapshot Sample(NavigationMapRoot root)
        {
            if (root == null)
            {
                throw new ArgumentNullException(nameof(root));
            }

            root.ValidateOrThrow();

            // 当前已 Bake NavMesh 的顶点和三角形快照；用于发现同 XZ 多层表面。
            NavMeshTriangulation triangulation = NavMesh.CalculateTriangulation();
            if (triangulation.vertices == null || triangulation.vertices.Length == 0 ||
                triangulation.indices == null || triangulation.indices.Length == 0)
            {
                throw new InvalidOperationException(
                    "NAVMESH_EMPTY: bake NavMeshSurface before export");
            }
            if (triangulation.indices.Length % 3 != 0 || triangulation.areas == null ||
                triangulation.areas.Length != triangulation.indices.Length / 3)
            {
                throw new InvalidOperationException("NAVMESH_TRIANGULATION_AREA_COUNT_MISMATCH");
            }

            // 本次采样的唯一结果对象；后续 Clearance/Validator/Writer 复用同一实例。
            var snapshot = new NavigationMapSnapshot {
                mapId      = root.mapId,
                mapVersion = root.mapVersion,
                width      = root.Width,
                height     = root.Height,
                cellSizeMm = root.CellSizeMm,
                originXMm  = root.OriginXMm,
                originZMm  = root.OriginZMm,
                cells      = new NavCell[checked(root.Width * root.Height)],
            };

            // z 是 Grid 行下标，对应世界 Z 方向。
            for (int z = 0; z < snapshot.height; ++z)
            {
                // x 是当前行内的 Grid 列下标，对应世界 X 方向。
                for (int x = 0; x < snapshot.width; ++x)
                {
                    // 当前 Cell Center 的 Unity world position，单位米。
                    Vector3 center = root.GridToWorldCenter(x, z);
                    // 该 XZ 穿过的去重高度层；0=不可走，1=单层，>1=格式无法表达。
                    List<HeightCandidate> candidates = CollectHeightCandidates(
                        triangulation, center.x, center.z, root.multiLayerSeparationMeters);

                    if (candidates.Count > 1)
                    {
                        throw new InvalidOperationException(string.Format(
                            "MULTI_LAYER_NOT_SUPPORTED map={0} grid=({1},{2}) heights={3}",
                            root.mapId, x, z, FormatHeights(candidates)));
                    }

                    // 默认 Cell 没有 Walkable bit，表示不可走；只有找到唯一三角形表面才填充。
                    NavCell cell = default;
                    if (candidates.Count == 1)
                    {
                        cell.flags = NavCellFlags.Walkable;
                        cell.heightMm =
                            NavigationMapRoot.MetersToMillimeters(candidates[0].y, "sampleHeight");
                        cell.areaType = MapArea(candidates[0].areaIndex);
                    }

                    snapshot.cells[snapshot.IndexOf(x, z)] = cell;
                }
            }

            return snapshot;
        }

        /// <param name="triangulation">当前 Bake NavMesh 的三角形快照。</param>
        /// <param name="x">待测 Cell Center 的世界 X，单位米。</param>
        /// <param name="z">待测 Cell Center 的世界 Z，单位米。</param>
        /// <param name="separation">合并同层浮点误差的高度阈值，单位米。</param>
        private static List<HeightCandidate> CollectHeightCandidates(
            NavMeshTriangulation triangulation, float x, float z, float separation)
        {
            // 单层地图通常只有 0/1 个候选，容量 2 足以容纳并报告首次多层冲突。
            var result = new List<HeightCandidate>(2);
            // Bake 后的世界空间顶点数组，坐标单位为米。
            Vector3[] vertices = triangulation.vertices;
            // 每连续三个下标定义一个三角形。
            int[] indices = triangulation.indices;
            int[] areas   = triangulation.areas;

            // i 是 indices 的三角形起始偏移，每次跨过三个顶点下标。
            for (int i = 0; i < indices.Length; i += 3)
            {
                // a 是当前三角形第一个世界空间顶点，单位米。
                Vector3 a = vertices[indices[i]];
                // b 是当前三角形第二个世界空间顶点，单位米。
                Vector3 b = vertices[indices[i + 1]];
                // c 是当前三角形第三个世界空间顶点，单位米。
                Vector3 c = vertices[indices[i + 2]];

                // y 是当前三角形在待测 XZ 上插值得到的世界高度，单位米。
                if (!TryInterpolateY(a, b, c, x, z, out float y))
                {
                    continue;
                }

                int areaIndex = areas[i / 3];

                // 标记 y 是否只是已有层的浮点扰动，避免共享三角形边产生重复候选。
                bool sameLayer = false;
                // candidateIndex 是 result 内已有高度候选的数组下标。
                for (int candidateIndex = 0; candidateIndex < result.Count; ++candidateIndex)
                {
                    if (Mathf.Abs(result[candidateIndex].y - y) <= separation)
                    {
                        sameLayer = true;
                        break;
                    }
                }

                if (!sameLayer)
                {
                    result.Add(new HeightCandidate(y, areaIndex));
                }
            }

            result.Sort((left, right) => left.y.CompareTo(right.y));
            return result;
        }

        /// <summary>判断 XZ 点是否落在三角形投影内，并插值得到世界 Y。</summary>
        /// <param name="a">三角形顶点 A，Unity 世界坐标（米）。</param>
        /// <param name="b">三角形顶点 B，Unity 世界坐标（米）。</param>
        /// <param name="c">三角形顶点 C，Unity 世界坐标（米）。</param>
        /// <param name="x">待测世界 X，单位米。</param>
        /// <param name="z">待测世界 Z，单位米。</param>
        /// <param name="y">成功时返回插值世界 Y，单位米。</param>
        private static bool TryInterpolateY(Vector3 a, Vector3 b, Vector3 c, float x, float z,
                                            out float y)
        {
            // v0x 是从 a 到 b 的世界 X 差值。
            double v0x = b.x - a.x;
            // v0z 是从 a 到 b 的世界 Z 差值。
            double v0z = b.z - a.z;
            // v1x 是从 a 到 c 的世界 X 差值。
            double v1x = c.x - a.x;
            // v1z 是从 a 到 c 的世界 Z 差值。
            double v1z = c.z - a.z;
            // v2x 是从 a 到待测 Cell Center 的世界 X 差值。
            double v2x = x - a.x;
            // v2z 是从 a 到待测 Cell Center 的世界 Z 差值。
            double v2z = z - a.z;

            // denominator 是 XZ 投影的二维叉积；接近 0 表示投影退化。
            double denominator = v0x * v1z - v1x * v0z;
            if (Math.Abs(denominator) < 1e-10)
            {
                y = 0f;
                return false;
            }

            // u 是 XZ 投影中沿 a->b 方向的重心坐标。
            double u = (v2x * v1z - v1x * v2z) / denominator;
            // v 是 XZ 投影中沿 a->c 方向的重心坐标。
            double v = (v0x * v2z - v2x * v0z) / denominator;
            // epsilon 只容忍三角形边界的浮点误差，不能扩大实际可走区域。
            const double epsilon = 1e-6;
            if (u < -epsilon || v < -epsilon || u + v > 1.0 + epsilon)
            {
                y = 0f;
                return false;
            }

            y = (float)(a.y + u * (b.y - a.y) + v * (c.y - a.y));
            return true;
        }

        /// <param name="areaIndex">NavMesh 三角形携带的 Unity Area 编号。</param>
        /// <returns>稳定的 NavigationArea 单字节编码。</returns>
        private static byte MapArea(int areaIndex)
        {
            if (areaIndex < 0)
            {
                throw new InvalidOperationException("NAVMESH_AREA_MISSING");
            }

            // 团结引擎当前 API 提供“名称查编号”，这里逐个比较配置名称对应的编号。
            // 导出稳定的 NavigationArea 编码，不把 Unity Area 编号直接写入地图资产。
            if (MatchesArea(areaIndex, "Walkable") || MatchesArea(areaIndex, "Normal"))
            {
                return (byte)NavigationArea.Normal;
            }
            if (MatchesArea(areaIndex, "Mud"))
            {
                return (byte)NavigationArea.Mud;
            }
            if (MatchesArea(areaIndex, "Grass"))
            {
                return (byte)NavigationArea.Grass;
            }
            if (MatchesArea(areaIndex, "WaterShallow"))
            {
                return (byte)NavigationArea.WaterShallow;
            }

            throw new InvalidOperationException("UNMAPPED_NAVMESH_AREA index=" + areaIndex);
        }

        /// <param name="areaIndex">NavMesh 三角形携带的 Unity Area 编号。</param>
        /// <param name="areaName">Unity Navigation 面板中的 Area 名称。</param>
        /// <returns>该名称配置的编号是否与采样结果一致。</returns>
        private static bool MatchesArea(int areaIndex, string areaName)
        {
            // 未配置的名称会得到 -1，不会误匹配有效的 Area 编号。
            int configuredIndex = NavMesh.GetAreaFromName(areaName);
            return configuredIndex >= 0 && configuredIndex == areaIndex;
        }

        /// <param name="candidates">同一 XZ 上发现的高度层。</param>
        /// <returns>用于错误日志的毫米高度列表。</returns>
        private static string FormatHeights(List<HeightCandidate> candidates)
        {
            // values 只用于错误信息，把候选高度统一显示为毫米。
            var values = new string[candidates.Count];
            // i 是 candidates/values 的共同数组下标。
            for (int i = 0; i < candidates.Count; ++i)
            {
                values[i] =
                    NavigationMapRoot.MetersToMillimeters(candidates[i].y, "candidateHeight")
                        .ToString();
            }
            return "[" + string.Join(",", values) + "]";
        }
    }
}
