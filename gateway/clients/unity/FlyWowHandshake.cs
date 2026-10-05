// 职责：使用P-256/HKDF/HMAC实现FlyWow客户端握手，不依赖Unity场景或业务协议。
// 边界：Client SDK；输入SERVER_CHALLENGE/READY，输出HELLO/PROOF。
// 生命周期：每个实例只服务一条连接；Dispose清除可擦除的密钥数组并放弃临时私钥引用。
// 不负责：不写Socket、不建立登录、不开线程、不加密业务帧；BC私钥对象由托管GC回收。
using System;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Asn1.Sec;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;

namespace FlyWow.Gateway
{
    public sealed class HandshakeClient : IDisposable
    {
        private AsymmetricCipherKeyPair      pair      ; // 独占临时密钥对，不写日志或网络。
        private readonly ECDomainParameters  domain    ; // 固定P-256公开参数。
        private byte[]                     hello; // 公开CLIENT_HELLO，用于精确transcript。
        private byte[]                     key; // 派生HMAC密钥；握手完成/失败后擦除。
        private byte[]                     transcript; // 公开消息摘要。
        private int                          phase     ; // 0=新建，1=等待challenge，2=等待ready，3=ready，4=关闭。

        /// <summary>创建本连接的P-256临时密钥；执行随机生成，不进行I/O。</summary>
        public HandshakeClient()
        {
            var curve = SecNamedCurves.GetByName("secp256r1");
            domain = new ECDomainParameters(curve.Curve, curve.G, curve.N, curve.H);
            var generator = new ECKeyPairGenerator();
            generator.Init(new ECKeyGenerationParameters(domain, new SecureRandom()));
            pair = generator.GenerateKeyPair();
        }

        /// <summary>返回新的67字节HELLO；只能调用一次，返回数组归调用者。</summary>
        public byte[] Begin()
        {
            if (phase != 0) throw new InvalidOperationException("HANDSHAKE_STATE");
            hello = Join(new byte[] { 1, 1 }, ((ECPublicKeyParameters)pair.Public).Q.GetEncoded(false));
            phase = 1;
            return (byte[])hello.Clone();
        }

        /// <summary>验证challenge并返回33字节PROOF；失败释放本实例，消息只读借用。</summary>
        public byte[] Respond(byte[] challenge)
        {
            if (phase != 1) throw new InvalidOperationException("HANDSHAKE_STATE");
            byte[] raw = null, z = null, prk = null;
            try
            {
                if (challenge == null || challenge.Length != 99 || challenge[0] != 2 || challenge[1] != 1 || challenge[2] != 4)
                    throw new InvalidOperationException("HANDSHAKE_CHALLENGE");
                var point = domain.Curve.DecodePoint(Slice(challenge, 2, 65));
                if (point.IsInfinity || !point.IsValid()) throw new InvalidOperationException("INVALID_PUBLIC_KEY");
                var peer = new ECPublicKeyParameters(point, domain);
                var agreement = new ECDHBasicAgreement();
                agreement.Init(pair.Private);
                raw = agreement.CalculateAgreement(peer).ToByteArrayUnsigned();
                z = new byte[32];
                Buffer.BlockCopy(raw, 0, z, 32 - raw.Length, raw.Length);
                using (var sha = SHA256.Create()) transcript = sha.ComputeHash(Join(hello, challenge));
                // HKDF输出32字节：Extract一次、Expand一个块；不调用默认散列式ECDH API。
                prk = Mac(Slice(challenge, 67, 32), z);
                key = Mac(prk, Join(Encoding.ASCII.GetBytes("flywow/handshake/v1"), transcript, new byte[] { 1 }));
                pair = null;
                phase = 2;
                return Join(new byte[] { 3 }, Mac(key, Join(Encoding.ASCII.GetBytes("client-proof"), transcript)));
            }
            catch
            {
                Dispose();
                throw;
            }
            finally
            {
                Erase(raw); Erase(z); Erase(prk);
            }
        }

        /// <summary>验证33字节服务端证明；成功后Ready=true，失败释放并抛出异常。</summary>
        public void Complete(byte[] ready)
        {
            if (phase != 2) throw new InvalidOperationException("HANDSHAKE_STATE");
            try
            {
                if (ready == null || ready.Length != 33 || ready[0] != 4)
                    throw new InvalidOperationException("HANDSHAKE_READY");
                var expected = Mac(key, Join(Encoding.ASCII.GetBytes("server-ready"), transcript));
                int difference = 0;
                for (int i = 0; i < 32; ++i) difference |= expected[i] ^ ready[i + 1];
                if (difference != 0) throw new InvalidOperationException("HANDSHAKE_READY");
                Erase(key); key = null;
                phase = 3;
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        /// <summary>只报告本SDK握手是否完成，不代表账号授权。</summary>
        public bool Ready
        {
            // 读取本实例阶段，无I/O或状态变化。
            get
            {
                return phase == 3;
            }
        }

        /// <summary>幂等释放连接握手状态；不执行I/O，托管私钥引用交给GC。</summary>
        public void Dispose()
        {
            Erase(key); key = null;
            pair = null;
            phase = 4;
        }

        /// <summary>计算HMAC-SHA256；借用输入，返回新32字节数组。</summary>
        private static byte[] Mac(byte[] secret, byte[] message)
        {
            using (var mac = new HMACSHA256(secret)) return mac.ComputeHash(message);
        }

        /// <summary>复制已校验的固定区间；返回新数组，不改变输入。</summary>
        private static byte[] Slice(byte[] source, int start, int count)
        {
            var result = new byte[count];
            Buffer.BlockCopy(source, start, result, 0, count);
            return result;
        }

        /// <summary>按顺序连接SDK内部的有限数组；返回新字节数组，无I/O。</summary>
        private static byte[] Join(params byte[][] parts)
        {
            int count = 0;
            foreach (var part in parts) count = checked(count + part.Length);
            var result = new byte[count];
            int offset = 0;
            foreach (var part in parts)
            {
                Buffer.BlockCopy(part, 0, result, offset, part.Length);
                offset += part.Length;
            }
            return result;
        }

        /// <summary>擦除可变敏感数组；托管运行时的内部副本不作零残留保证。</summary>
        private static void Erase(byte[] bytes)
        {
            if (bytes != null) Array.Clear(bytes, 0, bytes.Length);
        }
    }
}
