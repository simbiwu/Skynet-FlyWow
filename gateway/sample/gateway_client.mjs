import { connectGateway } from "../clients/h5/handshake.mjs";
function join(...parts)
{
    const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
    let offset = 0;
    for (const part of parts) { out.set(part, offset); offset += part.length; }
    return out;
}
function varint(value)
{
    const out = [];
    while (value > 127) { out.push((value & 127) | 128); value >>>= 7; }
    out.push(value);
    return Uint8Array.from(out);
}
function field(number, wire, value)
{
    return join(varint(number * 8 + wire),
        wire === 2 ? join(varint(value.length), value) : varint(value));
}
function fields(bytes)
{
    const out = new Map();
    let offset = 0;
    const read = () =>
    {
        let value = 0, shift = 0, byte;
        do
        {
            if (offset >= bytes.length || shift >= 35) throw new Error("INVALID_PROTOBUF_VARINT");
            byte = bytes[offset++];
            value |= (byte & 127) << shift;
            shift += 7;
        } while (byte & 128);
        return value >>> 0;
    };
    while (offset < bytes.length)
    {
        const key = read(), number = key >>> 3, wire = key & 7;
        if (wire === 0) out.set(number, read());
        else if (wire === 2)
        {
            const length = read(), end = offset + length;
            if (end > bytes.length) throw new Error("INVALID_PROTOBUF_LENGTH");
            out.set(number, bytes.slice(offset, end));
            offset = end;
        }
        else throw new Error("UNSUPPORTED_PROTOBUF_WIRE_TYPE");
    }
    return out;
}
const request = join(field(1, 0, 1), field(2, 0, 0), field(3, 0, 1));
const envelope = join(field(1, 0, 4), field(2, 0, 1101), field(3, 2, request));
let connection;
connection = await connectGateway(process.argv[2],
{
    timeoutMs: 10000,
    onmessage(bytes)
    {
        const received = fields(bytes);
        if (received.get(1) !== 4 || received.get(2) !== 1101)
            throw new Error("UNEXPECTED_GATEWAY_ENVELOPE");
        const response = fields(received.get(3));
        if (new TextDecoder().decode(response.get(1)) !== "OK" ||
            response.get(2) !== 42 || response.get(3) !== 1)
            throw new Error("UNEXPECTED_FRAME_JOIN_RESPONSE");
        console.log("FrameJoin 响应已验证：battle_id=42 seat_id=1");
        connection.close();
    },
});
connection.send(envelope);
