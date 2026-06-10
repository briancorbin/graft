import Foundation
import Security
import Testing
@testable import GraftCore

@Suite("App JWT signing")
struct AppJWTTests {
    /// Generate a throwaway RSA key, sign a JWT, and verify the signature with the
    /// matching public key — proves the full PEM → SecKey → RS256 path end-to-end,
    /// no network or real App needed.
    @Test("signs an RS256 JWT the matching public key verifies")
    func signAndVerify() throws {
        let (pem, publicKey) = try Self.makeRSAKeyPair()

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let jwt = try AppJWT.sign(appID: 424242, pem: pem, now: when, ttl: 480)

        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        // Signature verifies.
        let signingInput = Data((parts[0] + "." + parts[1]).utf8)
        let signature = try #require(Base64URL.decode(parts[2]))
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signingInput as CFData,
            signature as CFData,
            &error
        )
        #expect(verified)

        // Header is RS256/JWT.
        let header = try #require(Base64URL.decode(parts[0]))
        let headerJSON = try #require(try JSONSerialization.jsonObject(with: header) as? [String: String])
        #expect(headerJSON["alg"] == "RS256")
        #expect(headerJSON["typ"] == "JWT")

        // Claims: iss is the app id, iat backdated 60s, exp - iat under GitHub's 600s cap.
        let payload = try #require(Base64URL.decode(parts[1]))
        let claims = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Int])
        #expect(claims["iss"] == 424242)
        #expect(claims["iat"] == Int(when.timeIntervalSince1970) - 60)
        let lifetime = try #require(claims["exp"]).advanced(by: -(try #require(claims["iat"])))
        #expect(lifetime <= 600)
    }

    @Test("rejects a non-PEM string")
    func rejectsGarbage() {
        #expect(throws: GraftError.self) {
            _ = try AppJWT.sign(appID: 1, pem: "not a key")
        }
    }

    @Test("base64url round-trips and is padding-free")
    func base64url() {
        let data = Data([0xFB, 0xEF, 0xFF, 0x00, 0x10])
        let encoded = Base64URL.encode(data)
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(Base64URL.decode(encoded) == data)
    }

    /// Returns a PKCS#1 PEM (GitHub's format) and the matching public SecKey.
    private static func makeRSAKeyPair() throws -> (pem: String, publicKey: SecKey) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw GraftError("could not generate test key")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw GraftError("could not derive public key")
        }
        // SecKeyCopyExternalRepresentation gives PKCS#1 DER for RSA private keys.
        guard let der = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw GraftError("could not export test key")
        }
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n"
            + der.base64EncodedString()
            + "\n-----END RSA PRIVATE KEY-----"
        return (pem, publicKey)
    }
}
