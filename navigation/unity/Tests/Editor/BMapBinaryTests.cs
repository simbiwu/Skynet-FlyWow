// 职责：锁定 BMAP CRC、Little Endian 和 Writer 文件长度等二进制合同。
// 边界：Unity EditMode Test；使用临时内存或文件，不依赖真实 Scene。
// 输入/输出：固定测试向量和最小 Snapshot -> NUnit 断言结果。
// 不负责：不验证 NavMesh Bake 和真实场景采样。
using System.IO;
using NUnit.Framework;
using FlyWow.Navigation.Editor;

namespace FlyWow.Navigation.Tests
{
    /// <summary>锁定 BMAP 字节序、CRC 变体、记录宽度和 Writer 回读行为。</summary>
    public sealed class BMapBinaryTests
    {
        [Test]
        public void Crc32MatchesPublishedVector()
        {
            // bytes 是 CRC-32/ISO-HDLC 的标准 ASCII Golden Vector。
            byte[] bytes = System.Text.Encoding.ASCII.GetBytes("123456789");
            Assert.That(BMapCrc32.Compute(bytes), Is.EqualTo(0xcbf43926u));
        }

        [Test]
        public void LittleEndianRoundTripKeepsBits()
        {
            // bytes 是同时容纳 u16 和 u32 测试值的临时缓冲区。
            var bytes = new byte[8];
            BMapLittleEndian.WriteU16(bytes, 0, 0xabcd);
            BMapLittleEndian.WriteU32(bytes, 2, 0x89abcdefu);
            Assert.That(BMapLittleEndian.ReadU16(bytes, 0), Is.EqualTo(0xabcd));
            Assert.That(BMapLittleEndian.ReadU32(bytes, 2), Is.EqualTo(0x89abcdefu));
        }

        [Test]
        public void WriterProducesExactSizeAndValidCrc()
        {
            // snapshot 是脱离真实 Scene 的最小 2×2 确定性输入。
            var snapshot = new NavigationMapSnapshot {
                mapId      = 1001,
                mapVersion = 7,
                width      = 2,
                height     = 2,
                cellSizeMm = 500,
                originXMm  = -500,
                originZMm  = 1000,
                cells =
                    new[] {
                        Walkable(0, 2),
                        default(NavCell),
                        Walkable(500, 1),
                        Walkable(1000, 1),
                    },
            };

            // directory 放在 Library 下，不污染需要版本控制的 Assets。
            string directory = Path.GetFullPath(Path.Combine(UnityEngine.Application.dataPath, "..",
                                                             "Library", "BattleNavigationTests"));
            Directory.CreateDirectory(directory);
            // path 是本测试独占的临时 BMAP 输出。
            string path = Path.Combine(directory, "writer_test.bmap");

            BMapWriter.Write(snapshot, path);
            Assert.That(new FileInfo(path).Length, Is.EqualTo(64 + 4 * 8));
            Assert.DoesNotThrow(() => BMapWriter.Verify(path));
        }

        /// <param name="heightMm">测试 Cell 的可走表面世界 Y，单位毫米。</param>
        /// <param name="clearance">测试 Cell 的静态 Clearance，单位 Cell。</param>
        private static NavCell Walkable(int heightMm, byte clearance)
        {
            return new NavCell {
                heightMm       = heightMm,
                flags          = NavCellFlags.Walkable,
                areaType       = (byte)NavigationArea.Normal,
                clearanceCells = clearance,
            };
        }
    }
}
