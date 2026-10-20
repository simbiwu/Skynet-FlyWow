import { connectGateway } from "../clients/h5/handshake.mjs";
import { frame_join, verify } from "./gateway_protobuf.mjs";

const url = process.argv[2];
if (!url) throw new Error("用法: node gateway_client.mjs ws://127.0.0.1:PORT");
let connection;
let response_received = false;
connection = await connectGateway(url,
{
    timeoutMs: 10000,
    onmessage(bytes)
    {
        const kind = verify(new Uint8Array(bytes));
        if (kind === "response") response_received = true;
        if (kind === "push")
        {
            if (!response_received) throw new Error("PUSH_ARRIVED_BEFORE_RESPONSE");
            connection.close();
        }
    },
});
connection.send(frame_join());
console.log("FrameJoin 请求已发送：scenario_id=1");
