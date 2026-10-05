// 职责：集中声明 BMAP V1 的 Magic、版本、Header 和 Cell 固定布局常量。
// 边界：跨 Unity Writer/C++ Reader 的 Asset Contract。
// 输入/输出：无运行时输入；供二进制读写和测试引用。
// 不负责：不保存某张地图的数据，不执行序列化。
namespace FlyWow.Navigation
{
    /// <summary>BMAP V1 的跨语言常量；C# Writer 与 C++ Reader 必须完全一致。</summary>
    public static class BMapFormat
    {
        // 当前跨语言文件格式版本。
        public const ushort FormatVersion = 1;
        // Header 固定字节数。
        public const ushort HeaderSize = 64;
        // 每个 Cell 记录固定字节数。
        public const ushort CellStride = 8;

        // 计算 Header CRC 时，52..55 必须先保持为 0。
        public const int HeaderCrcOffset = 52;
        // 文件 Magic 固定占用 4 bytes。
        public const int MagicSize = 4;

        // 文件开头的 ASCII "BMAP"，用于快速拒绝错误资产类型。
        public static readonly byte[] Magic = { (byte)'B', (byte)'M', (byte)'A', (byte)'P' };
    }
}
