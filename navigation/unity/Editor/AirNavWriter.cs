// 职责：离线生产/验证 AIRN V1；保守闭合格柱，不推断建筑或使用 BMAP 保留位。
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using UnityEngine;
namespace FlyWow.Navigation.Editor
{
    public struct AirNavInterval
    {
        // 世界 Y 闭区间，整数毫米；接触边界阻挡。
        public long minY;
        public long maxY;
    }
    public sealed class AirNavSnapshot
    {
        // 稀疏格按行主序排序；仅导出时可变，发布后不可变。
        public readonly SortedDictionary<uint, List<AirNavInterval>> cells =
            new SortedDictionary<uint, List<AirNavInterval>>();
    }
    public static class AirNavWriter
    {
        public const int HeaderSize   = 96;
        public const int MaxBytes     = 32 * 1024 * 1024;
        public const int MaxIntervals = 1048576;
        // 闭区间下界向负无穷取整，上界向正无穷取整；禁止浮点 NaN/溢出。
        public static long Millimeters(double meters, bool lower)
        {
            double scaled = meters * 1000.0;
            // long.MaxValue 转为 double 会四舍五入到 2^63，故上界使用排除式比较。
            if (double.IsNaN(scaled) || double.IsInfinity(scaled) ||
                scaled < -9223372036854775808.0 || scaled >= 9223372036854775808.0)
                throw new InvalidOperationException("AIRNAV_COORDINATE_OVERFLOW");
            return checked((long)(lower ? Math.Floor(scaled) : Math.Ceiling(scaled)));
        }
        public static long FloorDiv(long a, long b)
        {
            return a / b - ((a < 0 && a % b != 0) ? 1 : 0);
        }
        /// <summary>只使用显式 LayerMask 的启用 Collider；所有几何采用保守世界 AABB。</summary>
        public static AirNavSnapshot Sample(NavigationMapRoot root, NavigationMapSnapshot map)
        {
            if (!root.exportAirNavigation)
                return null;
            var air      = new AirNavSnapshot();
            int rawCount = 0;
            foreach (Collider collider in UnityEngine.Object.FindObjectsByType<Collider>(
                         FindObjectsSortMode.None))
            {
                if (collider.gameObject.scene != root.gameObject.scene || !collider.enabled ||
                    !collider.gameObject.activeInHierarchy ||
                    (root.airObstacleLayers.value & (1 << collider.gameObject.layer)) == 0)
                    continue;
                // 旋转 BoxCollider 及其它 Collider 都以世界 bounds 保守覆盖，可能关闭模型通道。
                if (!(collider is BoxCollider) ||
                    collider.transform.rotation != Quaternion.identity)
                    Debug.LogWarning("AIRNAV_CONSERVATIVE_AABB " + collider.name);
                Bounds bounds = collider.bounds;
                long   minX   = Millimeters(bounds.min.x, true),
                     maxX     = Millimeters(bounds.max.x, false);
                long minZ     = Millimeters(bounds.min.z, true),
                     maxZ     = Millimeters(bounds.max.z, false);
                long minY     = Millimeters(bounds.min.y, true),
                     maxY     = Millimeters(bounds.max.y, false);
                AddBounds(air, map, minX, maxX, minZ, maxZ, minY, maxY, ref rawCount);
            }
            Canonicalize(air);
            return air;
        }
        /// <summary>闭合格线同时覆盖两边；原点 -1000、500 格，x=-500 接触第 0 与第 1 格。</summary>
        public static void AddBounds(AirNavSnapshot air, NavigationMapSnapshot map, long minX,
                                     long maxX, long minZ, long maxZ, long minY, long maxY,
                                     ref int rawCount)
        {
            if (minX > maxX || minZ > maxZ || minY > maxY)
                throw new ArgumentException("AIRNAV_BOUNDS");
            // checked 相减防止作者的极端 int64 坐标绕回地图内。
            long rx = checked(minX - map.originXMm), rz = checked(minZ - map.originZMm);
            long x0 = FloorDiv(rx, map.cellSizeMm), z0 = FloorDiv(rz, map.cellSizeMm);
            if (rx % map.cellSizeMm == 0)
                --x0;
            if (rz % map.cellSizeMm == 0)
                --z0;
            long x1 = FloorDiv(checked(maxX - map.originXMm), map.cellSizeMm);
            long z1 = FloorDiv(checked(maxZ - map.originZMm), map.cellSizeMm);
            x0      = Math.Max(0, x0);
            z0      = Math.Max(0, z0);
            x1      = Math.Min(map.width - 1, x1);
            z1      = Math.Min(map.height - 1, z1);
            for (long z = z0; z <= z1; ++z)
            {
                for (long x = x0; x <= x1; ++x)
                {
                    if (rawCount == MaxIntervals)
                        throw new InvalidOperationException("AIRNAV_EXPORT_CAPACITY");
                    ++rawCount;
                    uint index = checked((uint)(z * map.width + x));
                    if (!air.cells.TryGetValue(index, out List<AirNavInterval> list))
                    {
                        list = new List<AirNavInterval>();
                        air.cells.Add(index, list);
                    }
                    list.Add(new AirNavInterval { minY = minY, maxY = maxY });
                }
            }
        }
        public static void Canonicalize(AirNavSnapshot air)
        {
            foreach (List<AirNavInterval> list in air.cells.Values)
            {
                list.Sort((a, b) => a.minY != b.minY ? a.minY.CompareTo(b.minY)
                                                     : a.maxY.CompareTo(b.maxY));
                int output = 0;
                foreach (AirNavInterval item in list.ToArray())
                {
                    if (output != 0 && item.minY <= list[output - 1].maxY)
                    {
                        var previous     = list[output - 1];
                        previous.maxY    = Math.Max(previous.maxY, item.maxY);
                        list[output - 1] = previous;
                    }
                    else
                    {
                        list[output++] = item;
                    }
                }
                list.RemoveRange(output, list.Count - output);
                if (output > 64)
                    throw new InvalidOperationException("AIRNAV_CELL_INTERVAL_CAPACITY");
            }
        }
        private static void Put(byte[] bytes, int offset, ulong value, int size)
        {
            for (int i = 0; i < size; ++i)
                bytes[offset + i] = (byte)(value >> (i * 8));
        }
        private static ulong Get(byte[] bytes, int offset, int size)
        {
            ulong value = 0;
            for (int i = 0; i < size; ++i)
                value |= (ulong)bytes[offset + i] << (i * 8);
            return value;
        }
        private static byte[] Hash(byte[] data)
        {
            using (SHA256 sha = SHA256.Create()) return sha.ComputeHash(data);
        }
        /// <summary>显式 Little Endian 编码；输入必须已规范化，禁止直接 dump struct。</summary>
        public static byte[] Encode(NavigationMapSnapshot map, AirNavSnapshot air, byte[] bmap)
        {
            if (air == null || map == null || bmap == null)
                throw new ArgumentException("AIRNAV_ARGUMENT");
            long count = air.cells.Values.Sum(list => (long)list.Count);
            long size  = checked(HeaderSize + air.cells.Count * 12L + count * 16);
            if (size > MaxBytes || count > MaxIntervals)
                throw new InvalidOperationException("AIRNAV_FILE_CAPACITY");
            byte[] bytes = new byte[checked((int)size)];
            bytes[0]     = (byte)'A';
            bytes[1]     = (byte)'I';
            bytes[2]     = (byte)'R';
            bytes[3]     = (byte)'N';
            Put(bytes, 4, 1, 2);
            Put(bytes, 6, HeaderSize, 2);
            uint[] metadata = { map.mapId,
                                map.mapVersion,
                                checked((uint)map.width),
                                checked((uint)map.height),
                                checked((uint)map.cellSizeMm),
                                unchecked((uint)map.originXMm),
                                unchecked((uint)map.originZMm) };
            for (int i = 0; i < metadata.Length; ++i)
                Put(bytes, 8 + i * 4, metadata[i], 4);
            Array.Copy(Hash(bmap), 0, bytes, 40, 32);
            Put(bytes, 72, (ulong)air.cells.Count, 4);
            Put(bytes, 76, (ulong)count, 4);
            int row = 0, interval = 0;
            foreach (var entry in air.cells)
            {
                if (entry.Key >= (ulong)map.width * (ulong)map.height || entry.Value.Count == 0 ||
                    entry.Value.Count > 64)
                    throw new InvalidOperationException("AIRNAV_RECORD");
                int offset = HeaderSize + row++ * 12;
                Put(bytes, offset, entry.Key, 4);
                Put(bytes, offset + 4, (ulong)interval, 4);
                Put(bytes, offset + 8, (ulong)entry.Value.Count, 4);
                long previous = 0;
                bool first    = true;
                foreach (var item in entry.Value)
                {
                    if (item.minY > item.maxY || (!first && item.minY <= previous))
                        throw new InvalidOperationException("AIRNAV_INTERVAL_ORDER");
                    int location = HeaderSize + air.cells.Count * 12 + interval++ * 16;
                    Put(bytes, location, unchecked((ulong)item.minY), 8);
                    Put(bytes, location + 8, unchecked((ulong)item.maxY), 8);
                    first    = false;
                    previous = item.maxY;
                }
            }
            return bytes;
        }
        /// <summary>完整回读并验证精确长度、预留位、配对、记录及区间；不修改输入。</summary>
        public static AirNavSnapshot Decode(byte[] bytes, NavigationMapSnapshot map, byte[] bmap)
        {
            if (bytes.Length < HeaderSize || bytes.Length > MaxBytes || bytes[0] != 'A' ||
                bytes[1] != 'I' || bytes[2] != 'R' || bytes[3] != 'N' || Get(bytes, 4, 2) != 1 ||
                Get(bytes, 6, 2) != HeaderSize)
                throw new InvalidOperationException("AIRNAV_HEADER");
            ulong records = Get(bytes, 72, 4), count = Get(bytes, 76, 4);
            if (count > MaxIntervals || records > (ulong)map.width * (ulong)map.height ||
                HeaderSize + records * 12 + count * 16 != (ulong)bytes.Length ||
                Get(bytes, 36, 4) != 0 || Get(bytes, 80, 8) != 0 || Get(bytes, 88, 8) != 0)
                throw new InvalidOperationException("AIRNAV_LENGTH");
            var  air      = new AirNavSnapshot();
            uint expected = 0, previous = 0;
            for (ulong i = 0; i < records; ++i)
            {
                int  pos  = checked(HeaderSize + (int)i * 12);
                uint cell = (uint)Get(bytes, pos, 4), offset = (uint)Get(bytes, pos + 4, 4),
                     length = (uint)Get(bytes, pos + 8, 4);
                if ((i != 0 && cell <= previous) || offset != expected || length == 0 ||
                    length > 64 || (ulong)offset + length > count)
                    throw new InvalidOperationException("AIRNAV_RECORD");
                var list = new List<AirNavInterval>();
                for (uint j = 0; j < length; ++j)
                {
                    int at = checked(HeaderSize + (int)records * 12 + (int)(offset + j) * 16);
                    list.Add(new AirNavInterval { minY = unchecked((long)Get(bytes, at, 8)),
                                                  maxY = unchecked((long)Get(bytes, at + 8, 8)) });
                }
                air.cells.Add(cell, list);
                expected += length;
                previous = cell;
            }
            if (expected != count || !bytes.SequenceEqual(Encode(map, air, bmap)))
                throw new InvalidOperationException("AIRNAV_PAIR_OR_CANONICAL");
            return air;
        }
        public static void Write(NavigationMapSnapshot map, AirNavSnapshot air, string bmap,
                                 string output)
        {
            byte[] ground = File.ReadAllBytes(bmap);
            File.WriteAllBytes(output, Encode(map, air, ground));
            Decode(File.ReadAllBytes(output), map, ground);
        }
    }
}
