// 职责：把已验证 Snapshot 编码成 BMAP V1，并在发布前回读校验。
// 边界：Unity Editor Asset Writer；正式文件只在完整成功后替换。
// 输入/输出：Snapshot + 输出路径 -> BMAP 文件或明确异常。
// 不负责：不采样 Scene、不补算 Clearance、不创建 Server 类型。
using System;
using System.IO;

namespace FlyWow.Navigation.Editor
{
    /// <summary>
    /// 把已通过 Validator 的 Snapshot 编码为 BMAP V1，并在发布前回读 CRC。
    /// 不访问 Scene/NavMesh，也不修改 Snapshot。
    /// </summary>
    public static class BMapWriter
    {
        /// <param name="snapshot">已经通过 Validator 的确定性内存快照。</param>
        /// <param name="path">正式 BMAP 输出路径。</param>
        public static void Write(NavigationMapSnapshot snapshot, string path)
        {
            if (snapshot == null)
            {
                throw new ArgumentNullException(nameof(snapshot));
            }
            if (string.IsNullOrWhiteSpace(path))
            {
                throw new ArgumentException("output path is empty", nameof(path));
            }

            // Header 尺寸推导出的 Cell 总数。
            int cellCount = checked(snapshot.width * snapshot.height);
            if (snapshot.cells == null || snapshot.cells.Length != cellCount)
            {
                throw new InvalidOperationException("BMAP_CELL_COUNT_MISMATCH");
            }

            // Cell Payload 的精确字节数，不包含 64-byte Header。
            int payloadSize = checked(cellCount * BMapFormat.CellStride);
            // 仅包含 row-major Cell 记录的连续输出缓冲区。
            var payload = new byte[payloadSize];
            // index 同时是 Cell 数组下标和第 index 条 8-byte 记录编号。
            for (int index = 0; index < cellCount; ++index)
            {
                // 当前 Cell 在 payload 中的 byte 起始偏移。
                int offset = index * BMapFormat.CellStride;
                // 当前待编码的逻辑 Cell；不能依赖 struct 内存布局整块写入。
                NavCell cell = snapshot.cells[index];
                BMapLittleEndian.WriteI32(payload, offset, cell.heightMm);
                BMapLittleEndian.WriteU16(payload, offset + 4, cell.flags);
                payload[offset + 6] = cell.areaType;
                payload[offset + 7] = cell.clearanceCells;
            }

            // payloadCrc 只覆盖 Cell Payload，写入 Header 的 48..51。
            uint payloadCrc = BMapCrc32.Compute(payload);
            // header 初建时 header_crc32 字段保持为 0。
            byte[] header = BuildHeader(snapshot, payloadSize, payloadCrc);
            // headerCrc 覆盖完整 64-byte Header，其中自身字段仍为 0。
            uint headerCrc = BMapCrc32.Compute(header);
            BMapLittleEndian.WriteU32(header, BMapFormat.HeaderCrcOffset, headerCrc);

            // fullPath 是最终正式 BMAP 的绝对路径。
            string fullPath = Path.GetFullPath(path);
            // directory 是正式文件所在目录；不存在时由 Writer 创建。
            string directory = Path.GetDirectoryName(fullPath) ??
                               throw new InvalidOperationException("output directory missing");
            Directory.CreateDirectory(directory);

            // temporaryPath 承载未验证输出，验证通过前不能覆盖正式资产。
            string temporaryPath = fullPath + ".tmp";
            using (var stream = new FileStream(temporaryPath, FileMode.Create, FileAccess.Write,
                                               FileShare.None))
            {
                stream.Write(header, 0, header.Length);
                stream.Write(payload, 0, payload.Length);
                stream.Flush(true);
            }

            Verify(temporaryPath);
            if (File.Exists(fullPath))
            {
                File.Replace(temporaryPath, fullPath, null);
            }
            else
            {
                File.Move(temporaryPath, fullPath);
            }
        }

        /// <param name="path">待回读校验的 BMAP 路径，可指向临时文件。</param>
        public static void Verify(string path)
        {
            // file 是待验证 BMAP 的完整字节；本方法不信任文件内任何长度字段。
            byte[] file = File.ReadAllBytes(path);
            if (file.Length < BMapFormat.HeaderSize)
            {
                throw new InvalidDataException("BMAP_TRUNCATED_HEADER");
            }

            // i 是 Magic 内的 byte 偏移。
            for (int i = 0; i < BMapFormat.MagicSize; ++i)
            {
                if (file[i] != BMapFormat.Magic[i])
                {
                    throw new InvalidDataException("BMAP_BAD_MAGIC");
                }
            }

            // version 是文件声明的 BMAP format_version。
            ushort version = BMapLittleEndian.ReadU16(file, 4);
            // headerSize 是文件声明的 Header 字节数。
            ushort headerSize = BMapLittleEndian.ReadU16(file, 6);
            // payloadSize 是文件声明的 Cell Payload 字节数。
            uint payloadSize = BMapLittleEndian.ReadU32(file, 44);
            // expectedPayloadCrc 是 Header 保存的 Payload 期望 CRC。
            uint expectedPayloadCrc = BMapLittleEndian.ReadU32(file, 48);
            // expectedHeaderCrc 是 Header 保存的 Header 期望 CRC。
            uint expectedHeaderCrc = BMapLittleEndian.ReadU32(file, 52);

            if (version != BMapFormat.FormatVersion || headerSize != BMapFormat.HeaderSize)
            {
                throw new InvalidDataException("BMAP_HEADER_VERSION_OR_SIZE");
            }
            if (payloadSize != file.Length - headerSize)
            {
                throw new InvalidDataException("BMAP_PAYLOAD_SIZE_MISMATCH");
            }

            // header 是独立副本，便于把 CRC 自身字段清零后重新计算。
            byte[] header = new byte[headerSize];
            Buffer.BlockCopy(file, 0, header, 0, header.Length);
            BMapLittleEndian.WriteU32(header, BMapFormat.HeaderCrcOffset, 0);
            if (BMapCrc32.Compute(header) != expectedHeaderCrc)
            {
                throw new InvalidDataException("BMAP_HEADER_CRC_MISMATCH");
            }
            if (BMapCrc32.Compute(file, headerSize, checked((int)payloadSize)) !=
                expectedPayloadCrc)
            {
                throw new InvalidDataException("BMAP_PAYLOAD_CRC_MISMATCH");
            }
        }

        /// <param name="snapshot">提供 Header 地图元数据的快照。</param>
        /// <param name="payloadSize">Cell Payload 字节数。</param>
        /// <param name="payloadCrc">Cell Payload 的 CRC32。</param>
        /// <returns>header_crc32 尚为 0 的 64-byte Header。</returns>
        private static byte[] BuildHeader(NavigationMapSnapshot snapshot, int payloadSize,
                                          uint payloadCrc)
        {
            // 新数组默认全 0，保证 reserved 和 header_crc32 初始值确定。
            var header = new byte[BMapFormat.HeaderSize];
            Buffer.BlockCopy(BMapFormat.Magic, 0, header, 0, 4);
            BMapLittleEndian.WriteU16(header, 4, BMapFormat.FormatVersion);
            BMapLittleEndian.WriteU16(header, 6, BMapFormat.HeaderSize);
            BMapLittleEndian.WriteU32(header, 8, snapshot.mapId);
            BMapLittleEndian.WriteU32(header, 12, snapshot.mapVersion);
            BMapLittleEndian.WriteU32(header, 16, checked((uint)snapshot.width));
            BMapLittleEndian.WriteU32(header, 20, checked((uint)snapshot.height));
            BMapLittleEndian.WriteU32(header, 24, checked((uint)snapshot.cellSizeMm));
            BMapLittleEndian.WriteI32(header, 28, snapshot.originXMm);
            BMapLittleEndian.WriteI32(header, 32, snapshot.originZMm);
            BMapLittleEndian.WriteU32(header, 36, 0);
            BMapLittleEndian.WriteU16(header, 40, BMapFormat.CellStride);
            BMapLittleEndian.WriteU16(header, 42, 0);
            BMapLittleEndian.WriteU32(header, 44, checked((uint)payloadSize));
            BMapLittleEndian.WriteU32(header, 48, payloadCrc);
            BMapLittleEndian.WriteU32(header, 52, 0);
            // 56..63 reserved，new byte[] 已经清零。
            return header;
        }
    }
}
