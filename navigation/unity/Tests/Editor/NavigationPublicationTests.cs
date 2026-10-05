// 职责：在没有课程 Battle 组件的场景中验证 Bake、采样与完整候选包发布。
// 边界：独立 Package EditMode Test；NavMesh 和临时目录由测试独占并清理。
// 输入/输出：地面 Cube -> NavMesh -> BMAP + Manifest；失败行为也必须可断言。
using System;
using System.IO;
using NUnit.Framework;
using Unity.AI.Navigation;
using UnityEngine;
using UnityEngine.AI;
using FlyWow.Navigation.Editor;

namespace FlyWow.Navigation.Tests
{
    public sealed class NavigationPublicationTests
    {
        /// <summary>新场景不需要 BattleSpawnPoint；通用导航仍能产出可加载的候选包。</summary>
        [Test]
        public void NewSceneBakesSamplesAndPublishesCompleteCandidate()
        {
            var    container = new GameObject("NavigationPackageTest");
            string output =
                Path.Combine(Path.GetTempPath(), "flywow-nav-" + Guid.NewGuid().ToString("N"));
            NavMeshSurface surface = null;
            try
            {
                NavigationMapRoot root = container.AddComponent<NavigationMapRoot>();
                root.mapId             = 17;
                root.originMeters      = new Vector2(-5f, -5f);
                root.sizeXMeters       = 10f;
                root.sizeZMeters       = 10f;

                GameObject floor = GameObject.CreatePrimitive(PrimitiveType.Cube);
                floor.transform.SetParent(container.transform);
                floor.transform.position   = new Vector3(0f, -0.5f, 0f);
                floor.transform.localScale = new Vector3(10f, 1f, 10f);
                surface                    = container.AddComponent<NavMeshSurface>();
                // 只收集本测试子物体，避免其它 Scene 的几何影响 Bake。
                surface.collectObjects = CollectObjects.Children;
                surface.useGeometry    = NavMeshCollectGeometry.PhysicsColliders;
                surface.BuildNavMesh();

                NavigationMapSnapshot snapshot = NavigationMapSampler.Sample(root);
                NavigationMapClearance.Compute(snapshot);
                NavigationMapValidator.ValidateSnapshot(root, snapshot);
                Assert.That(snapshot.CellAt(10, 10).IsWalkable, Is.True);

                string candidate = NavigationAssetPublisher.WriteCandidate(snapshot, output);
                Assert.That(File.Exists(Path.Combine(candidate, "map.manifest.json")), Is.True);
                Assert.DoesNotThrow(() => BMapWriter.Verify(Path.Combine(candidate, "map.bmap")));
                string manifest = File.ReadAllText(Path.Combine(candidate, "map.manifest.json"));
                Assert.That(manifest, Does.Contain(NavigationAssetPublisher.ContentHash(
                                          Path.Combine(candidate, "map.bmap"))));
                Assert.That(manifest, Does.Contain("ground_2_5d"));

                // 相同内容重复导出复用完整目录，不产生新版本、不覆盖已有文件。
                Assert.That(NavigationAssetPublisher.WriteCandidate(snapshot, output),
                            Is.EqualTo(candidate));
                // 即使目录名正确，旧 Manifest 被损坏也必须拒绝；清理未提交 staging。
                File.WriteAllText(Path.Combine(candidate, "map.manifest.json"), "{}");
                Assert.Throws<IOException>(
                    () => NavigationAssetPublisher.WriteCandidate(snapshot, output));
                Assert.That(Directory.GetDirectories(output, ".staging-*"), Is.Empty);
            }
            finally
            {
                if (surface != null)
                {
                    surface.RemoveData();
                }
                UnityEngine.Object.DestroyImmediate(container);
                if (Directory.Exists(output))
                {
                    Directory.Delete(output, true);
                }
            }
        }
    }
}
