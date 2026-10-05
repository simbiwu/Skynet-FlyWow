// 职责：定义一个采样 Cell 在 Unity 内存中的静态导航字段。
// 边界：Unity Asset Pipeline 中间数据；Writer 会把字段编码进 BMAP。
// 输入/输出：Sampler/Clearance 写入 -> Validator、Overlay 和 Writer 读取。
// 不负责：不保存世界 XZ、不表达动态单位或路径。
namespace FlyWow.Navigation
{
    // flags 用不同 bit 组合表示静态地图属性；每个 bit 都有固定含义。
    public static class NavCellFlags
    {
        // bit 0：Cell Center 对当前静态地图可走。
        public const ushort Walkable = 1 << 0;
        // bit 1：预留的静态视线阻挡语义；V1 Writer 保留该 bit。
        public const ushort VisionBlock = 1 << 1;
        // bit 2：预留的静态技能阻挡语义；不表示动态单位阻挡。
        public const ushort SkillBlock = 1 << 2;
        // bit 3：静态水域标志；具体 Area 仍由 areaType 表达。
        public const ushort Water = 1 << 3;
    }

    // Area 描述静态地表类型；是否可走仍由 flags 决定。
    public enum NavigationArea : byte
    {
        // 默认普通地表。
        Normal = 0,
        // 泥地静态 Area；本课只导出类型，不展开后续消费策略。
        Mud = 1,
        // 草地静态 Area。
        Grass = 2,
        // 浅水静态 Area；是否可走仍读取 Walkable bit。
        WaterShallow = 3,
    }

    // 仅用于当前 Grid 实现和调试，不能持久化为长期 Lua 业务位置。
    public struct GridPos
    {
        // Grid X 下标，从左向右递增，不是世界坐标毫米值。
        public int x;
        // Grid Z 下标，从下向上递增，不是 Unity world Y。
        public int z;

        /// <param name="xValue">Grid X 下标。</param>
        /// <param name="zValue">Grid Z 下标。</param>
        public GridPos(int xValue, int zValue)
        {
            x = xValue;
            z = zValue;
        }
    }

    // 保存一个 Cell 的逻辑字段，供 Snapshot 和采样流程使用。
    public struct NavCell
    {
        // 可走表面的世界 Y，单位毫米；不可走格不得读取该值作为有效高度。
        public int heightMm;
        // NavCellFlags 位集合；bit 0 决定当前格是否可走。
        public ushort flags;
        // NavigationArea 的稳定数值编码，用来标记静态地表类型。
        public byte areaType;
        // 到最近静态障碍/地图外的保守 8 邻域距离，单位 Cell。
        public byte clearanceCells;

        public bool IsWalkable
        {
            get {
                return (flags & NavCellFlags.Walkable) != 0;
            }
        }
    }
}
