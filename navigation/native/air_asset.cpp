// 职责：逐字段加载 AIRN V1，并执行有界格式、区间及 BMAP 配对校验。
#include "air_asset.h"
#include <algorithm>
#include <cstring>
#include <fstream>
namespace flywow_navigation
{
namespace
{
std::uint32_t rotate(std::uint32_t x, unsigned n)
{
    return (x >> n) | (x << (32 - n));
}
// SHA-256 标准轮常量；与空消息、abc、长消息的已知向量共同锁定实现。
constexpr std::uint32_t kRound[] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
std::uint64_t little(const std::uint8_t *p, unsigned n)
{
    std::uint64_t v = 0;
    for (unsigned i = 0; i < n; ++i)
    {
        v |= std::uint64_t(p[i]) << (8 * i);
    }
    return v;
}
std::int64_t signedLittle(const std::uint8_t *p)
{
    const auto   u = little(p, 8);
    std::int64_t v;
    std::memcpy(&v, &u, 8);
    return v;
}
} // namespace
AssetHash sha256(const std::uint8_t *data, std::size_t size)
{
    std::uint32_t h[]    = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    // 输入最大 128 MiB；长度乘 8 与填充长度均不会溢出。
    const auto    blocks = (size + 9 + 63) / 64;
    for (std::size_t b = 0; b < blocks; ++b)
    {
        std::uint8_t bytes[64]{};
        for (std::size_t i = 0; i < 64; ++i)
        {
            const auto pos = b * 64 + i;
            if (pos < size)
            {
                bytes[i] = data[pos];
            }
            else if (pos == size)
            {
                bytes[i] = 0x80;
            }
            if (pos >= blocks * 64 - 8)
            {
                bytes[i] = static_cast<std::uint8_t>((std::uint64_t(size) * 8) >>
                                                     (8 * (blocks * 64 - 1 - pos)));
            }
        }
        std::uint32_t w[64]{};
        for (unsigned i = 0; i < 16; ++i)
        {
            for (unsigned j = 0; j < 4; ++j)
            {
                w[i] = (w[i] << 8) | bytes[i * 4 + j];
            }
        }
        for (unsigned i = 16; i < 64; ++i)
        {
            const auto s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3);
            const auto s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i]          = w[i - 16] + s0 + w[i - 7] + s1;
        }
        std::uint32_t a = h[0], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], v = h[7],
                      bb = h[1];
        for (unsigned i = 0; i < 64; ++i)
        {
            const auto t1 = v + (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) +
                            ((e & f) ^ ((~e) & g)) + kRound[i] + w[i];
            const auto t2 =
                (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) + ((a & bb) ^ (a & c) ^ (bb & c));
            v  = g;
            g  = f;
            f  = e;
            e  = d + t1;
            d  = c;
            c  = bb;
            bb = a;
            a  = t1 + t2;
        }
        h[0] += a;
        h[1] += bb;
        h[2] += c;
        h[3] += d;
        h[4] += e;
        h[5] += f;
        h[6] += g;
        h[7] += v;
    }

    AssetHash out{};
    for (unsigned i = 0; i < 32; ++i)
    {
        out[i] = static_cast<std::uint8_t>(h[i / 4] >> (8 * (3 - i % 4)));
    }
    return out;
}
NavResult<AirAsset> readAirAsset(const std::string &path, const BMapMetadata &m,
                                 const AssetHash &hash)
{
    auto fail = [](NavError e, const char *s) { return NavResult<AirAsset>::Failure(e, s); };
    std::ifstream in(path, std::ios::binary | std::ios::ate);
    if (!in)
    {
        return fail(NavError::kIoError, "cannot open airnav");
    }

    const auto length = in.tellg();
    if (length < 96 || length > 32 * 1024 * 1024)
    {
        return fail(NavError::kInvalidAirAsset, "airnav length outside limit");
    }

    std::vector<std::uint8_t> file(static_cast<std::size_t>(length));
    in.seekg(0);
    in.read(reinterpret_cast<char *>(file.data()), length);
    if (!in)
    {
        return fail(NavError::kTruncated, "short airnav read");
    }

    const auto *p = file.data();
    if (std::memcmp(p, "AIRN", 4) || little(p + 4, 2) != 1 || little(p + 6, 2) != 96)
    {
        return fail(NavError::kInvalidAirAsset, "AIRN V1 header required");
    }

    const std::uint32_t fields[] = {m.map_id,
                                    m.map_version,
                                    m.width,
                                    m.height,
                                    m.cell_size_mm,
                                    std::uint32_t(m.origin_x_mm),
                                    std::uint32_t(m.origin_z_mm)};
    for (unsigned i = 0; i < 7; ++i)
    {
        if (little(p + 8 + 4 * i, 4) != fields[i])
        {
            return fail(NavError::kAssetMismatch, "airnav metadata mismatch");
        }
    }
    if (!std::equal(hash.begin(), hash.end(), p + 40))
    {
        return fail(NavError::kAssetMismatch, "airnav BMAP SHA-256 mismatch");
    }

    const auto records = little(p + 72, 4), intervals = little(p + 76, 4);
    if (little(p + 36, 4) || little(p + 80, 8) || little(p + 88, 8) ||
        records > std::uint64_t(m.width) * m.height || intervals > 1048576 ||
        96 + records * 12 + intervals * 16 != file.size())
    {
        return fail(NavError::kInvalidAirAsset, "airnav counts/reserved/length invalid");
    }

    AirAsset out;
    out.bmap_hash = hash;
    out.air_hash  = sha256(p, file.size());
    out.present   = true;
    out.cells.reserve(records);
    out.intervals.reserve(intervals);

    std::uint32_t offset = 0;
    for (std::size_t i = 0; i < records; ++i)
    {
        const auto *r = p + 96 + i * 12;
        AirCell     c{std::uint32_t(little(r, 4)), std::uint32_t(little(r + 4, 4)),
                  std::uint32_t(little(r + 8, 4))};
        if (c.cell_index >= std::uint64_t(m.width) * m.height ||
            (i && c.cell_index <= out.cells.back().cell_index) || c.offset != offset || !c.count ||
            c.count > 64 || std::uint64_t(offset) + c.count > intervals)
        {
            return fail(NavError::kInvalidAirAsset, "airnav sparse record invalid");
        }
        for (unsigned j = 0; j < c.count; ++j)
        {
            const auto *v = p + 96 + records * 12 + std::uint64_t(offset + j) * 16;
            AirInterval a{signedLittle(v), signedLittle(v + 8)};
            if (a.min_y_mm > a.max_y_mm || (j && a.min_y_mm <= out.intervals.back().max_y_mm))
            {
                return fail(NavError::kInvalidAirAsset, "airnav intervals not canonical");
            }
            out.intervals.push_back(a);
        }
        offset += c.count;
        out.cells.push_back(c);
    }

    if (offset != intervals)
    {
        return fail(NavError::kInvalidAirAsset, "unreferenced air intervals");
    }
    return NavResult<AirAsset>::Success(std::move(out));
}
} // namespace flywow_navigation
