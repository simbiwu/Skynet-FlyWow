// 职责：为一次 BMAP 导出生成便于人和 CI 审查的 JSON 摘要。
// 边界：Unity Editor Review Artifact；发布工具与 Server 加载边界校验 Manifest。
// 输入/输出：Snapshot + BMAP 校验信息 -> JSON 文件。
// 不负责：不影响 BMAP 合法性，不作为 Runtime 数据源。
using System;
using System.IO;
using UnityEngine;

namespace FlyWow.Navigation.Editor
{
    /// <summary>生成供人和 CI Review 的 JSON 摘要；Server Runtime 不读取它。</summary>
    public static class BMapManifestWriter
    {
        [Serializable]
        private sealed class Manifest
        {
            // 单层 2.5D Ground 的明确空间合同；不表示支持多层或平台跳跃。
            public string space_type = "ground_2_5d";
            // 对应 BMAP V1 的毫米世界坐标，Y 为高度。
            public string coordinate_axes = "x,y_height,z";
            // 完整 BMAP 的 SHA-256，与 Payload CRC 的损坏校验职责不同。
            public string content_sha256 = string.Empty;
            // BMAP 文件格式版本。
            public uint format_version;
            // 地图数值 ID。
            public uint map_id;
            // 地图资产版本。
            public uint map_version;
            // Grid X 方向 Cell 数。
            public int width;
            // Grid Z 方向 Cell 数。
            public int height;
            // Cell 边长，单位毫米。
            public int cell_size_mm;
            // Grid 左下角 [world_x_mm, world_z_mm]。
            public int[] origin_mm = Array.Empty<int>();
            // Payload CRC32 的 8 位大写十六进制显示文本。
            public string payload_crc32 = string.Empty;
            // 带 Walkable bit 的 Cell 数量。
            public int walkable_cells;
            // 不带 Walkable bit 的 Cell 数量。
            public int blocked_cells;
            // 全部可走 Cell 中最小的世界 Y，单位毫米。
            public int min_height_mm;
            // 全部可走 Cell 中最大的世界 Y，单位毫米。
            public int max_height_mm;
        }

        /// <param name="snapshot">与正式 BMAP 对应的已验证快照。</param>
        /// <param name="bmapPath">刚完成回读验证的正式 BMAP 路径。</param>
        public static void Write(NavigationMapSnapshot snapshot, string bmapPath)
        {
            // bmap 是刚完成回读验证的正式文件字节。
            byte[] bmap = File.ReadAllBytes(bmapPath);
            // payloadCrc 从正式 BMAP Header 读取，避免 Manifest 自己重算出另一份来源。
            uint payloadCrc = BMapLittleEndian.ReadU32(bmap, 48);
            // walkable 是可走 Cell 数量，blocked 由总数减去它得到。
            int walkable = 0;
            // minHeight 只统计可走表面的最小世界 Y，单位毫米。
            int minHeight = int.MaxValue;
            // maxHeight 只统计可走表面的最大世界 Y，单位毫米。
            int maxHeight = int.MinValue;

            // cell 是当前用于 Manifest 统计的静态格数据。
            foreach (NavCell cell in snapshot.cells)
            {
                if (!cell.IsWalkable)
                {
                    continue;
                }
                ++walkable;
                minHeight = Math.Min(minHeight, cell.heightMm);
                maxHeight = Math.Max(maxHeight, cell.heightMm);
            }

            // manifest 是纯观察数据，不参与 Server 决策。
            var manifest = new Manifest {
                content_sha256 = NavigationAssetPublisher.ContentHash(bmapPath),
                format_version = BMapFormat.FormatVersion,
                map_id         = snapshot.mapId,
                map_version    = snapshot.mapVersion,
                width          = snapshot.width,
                height         = snapshot.height,
                cell_size_mm   = snapshot.cellSizeMm,
                origin_mm      = new[] { snapshot.originXMm, snapshot.originZMm },
                payload_crc32  = payloadCrc.ToString("X8"),
                walkable_cells = walkable,
                blocked_cells  = snapshot.cells.Length - walkable,
                min_height_mm  = minHeight,
                max_height_mm  = maxHeight,
            };

            // Manifest 与 BMAP 同名同目录，扩展名固定为 .manifest.json。
            string manifestPath = Path.ChangeExtension(bmapPath, ".manifest.json");
            File.WriteAllText(manifestPath, JsonUtility.ToJson(manifest, true) + "\n");
        }
    }
}
