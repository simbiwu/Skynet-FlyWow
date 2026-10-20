// TCP 握手复用 H5 SDK 的同一合同；业务帧使用 uint16 大端长度头。
import net from "node:net";
import { HandshakeClient } from "../clients/h5/handshake.mjs";

export async function connectTcp(port)
{
    const socket = net.createConnection({host: "127.0.0.1", port});
    socket.setTimeout(10000);
    socket.once("timeout", () => socket.destroy(new Error("TCP_TIMEOUT")));
    await new Promise((resolve, reject) =>
    {
        socket.once("connect", resolve);
        socket.once("error", reject);
    });

    let buffer = Buffer.alloc(0);
    let failure;
    const frames = [];
    const waiters = [];
    socket.on("data", chunk =>
    {
        buffer = Buffer.concat([buffer, chunk]);
        while (buffer.length >= 2)
        {
            const size = buffer.readUInt16BE(0);
            if (size === 0)
            {
                failure = new Error("EMPTY_TCP_FRAME");
                break;
            }
            if (buffer.length < size + 2) break;

            frames.push(buffer.subarray(2, size + 2));
            buffer = buffer.subarray(size + 2);
        }
        while (frames.length > 0 && waiters.length > 0)
        {
            waiters.shift()(frames.shift());
        }
    });
    socket.on("error", error =>
    {
        failure = error;
        while (waiters.length > 0) waiters.shift()(null, error);
    });
    socket.on("close", () =>
    {
        failure ??= new Error("TCP_CLOSED");
        while (waiters.length > 0) waiters.shift()(null, failure);
    });

    const readFrame = () =>
    {
        if (frames.length > 0) return Promise.resolve(frames.shift());
        if (failure) return Promise.reject(failure);
        return new Promise((resolve, reject) =>
            waiters.push((bytes, error) => error ? reject(error) : resolve(bytes)));
    };
    const writeRaw = bytes => socket.write(bytes);
    const writeFrame = bytes =>
    {
        if (bytes.length < 1 || bytes.length > 65535) throw new Error("TCP_FRAME_LENGTH");
        const header = Buffer.alloc(2);
        header.writeUInt16BE(bytes.length, 0);
        writeRaw(Buffer.concat([header, bytes]));
    };

    const handshake = new HandshakeClient(globalThis.crypto);
    writeFrame(await handshake.begin());
    writeFrame(await handshake.respond(await readFrame()));
    await handshake.complete(await readFrame());

    return {
        readFrame,
        writeFrame,
        writeRaw,
        close()
        {
            handshake.close();
            socket.end();
        },
    };
}
