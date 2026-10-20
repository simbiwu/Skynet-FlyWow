// 只编码/解码 sample 使用的 varint 与 bytes/string 字段；字段号来自 Lesson 3 schema。
export function join(...parts)
{
    return Buffer.concat(parts.map(part => Buffer.from(part)));
}

export function varint(value)
{
    const bytes = [];
    while (value > 127)
    {
        bytes.push((value & 127) | 128);
        value >>>= 7;
    }
    bytes.push(value);
    return Buffer.from(bytes);
}

export function field(number, wire, value)
{
    const key = varint(number * 8 + wire);
    return wire === 2
        ? join(key, varint(value.length), value)
        : join(key, varint(value));
}

export function fields(bytes)
{
    const result = new Map();
    let offset = 0;
    const read_varint = () =>
    {
        let value = 0;
        let shift = 0;
        while (offset < bytes.length && shift < 35)
        {
            const byte = bytes[offset++];
            value |= (byte & 127) << shift;
            if ((byte & 128) === 0) return value >>> 0;
            shift += 7;
        }
        throw new Error("INVALID_PROTOBUF_VARINT");
    };

    while (offset < bytes.length)
    {
        const key = read_varint();
        const number = key >>> 3;
        const wire = key & 7;
        if (wire === 0)
        {
            result.set(number, read_varint());
        }
        else if (wire === 2)
        {
            const length = read_varint();
            const end = offset + length;
            if (end > bytes.length) throw new Error("INVALID_PROTOBUF_LENGTH");
            result.set(number, bytes.subarray(offset, end));
            offset = end;
        }
        else
        {
            throw new Error("UNSUPPORTED_PROTOBUF_WIRE_TYPE");
        }
    }
    return result;
}

export function frame_join()
{
    const body = join(field(1, 0, 1), field(2, 0, 0), field(3, 0, 1));
    return join(field(1, 0, 4), field(2, 0, 1101), field(3, 2, body));
}

export function verify(bytes)
{
    const envelope = fields(bytes);
    if (envelope.get(1) !== 4) throw new Error("UNEXPECTED_PROTOCOL_VERSION");
    const body = fields(envelope.get(3));
    if (envelope.get(2) === 1101)
    {
        if (new TextDecoder().decode(body.get(1)) !== "OK" ||
            body.get(2) !== 42 || body.get(3) !== 1)
            throw new Error("UNEXPECTED_FRAME_JOIN_RESPONSE");
        console.log("FrameJoin 回包已验证：battle_id=42 seat_id=1");
        return "response";
    }
    if (envelope.get(2) === 1103)
    {
        if (body.get(1) !== 42 || body.get(2) !== 1 ||
            new TextDecoder().decode(body.get(4)) !== "OK")
            throw new Error("UNEXPECTED_FRAME_PUSH");
        console.log("FramePush 主动下发已验证：battle_id=42 generation=1");
        return "push";
    }
    throw new Error("UNEXPECTED_GATEWAY_COMMAND");
}
