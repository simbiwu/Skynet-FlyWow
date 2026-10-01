// 职责：使用真实H5 SDK建立WebSocket并发送一个示例Envelope。
// 边界：Example/Interop；Node 22可运行，浏览器可直接import同一SDK。
// 生命周期：完成一条响应后关闭，不保存业务会话，不打印秘密。
// 不负责：不模拟握手；示例命令1001只演示调用，由宿主提供.proto。
import { connectGateway } from "./handshake.mjs";

// 示例只校验Envelope数值字段；Protobuf字段顺序不固定，不能按前两个字节判断。
function validEnvelope(bytes)
{
    let offset = 0;
    const fields = new Map();
    // 读取示例使用的有限正整数varint；损坏或过大字段立即失败。
    const integer = () =>
    {
        let value = 0;
        for (let n = 0; n < 5; ++n)
        {
            if (offset >= bytes.length) throw new Error("TRUNCATED_ENVELOPE");
            const b = bytes[offset++];
            value += (b & 127) * 2 ** (7 * n);
            if (b < 128) return value;
        }
        throw new Error("OVERSIZED_VARINT");
    };
    while (offset < bytes.length)
    {
        const tag = integer();
        if ((tag & 7) === 0) fields.set(tag >>> 3, integer());
        else if ((tag & 7) === 2)
        {
            const size = integer();
            if (offset + size > bytes.length) return false;
            offset += size;
        }
        else return false;
    }
    return fields.get(1) === 3 && fields.get(2) === 1001 && fields.get(3) === 2;
}

// 使用公开SDK接入；URL由调用者注入，不将开发绝对路径写入Runtime。
export async function queryExample(url)
{
    let done, fail;
    const result = new Promise((resolve, reject) =>
    {
        done = resolve;
        fail = reject;
    });
    const connection = await connectGateway(url,
    {
        onmessage(bytes)
        {
            if (!validEnvelope(bytes)) fail(new Error("BAD_ENVELOPE"));
            else done(bytes);
        }
    });
    const timer = setTimeout(() => fail(new Error("RESPONSE_TIMEOUT")), 3000);
    try
    {
        // version=3, command=1001, request_id=2, QueryCell(map_id=1001,map_version=1)。
        connection.send(new Uint8Array([8,3,16,233,7,24,2,34,5,8,233,7,16,1]));
        await result;
    }
    finally
    {
        clearTimeout(timer);
        connection.close();
    }
}

if (typeof process !== "undefined" && process.argv[1]?.endsWith("example.mjs"))
{
    await queryExample(process.argv[2]);
    console.log("H5_WEBCRYPTO_WEBSOCKET_SKYNET_OK");
}
