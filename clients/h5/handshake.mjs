// 职责：使用Web Crypto封装无登录依赖的FlyWow握手和WebSocket连接。
// 边界：Client SDK；固定P-256/HKDF/HMAC；需要支持Web Crypto的安全上下文。
// 生命周期：每实例只服务一条连接；close释放CryptoKey引用，不保存登录或业务状态。
// 不负责：不加密业务数据、不自动重连、不假定Web Crypto可擦除内部密钥副本。
const ascii = new TextEncoder();

// 连接有限公开字节数组；返回新Uint8Array，不改变输入。
function join(...parts)
{
    const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
    let offset = 0;
    for (const part of parts)
    {
        out.set(part, offset);
        offset += part.length;
    }
    return out;
}

export class HandshakeClient
{
    // 注入平台Crypto接口以便Node互通验证；默认使用浏览器Crypto，不执行I/O。
    constructor(crypto = globalThis.crypto)
    {
        if (!crypto?.subtle) throw new Error("WEB_CRYPTO_UNAVAILABLE");
        this.crypto = crypto;
        this.phase = "new";
    }

    // 生成临时密钥对并返回67字节HELLO；只调用一次，异步完成前不能发送业务。
    async begin()
    {
        if (this.phase !== "new") throw new Error("HANDSHAKE_STATE");
        this.phase = "generating";
        try
        {
            const pair = await this.crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
            if (this.phase === "closed") throw new Error("HANDSHAKE_CLOSED");
            this.pair = pair;
            const pub = new Uint8Array(await this.crypto.subtle.exportKey("raw", pair.publicKey));
            if (this.phase === "closed") throw new Error("HANDSHAKE_CLOSED");
            this.hello = join(new Uint8Array([1, 1]), pub);
            this.phase = "challenge";
            return this.hello.slice();
        }
        catch (error)
        {
            this.close();
            throw error;
        }
    }

    // 校验99字节challenge并返回PROOF；异步计算期间禁止重入，失败关闭状态。
    async respond(bytes)
    {
        if (this.phase !== "challenge") throw new Error("HANDSHAKE_STATE");
        this.phase = "deriving";
        let z;
        try
        {
            if (bytes.length !== 99 || bytes[0] !== 2 || bytes[1] !== 1 || bytes[2] !== 4)
                throw new Error("HANDSHAKE_CHALLENGE");
            const s = this.crypto.subtle;
            const peer = await s.importKey("raw", bytes.slice(2, 67), { name: "ECDH", namedCurve: "P-256" }, false, []);
            z = new Uint8Array(await s.deriveBits({ name: "ECDH", public: peer }, this.pair.privateKey, 256));
            this.hash = new Uint8Array(await s.digest("SHA-256", join(this.hello, bytes)));
            const base = await s.importKey("raw", z, "HKDF", false, ["deriveKey"]);
            const key = await s.deriveKey(
                { name: "HKDF", hash: "SHA-256", salt: bytes.slice(67), info: join(ascii.encode("flywow/handshake/v1"), this.hash) },
                base, { name: "HMAC", hash: "SHA-256", length: 256 }, false, ["sign", "verify"]);
            const tag = new Uint8Array(await s.sign("HMAC", key, join(ascii.encode("client-proof"), this.hash)));
            if (this.phase === "closed") throw new Error("HANDSHAKE_CLOSED");
            this.key = key;
            this.pair = null;
            this.phase = "ready-proof";
            return join(new Uint8Array([3]), tag);
        }
        catch (error)
        {
            this.close();
            throw error;
        }
        finally
        {
            if (z) z.fill(0);
        }
    }

    // 验证服务端READY；使用Web Crypto验证接口，成功后释放密钥，仅保留ready状态。
    async complete(bytes)
    {
        if (this.phase !== "ready-proof") throw new Error("HANDSHAKE_STATE");
        this.phase = "verifying";
        try
        {
            if (bytes.length !== 33 || bytes[0] !== 4 ||
                !await this.crypto.subtle.verify("HMAC", this.key, bytes.slice(1), join(ascii.encode("server-ready"), this.hash)))
                throw new Error("HANDSHAKE_READY");
            if (this.phase === "closed") throw new Error("HANDSHAKE_CLOSED");
            this.key = null;
            this.phase = "ready";
        }
        catch (error)
        {
            this.close();
            throw error;
        }
    }

    // 显式释放本握手的引用；Web Crypto内部内存由平台管理，无I/O。
    close()
    {
        this.pair = null;
        this.key = null;
        this.phase = "closed";
    }
}

// 建立并握手后返回受控连接；调用者只提供URL和业务消息回调，不管理secret。
// Promise仅在ready后resolve；消息处理串行，业务不提前缓存，失败关闭唯一拥有的Socket。
export function connectGateway(url, { onmessage, timeoutMs = 10000 } = {})
{
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 3600000)
        return Promise.reject(new Error("HANDSHAKE_TIMEOUT_CONFIG"));
    return new Promise((resolve, reject) =>
    {
        const handshake = new HandshakeClient();
        const socket = new WebSocket(url);
        socket.binaryType = "arraybuffer";
        let chain = Promise.resolve();
        let ready = false;
        // 统一失败路径只拒绝一次Promise；握手状态关闭阻止异步结果复活。
        const fail = error =>
        {
            clearTimeout(timer);
            handshake.close();
            socket.close();
            reject(error);
        };
        const timer = setTimeout(() => fail(new Error("HANDSHAKE_TIMEOUT")), timeoutMs);
        socket.onopen = () =>
        {
            chain = chain.then(async () => socket.send(await handshake.begin())).catch(fail);
        };
        socket.onmessage = event =>
        {
            chain = chain.then(async () =>
            {
                if (handshake.phase === "closed") return;
                if (!(event.data instanceof ArrayBuffer)) throw new Error("BINARY_REQUIRED");
                const bytes = new Uint8Array(event.data);
                if (ready)
                {
                    onmessage?.(bytes);
                    return;
                }
                if (handshake.phase === "challenge") socket.send(await handshake.respond(bytes));
                else
                {
                    await handshake.complete(bytes);
                    clearTimeout(timer);
                    ready = true;
                    resolve(
                    {
                        // 原有Envelope bytes直接发送，SDK已完成握手；不泄露原始Socket。
                        send(bytes)
                        {
                            if (socket.readyState !== WebSocket.OPEN) throw new Error("GATEWAY_CLOSED");
                            socket.send(bytes);
                        },
                        // 调用方关闭连接；释放SDK状态，Socket由本对象独占。
                        close()
                        {
                            handshake.close();
                            socket.close();
                        }
                    });
                }
            }).catch(fail);
        };
        socket.onerror = () => fail(new Error("GATEWAY_SOCKET"));
        // 连接关闭后，释放握手并使尚未完成的连接Promise失败。
        socket.onclose = () =>
        {
            clearTimeout(timer);
            handshake.close();
            reject(new Error("GATEWAY_CLOSED"));
        };
    });
}
