# 职责：真实 Skynet 验证日志等级、自动 preload、Native SDK 与默认回退。
# 固定依赖通过参数提供；测试拥有临时配置和日志，结束释放，不使用业务端口。
import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path

# 启动独立进程并等待退出；stderr 用于诊断 Native/bootstrap 失败。
def run_probe(skynet, framework, build, directory, level, enabled=True, bad_path=False):
    tests = framework / "logger/tests"
    path = directory / "logs"
    if bad_path:
        path.write_text("not a directory")
    config = directory / "config.lua"
    values = [
        "thread = 2", "harbor = 0", 'bootstrap = "snlua bootstrap"', 'start = "logger_probe"',
        "luaservice = " + json.dumps(str(tests / "?.lua") + ";" + str(skynet / "service/?.lua")),
        "lualoader = " + json.dumps(str(skynet / "lualib/loader.lua")),
        "lua_path = " + json.dumps(str(skynet / "lualib/?.lua") + ";" +
            str(skynet / "lualib/?/init.lua") + ";" + str(framework / "logger/lualib/?.lua")),
        "lua_cpath = " + json.dumps(str(skynet / "luaclib/?.so")),
        "cpath = " + json.dumps(str(skynet / "cservice/?.so") + ";" + str(build / "native/?.so") + ";" + str(build / "cmake/logger/?.so")),
    ]
    if enabled:
        values += [
            'logservice = "flywow_logger"',
            "logger = " + json.dumps(str(path)),
            "flywow_logger_level = " + json.dumps(level),
            "preload = " + json.dumps(str(framework / "logger/lualib/flywow_logger_preload.lua")),
        ]
    config.write_text("\n".join(values) + "\n")
    result = subprocess.run([str(skynet / "skynet"), str(config)], cwd=directory,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    if bad_path:
        assert result.returncode != 0 and "启动失败" in result.stderr, result.stderr
        return ""
    assert result.returncode == 0, result.stderr
    if not enabled:
        assert "PROBE_ERROR" in result.stdout
        assert "[DEBUG] NATIVE_DEBUG" in result.stdout
        assert "[NORMAL] NATIVE_NORMAL" in result.stdout
        assert "[ERROR] NATIVE_ERROR" in result.stdout
        return result.stdout
    files = list(path.glob("*.log"))
    assert len(files) == 1, result.stderr
    return files[0].read_text()

# 验证三个阈值、追加、故障和回退；每次运行独立，不污染宿主日志。
def main():
    parser = argparse.ArgumentParser(description="真实 Skynet Logger 集成验证")
    parser.add_argument("--skynet", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    args = parser.parse_args()
    framework = Path(__file__).resolve().parents[2]
    skynet, build = args.skynet.resolve(), args.build.resolve()
    with tempfile.TemporaryDirectory(prefix="flywow_logger_integration_") as temporary:
        root = Path(temporary)
        for level in ("debug", "normal", "error"):
            directory = root / level
            directory.mkdir()
            text = run_probe(skynet, framework, build, directory, level)
            assert ("PROBE_DEBUG" in text) == (level == "debug")
            assert ("PROBE_NORMAL" in text) == (level != "error")
            assert "PROBE_ERROR" in text and "NATIVE_ERROR" in text
            assert ("NATIVE_DEBUG" in text) == (level == "debug")
            assert ("NATIVE_NORMAL" in text) == (level != "error")
            if level != "error":
                assert "[logger_child:" in text and "[logger_probe:" in text
                assert "PROBE_NIL nil" in text and "[TRUNCATED]" in text
                assert "PROBE_LINE\\nsecond" in text
            assert re.search(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[ERROR\]", text)
            again = run_probe(skynet, framework, build, directory, level)
            assert again.count("PROBE_ERROR") == 2
        for mode in ("default", "invalid"):
            directory = root / mode
            directory.mkdir()
            run_probe(skynet, framework, build, directory, "normal",
                enabled=mode != "default", bad_path=mode == "invalid")
    print("FLYWOW_LOGGER_INTEGRATION_OK thresholds=3 append preload child flush default invalid")

if __name__ == "__main__":
    main()
