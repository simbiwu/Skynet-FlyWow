// 职责：实现 BMAP V1 固定的 reflected CRC-32/ISO-HDLC。
// 边界：Unity Editor Binary Asset；算法参数必须与 C++ Reader 一致。
// 输入/输出：byte 范围 -> uint32 CRC。
// 不负责：不选择文件字段、不执行 I/O。
using System;

namespace FlyWow.Navigation.Editor
{
    /// <summary>reflected CRC-32/ISO-HDLC；Unity Writer 与 C++ Reader 共用同一参数。</summary>
    public static class BMapCrc32
    {
        // 256 项查表在类型初始化时只构建一次，之后的 Compute 不再分配。
        private static readonly uint[] Table = BuildTable();

        /// <param name="bytes">完整参与 CRC 的 byte 数组。</param>
        /// <returns>CRC-32/ISO-HDLC 校验值。</returns>
        public static uint Compute(byte[] bytes)
        {
            if (bytes == null)
            {
                throw new ArgumentNullException(nameof(bytes));
            }
            return Compute(bytes, 0, bytes.Length);
        }

        /// <param name="bytes">源 byte 数组。</param>
        /// <param name="offset">参与计算的第一个 byte 下标。</param>
        /// <param name="count">参与计算的 byte 数量。</param>
        public static uint Compute(byte[] bytes, int offset, int count)
        {
            if (bytes == null)
            {
                throw new ArgumentNullException(nameof(bytes));
            }
            if (offset < 0 || count < 0 || offset > bytes.Length - count)
            {
                throw new ArgumentOutOfRangeException("offset/count");
            }

            // CRC-32/ISO-HDLC 的固定初始值；返回前再与 0xFFFFFFFF 异或。
            uint crc = 0xffffffffu;
            // i 是当前参与 CRC 的 byte 下标，范围为 [offset, offset + count)。
            for (int i = offset; i < offset + count; ++i)
            {
                crc = Table[(crc ^ bytes[i]) & 0xffu] ^ (crc >> 8);
            }
            return crc ^ 0xffffffffu;
        }

        private static uint[] BuildTable()
        {
            // 每个可能的输入 byte 对应一个预计算余数。
            var table = new uint[256];
            // value 同时是查表下标和本轮初始 8-bit 值。
            for (uint value = 0; value < table.Length; ++value)
            {
                // entry 是对 value 做 8 次 reflected 多项式迭代后的表项。
                uint entry = value;
                // bit 表示当前处理 value 的第几个 bit。
                for (int bit = 0; bit < 8; ++bit)
                {
                    entry = (entry & 1u) != 0 ? 0xedb88320u ^ (entry >> 1) : entry >> 1;
                }
                table[value] = entry;
            }
            return table;
        }
    }
}
