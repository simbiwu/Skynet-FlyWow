// 职责：为首次接入创建一个不含游戏规则的最小导航场景。
// 边界：Unity Editor Example；只在用户明确点击菜单时创建新场景，不覆盖已有场景。
// 输入输出：用户选择保存路径 -> 地面、障碍、地图根与 NavMeshSurface。
using Unity.AI.Navigation;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace FlyWow.Navigation.Editor
{
    public static class NavigationExampleBuilder
    {
        /// <summary>提示保存当前修改后创建示例；取消时不改变场景，不自动 Bake 或发布。</summary>
        [MenuItem("Tools/FlyWow/Navigation/创建最小接入场景")]
        public static void Create()
        {
            string path = EditorUtility.SaveFilePanelInProject("保存导航示例", "NavigationExample",
                                                               "unity", "选择新场景路径");
            if (string.IsNullOrEmpty(path) ||
                !EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo())
            {
                return;
            }
            if (System.IO.File.Exists(path))
            {
                throw new System.InvalidOperationException("NAVIGATION_EXAMPLE_TARGET_EXISTS");
            }
            Scene scene =
                EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            GameObject        root = new GameObject("NavigationMap");
            NavigationMapRoot map  = root.AddComponent<NavigationMapRoot>();
            map.originMeters       = new Vector2(-5, -5);
            map.sizeXMeters        = 10;
            map.sizeZMeters        = 10;
            root.AddComponent<NavMeshSurface>();
            GameObject ground             = GameObject.CreatePrimitive(PrimitiveType.Cube);
            ground.name                   = "Ground";
            ground.transform.position     = new Vector3(0, -0.25f, 0);
            ground.transform.localScale   = new Vector3(10, 0.5f, 10);
            GameObject obstacle           = GameObject.CreatePrimitive(PrimitiveType.Cube);
            obstacle.name                 = "Obstacle";
            obstacle.transform.position   = new Vector3(0, 1, 0);
            obstacle.transform.localScale = new Vector3(2, 2, 2);
            EditorSceneManager.SaveScene(scene, path);
            Selection.activeGameObject = root;
        }
    }
}
