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
        public static string WriteCandidate(NavigationMapSnapshot snapshot, string outputRoot)
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
                BMapManifestWriter.Write(snapshot, map);
                string hash   = ContentHash(map);
                string target = Path.Combine(outputRoot, "map-" + snapshot.mapId + "-v" +
                                                             snapshot.mapVersion + "-" + hash);
                if (Directory.Exists(target))
                {
                    // 名字相同不能直接相信旧文件；回读两份文件，防止损坏包被当作成功。
                    BMapWriter.Verify(Path.Combine(target, "map.bmap"));
                    if (ContentHash(Path.Combine(target, "map.bmap")) != hash ||
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

        /// <summary>计算完整 BMAP 文件的 SHA-256；返回小写十六进制内容身份。</summary>
        /// <param name="path">调用方指定的本地文件，只读；执行流式文件 I/O。</param>
        public static string ContentHash(string path)
        {
            using (SHA256 sha = SHA256.Create()) using (FileStream input = File.OpenRead(path))
            {
                return BitConverter.ToString(sha.ComputeHash(input))
                    .Replace("-", "")
                    .ToLowerInvariant();
            }
        }
    }
}
