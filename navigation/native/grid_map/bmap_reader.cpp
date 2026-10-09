// 职责：逐字段读取并验证 Little Endian BMAP V1，校验成功后创建 GridMap。
// 边界：Server Asset Loader；磁盘数据在通过尺寸、CRC 和版本检查前一律不可信。
// 输入/输出：文件字节 -> BMapMetadata、NavCell 数组和 immutable GridMap。
// 生命周期：临时文件缓冲只在 Read 内存活；返回地图由 shared_ptr 管理。
// 不负责：不使用 struct cast、不注册地图、不修复损坏资产。
#include "bmap_reader.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <limits>
#include <sstream>
#include <utility>
#include <vector>

namespace flywow_navigation
{
namespace
{

// ---- 字节解码 helper：只有调用方确认长度后才可读取 ----

constexpr std::size_t kHeaderCrcOffset = 52; // Header CRC 字段相对文件起点的 byte offset。

// 从 bytes[0..1] 读取一个无符号 Little Endian 16-bit 值；调用方保证至少 2 bytes。
std::uint16_t ReadU16Le(const std::uint8_t *bytes) noexcept
{
    // 磁盘低位字节在前，例如 [0x34,0x12] 解码为 0x1234。
    // 逐字节拼接避免依赖主机字节序、地址对齐或 C++ struct 的填充方式。
    return static_cast<std::uint16_t>(bytes[0]) | static_cast<std::uint16_t>(bytes[1]) << 8;
}

// 从 bytes[0..3] 读取一个无符号 Little Endian 32-bit 值；调用方保证至少 4 bytes。
std::uint32_t ReadU32Le(const std::uint8_t *bytes) noexcept
{
    return static_cast<std::uint32_t>(bytes[0]) | static_cast<std::uint32_t>(bytes[1]) << 8 |
           static_cast<std::uint32_t>(bytes[2]) << 16 | static_cast<std::uint32_t>(bytes[3]) << 24;
}

// 读取 Little Endian 32-bit 位型并按补码解释为有符号值。
std::int32_t ReadI32Le(const std::uint8_t *bytes) noexcept
{
    return static_cast<std::int32_t>(ReadU32Le(bytes));
}

// 把 value 写入 bytes[0..3]，用于计算 Header CRC 前临时清零 CRC 字段。
void WriteU32Le(std::uint8_t *bytes, std::uint32_t value) noexcept
{
    bytes[0] = static_cast<std::uint8_t>(value);
    bytes[1] = static_cast<std::uint8_t>(value >> 8);
    bytes[2] = static_cast<std::uint8_t>(value >> 16);
    bytes[3] = static_cast<std::uint8_t>(value >> 24);
}

// 计算 [bytes, bytes+size) 的 reflected CRC-32/ISO-HDLC；与 Unity Writer 参数一致。
// 时间复杂度 O(size*8)，不分配内存，不读取范围外字节。
std::uint32_t Crc32(const std::uint8_t *bytes, std::size_t size) noexcept
{
    // 将每个字节混入累计校验值，再处理其 8 个 bit；结果必须与 Writer 一致。
    // 这是检测内容损坏的校验，不承担资产身份认证；不应随意替换常量或初末值。
    std::uint32_t crc = 0xffffffffu;
    for (std::size_t i = 0; i < size; ++i)
    {
        crc ^= bytes[i];
        for (int bit = 0; bit < 8; ++bit)
        {
            crc = (crc & 1u) != 0 ? 0xedb88320u ^ (crc >> 1) : crc >> 1;
        }
    }
    return crc ^ 0xffffffffu;
}

// 生成长度校验失败的诊断文字；expected/actual 的单位由调用点保持一致。
std::string SizeDetail(std::uint64_t expected, std::uint64_t actual)
{
    std::ostringstream stream;
    stream << "expected=" << expected << " actual=" << actual;
    return stream.str();
}

} // namespace

NavResult<std::shared_ptr<const GridMap>> BMapReader::Read(const std::string &path)
{
    // 1. 先取得文件长度，再一次读入字节缓冲；后续不逐格访问磁盘。
    // binary 保持原字节不变；ate 让打开后的读取位置位于文件尾，便于 tellg 取长度。
    // stream 在函数退出时关闭，file 在退出时释放；返回的地图不借用这个缓冲。
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kIoError,
                                                                  "cannot open: " + path);
    }

    const std::streamoff end = stream.tellg();
    if (end < 0)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kIoError,
                                                                  "tellg failed: " + path);
    }
    const std::uint64_t file_size = static_cast<std::uint64_t>(end);
    if (file_size < kBMapHeaderSize)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTruncated, SizeDetail(kBMapHeaderSize, file_size));
    }
    if (file_size > kBMapMaxFileSize || file_size > std::numeric_limits<std::size_t>::max())
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kSizeOverflow, "file exceeds 128 MiB or addressable memory");
    }

    // 取得长度后必须回到文件开头；否则会从尾部读到空数据。
    stream.seekg(0, std::ios::beg);
    std::vector<std::uint8_t> file(static_cast<std::size_t>(file_size));
    stream.read(reinterpret_cast<char *>(file.data()), static_cast<std::streamsize>(file.size()));
    if (!stream || static_cast<std::size_t>(stream.gcount()) != file.size())
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kTruncated,
                                                                  "short read: " + path);
    }

    // 2. 已确认至少含完整 Header，才能按固定偏移读字段。
    // 先检查 BMAP 标识、格式版本与 Header 长度，避免用 V1 布局解释其他格式。
    if (file[0] != 'B' || file[1] != 'M' || file[2] != 'A' || file[3] != 'P')
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kBadMagic,
                                                                  "magic is not BMAP");
    }

    const std::uint16_t format_version = ReadU16Le(file.data() + 4);
    const std::uint16_t header_size    = ReadU16Le(file.data() + 6);
    if (format_version != kBMapFormatVersion)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kUnsupportedVersion, "format_version=" + std::to_string(format_version));
    }
    if (header_size != kBMapHeaderSize)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kInvalidHeaderSize, "header_size=" + std::to_string(header_size));
    }

    // 下面是磁盘合同规定的 byte 偏移，不是 Runtime struct 成员的内存偏移。
    // 同一 map_id 可以有多个内容版本；format_version 则决定 Reader 如何解码文件。
    BMapMetadata metadata;
    metadata.map_id                          = ReadU32Le(file.data() + 8);
    metadata.map_version                     = ReadU32Le(file.data() + 12);
    metadata.width                           = ReadU32Le(file.data() + 16);
    metadata.height                          = ReadU32Le(file.data() + 20);
    metadata.cell_size_mm                    = ReadU32Le(file.data() + 24);
    metadata.origin_x_mm                     = ReadI32Le(file.data() + 28);
    metadata.origin_z_mm                     = ReadI32Le(file.data() + 32);
    metadata.flags                           = ReadU32Le(file.data() + 36);
    const std::uint16_t cell_stride          = ReadU16Le(file.data() + 40);
    const std::uint16_t reserved0            = ReadU16Le(file.data() + 42);
    const std::uint32_t payload_size         = ReadU32Le(file.data() + 44);
    const std::uint32_t expected_payload_crc = ReadU32Le(file.data() + 48);
    const std::uint32_t expected_header_crc  = ReadU32Le(file.data() + 52);

    if (metadata.map_id == 0 || metadata.map_version == 0 || metadata.width == 0 ||
        metadata.height == 0 || metadata.cell_size_mm == 0)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kInvalidDimensions, "zero identity/dimension/cell size");
    }
    if (cell_stride != kBMapCellStride || reserved0 != 0)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kInvalidStride,
                                                                  "cell_stride/reserved mismatch");
    }

    // 3. 交叉核对“尺寸算出的长度”“Header 声明长度”“实际文件长度”。
    // 例如 2x3 格、每格 8 bytes，应有 48 bytes payload，加上 64 bytes Header 共 112。
    // 三者必须一致，不能只信 Header 的 payload_size 就直接分配或读取 Cell。
    const std::uint64_t cell_count = static_cast<std::uint64_t>(metadata.width) * metadata.height;
    const std::uint64_t expected_payload_size =
        cell_count * static_cast<std::uint64_t>(cell_stride);
    if (cell_count > std::numeric_limits<std::size_t>::max() ||
        expected_payload_size > std::numeric_limits<std::uint32_t>::max())
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kSizeOverflow, "dimension multiplication overflow");
    }
    if (payload_size != expected_payload_size)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kPayloadSizeMismatch, SizeDetail(expected_payload_size, payload_size));
    }

    const std::uint64_t expected_file_size = header_size + expected_payload_size;
    if (file_size < expected_file_size)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTruncated, SizeDetail(expected_file_size, file_size));
    }
    if (file_size > expected_file_size)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(
            NavError::kTrailingBytes, SizeDetail(expected_file_size, file_size));
    }

    // 4. 长度都通过后再校验内容，确保 CRC 读取范围确实在缓冲中。
    // Header 校验不能把存放结果的 CRC 字段也原样算进去；Writer 计算时该字段为 0，
    // 因此这里只清零 Header 副本，保留原文件缓冲与预期校验值。
    std::array<std::uint8_t, kBMapHeaderSize> header{};
    std::copy_n(file.data(), header.size(), header.data());
    WriteU32Le(header.data() + kHeaderCrcOffset, 0);
    if (Crc32(header.data(), header.size()) != expected_header_crc)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kHeaderCrcMismatch,
                                                                  "header crc mismatch");
    }

    const std::uint8_t *payload = file.data() + header_size;
    if (Crc32(payload, payload_size) != expected_payload_crc)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kPayloadCrcMismatch,
                                                                  "payload crc mismatch");
    }

    // 5. 只有长度与 CRC 都通过，才将磁盘字节解码成运行期 Cell。
    // 每条 8 bytes 依次为高度、flags、Area、clearance；数组顺序与 z*width+x 一致。
    std::vector<NavCell> cells;
    cells.resize(static_cast<std::size_t>(cell_count));
    for (std::size_t index = 0; index < cells.size(); ++index)
    {
        const std::uint8_t *source   = payload + index * cell_stride;
        cells[index].height_mm       = ReadI32Le(source);
        cells[index].flags           = ReadU16Le(source + 4);
        cells[index].area_type       = source[6];
        cells[index].clearance_cells = source[7];
    }

    // 6. 将已解码数组 move 给只读地图；地图自己持有 Cell，不依赖临时 file。
    // 构造失败时不向 Registry 发布半成品；此 catch 覆盖地图构造阶段，
    // 不包含前面读取缓冲与 Cell 数组分配时可能抛出的异常。
    try
    {
        std::shared_ptr<const GridMap> map =
            std::make_shared<const GridMap>(metadata, std::move(cells));
        return NavResult<std::shared_ptr<const GridMap>>::Success(std::move(map));
    }
    catch (const std::exception &exception)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kInvalidDimensions,
                                                                  exception.what());
    }
}

} // namespace flywow_navigation
