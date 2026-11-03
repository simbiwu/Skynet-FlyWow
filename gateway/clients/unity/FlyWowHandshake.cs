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
        private const byte ClientHelloType = 1; // 客户端首条握手消息。
        private const byte ClientProofType = 3; // 客户端证明消息。
        private const byte ServerChallengeType = 2; // 服务端挑战消息。
        private const byte ServerReadyType = 4; // 服务端证明消息。
        private const byte HandshakeVersion = 1; // 框架握手版本，独立于业务协议。
        private const int ChallengeSize = 99; // 类型、版本、公钥与随机 salt。
        private const int ProofSize = 33; // 类型与完整 HMAC-SHA256。
        private const int PublicKeyOffset = 2; // 类型和版本之后为非压缩公钥。
        private const int PublicKeySize = 65; // SEC1 非压缩 P-256 公钥。
        private const int SaltOffset = PublicKeyOffset + PublicKeySize; // challenge 公钥后的 HKDF salt 起点。

        private AsymmetricCipherKeyPair keyPair;    // 当前连接独占的临时密钥对；派生完成后释放引用。
        private readonly ECDomainParameters domain; // 固定 P-256 参数，用于校验并导入服务端公钥。
        private byte[] hello;                       // 已发出的完整 HELLO，参与 transcriptHash 摘要。
        private byte[] proofKey;                    // HKDF 派生的证明密钥；成功或失败时擦除。
        private byte[] transcriptHash;              // HELLO 与 CHALLENGE 的 SHA-256，参与双向证明。
        // 连接实例独占的握手阶段；保持原来的推进顺序。
        private enum HandshakePhase
        {
            Created, // 尚未发送 HELLO。
            AwaitingChallenge, // HELLO 已发出，等待 SERVER_CHALLENGE。
            AwaitingReady, // CLIENT_PROOF 已生成，等待 SERVER_READY。
            Ready, // 服务端证明已验证，允许业务通信。
            Closed, // 失败或主动释放后的终态。
        }
        private HandshakePhase phase;

        /// <summary>创建本连接的P-256临时密钥；执行随机生成，不进行I/O。</summary>
        public HandshakeClient()
        {
            var curve = SecNamedCurves.GetByName("secp256r1"); // BouncyCastle 的 P-256 曲线参数源。
            domain = new ECDomainParameters(curve.Curve, curve.G, curve.N, curve.H);
            var generator = new ECKeyPairGenerator(); // 仅用于创建本实例的临时 ECDH 密钥对。
            generator.Init(new ECKeyGenerationParameters(domain, new SecureRandom()));
            keyPair = generator.GenerateKeyPair();
        }

        /// <summary>返回新的67字节HELLO；只能调用一次，返回数组归调用者。</summary>
        /// <returns>调用方独占的新 HELLO 数组；内部另存副本参与 transcript。</returns>
        public byte[] Begin()
        {
            if (phase != HandshakePhase.Created) throw new InvalidOperationException("HANDSHAKE_STATE");
            hello = Join(new byte[] { ClientHelloType, HandshakeVersion }, ((ECPublicKeyParameters)keyPair.Public).Q.GetEncoded(false));
            phase = HandshakePhase.AwaitingChallenge;
            return (byte[])hello.Clone();
        }

        /// <summary>验证challenge并返回33字节PROOF；失败释放本实例，消息只读借用。</summary>
        /// <param name="challenge">transport 收到的完整 SERVER_CHALLENGE；本函数只读。</param>
        /// <returns>新分配的 CLIENT_PROOF；格式或密码校验失败时抛出异常。</returns>
        public byte[] Respond(byte[] challenge)
        {
            if (phase != HandshakePhase.AwaitingChallenge) throw new InvalidOperationException("HANDSHAKE_STATE");
            byte[] rawSharedSecret = null; // BC 输出的无符号 ECDH 整数；可能不足 32 字节。
            byte[] sharedSecret = null;   // 左侧补零后的固定 32 字节 ECDH 秘密，供 HKDF Extract 使用。
            byte[] prk = null; // Extract 产生的中间密钥；finally 与原始秘密一起擦除。
            try
            {
                if (challenge == null || challenge.Length != ChallengeSize || challenge[0] != ServerChallengeType || challenge[1] != HandshakeVersion || challenge[PublicKeyOffset] != 4)
                    throw new InvalidOperationException("HANDSHAKE_CHALLENGE");
                var point = domain.Curve.DecodePoint(Slice(challenge, PublicKeyOffset, PublicKeySize)); // 从 challenge 公钥区间解码出的服务端曲线点。
                if (point.IsInfinity || !point.IsValid()) throw new InvalidOperationException("INVALID_PUBLIC_KEY");
                var peer = new ECPublicKeyParameters(point, domain); // 绑定到固定 P-256 域的服务端公钥。
                // 先取得原始 ECDH 整数并左补零到 32 字节，避免平台默认二次散列改变协议。
                var agreement = new ECDHBasicAgreement(); // 本次连接的 ECDH 运算器，不跨调用复用。
                agreement.Init(keyPair.Private);
                rawSharedSecret = agreement.CalculateAgreement(peer).ToByteArrayUnsigned();
                sharedSecret = new byte[32];
                Buffer.BlockCopy(rawSharedSecret, 0, sharedSecret, 32 - rawSharedSecret.Length, rawSharedSecret.Length);
                using (var sha = SHA256.Create()) transcriptHash = sha.ComputeHash(Join(hello, challenge));
                // HKDF输出32字节：Extract一次、Expand一个块；不调用默认散列式ECDH API。
                prk = HmacSha256(Slice(challenge, SaltOffset, 32), sharedSecret);
                proofKey = HmacSha256(prk, Join(Encoding.ASCII.GetBytes("flywow/handshake/v1"), transcriptHash, new byte[] { 1 }));
                // 派生密钥已经足够生成并验证证明；不再持有临时私钥。
                keyPair = null;
                phase = HandshakePhase.AwaitingReady;
                return Join(new byte[] { ClientProofType }, HmacSha256(proofKey, Join(Encoding.ASCII.GetBytes("client-proof"), transcriptHash)));
            }
            catch
            {
                Dispose();
                throw;
            }
            finally
            {
                Erase(rawSharedSecret);
                Erase(sharedSecret);
                Erase(prk);
            }
        }

        /// <summary>验证33字节服务端证明；成功后Ready=true，失败释放并抛出异常。</summary>
        /// <param name="ready">transport 收到的完整 SERVER_READY；本函数校验其证明。</param>
        public void Complete(byte[] ready)
        {
            if (phase != HandshakePhase.AwaitingReady) throw new InvalidOperationException("HANDSHAKE_STATE");
            try
            {
                if (ready == null || ready.Length != ProofSize || ready[0] != ServerReadyType)
                    throw new InvalidOperationException("HANDSHAKE_READY");
                var expectedServerProof = HmacSha256(proofKey, Join(Encoding.ASCII.GetBytes("server-ready"), transcriptHash)); // 与收到证明比较的服务端 HMAC。
                int difference = 0; // 累计所有证明字节的差异，避免遇到首个不同字节便提前退出。
                for (int i = 0; i < 32; ++i) difference |= expectedServerProof[i] ^ ready[i + 1];
                if (difference != 0) throw new InvalidOperationException("HANDSHAKE_READY");
                // 双向证明均完成，擦除派生密钥后才向宿主开放业务。
                Erase(proofKey);
                proofKey = null;
                phase = HandshakePhase.Ready;
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
                return phase == HandshakePhase.Ready;
            }
        }

        /// <summary>幂等释放连接握手状态；不执行I/O，托管私钥引用交给GC。</summary>
        public void Dispose()
        {
            Erase(proofKey);
            proofKey = null;
            keyPair = null;
            phase = HandshakePhase.Closed;
        }

        /// <summary>计算HMAC-SHA256；借用输入，返回新32字节数组。</summary>
        /// <param name="secret">本次 HKDF 或握手证明使用的密钥；只在调用期间借用。</param>
        /// <param name="message">HKDF 输入，或用途前缀与 transcript 摘要的拼接字节。</param>
        /// <returns>新分配的 32 字节 HMAC，输入数组不变。</returns>
        private static byte[] HmacSha256(byte[] secret, byte[] message)
        {
            using (var mac = new HMACSHA256(secret)) return mac.ComputeHash(message);
        }

        /// <summary>复制已校验的固定区间；返回新数组，不改变输入。</summary>
        /// <param name="source">已经验证固定布局的 challenge 字节，调用期间只读。</param>
        /// <param name="start">公钥或 salt 在 challenge 中的零基字节偏移。</param>
        /// <param name="count">要复制的公钥或 salt 长度。</param>
        /// <returns>调用方独占的新数组。</returns>
        private static byte[] Slice(byte[] source, int start, int count)
        {
            var result = new byte[count]; // 新建目标区，避免修改调用者提供的 source。
            Buffer.BlockCopy(source, start, result, 0, count);
            return result;
        }

        /// <summary>按顺序连接SDK内部的有限数组；返回新字节数组，无I/O。</summary>
        /// <param name="parts">按协议顺序排列的消息头、公钥、摘要或证明片段，只读借用。</param>
        /// <returns>连接所有输入片段的新数组。</returns>
        private static byte[] Join(params byte[][] parts)
        {
            int count = 0; // 所有输入片段合并后的总字节数。
            foreach (var part in parts) count = checked(count + part.Length);
            var result = new byte[count]; // 当前拼接结果的独占目标区，不修改 parts 中的数组。
            int offset = 0; // 下一片段在 result 中的写入位置。
            foreach (var part in parts)
            {
                Buffer.BlockCopy(part, 0, result, offset, part.Length);
                offset += part.Length;
            }
            return result;
        }

        /// <summary>擦除可变敏感数组；托管运行时的内部副本不作零残留保证。</summary>
        /// <param name="bytes">本实例可擦除的秘密或中间密钥数组；空值表示尚未创建或已经释放。</param>
        private static void Erase(byte[] bytes)
        {
            if (bytes != null) Array.Clear(bytes, 0, bytes.Length);
        }
    }
}
