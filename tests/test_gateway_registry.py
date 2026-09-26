import importlib.util
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).resolve().parents[1] / "tools" / "generate_gateway_registry.py"
SPEC = importlib.util.spec_from_file_location("generate_gateway_registry", TOOL)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class GatewayRegistryTest(unittest.TestCase):
    """验证协议生成器的成功、缺失 command 和重复 command 失败路径。"""

    def test_render_rpc_registry(self):
        package, commands = MODULE.parse_proto(
            """syntax = \"proto3\";\npackage demo.v1;\nservice Demo {\n  // command_id=42\n  rpc Echo(EchoRequest) returns (EchoResponse);\n}\n"""
        )
        output = MODULE.render(package, commands)
        self.assertIn('[42] = {', output)
        self.assertIn('.demo.v1.EchoRequest', output)

    def test_missing_command_id_fails(self):
        with self.assertRaises(ValueError):
            MODULE.parse_proto(
                "package demo.v1; service Demo { rpc Echo(EchoRequest) returns (EchoResponse); }"
            )

    def test_duplicate_command_id_fails(self):
        with self.assertRaises(ValueError):
            MODULE.parse_proto(
                """package demo.v1; service Demo {
                // command_id=42
                rpc A(ARequest) returns (AResponse);
                // command_id=42
                rpc B(BRequest) returns (BResponse);
                }"""
            )


if __name__ == "__main__":
    unittest.main()
