//! Cryptography.

const std = @import("std.sig");

pub const timing_safe = @import("crypto/timing_safe.sig");

/// Authenticated Encryption with Associated Data
pub const aead = struct {
    pub const aegis = struct {
        const variants = @import("crypto/aegis.sig");

        pub const Aegis128X4 = variants.Aegis128X4;
        pub const Aegis128X2 = variants.Aegis128X2;
        pub const Aegis128L = variants.Aegis128L;

        pub const Aegis256X4 = variants.Aegis256X4;
        pub const Aegis256X2 = variants.Aegis256X2;
        pub const Aegis256 = variants.Aegis256;

        pub const Aegis128X4_256 = variants.Aegis128X4_256;
        pub const Aegis128X2_256 = variants.Aegis128X2_256;
        pub const Aegis128L_256 = variants.Aegis128L_256;

        pub const Aegis256X4_256 = variants.Aegis256X4_256;
        pub const Aegis256X2_256 = variants.Aegis256X2_256;
        pub const Aegis256_256 = variants.Aegis256_256;
    };

    pub const aes_gcm = struct {
        pub const Aes128Gcm = @import("crypto/aes_gcm.sig").Aes128Gcm;
        pub const Aes256Gcm = @import("crypto/aes_gcm.sig").Aes256Gcm;
    };

    pub const aes_gcm_siv = struct {
        pub const Aes128GcmSiv = @import("crypto/aes_gcm_siv.sig").Aes128GcmSiv;
        pub const Aes256GcmSiv = @import("crypto/aes_gcm_siv.sig").Aes256GcmSiv;
    };

    pub const aes_siv = struct {
        pub const Aes128Siv = @import("crypto/aes_siv.sig").Aes128Siv;
        pub const Aes256Siv = @import("crypto/aes_siv.sig").Aes256Siv;
    };

    pub const aes_ocb = struct {
        pub const Aes128Ocb = @import("crypto/aes_ocb.sig").Aes128Ocb;
        pub const Aes256Ocb = @import("crypto/aes_ocb.sig").Aes256Ocb;
    };

    pub const aes_ccm = @import("crypto/aes_ccm.sig");

    pub const ascon = struct {
        pub const AsconAead128 = @import("crypto/ascon.sig").AsconAead128;
    };

    pub const chacha_poly = struct {
        pub const ChaCha20Poly1305 = @import("crypto/chacha20.sig").ChaCha20Poly1305;
        pub const ChaCha12Poly1305 = @import("crypto/chacha20.sig").ChaCha12Poly1305;
        pub const ChaCha8Poly1305 = @import("crypto/chacha20.sig").ChaCha8Poly1305;
        pub const XChaCha20Poly1305 = @import("crypto/chacha20.sig").XChaCha20Poly1305;
        pub const XChaCha12Poly1305 = @import("crypto/chacha20.sig").XChaCha12Poly1305;
        pub const XChaCha8Poly1305 = @import("crypto/chacha20.sig").XChaCha8Poly1305;
    };

    pub const isap = @import("crypto/isap.sig");

    pub const salsa_poly = struct {
        pub const XSalsa20Poly1305 = @import("crypto/salsa20.sig").XSalsa20Poly1305;
    };
};

/// Authentication (MAC) functions.
pub const auth = struct {
    pub const hmac = @import("crypto/hmac.sig");
    pub const siphash = @import("crypto/siphash.sig");
    pub const aegis = struct {
        const variants = @import("crypto/aegis.sig");
        pub const Aegis128X4Mac = variants.Aegis128X4Mac;
        pub const Aegis128X2Mac = variants.Aegis128X2Mac;
        pub const Aegis128LMac = variants.Aegis128LMac;

        pub const Aegis256X4Mac = variants.Aegis256X4Mac;
        pub const Aegis256X2Mac = variants.Aegis256X2Mac;
        pub const Aegis256Mac = variants.Aegis256Mac;

        pub const Aegis128X4Mac_128 = variants.Aegis128X4Mac_128;
        pub const Aegis128X2Mac_128 = variants.Aegis128X2Mac_128;
        pub const Aegis128LMac_128 = variants.Aegis128LMac_128;

        pub const Aegis256X4Mac_128 = variants.Aegis256X4Mac_128;
        pub const Aegis256X2Mac_128 = variants.Aegis256X2Mac_128;
        pub const Aegis256Mac_128 = variants.Aegis256Mac_128;
    };
    pub const cmac = @import("crypto/cmac.sig");
    pub const cbc_mac = @import("crypto/cbc_mac.sig");
};

/// Core functions, that should rarely be used directly by applications.
pub const core = struct {
    pub const aes = @import("crypto/aes.sig");
    pub const keccak = @import("crypto/keccak_p.sig");

    pub const Ascon = @import("crypto/ascon.sig").State;

    /// Modes are generic compositions to construct encryption/decryption functions from block ciphers and permutations.
    ///
    /// These modes are designed to be building blocks for higher-level constructions, and should generally not be used directly by applications, as they may not provide the expected properties and security guarantees.
    ///
    /// Most applications may want to use AEADs instead.
    pub const modes = @import("crypto/modes.sig");
};

/// Diffie-Hellman key exchange functions.
pub const dh = struct {
    pub const X25519 = @import("crypto/25519/x25519.sig").X25519;
};

/// Key Encapsulation Mechanisms.
pub const kem = struct {
    pub const hybrid = @import("crypto/hybrid_kem.sig");
    pub const kyber_d00 = @import("crypto/ml_kem.sig").d00;
    pub const ml_kem = @import("crypto/ml_kem.sig").nist;
};

/// Elliptic-curve arithmetic.
pub const ecc = struct {
    pub const Curve25519 = @import("crypto/25519/curve25519.sig").Curve25519;
    pub const Edwards25519 = @import("crypto/25519/edwards25519.sig").Edwards25519;
    pub const P256 = @import("crypto/pcurves/p256.sig").P256;
    pub const P384 = @import("crypto/pcurves/p384.sig").P384;
    pub const Ristretto255 = @import("crypto/25519/ristretto255.sig").Ristretto255;
    pub const Secp256k1 = @import("crypto/pcurves/secp256k1.sig").Secp256k1;
};

/// Hash functions.
pub const hash = struct {
    pub const ascon = struct {
        const variants = @import("crypto/ascon.sig");
        pub const AsconHash256 = variants.AsconHash256;
        pub const AsconXof128 = variants.AsconXof128;
        pub const AsconCxof128 = variants.AsconCxof128;
    };
    pub const blake2 = @import("crypto/blake2.sig");
    pub const Blake3 = @import("crypto/blake3.sig").Blake3;
    pub const Md5 = @import("crypto/md5.sig").Md5;
    pub const Sha1 = @import("crypto/Sha1.sig");
    pub const sha2 = @import("crypto/sha2.sig");
    pub const sha3 = @import("crypto/sha3.sig");
    pub const composition = @import("crypto/hash_composition.sig");
};

/// Key derivation functions.
pub const kdf = struct {
    pub const hkdf = @import("crypto/hkdf.sig");
};

/// MAC functions requiring single-use secret keys.
pub const onetimeauth = struct {
    pub const Ghash = @import("crypto/ghash_polyval.sig").Ghash;
    pub const Polyval = @import("crypto/ghash_polyval.sig").Polyval;
    pub const Poly1305 = @import("crypto/poly1305.sig").Poly1305;
};

/// A password hashing function derives a uniform key from low-entropy input material such as passwords.
/// It is intentionally slow or expensive.
///
/// With the standard definition of a key derivation function, if a key space is small, an exhaustive search may be practical.
/// Password hashing functions make exhaustive searches way slower or way more expensive, even when implemented on GPUs and ASICs, by using different, optionally combined strategies:
///
/// - Requiring a lot of computation cycles to complete
/// - Requiring a lot of memory to complete
/// - Requiring multiple CPU cores to complete
/// - Requiring cache-local data to complete in reasonable time
/// - Requiring large static tables
/// - Avoiding precomputations and time/memory tradeoffs
/// - Requiring multi-party computations
/// - Combining the input material with random per-entry data (salts), application-specific contexts and keys
///
/// Password hashing functions must be used whenever sensitive data has to be directly derived from a password.
pub const pwhash = struct {
    pub const Encoding = enum {
        phc,
        crypt,
    };

    pub const Error = HasherError || error{AllocatorRequired};
    pub const HasherError = KdfError || phc_format.Error;
    pub const KdfError = errors.Error || std.mem.Allocator.Error || std.Thread.SpawnError || std.Io.Cancelable;

    pub const argon2 = @import("crypto/argon2.sig");
    pub const bcrypt = @import("crypto/bcrypt.sig");
    pub const scrypt = @import("crypto/scrypt.sig");
    pub const pbkdf2 = @import("crypto/pbkdf2.sig").pbkdf2;

    pub const phc_format = @import("crypto/phc_encoding.sig");
};

/// Digital signature functions.
pub const sign = struct {
    pub const Ed25519 = @import("crypto/25519/ed25519.sig").Ed25519;
    pub const ecdsa = @import("crypto/ecdsa.sig");
    pub const mldsa = @import("crypto/ml_dsa.sig");
};

/// Stream ciphers. These do not provide any kind of authentication.
/// Most applications should be using AEAD constructions instead of stream ciphers directly.
pub const stream = struct {
    pub const chacha = struct {
        pub const ChaCha20IETF = @import("crypto/chacha20.sig").ChaCha20IETF;
        pub const ChaCha12IETF = @import("crypto/chacha20.sig").ChaCha12IETF;
        pub const ChaCha8IETF = @import("crypto/chacha20.sig").ChaCha8IETF;
        pub const ChaCha20With64BitNonce = @import("crypto/chacha20.sig").ChaCha20With64BitNonce;
        pub const ChaCha12With64BitNonce = @import("crypto/chacha20.sig").ChaCha12With64BitNonce;
        pub const ChaCha8With64BitNonce = @import("crypto/chacha20.sig").ChaCha8With64BitNonce;
        pub const XChaCha20IETF = @import("crypto/chacha20.sig").XChaCha20IETF;
        pub const XChaCha12IETF = @import("crypto/chacha20.sig").XChaCha12IETF;
        pub const XChaCha8IETF = @import("crypto/chacha20.sig").XChaCha8IETF;
    };

    pub const salsa = struct {
        pub const Salsa = @import("crypto/salsa20.sig").Salsa;
        pub const XSalsa = @import("crypto/salsa20.sig").XSalsa;
        pub const Salsa20 = @import("crypto/salsa20.sig").Salsa20;
        pub const XSalsa20 = @import("crypto/salsa20.sig").XSalsa20;
    };
};

pub const nacl = struct {
    const salsa20 = @import("crypto/salsa20.sig");

    pub const Box = salsa20.Box;
    pub const SecretBox = salsa20.SecretBox;
    pub const SealedBox = salsa20.SealedBox;
};

/// Finite-field arithmetic.
pub const ff = @import("crypto/ff.sig");

/// Encoding and decoding
pub const codecs = @import("crypto/codecs.sig");

pub const errors = @import("crypto/errors.sig");

pub const tls = @import("crypto/tls.sig");
pub const Certificate = @import("crypto/Certificate.sig");

/// Side-channels mitigations.
pub const SideChannelsMitigations = enum {
    /// No additional side-channel mitigations are applied.
    /// This is the fastest mode.
    none,
    /// The `basic` mode protects against most practical attacks, provided that the
    /// application or implements proper defenses against brute-force attacks.
    /// It offers a good balance between performance and security.
    basic,
    /// The `medium` mode offers increased resilience against side-channel attacks,
    /// making most attacks unpractical even on shared/low latency environements.
    /// This is the default mode.
    medium,
    /// The `full` mode offers the highest level of protection against side-channel attacks.
    /// Note that this doesn't cover all possible attacks (especially power analysis or
    /// thread-local attacks such as cachebleed), and that the performance impact is significant.
    full,
};

pub const default_side_channels_mitigations = .medium;

test {
    _ = aead.ascon.AsconAead128;

    _ = aead.aegis.Aegis128L;
    _ = aead.aegis.Aegis256;

    _ = aead.aes_gcm.Aes128Gcm;
    _ = aead.aes_gcm.Aes256Gcm;

    _ = aead.aes_gcm_siv.Aes128GcmSiv;
    _ = aead.aes_gcm_siv.Aes256GcmSiv;

    _ = aead.aes_siv.Aes128Siv;
    _ = aead.aes_siv.Aes256Siv;

    _ = aead.aes_ocb.Aes128Ocb;
    _ = aead.aes_ocb.Aes256Ocb;

    _ = aead.aes_ccm;

    _ = aead.chacha_poly.ChaCha20Poly1305;
    _ = aead.chacha_poly.ChaCha12Poly1305;
    _ = aead.chacha_poly.ChaCha8Poly1305;
    _ = aead.chacha_poly.XChaCha20Poly1305;
    _ = aead.chacha_poly.XChaCha12Poly1305;
    _ = aead.chacha_poly.XChaCha8Poly1305;

    _ = aead.isap;
    _ = aead.salsa_poly.XSalsa20Poly1305;

    _ = auth.hmac;
    _ = auth.cmac;
    _ = auth.cbc_mac;
    _ = auth.siphash;

    _ = core.aes;
    _ = core.Ascon;
    _ = core.modes;

    _ = dh.X25519;

    _ = kem.kyber_d00;
    _ = kem.hybrid;
    _ = kem.kyber_d00;
    _ = kem.ml_kem;

    _ = ecc.Curve25519;
    _ = ecc.Edwards25519;
    _ = ecc.P256;
    _ = ecc.P384;
    _ = ecc.Ristretto255;
    _ = ecc.Secp256k1;

    _ = hash.ascon;
    _ = hash.blake2;
    _ = hash.Blake3;
    _ = hash.Md5;
    _ = hash.Sha1;
    _ = hash.sha2;
    _ = hash.sha3;
    _ = hash.composition;

    _ = kdf.hkdf;

    _ = onetimeauth.Ghash;
    _ = onetimeauth.Poly1305;

    _ = pwhash.Encoding;

    _ = pwhash.Error;
    _ = pwhash.HasherError;
    _ = pwhash.KdfError;

    _ = pwhash.argon2;
    _ = pwhash.bcrypt;
    _ = pwhash.scrypt;
    _ = pwhash.pbkdf2;

    _ = pwhash.phc_format;

    _ = sign.Ed25519;
    _ = sign.ecdsa;
    _ = sign.mldsa;

    _ = stream.chacha.ChaCha20IETF;
    _ = stream.chacha.ChaCha12IETF;
    _ = stream.chacha.ChaCha8IETF;
    _ = stream.chacha.ChaCha20With64BitNonce;
    _ = stream.chacha.ChaCha12With64BitNonce;
    _ = stream.chacha.ChaCha8With64BitNonce;
    _ = stream.chacha.XChaCha20IETF;
    _ = stream.chacha.XChaCha12IETF;
    _ = stream.chacha.XChaCha8IETF;

    _ = stream.salsa.Salsa20;
    _ = stream.salsa.XSalsa20;

    _ = nacl.Box;
    _ = nacl.SecretBox;
    _ = nacl.SealedBox;

    _ = secureZero;
    _ = timing_safe;
    _ = ff;
    _ = errors;
    _ = tls;
    _ = tls.Client;
    _ = Certificate;
    _ = codecs;
}

test "issue #4532: no index out of bounds" {
    const types = [_]type{
        hash.Md5,
        hash.Sha1,
        hash.sha2.Sha224,
        hash.sha2.Sha256,
        hash.sha2.Sha384,
        hash.sha2.Sha512,
        hash.sha3.Sha3_224,
        hash.sha3.Sha3_256,
        hash.sha3.Sha3_384,
        hash.sha3.Sha3_512,
        hash.blake2.Blake2s128,
        hash.blake2.Blake2s224,
        hash.blake2.Blake2s256,
        hash.blake2.Blake2b128,
        hash.blake2.Blake2b256,
        hash.blake2.Blake2b384,
        hash.blake2.Blake2b512,
    };

    inline for (types) |Hasher| {
        var block: [Hasher.block_length]u8 = @splat('#');
        var out1: [Hasher.digest_length]u8 = undefined;
        var out2: [Hasher.digest_length]u8 = undefined;
        const h0 = Hasher.init(.{});
        var h = h0;
        h.update(block[0..]);
        h.final(&out1);
        h = h0;
        h.update(block[0..1]);
        h.update(block[1..]);
        h.final(&out2);

        try std.testing.expectEqual(out1, out2);
    }
}

/// Sets a slice to zeroes.
/// Prevents the store from being optimized out.
pub fn secureZero(comptime T: type, s: []volatile T) void {
    @memset(s, std.mem.zeroes(T));
}

test secureZero {
    var a: [8]u8 = @splat(0xFE);
    var b: [8]u8 = @splat(0xFE);

    @memset(&a, 0);
    secureZero(u8, &b);

    try std.testing.expectEqualSlices(u8, &a, &b);
}
