// 职责：使用真实H5 SDK建立WebSocket并发送一个示例Envelope。
// 边界：Example/Interop；Node 22可运行，浏览器可直接import同一SDK。
// 生命周期：完成一条响应后关闭，不保存业务会话，不打印秘密。
// 不负责：不模拟握手；示例命令1001只演示调用，由宿主提供.proto。
import { connectGateway } from "./handshake.mjs";

// 只解析此示例需要的 Protobuf varint 与 bytes 字段；截断和未知 wire type 会拒绝响应。
function decodeFields(bytes)
{
    let offset = 0;
    const fields = new Map();
    const integer = () =>
    {
        let value = 0;
        for (let n = 0; n < 5; ++n)
        {
            if (offset >= bytes.length) throw new Error("TRUNCATED_PROTOBUF");
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
            if (offset + size > bytes.length) throw new Error("TRUNCATED_PROTOBUF");
            fields.set(tag >>> 3, bytes.slice(offset, offset + size));
            offset += size;
        }
        else throw new Error("UNSUPPORTED_WIRE_TYPE");
    }
    return fields;
}

// 当前 Lesson 2 响应必须是版本 4 的 QueryCellResponse，且来自本示例查询的地图。
function validEnvelope(bytes)
{
    try
    {
        const envelope = decodeFields(bytes);
        const body = envelope.get(3);
        if (envelope.get(1) !== 4 || envelope.get(2) !== 1001 || !(body instanceof Uint8Array))
            return false;
        const response = decodeFields(body);
        return Number.isInteger(response.get(1)) && response.get(3) === 1001 && response.get(4) === 1;
    }
    catch
    {
        return false;
    }
}

// 使用公开SDK接入；URL由调用者注入，不将开发绝对路径写入Runtime。
export async function queryExample(url)
{
    let done; // 收到有效样例响应时完成等待。
    let fail; // 格式错误或响应超时时拒绝等待。
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
        // version=4, command=1001, QueryCell(map_id=1001,map_version=1,position=0/0/0 mm)。
        connection.send(new Uint8Array([8,4,16,233,7,26,7,8,233,7,16,1,26,0]));
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
