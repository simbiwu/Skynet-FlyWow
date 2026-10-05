// 职责：显式读写 BMAP Little Endian 整数，避免依赖本机字节序。
// 边界：Unity Editor Binary Asset；所有 offset 和 length 单位均为 byte。
// 输入/输出：整数 + byte buffer/offset <-> 固定字节布局。
// 不负责：不分配文件、不校验业务字段。
using System;

namespace FlyWow.Navigation.Editor
{
    /// <summary>BMAP 固定 Little Endian 编解码，不依赖当前 CPU 或 BitConverter。</summary>
    public static class BMapLittleEndian
    {
        /// <param name="target">目标 byte 缓冲区。</param>
        /// <param name="offset">写入起始 byte 偏移。</param>
        /// <param name="value">待写入的无符号 16-bit 值。</param>
        public static void WriteU16(byte[] target, int offset, ushort value)
        {
            Require(target, offset, 2);
            target[offset]     = (byte)value;
            target[offset + 1] = (byte)(value >> 8);
        }

        /// <param name="target">目标 byte 缓冲区。</param>
        /// <param name="offset">写入起始 byte 偏移。</param>
        /// <param name="value">待写入的无符号 32-bit 值。</param>
        public static void WriteU32(byte[] target, int offset, uint value)
        {
            Require(target, offset, 4);
            target[offset]     = (byte)value;
            target[offset + 1] = (byte)(value >> 8);
            target[offset + 2] = (byte)(value >> 16);
            target[offset + 3] = (byte)(value >> 24);
        }

        /// <param name="target">目标 byte 缓冲区。</param>
        /// <param name="offset">写入起始 byte 偏移。</param>
        /// <param name="value">待写入的有符号 32-bit 值。</param>
        public static void WriteI32(byte[] target, int offset, int value)
        {
            WriteU32(target, offset, unchecked((uint)value));
        }

        /// <param name="source">源 byte 缓冲区。</param>
        /// <param name="offset">读取起始 byte 偏移。</param>
        public static ushort ReadU16(byte[] source, int offset)
        {
            Require(source, offset, 2);
            return (ushort)(source[offset] | source[offset + 1] << 8);
        }

        /// <param name="source">源 byte 缓冲区。</param>
        /// <param name="offset">读取起始 byte 偏移。</param>
        public static uint ReadU32(byte[] source, int offset)
        {
            Require(source, offset, 4);
            return (uint)(source[offset] | source[offset + 1] << 8 | source[offset + 2] << 16 |
                          source[offset + 3] << 24);
        }

        /// <param name="bytes">待访问的 byte 缓冲区。</param>
        /// <param name="offset">访问起始 byte 偏移。</param>
        /// <param name="size">本次访问需要的 byte 数量。</param>
        private static void Require(byte[] bytes, int offset, int size)
        {
            // offset 是 byte 数组偏移，size 是本次访问所需字节数；先检查再读写。
            if (bytes == null || offset < 0 || size < 0 || offset > bytes.Length - size)
            {
                throw new ArgumentOutOfRangeException("binary range");
            }
        }
    }
}
