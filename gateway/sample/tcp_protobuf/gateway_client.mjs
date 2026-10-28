import { connectTcp } from "../gateway_tcp_support.mjs";
import { frame_join, verify } from "../gateway_protobuf.mjs";

const port = Number(process.argv[2]); // run script 传入的本地 Gateway TCP 端口。
if (!Number.isInteger(port) || port < 1 || port > 65535)
    throw new Error("用法: node gateway_client.mjs PORT");

const connection = await connectTcp(port); // 握手完成后由此客户端独占读写和关闭的 TCP 连接。
connection.writeFrame(frame_join());
console.log("TCP Protobuf FrameJoin 请求已发送");
if (verify(await connection.readFrame()) !== "response")
    throw new Error("FRAME_JOIN_RESPONSE_MISSING");
if (verify(await connection.readFrame()) !== "push")
    throw new Error("FRAME_PUSH_MISSING");
connection.close();
