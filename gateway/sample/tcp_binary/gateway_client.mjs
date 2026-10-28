import { connectTcp } from "../gateway_tcp_support.mjs";
import { verify } from "../gateway_protobuf.mjs";

const port = Number(process.argv[2]); // run script 传入的本地 Gateway TCP 端口。
if (!Number.isInteger(port) || port < 1 || port > 65535)
    throw new Error("用法: node gateway_client.mjs PORT");

// uint16 大端长度头后是 Protobuf Envelope wire bytes。
// Envelope 长度 13 字节，包含 version=4、command=1101 和三个 FrameJoin 请求字段。
const packet = Buffer.from(
    [0x00, 0x0d, 0x08, 0x04, 0x10, 0xcd, 0x08, 0x1a, 0x06, 0x08, 0x01, 0x10, 0x00, 0x18, 0x01]);
const connection = await connectTcp(port); // 握手完成后由此客户端独占读写和关闭的 TCP 连接。
connection.writeRaw(packet);
console.log("TCP 二进制帧已发送：length=13 command=1101");
if (verify(await connection.readFrame()) !== "response")
    throw new Error("FRAME_JOIN_RESPONSE_MISSING");
if (verify(await connection.readFrame()) !== "push")
    throw new Error("FRAME_PUSH_MISSING");
connection.close();
