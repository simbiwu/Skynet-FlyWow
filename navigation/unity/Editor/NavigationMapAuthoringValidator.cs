// 职责：检查当前导航场景 的通用 Authoring 组件、Layer、Collider 和 NavMesh 前置条件。
// 边界：Unity Editor Authoring Check；可用于新增或导入的 Battle Scene。
// 输入/输出：当前 Scene -> 通过日志或带错误码的明确异常。
// 不负责：不自动修改 Scene、不 Bake、不导出 BMAP。
#if UNITY_EDITOR
using System.Linq;
using FlyWow.Navigation;
using UnityEditor;
using UnityEngine;

namespace FlyWow.Navigation.Editor
{
    /// <summary>
    /// 检查当前导航场景 是否具备地图导出前的基础配置。
    /// 检查对象始终是当前打开的场景，不绑定场景名或固定 mapId，因此可供不同导航场景 复用。
    /// 只验证离线前置条件，不执行运行时导航查询；失败阻止后续导出。
    /// </summary>
    public static class NavigationMapAuthoringValidator
    {
        /// <summary>
        /// 验证当前打开的场景。
        /// 本方法只做快速检查，不执行 NavMesh Bake、Grid Sampling 或 BMAP Export。
        /// </summary>
        [MenuItem("Tools/FlyWow/Navigation/01 校验当前战斗场景", false, 101)]
        public static void Validate()
        {
            // 每个导航场景 必须只有一个 NavigationMapRoot，它保存该地图的导出配置。
            NavigationMapRoot[] roots =
                UnityEngine.Object.FindObjectsOfType<NavigationMapRoot>()
                    .Where(item => item.gameObject.scene ==
                                   UnityEngine.SceneManagement.SceneManager.GetActiveScene())
                    .ToArray();
            if (roots.Length != 1)
            {
                throw new System.InvalidOperationException(
                    $"BATTLE_MAP_ROOT_COUNT expected=1 actual={roots.Length}");
            }

            NavigationMapRoot root = roots[0];
            root.ValidateOrThrow();

            // NavMesh 构建需要从场景几何收集 Collider；完全没有 Collider 通常表示场景尚未配置好。
            Collider[] colliders =
                UnityEngine.Object.FindObjectsOfType<Collider>()
                    .Where(item => item.gameObject.scene == root.gameObject.scene)
                    .ToArray();
            if (colliders.Length == 0)
            {
                throw new System.InvalidOperationException("AUTHORING_COLLIDER_MISSING");
            }

            Debug.Log($"BATTLE_MAP_AUTHORING_OK map={root.mapId} version={root.mapVersion} " +
                      $"grid={root.Width}x{root.Height} cell_mm={root.CellSizeMm} " +
                      $"colliders={colliders.Length}");
        }
    }
}
#endif
