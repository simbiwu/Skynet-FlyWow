// 职责：验证真实Web Crypto SDK的失败、重复调用和关闭竞态。
// 边界：Unit Test；Node 22执行平台密码API，无Socket，不替代浏览器验收。
// 生命周期：每个用例独占SDK，完成后close，不输出秘密。
// 不负责：不模拟服务端通过证明；成功互通由真实Skynet集成验收。
import assert from "node:assert/strict";
import { HandshakeClient, connectGateway } from "../clients/h5/handshake.mjs";

// 错误challenge必须关闭；阶段变更不能让失败实例继续计算或复用。
async function badChallenge(bytes)
{
    const client = new HandshakeClient();
    await client.begin();
    await assert.rejects(client.respond(bytes));
    assert.equal(client.phase, "closed");
    client.close();
}

await badChallenge(new Uint8Array(98));
await badChallenge(new Uint8Array([2, 2, 4, ...new Uint8Array(96)]));
await badChallenge(new Uint8Array([2, 1, 4, ...new Uint8Array(96)]));
const client = new HandshakeClient();
const hello = await client.begin();
await assert.rejects(client.begin(), /HANDSHAKE_STATE/);
// 有效曲线点但没有正确server-ready证明，SDK也不能开放业务。
const challenge = new Uint8Array(99);
challenge.set([2, 1]);
challenge.set(hello.slice(2), 2);
crypto.getRandomValues(challenge.subarray(67));
assert.equal((await client.respond(challenge)).length, 33);
await assert.rejects(client.complete(new Uint8Array([4, ...new Uint8Array(32)])), /HANDSHAKE_READY/);
assert.equal(client.phase, "closed");
const closing = new HandshakeClient();
const pending = closing.begin();
closing.close();
await assert.rejects(pending, /HANDSHAKE_CLOSED/);
assert.equal(closing.phase, "closed");
console.log("H5_HANDSHAKE_SDK_FAILURES_OK");

// 只替换握手阶段推进以隔离传输 Promise 顺序；密码正确性由上面的真实 WebCrypto 用例覆盖。
const originalBegin = HandshakeClient.prototype.begin;
const originalComplete = HandshakeClient.prototype.complete;
const originalWebSocket = globalThis.WebSocket;
let activeSocket;
class TestSocket
{
    static OPEN = 1;
    readyState = 1;
    closeCount = 0;
    constructor() { activeSocket = this; }
    send() {}
    close() { this.closeCount++; }
}
HandshakeClient.prototype.begin = async function() { this.phase = "ready-message"; return new Uint8Array(); };
HandshakeClient.prototype.complete = async function() { this.phase = "ready"; };
globalThis.WebSocket = TestSocket;
const flush = () => new Promise(resolve => setImmediate(resolve));
try
{
    let release;
    const order = [];
    const connected = connectGateway("ws://test", { onmessage: async bytes =>
    {
        order.push(bytes[0]);
        if (bytes[0] === 1) await new Promise(resolve => { release = resolve; });
        if (bytes[0] === 3) throw new Error("CALLBACK_FAILED");
    } });
    activeSocket.onopen();
    await flush();
    activeSocket.onmessage({ data: new ArrayBuffer(0) });
    await connected;
    activeSocket.onmessage({ data: new Uint8Array([1]).buffer });
    activeSocket.onmessage({ data: new Uint8Array([2]).buffer });
    await flush();
    assert.deepEqual(order, [1], "async callbacks must execute serially");
    release();
    await flush();
    assert.deepEqual(order, [1, 2]);
    activeSocket.onmessage({ data: new Uint8Array([3]).buffer });
    activeSocket.onmessage({ data: new Uint8Array([4]).buffer });
    await flush();
    assert.deepEqual(order, [1, 2, 3], "callback rejection must stop queued delivery");
    assert.equal(activeSocket.closeCount, 1, "callback rejection follows existing fail path");
}
finally
{
    HandshakeClient.prototype.begin = originalBegin;
    HandshakeClient.prototype.complete = originalComplete;
    globalThis.WebSocket = originalWebSocket;
}
console.log("H5_ASYNC_MESSAGE_ORDER_OK");
