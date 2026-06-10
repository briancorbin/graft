import Foundation
import Security

/// base64url (RFC 7515) — base64 with `+/` → `-_` and no padding. JWTs use it.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}

/// PEM → DER for RSA private keys. GitHub App keys are PKCS#1
/// (`-----BEGIN RSA PRIVATE KEY-----`); PKCS#8 (`-----BEGIN PRIVATE KEY-----`)
/// is also handled by stripping its fixed algorithm-identifier prefix.
enum PEM {
    static func rsaDER(from pem: String) throws -> Data {
        let isPKCS8 = pem.contains("BEGIN PRIVATE KEY")
        let body = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body) else {
            throw GraftError("private key is not valid base64 PEM")
        }
        guard isPKCS8 else { return der }

        // PKCS#8 wraps the PKCS#1 RSAPrivateKey behind a 26-byte algorithm header
        // (SEQUENCE, version, rsaEncryption OID, OCTET STRING). Strip it to get the
        // PKCS#1 DER that SecKeyCreateWithData expects.
        let prefix = 26
        guard der.count > prefix else { throw GraftError("malformed PKCS#8 private key") }
        return der.subdata(in: prefix ..< der.count)
    }
}

/// Signs the short-lived RS256 JWT that authenticates as the GitHub App. Uses
/// Apple's Security framework for the RSA signing — no third-party crypto, and no
/// hand-rolled primitives.
enum AppJWT {
    /// GitHub caps App JWT lifetime at 10 minutes. We backdate `iat` 60s for clock
    /// skew and default `exp` to 8 minutes out, keeping `exp - iat` safely under 600s.
    static func sign(
        appID: Int,
        pem: String,
        now: Date = Date(),
        ttl: TimeInterval = 480
    ) throws -> String {
        let der = try PEM.rsaDER(from: pem)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw GraftError("invalid RSA private key: \(Self.message(error))")
        }

        let issued = Int(now.timeIntervalSince1970) - 60
        let expires = Int(now.timeIntervalSince1970) + Int(ttl)
        let header = #"{"alg":"RS256","typ":"JWT"}"#
        let payload = #"{"iat":\#(issued),"exp":\#(expires),"iss":\#(appID)}"#
        let signingInput = Base64URL.encode(Data(header.utf8)) + "." + Base64URL.encode(Data(payload.utf8))

        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error
        ) else {
            throw GraftError("JWT signing failed: \(Self.message(error))")
        }

        return signingInput + "." + Base64URL.encode(signature as Data)
    }

    private static func message(_ error: Unmanaged<CFError>?) -> String {
        guard let error = error?.takeRetainedValue() else { return "unknown error" }
        return CFErrorCopyDescription(error) as String? ?? "unknown error"
    }
}
