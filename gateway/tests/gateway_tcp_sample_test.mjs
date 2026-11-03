// 职责：用真实本机 TCP 与 Web Crypto 验证 Sample 握手失败后立即关闭 Socket。
// 边界：只监听随机本机端口；不启动 Skynet，不代替 Native 密码互通验收。
import assert from "node:assert/strict";
import net from "node:net";
import { createECDH, randomBytes } from "node:crypto";
import { HandshakeClient } from "../clients/h5/handshake.mjs";
import { connectTcp } from "../sample/gateway_tcp_support.mjs";

// 模拟服务端提供坏挑战、坏 READY 或 EOF，验证 connectTcp 拒绝后对端能立即观察到关闭。
async function verifyFailure(mode)
{
    const sockets = new Set(); // 本场景创建的服务端 Socket；finally 逐个释放，失败也不留下监听连接。
    let observeClose; // 客户端销毁 Socket 后由服务端 close 事件完成。
    const peerClosed = new Promise(resolve => { observeClose = resolve; });
    const server = net.createServer(socket =>
    {
        sockets.add(socket);
        socket.on("error", () => {});
        socket.on("close", () => { sockets.delete(socket); observeClose(); });
        let buffer = Buffer.alloc(0); // 服务端尚未读满的 TCP 长度帧。
        let receivedHello = false; // 此测试服务端仅等待 HELLO、PROOF 两个阶段。
        socket.on("data", chunk =>
        {
            buffer = Buffer.concat([buffer, chunk]);
            while (buffer.length >= 2 && buffer.length >= buffer.readUInt16BE(0) + 2)
            {
                const length = buffer.readUInt16BE(0); // 当前完整入站帧的长度，不含两字节头。
                buffer = buffer.subarray(length + 2);
                if (!receivedHello)
                {
                    receivedHello = true;
                    if (mode === "empty") { socket.write(Buffer.from([0, 0])); return; }
                    if (mode === "eof") { socket.end(); return; }
                    if (mode === "challenge") { socket.write(Buffer.from([0, 1, 2])); return; }
                    const ecdh = createECDH("prime256v1"); // 合法 P-256 公钥让真实 SDK 进入 PROOF，再测试坏 READY。
                    const challenge = Buffer.concat([Buffer.from([2, 1]), ecdh.generateKeys(), randomBytes(32)]);
                    const header = Buffer.alloc(2); // SERVER_CHALLENGE 的真实 TCP 长度头。
                    header.writeUInt16BE(challenge.length);
                    socket.write(Buffer.concat([header, challenge]));
                }
                else
                {
                    socket.write(Buffer.concat([Buffer.from([0, 33, 4]), Buffer.alloc(32)]));
                }
            }
        });
    });
    let timer; // 限制测试等待关闭的时间，不能依赖 Sample 原本十秒的空闲超时。
    try
    {
        await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
        const rejected = connectTcp(server.address().port); // 真实客户端应在握手失败后拒绝，并销毁它拥有的 Socket。
        await assert.rejects(rejected);
        await Promise.race([peerClosed, new Promise((_, reject) =>
        {
            timer = setTimeout(() => reject(new Error("sample did not close failed handshake")), 1000);
        })]);
    }
    finally
    {
        clearTimeout(timer);
        for (const socket of sockets) socket.destroy();
        await new Promise(resolve => server.close(resolve));
    }
}

for (const mode of ["challenge", "ready", "eof", "empty"]) await verifyFailure(mode);
const originalBegin = HandshakeClient.prototype.begin; // 故障注入后恢复公开 SDK 方法，避免场景污染。
try
{
    HandshakeClient.prototype.begin = async () => { throw new Error("injected crypto failure"); };
    await verifyFailure("crypto");
}
finally
{
    HandshakeClient.prototype.begin = originalBegin;
}
console.log("GATEWAY_TCP_SAMPLE_FAILURE_CLEANUP_OK");
