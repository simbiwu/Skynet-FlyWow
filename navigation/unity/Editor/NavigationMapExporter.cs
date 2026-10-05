// 职责：按 Sample -> Clearance -> Validate -> Write -> Manifest 编排唯一正式导出入口。
// 边界：Unity Editor Tool；由菜单触发，不进入 Player Runtime。
// 输入/输出：当前 Scene -> 显式候选目录中的完整 BMAP/Manifest 包及 Overlay Snapshot。
// 生命周期：开发者在 Editor 菜单显式触发；输出只是待验证、待提交的发布候选资产。
// 不负责：各阶段算法由对应组件实现，本文件只负责顺序和失败传播。
using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;

namespace FlyWow.Navigation.Editor
{
    /// <summary>Unity 侧正式 BMAP 生产入口；只编排已经可独立验证的阶段。</summary>
    public static class NavigationMapExporter
    {
        /// <summary>宿主可追加场景规则校验；同步调用，异常阻止写盘，不修改 Snapshot。</summary>
        public static event Action<NavigationMapRoot, NavigationMapSnapshot> ValidateCandidate;

        // 最近一次成功导出的内存结果；仅供当前 Editor Session 的 Overlay 使用。
        public static NavigationMapSnapshot LastSnapshot { get; private set; }

        /// <summary>
        /// 采样并验证当前场景，把完整候选包提交到宿主指定目录。
        /// </summary>
        /// <exception cref="InvalidOperationException">
        /// 当前场景没有唯一 NavigationMapRoot，或采样、规则校验失败时抛出。
        /// </exception>
        /// <remarks>
        /// 执行磁盘 I/O 并更新 Editor Session 内的 Overlay Snapshot；不提交 Git，也不通知运行中的 Server。
        /// </remarks>
        [MenuItem("Tools/FlyWow/Navigation/03 导出当前场景 BMAP", false, 103)]
        public static void Export()
        {
            try
            {
                // roots 应且只能包含当前 Scene 的唯一地图合同。
                NavigationMapRoot[] roots =
                    UnityEngine.Object
                        .FindObjectsByType<NavigationMapRoot>(FindObjectsSortMode.None)
                        .Where(item => item.gameObject.scene ==
                                       UnityEngine.SceneManagement.SceneManager.GetActiveScene())
                        .ToArray();
                if (roots.Length != 1)
                {
                    throw new InvalidOperationException("BATTLE_MAP_ROOT_COUNT expected=1 actual=" +
                                                        roots.Length);
                }

                // snapshot 是本次完整流水线共享的唯一内存数据源。
                NavigationMapSnapshot snapshot = NavigationMapSampler.Sample(roots[0]);
                NavigationMapClearance.Compute(snapshot);
                NavigationMapValidator.ValidateSnapshot(roots[0], snapshot);
                ValidateCandidate?.Invoke(roots[0], snapshot);
                if (string.IsNullOrWhiteSpace(roots[0].exportDirectory))
                {
                    throw new InvalidOperationException("NAVIGATION_EXPORT_DIRECTORY_REQUIRED");
                }
                string outputDirectory = Path.GetFullPath(
                    Path.Combine(Application.dataPath, "..", roots[0].exportDirectory));
                NavigationAssetPublisher.WriteCandidate(snapshot, outputDirectory);
                LastSnapshot = snapshot;
                SceneView.RepaintAll();

                Debug.Log(string.Format("BMAP_EXPORT_OK path={0} map={1} version={2} size={3}x{4}",
                                        outputDirectory, snapshot.mapId, snapshot.mapVersion,
                                        snapshot.width, snapshot.height));
            }
            catch (Exception exception)
            {
                Debug.LogError("BMAP_EXPORT_FAILED " + exception);
                throw;
            }
        }
    }
}
