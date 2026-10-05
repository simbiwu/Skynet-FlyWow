# 职责：验证独立握手状态机和真实OpenSSL对cryptography的密码互通。
# 边界：Test Runner；显式注入固定Lua和宿主luaclib，cryptography仅属于验收依赖。
# 生命周期：子进程communicate超时后终止；不启动Skynet、不输出secret。
# 不负责：缺少依赖显式skip，不把skip描述为通过。
import hashlib
import hmac
import os
from pathlib import Path
import subprocess
import select
import shutil
import unittest


class HandshakeTests(unittest.TestCase):
    # 真实Web Crypto的错误输入与异步关闭，Node不存在时明确skip。
    def test_h5_sdk_failures(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("需要Node 22/Web Crypto")
        root = Path(__file__).resolve().parents[2]
        result = subprocess.run([node, str(root / "gateway/tests/gateway_handshake_sdk_test.mjs")], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("H5_HANDSHAKE_SDK_FAILURES_OK", result.stdout)

    # 固定Lua驱动真实状态机；没有解释器时明确跳过。
    def test_state_machine(self):
        lua = os.environ.get("SKYNET_LUA")
        if not lua:
            self.skipTest("需要SKYNET_LUA")
        root = Path(__file__).resolve().parents[2]
        result = subprocess.run([lua, str(root / "gateway/tests/gateway_handshake_test.lua"), str(root)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GATEWAY_HANDSHAKE_UNIT_OK", result.stdout)

    # 使用独立Python库计算Z/HKDF/HMAC，与真实Native交互，不使用替身密码运算。
    def test_native_interop(self):
        lua = os.environ.get("SKYNET_LUA")
        lib = os.environ.get("SKYNET_LUACLIB")
        if not lua or not lib:
            self.skipTest("需要SKYNET_LUA和SKYNET_LUACLIB")
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.kdf.hkdf import HKDF
        root = Path(__file__).resolve().parents[2]
        private = ec.generate_private_key(ec.SECP256R1())
        hello = b"\x01\x01" + private.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        child = subprocess.Popen([lua, str(root / "gateway/tests/gateway_crypto_driver.lua"), lib], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            child.stdin.write(hello.hex() + "\n")
            child.stdin.flush()
            self.assertTrue(select.select([child.stdout], [], [], 10)[0], "Native challenge timeout")
            challenge = bytes.fromhex(child.stdout.readline().strip())
            self.assertEqual(len(challenge), 99)
            peer = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), challenge[2:67])
            z = private.exchange(ec.ECDH(), peer)
            transcript = hashlib.sha256(hello + challenge).digest()
            key = HKDF(algorithm=hashes.SHA256(), length=32, salt=challenge[67:], info=b"flywow/handshake/v1" + transcript).derive(z)
            proof = b"\x03" + hmac.digest(key, b"client-proof" + transcript, "sha256")
            output, error = child.communicate(proof.hex() + "\n", timeout=10)
            self.assertEqual(child.returncode, 0, error)
            expected = b"\x04" + hmac.digest(key, b"server-ready" + transcript, "sha256")
            self.assertEqual(bytes.fromhex(output.splitlines()[0]), expected)
            self.assertIn("NATIVE_LIFECYCLE_OK", output)
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()
            for stream in (child.stdin, child.stdout, child.stderr):
                if stream:
                    stream.close()


if __name__ == "__main__":
    unittest.main()
