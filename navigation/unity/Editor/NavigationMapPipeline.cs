// 职责：为当前 Battle Scene 提供带顺序的单步菜单和一键 Authoring 资产构建入口。
// 边界：Unity Editor Authoring Pipeline；调用正式 Validator、AI Navigation Bake 和 BMAP Exporter。
// 输入/输出：当前已保存 Scene -> 持久化 NavMeshData、BMAP、Manifest 和明确阶段日志。
// 生命周期：Bake 是 Editor 异步任务；静态状态只在一次域生命周期内跟踪当前流水线。
// 不负责：不修改地图业务配置、不注册 Server 地图、不吞掉校验或导出失败。
#if UNITY_EDITOR
using System;
using System.Linq;
using Unity.AI.Navigation;
using Unity.AI.Navigation.Editor;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace FlyWow.Navigation.Editor
{
    /// <summary>
    /// 复用各正式阶段实现，把当前 Scene 的校验、异步 Bake、保存和导出按固定顺序编排。
    /// </summary>
    public static class NavigationMapPipeline
    {
        // 当前正在 Bake 的唯一 Surface；非空也表示流水线占用中。
        private static NavMeshSurface pendingSurface;
        // true 表示 Bake 成功并保存后继续执行正式 BMAP Exporter。
        private static bool exportAfterBake;

        /// <summary>
        /// 执行推荐的完整资产构建链；任一阶段失败都会停止后续阶段。
        /// 本函数会启动异步 Bake，最终导出在 Editor update 回调中完成。
        /// </summary>
        [MenuItem("Tools/FlyWow/Navigation/00 一键执行：校验 -> 烘焙 -> 导出（推荐）", false, 100)]
        public static void BuildAll()
        {
            StartBake(true);
        }

        /// <summary>
        /// 单独校验并烘焙当前 Scene，用于隔离 NavMesh Authoring 问题；不导出 BMAP。
        /// </summary>
        [MenuItem("Tools/FlyWow/Navigation/02 烘焙当前场景 NavMesh", false, 102)]
        public static void BakeOnly()
        {
            StartBake(false);
        }

        /// <summary>
        /// 验证当前 Scene 前置条件并启动 AI Navigation 1.1.7 的异步 Bake。
        /// </summary>
        /// <param name="shouldExport">Bake 与 Scene 保存成功后是否继续导出 BMAP。</param>
        /// <exception cref="InvalidOperationException">播放模式、未保存 Scene、Surface 数量或并发状态非法。</exception>
        private static void StartBake(bool shouldExport)
        {
            if (EditorApplication.isPlayingOrWillChangePlaymode)
            {
                throw new InvalidOperationException("BATTLE_MAP_PIPELINE_PLAY_MODE_NOT_ALLOWED");
            }
            if (pendingSurface != null)
            {
                throw new InvalidOperationException("BATTLE_MAP_PIPELINE_ALREADY_RUNNING");
            }

            Scene scene = SceneManager.GetActiveScene();
            if (!scene.IsValid() || !scene.isLoaded || string.IsNullOrEmpty(scene.path))
            {
                throw new InvalidOperationException("BATTLE_MAP_SCENE_MUST_BE_SAVED");
            }

            // Bake 前先检查唯一地图根、Collider 和双方出生点，避免用昂贵 Bake 掩盖基础配置错误。
            NavigationMapAuthoringValidator.Validate();

            NavMeshSurface[] surfaces =
                UnityEngine.Object
                    .FindObjectsByType<NavMeshSurface>(FindObjectsInactive.Exclude,
                                                       FindObjectsSortMode.None)
                    .Where(surface => surface.gameObject.scene == scene)
                    .ToArray();
            if (surfaces.Length != 1)
            {
                throw new InvalidOperationException(
                    "BATTLE_NAVMESH_SURFACE_COUNT expected=1 actual=" + surfaces.Length);
            }

            NavMeshAssetManager manager = NavMeshAssetManager.instance;
            if (manager.IsSurfaceBaking(surfaces[0]))
            {
                throw new InvalidOperationException("BATTLE_NAVMESH_BAKE_ALREADY_RUNNING");
            }

            pendingSurface  = surfaces[0];
            exportAfterBake = shouldExport;
            EditorApplication.update += CompleteBakeWhenReady;
            try
            {
                // 使用 Package 的 Editor Asset Manager，确保 NavMeshData 被保存成 Scene 专属资产。
                manager.StartBakingSurfaces(new UnityEngine.Object[] { pendingSurface });
                Debug.Log("BATTLE_MAP_BAKE_STARTED scene=" + scene.path +
                          " export_after_bake=" + shouldExport);
            }
            catch
            {
                ResetPendingBake();
                throw;
            }
        }

        /// <summary>
        /// 在 Package 完成异步 Bake 后保存 Scene，并按请求继续执行正式 Exporter。
        /// 本回调不阻塞 Editor；异常会终止流水线并写出带阶段的错误日志。
        /// </summary>
        private static void CompleteBakeWhenReady()
        {
            if (pendingSurface == null ||
                NavMeshAssetManager.instance.IsSurfaceBaking(pendingSurface))
            {
                return;
            }

            NavMeshSurface completedSurface = pendingSurface;
            bool           shouldExport     = exportAfterBake;
            try
            {
                if (completedSurface.navMeshData == null)
                {
                    throw new InvalidOperationException("BATTLE_NAVMESH_BAKE_NO_DATA");
                }

                Scene scene = completedSurface.gameObject.scene;
                AssetDatabase.SaveAssets();
                if (!EditorSceneManager.SaveScene(scene))
                {
                    throw new InvalidOperationException("BATTLE_MAP_SCENE_SAVE_FAILED path=" +
                                                        scene.path);
                }

                Debug.Log("BATTLE_MAP_BAKE_OK scene=" + scene.path +
                          " navmesh=" + AssetDatabase.GetAssetPath(completedSurface.navMeshData));

                if (shouldExport)
                {
                    NavigationMapExporter.Export();
                    Debug.Log("BATTLE_MAP_PIPELINE_OK scene=" + scene.path);
                }
            }
            catch (Exception exception)
            {
                Debug.LogError("BATTLE_MAP_PIPELINE_FAILED " + exception);
            }
            finally
            {
                ResetPendingBake();
            }
        }

        /// <summary>取消 update 订阅并释放本次 Editor 流水线持有的引用。</summary>
        private static void ResetPendingBake()
        {
            EditorApplication.update -= CompleteBakeWhenReady;
            pendingSurface  = null;
            exportAfterBake = false;
        }
    }
}
#endif
