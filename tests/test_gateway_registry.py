# 职责：验证 Gateway registry 生成器的成功路径、结构失败和原子写入。
# 边界：FlyWow Build Tool Test；不启动 Skynet、不加载宿主 descriptor。
# 输入/输出：内存 Proto 文本和临时目录 -> unittest 断言。
# 生命周期：每个用例独立；TemporaryDirectory 负责回收输出。
# 不负责：不替代 protoc 语义验证，不测试 Gateway Runtime。

import importlib.util
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).resolve().parents[1] / "scripts" / "generate_gateway_registry.py"
SPEC = importlib.util.spec_from_file_location("generate_gateway_registry", TOOL)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class GatewayRegistryTest(unittest.TestCase):
    """验证生成器的确定性输出、结构校验和文件提交。"""

    @staticmethod
    def valid_proto() -> str:
        """返回最小合法 proto3 Gateway 合同；不执行 I/O。"""
        return """syntax = "proto3";
package demo.v1;
message Envelope
{}
enum CommandId
{
  COMMAND_UNSPECIFIED = 0;
  ECHO = 42;
}
message EchoRequest
{}
message EchoResponse
{}
"""

    def test_render_command_registry(self) -> None:
        """合法 CommandId 必须生成确定 command id 和完整类型名。"""
        package, commands = MODULE.parse_proto(self.valid_proto())
        output = MODULE.render(package, commands)
        self.assertIn("return\n{", output)
        self.assertIn("[42] =\n        {", output)
        self.assertIn(".demo.v1.EchoRequest", output)

    def test_push_command_without_request_is_supported(self) -> None:
        """只有 XxxResponse 的命令必须生成 nil request_type。"""
        _, commands = MODULE.parse_proto(
            self.valid_proto().replace("message EchoRequest\n{}\n", "")
        )
        self.assertIsNone(commands[0]["request"])
        self.assertIn("request_type  = nil", MODULE.render("demo.v1", commands))

    def test_duplicate_command_id_fails(self) -> None:
        """两个命令使用同一 command id 必须失败。"""
        with self.assertRaises(ValueError):
            MODULE.parse_proto(
                self.valid_proto().replace(
                    "  ECHO = 42;\n",
                    "  ECHO = 42;\n  OTHER = 42;\n",
                )
            )

    def test_one_way_command_is_supported(self) -> None:
        """没有 XxxResponse 的命令必须生成 nil response_type。"""
        proto = self.valid_proto().replace("message EchoResponse\n{}\n", "")
        _, commands = MODULE.parse_proto(proto)
        self.assertIsNone(commands[0]["response"])
        self.assertIn("response_type = nil", MODULE.render("demo.v1", commands))

    def test_invalid_structure_or_message_fails(self) -> None:
        """缺失 Envelope 或 CommandId 时必须失败。"""
        with self.assertRaisesRegex(ValueError, "Envelope"):
            MODULE.parse_proto(self.valid_proto().replace("message Envelope\n{}\n", ""))
        with self.assertRaisesRegex(ValueError, "CommandId"):
            MODULE.parse_proto(self.valid_proto().replace("enum CommandId", "enum OtherId"))

    def test_write_if_changed_is_stable_and_complete(self) -> None:
        """相同内容不改 mtime，变化内容只暴露完整最终文件。"""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "generated" / "registry.lua"
            MODULE.write_if_changed(output, "first\n")
            first_stat = output.stat()
            MODULE.write_if_changed(output, "first\n")
            self.assertEqual(first_stat.st_mtime_ns, output.stat().st_mtime_ns)
            MODULE.write_if_changed(output, "second\n")
            self.assertEqual("second\n", output.read_text(encoding="utf-8"))
            self.assertEqual([], list(output.parent.glob(".*.tmp")))


if __name__ == "__main__":
    unittest.main()
