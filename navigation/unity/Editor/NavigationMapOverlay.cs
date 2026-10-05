// 职责：把最后一次成功导出的 Snapshot 只读绘制回 Scene 便于人工检查。
// 边界：Unity Editor Debug Visualization；不进入资产和 Server。
// 输入/输出：缓存 Snapshot -> Scene View 颜色和文字标记。
// 不负责：不重新采样、不修改 Scene、不决定可走性。
using UnityEditor;
using UnityEngine;

namespace FlyWow.Navigation.Editor
{
    /// <summary>
    /// 把最近一次成功导出的 Snapshot 画回 Scene；不重新采样，不改变资产。
    /// </summary>
    [InitializeOnLoad]
    public static class NavigationMapOverlay
    {
        // 当前 Editor Session 的显示开关，不保存进 BMAP 或 Scene。
        private static bool enabled = true;

        static NavigationMapOverlay()
        {
            SceneView.duringSceneGui += Draw;
        }

        [MenuItem("Tools/FlyWow/Navigation/调试/11 切换 Grid Overlay", false, 111)]
        private static void Toggle()
        {
            enabled = !enabled;
            SceneView.RepaintAll();
        }

        private static void Draw(SceneView sceneView)
        {
            if (!enabled || NavigationMapExporter.LastSnapshot == null)
            {
                return;
            }

            // snapshot 与最近一次正式导出使用的是同一实例。
            NavigationMapSnapshot snapshot = NavigationMapExporter.LastSnapshot;
            // cellSize 是从毫米转换回 Unity 米的 Cell 边长，仅用于绘制。
            float cellSize = snapshot.cellSizeMm / 1000f;
            // originX 是从毫米转换回 Unity 米的 Grid 左下角世界 X。
            float originX = snapshot.originXMm / 1000f;
            // originZ 是从毫米转换回 Unity 米的 Grid 左下角世界 Z。
            float originZ = snapshot.originZMm / 1000f;

            // z/x 是当前绘制 Cell 的 Grid 行列下标。
            for (int z = 0; z < snapshot.height; ++z)
            {
                // x 是当前绘制 Cell 的 Grid 列下标。
                for (int x = 0; x < snapshot.width; ++x)
                {
                    // cell 是已经导出的静态格数据，不重新调用 NavMesh API。
                    NavCell cell = snapshot.CellAt(x, z);
                    // y 是绘制高度（米）；+0.03 避免与地表发生 z-fighting。
                    float y = cell.heightMm / 1000f + 0.03f;
                    // center 是当前 Cell 的 Unity world center，单位米。
                    Vector3 center = new Vector3(originX + (x + 0.5f) * cellSize, y,
                                                 originZ + (z + 0.5f) * cellSize);
                    // half 略小于半格，让相邻格之间保留可辨认缝隙。
                    float half = cellSize * 0.47f;
                    // corners 按矩形顺序保存四个世界空间顶点。
                    var corners = new[] {
                        center + new Vector3(-half, 0f, -half),
                        center + new Vector3(-half, 0f, half),
                        center + new Vector3(half, 0f, half),
                        center + new Vector3(half, 0f, -half),
                    };

                    // fill 只表达可走/不可走观察结果，不编码 Area 或业务状态。
                    Color fill = cell.IsWalkable ? new Color(0f, 0.8f, 0.1f, 0.18f)
                                                 : new Color(0.9f, 0f, 0f, 0.22f);
                    Handles.DrawSolidRectangleWithOutline(corners, fill,
                                                          new Color(fill.r, fill.g, fill.b, 0.55f));
                }
            }
        }
    }
}
