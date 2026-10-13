// 职责：真实 Unity Editor 导出、golden 配对、保守几何与原子发布回归。
using System;
using System.IO;
using System.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using FlyWow.Navigation.Editor;
namespace FlyWow.Navigation.Tests
{
    public sealed class AirNavigationTests
    {
        private static byte[] Golden(string guid)
        {
            string hex =
                AssetDatabase.LoadAssetAtPath<TextAsset>(AssetDatabase.GUIDToAssetPath(guid))
                    .text.Trim();
            return Enumerable.Range(0, hex.Length / 2)
                .Select(i => Convert.ToByte(hex.Substring(i * 2, 2), 16))
                .ToArray();
        }
        private static NavigationMapSnapshot Map()
        {
            return new NavigationMapSnapshot {
                mapId      = 17,
                mapVersion = 2,
                width      = 12,
                height     = 12,
                cellSizeMm = 500,
                originXMm  = -1000,
                originZMm  = -1000,
                cells      = Enumerable
                            .Repeat(new NavCell { heightMm = 0, flags = 1, areaType = 0,
                                                  clearanceCells = 10 },
                                    144)
                            .ToArray()
            };
        }
        private static AirNavSnapshot Air()
        {
            var air = new AirNavSnapshot();
            air.cells.Add(65, new System.Collections.Generic.List<AirNavInterval> {
                new AirNavInterval { minY = 0, maxY = 10000 },
                new AirNavInterval { minY = 12000, maxY = 13000 }
            });
            air.cells.Add(77, new System.Collections.Generic.List<AirNavInterval> {
                new AirNavInterval { minY = 0, maxY = 10000 }
            });
            return air;
        }
        [Test]
        public void UnityWriterMatchesNativeGoldenAndRejectsInvalidPair()
        {
            var map         = Map();
            var air         = Air();
            byte[] ground   = Golden("e176c1c734454cc68811d0a624cab39a");
            byte[] expected = Golden("f2b5d0543a6941a6a59671b38ec144e8");
            string temporary =
                Path.Combine(Path.GetTempPath(), "flywow-golden-" + Guid.NewGuid() + ".bmap");
            try
            {
                BMapWriter.Write(map, temporary);
                CollectionAssert.AreEqual(ground, File.ReadAllBytes(temporary));
                CollectionAssert.AreEqual(expected, AirNavWriter.Encode(map, air, ground));
                Assert.That(AirNavWriter.Decode(expected, map, ground).cells.Count, Is.EqualTo(2));
                byte[] corrupt = (byte[])expected.Clone();
                corrupt[40] ^= 1;
                Assert.Throws<InvalidOperationException>(
                    () => AirNavWriter.Decode(corrupt, map, ground));
                Assert.Throws<InvalidOperationException>(
                    () => AirNavWriter.Decode(expected.Take(expected.Length - 1).ToArray(), map,
                                              ground));
                Assert.That(AirNavWriter.Millimeters(-0.0001, true), Is.EqualTo(-1));
                Assert.That(AirNavWriter.Millimeters(0.0001, false), Is.EqualTo(1));
                Assert.Throws<InvalidOperationException>(
                    () => AirNavWriter.Millimeters(double.MaxValue, true));
            }
            finally
            {
                File.Delete(temporary);
            }
        }
        [Test]
        public void ExplicitColliderLayerExportsClosedBoundariesAndMergesIntervals()
        {
            var owner = new GameObject("AirAuthoringTest");
            try
            {
                var root               = owner.AddComponent<NavigationMapRoot>();
                root.airObstacleLayers = 1 << 30;
                var box                = new GameObject("DedicatedAirBox");
                box.transform.SetParent(owner.transform);
                box.layer                            = 30;
                box.transform.position               = new Vector3(-0.5f, 5f, -0.5f);
                box.AddComponent<BoxCollider>().size = new Vector3(0f, 10f, 0f);
                Physics.SyncTransforms();
                Assert.That(AirNavWriter.Sample(root, Map()), Is.Null);
                root.exportAirNavigation = true;
                var sampled              = AirNavWriter.Sample(root, Map());
                // x=z=-500mm 正好在格线，四个相邻闭格都被覆盖。
                Assert.That(sampled.cells.Keys, Is.EquivalentTo(new uint[] { 0, 1, 12, 13 }));
                var air = new AirNavSnapshot();
                int raw = 0;
                AirNavWriter.AddBounds(air, Map(), -500, -500, -500, -500, 0, 10000, ref raw);
                AirNavWriter.AddBounds(air, Map(), -500, -500, -500, -500, 5000, 12000, ref raw);
                AirNavWriter.Canonicalize(air);
                Assert.That(air.cells[0].Count, Is.EqualTo(1));
                Assert.That(air.cells[0][0].maxY, Is.EqualTo(12000));
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(owner);
            }
        }
        [Test]
        public void CompletePackageIdentityIncludesAirAndFailureRemovesStage()
        {
            string output =
                Path.Combine(Path.GetTempPath(), "flywow-air-publish-" + Guid.NewGuid());
            try
            {
                var    map   = Map();
                var    air   = Air();
                string old   = NavigationAssetPublisher.WriteCandidate(map, output);
                string first = NavigationAssetPublisher.WriteCandidate(map, output, air);
                Assert.That(first, Is.Not.EqualTo(old));
                Assert.That(NavigationAssetPublisher.WriteCandidate(map, output, air),
                            Is.EqualTo(first));
                air.cells[65][0] = new AirNavInterval { minY = 0, maxY = 11000 };
                string second    = NavigationAssetPublisher.WriteCandidate(map, output, air);
                Assert.That(second, Is.Not.EqualTo(first));
                Assert.That(File.ReadAllBytes(Path.Combine(first, "map.bmap")),
                            Is.EqualTo(File.ReadAllBytes(Path.Combine(second, "map.bmap"))));
                File.WriteAllText(Path.Combine(second, "map.manifest.json"), "{}");
                Assert.Throws<IOException>(
                    () => NavigationAssetPublisher.WriteCandidate(map, output, air));
                Assert.That(Directory.GetDirectories(output, ".staging-*"), Is.Empty);
                air.cells[65][0] = new AirNavInterval { minY = 1, maxY = 0 };
                Assert.Throws<InvalidOperationException>(
                    () => NavigationAssetPublisher.WriteCandidate(map, output, air));
                Assert.That(Directory.GetDirectories(output, ".staging-*"), Is.Empty);
            }
            finally
            {
                if (Directory.Exists(output))
                    Directory.Delete(output, true);
            }
        }
    }
}
