// 职责：锁定负世界坐标 FloorDiv 和静态 Clearance 的边界语义。
// 边界：Unity EditMode Test；只验证纯计算，不依赖 NavMesh。
// 输入/输出：固定整数样例和小 Grid -> NUnit 断言结果。
// 不负责：不验证文件格式和服务端协议。
using NUnit.Framework;
using FlyWow.Navigation.Editor;

namespace FlyWow.Navigation.Tests
{
    /// <summary>锁定负坐标 Grid 映射和静态 Clearance 的保守边界语义。</summary>
    public sealed class CoordinateAndClearanceTests
    {
        [TestCase(0, 500, 0)]
        [TestCase(499, 500, 0)]
        [TestCase(500, 500, 1)]
        [TestCase(-1, 500, -1)]
        [TestCase(-500, 500, -1)]
        [TestCase(-501, 500, -2)]
        /// <param name="value">相对 Grid 原点的毫米坐标。</param>
        /// <param name="divisor">Cell 边长，单位毫米。</param>
        /// <param name="expected">数学 floor 后的期望 Grid 下标。</param>
        public void FloorDivisionMatchesWorldGridContract(int value, int divisor, int expected)
        {
            Assert.That(NavigationMapValidator.FloorDiv(value, divisor), Is.EqualTo(expected));
        }

        [Test]
        public void BoundaryAndBlockedCellsLimitClearance()
        {
            // snapshot 是 5×5 全可走基线，随后人为放入一个静态障碍。
            var snapshot = new NavigationMapSnapshot {
                mapId = 1,  mapVersion = 1,   width = 5,
                height = 5, cellSizeMm = 500, cells = new NavCell[25],
            };

            // i 是初始化全部 Cell 的 row-major 数组下标。
            for (int i = 0; i < snapshot.cells.Length; ++i)
            {
                snapshot.cells[i].flags = NavCellFlags.Walkable;
            }
            snapshot.cells[snapshot.IndexOf(1, 2)].flags = 0;

            NavigationMapClearance.Compute(snapshot);

            Assert.That(snapshot.CellAt(1, 2).clearanceCells, Is.EqualTo(0));
            Assert.That(snapshot.CellAt(2, 2).clearanceCells, Is.EqualTo(1));
            Assert.That(snapshot.CellAt(4, 4).clearanceCells, Is.EqualTo(1));
        }
    }
}
