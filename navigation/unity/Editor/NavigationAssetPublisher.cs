// 职责：把 BMAP 与 Manifest 作为不可变候选目录一起提交，避免两份文件跨版本混合。
// 边界：Unity Editor Asset Publication；不更新运行中的 Server 或已发布地图。
// 输入：已验证 Snapshot 和显式输出根；输出：map/version/hash 标识的完整候选包。
// 生命周期：每次导出独占 staging 目录；失败清理 staging，成功目录由项目拥有。
using System;
using System.IO;
using System.Security.Cryptography;

namespace FlyWow.Navigation.Editor
{
    public static class NavigationAssetPublisher
    {
        /// <summary>写入完整候选包；文件 I/O 和 SHA-256 分配只发生在离线导出阶段。</summary>
        /// <param name="snapshot">调用方拥有的已验证快照，只读。</param>
        /// <param name="outputRoot">候选根目录；必须由宿主显式选择。</param>
        /// <returns>完整候选目录；同版本相同内容重复导出幂等，不覆盖不同内容。</returns>
        /// <exception cref="IOException">写盘或目录提交失败，已有候选保持不变。</exception>
        public static string WriteCandidate(NavigationMapSnapshot snapshot, string outputRoot,
                                            AirNavSnapshot air = null)
        {
            if (snapshot == null || string.IsNullOrWhiteSpace(outputRoot))
            {
                throw new ArgumentException("NAVIGATION_CANDIDATE_ARGUMENT");
            }

            Directory.CreateDirectory(outputRoot);
            string stage = Path.Combine(outputRoot, ".staging-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(stage);

            try
            {
                string map = Path.Combine(stage, "map.bmap");
                BMapWriter.Write(snapshot, map);
                string airPath = Path.Combine(stage, "map.airnav");
                // 同一份 BMAP 摘要用于 AIRN 配对、Manifest 和候选目录身份。
                byte[] bmapHash = HashFile(map);
                byte[] airHash = air == null ? null :
                    AirNavWriter.Hash(AirNavWriter.WriteWithHash(snapshot, air, bmapHash, airPath));
                string contentHash = FormatHash(bmapHash);
                string hash = airHash == null ? contentHash : PackageHash(bmapHash, airHash);
                BMapManifestWriter.WriteWithHashes(snapshot, map, contentHash,
                    airHash == null ? null : FormatHash(airHash), hash);

                string target = Path.Combine(outputRoot, "map-" + snapshot.mapId + "-v" +
                                                             snapshot.mapVersion + "-" + hash);
                if (Directory.Exists(target))
                {
                    // 名字相同不能直接相信旧文件；独立回读旧包的实际字节。
                    string previousMap = Path.Combine(target, "map.bmap");
                    BMapWriter.Verify(previousMap);
                    byte[] previousMapHash = HashFile(previousMap);
                    string previousAir = Path.Combine(target, "map.airnav");
                    if (File.Exists(previousAir) != (air != null))
                        throw new IOException("NAVIGATION_CANDIDATE_CONFLICT");
                    byte[] previousAirHash = null;
                    if (air != null)
                    {
                        byte[] bytes = File.ReadAllBytes(previousAir);
                        AirNavWriter.DecodeWithHash(bytes, snapshot, previousMapHash);
                        previousAirHash = AirNavWriter.Hash(bytes);
                    }
                    string previousHash = previousAirHash == null ? FormatHash(previousMapHash) :
                        PackageHash(previousMapHash, previousAirHash);
                    if (previousHash != hash ||
                        File.ReadAllText(Path.Combine(target, "map.manifest.json")) !=
                            File.ReadAllText(Path.Combine(stage, "map.manifest.json")))
                    {
                        throw new IOException("NAVIGATION_CANDIDATE_CONFLICT");
                    }
                    return target;
                }
                // staging 与 target 位于同一文件系统；最后一次目录 rename 才让完整包可见。
                Directory.Move(stage, target);
                return target;
            }
            finally
            {
                if (Directory.Exists(stage))
                {
                    Directory.Delete(stage, true);
                }
            }
        }

        /// <summary>版本化域 + 原始 BMAP hash + 存在位 + 原始 airnav hash；Manifest 不参与自身身份。</summary>
        public static string PackageHash(string bmap, string airnav)
        {
            return PackageHash(HashFile(bmap), airnav == null ? null : HashFile(airnav));
        }

        // 直接使用原始文件摘要，保留包身份的域、存在位和字节顺序。
        private static string PackageHash(byte[] bmapHash, byte[] airHash)
        {
            byte[] domain = System.Text.Encoding.ASCII.GetBytes("FlyWow.Navigation.Package.V1\0");
            using (var stream = new MemoryStream()) using (SHA256 sha = SHA256.Create())
            {
                stream.Write(domain, 0, domain.Length);
                stream.Write(bmapHash, 0, bmapHash.Length);
                stream.WriteByte(airHash == null ? (byte)0 : (byte)1);
                if (airHash != null)
                {
                    stream.Write(airHash, 0, airHash.Length);
                }
                return FormatHash(sha.ComputeHash(stream.ToArray()));
            }
        }

        /// <summary>计算完整 BMAP 文件的 SHA-256；返回小写十六进制内容身份。</summary>
        /// <param name="path">调用方指定的本地文件，只读；执行流式文件 I/O。</param>
        public static string ContentHash(string path)
        {
            return FormatHash(HashFile(path));
        }

        // 流式计算磁盘资产摘要，避免仅为哈希加载整张地图。
        internal static byte[] HashFile(string path)
        {
            using (SHA256 sha = SHA256.Create()) using (FileStream input = File.OpenRead(path))
            {
                return sha.ComputeHash(input);
            }
        }

        private static string FormatHash(byte[] hash)
        {
            return BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
        }
    }
}
