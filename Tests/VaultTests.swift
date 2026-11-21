import XCTest
import CryptoKit
@testable import Vault

final class VaultTests: XCTestCase {
    func testTOTPMatchesRFC6238() {
        // RFC 6238 test secret "12345678901234567890", SHA1, 8 digits, T = 59s -> 94287082
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let t = TOTP("otpauth://totp/test?secret=\(secret)&digits=8")!
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 59)), "94287082")
        XCTAssertEqual(t.code(at: Date(timeIntervalSince1970: 1_111_111_109)), "07081804")
    }

    func testEnvelopeUnlocksOnlyWithRightSecrets() throws {
        let key = SymmetricKey(size: .bits256)
        let code = VaultCrypto.newRecoveryCode()
        let env = try VaultCrypto.makeEnvelope(vaultKey: key, master: "correct horse battery staple", recoveryCode: code)
        let k1 = try VaultCrypto.unwrap(env, master: "correct horse battery staple")
        XCTAssertEqual(k1.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try VaultCrypto.unwrap(env, master: "Correct horse battery staple"))
        let k2 = try VaultCrypto.unwrap(env, recoveryCode: code.lowercased())
        XCTAssertEqual(k2.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try VaultCrypto.unwrap(env, recoveryCode: VaultCrypto.newRecoveryCode()))
    }

    func testPayloadRoundTripAndTamperDetection() throws {
        let key = SymmetricKey(size: .bits256)
        var p = VaultPayload()
        p.items = [VaultItem(title: "GitHub", username: "me", password: "x-Y-1-z", urls: ["github.com"])]
        var sealed = try VaultCrypto.sealPayload(p, key: key)
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("GitHub"))
        XCTAssertEqual(try VaultCrypto.openPayload(sealed, key: key).items.first?.password, "x-Y-1-z")
        sealed[sealed.count / 2] ^= 0x01
        XCTAssertThrowsError(try VaultCrypto.openPayload(sealed, key: key))
    }

    func testDomainMatchingBlocksLookalikes() {
        XCTAssertTrue(Domain.matches(saved: "https://github.com/login", requested: "github.com"))
        XCTAssertTrue(Domain.matches(saved: "accounts.google.com", requested: "mail.google.com"))
        XCTAssertFalse(Domain.matches(saved: "github.com", requested: "github.com.evil.io"))
        XCTAssertFalse(Domain.matches(saved: "github.com", requested: "githuub.com"))
        XCTAssertFalse(Domain.matches(saved: "bank.co.uk", requested: "other.co.uk"))
    }

    func testCSVHandlesQuotesCommasAndNewlines() {
        let rows = CSV.parse("\u{FEFF}a,b,c\r\n\"x, y\",\"he said \"\"hi\"\"\",\"line1\nline2\"\n")
        XCTAssertEqual(rows, [["a", "b", "c"], ["x, y", "he said \"hi\"", "line1\nline2"]])
    }

    func testDashlaneCredentialsCSV() throws {
        let csv = "username,username2,username3,title,password,note,url,category,otpUrl\n" +
            "dave@example.com,,,GitHub,pa\"ss,,https://github.com,Work,otpauth://totp/GitHub?secret=JBSWY3DPEHPK3PXP\n"
        let r = try DashlaneImport.read(data: Data(csv.utf8), filename: "credentials.csv")
        XCTAssertEqual(r.items.count, 1)
        let it = r.items[0]
        XCTAssertEqual(it.kind, .login)
        XCTAssertEqual(it.username, "dave@example.com")
        XCTAssertEqual(it.primaryHost, "github.com")
        XCTAssertNotNil(TOTP(it.otp))
        XCTAssertEqual(it.collection, "Work")
    }

    func testDashlanePaymentsBecomeCardsAndBanks() throws {
        let csv = "type,account_name,account_holder,cc_number,code,expiration_month,expiration_year,routing_number,account_number,country,issuing_bank,note\n" +
            "payment_card,Visa Business,Dave,4111111111114021,123,04,2029,,,US,,\n" +
            "bank,Checking,Dave,,,,,021000021,000123456789,US,Chase,\n"
        let r = try DashlaneImport.read(data: Data(csv.utf8), filename: "payments.csv")
        XCTAssertEqual(r.count(.card), 1)
        XCTAssertEqual(r.count(.bank), 1)
        XCTAssertEqual(r.items.first { $0.kind == .card }?.subtitle, "Ending in 4021")
    }

    func testZipReaderInflates() throws {
        // A zip with one deflated entry "credentials.csv", built in memory with Apple's zlib.
        let zip = try XCTUnwrap(TestZip.make(name: "credentials.csv", text: "username,password,url,title\nme,secret-one,example.com,Example\n"))
        let r = try DashlaneImport.read(data: zip, filename: "export.zip")
        XCTAssertEqual(r.items.first?.password, "secret-one")
    }

    func testPasskeySignaturesVerify() throws {
        let pk = WebAuthn.newPasskey(rpID: "example.com", userName: "dave", userHandle: Data([1, 2, 3]))
        let hash = Data(SHA256.hash(data: Data("client-data".utf8)))
        let a = try WebAuthn.assert(pk, clientDataHash: hash)
        XCTAssertEqual(a.authData.prefix(32), WebAuthn.rpIDHash("example.com"))
        XCTAssertEqual(a.authData[32] & 0x05, 0x05)   // user present + verified
        let pub = try P256.Signing.PrivateKey(rawRepresentation: pk.privateKey).publicKey
        XCTAssertTrue(pub.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: a.signature), for: a.authData + hash))
        let att = try WebAuthn.attestationObject(for: pk)
        XCTAssertTrue(att.range(of: Data("none".utf8)) != nil)
        XCTAssertTrue(att.range(of: pk.credentialID) != nil)
    }

    @MainActor func testSyncMergeNewestWinsAndDeletesStick() {
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
        var a = VaultPayload(), b = VaultPayload()
        let shared = UUID(), gone = UUID()
        a.items = [VaultItem(id: shared, title: "Old", modified: t0), VaultItem(id: gone, title: "Gone", modified: t0)]
        b.items = [VaultItem(id: shared, title: "New", modified: t1), VaultItem(title: "Only B", modified: t0)]
        b.deleted = [gone.uuidString: t1]
        let m = Sync.merge(a, b)
        XCTAssertEqual(m.items.first { $0.id == shared }?.title, "New")
        XCTAssertNil(m.items.first { $0.id == gone })
        XCTAssertNotNil(m.items.first { $0.title == "Only B" })
        XCTAssertEqual(Sync.merge(b, a).items.count, m.items.count)
    }

    /// Live round trip against the Cloudflare sync service with a throwaway vault.
    @MainActor func testLiveSyncRoundTrip() async throws {
        let store = VaultStore()
        store.eraseEverything()
        _ = try store.create(master: "test-only-master-pw-1", useBiometrics: false)
        store.finishSetup()
        store.add([VaultItem(title: "Example", username: "u", password: "p-Q-7-r-S", urls: ["example.com"])])
        let sync = Sync(store: store)
        UserDefaults.standard.set(true, forKey: "syncEnabled"); sync.enabled = true
        await sync.syncNow()
        XCTAssertEqual(sync.status, "Up to date")
        let k = try XCTUnwrap(store.syncKey)
        let remote = try await Sync.getRemote(id: Sync.vaultID(k), token: Sync.token(k))
        let p = try VaultCrypto.openPayload(try XCTUnwrap(remote).payload, key: k)
        XCTAssertEqual(p.items.first?.title, "Example")
        // A wrong key cannot read it.
        let other = SymmetricKey(size: .bits256)
        let denied = try? await Sync.getRemote(id: Sync.vaultID(k), token: Sync.token(other))
        XCTAssertNil(denied ?? nil)
        UserDefaults.standard.set(false, forKey: "syncEnabled")
        store.eraseEverything()
    }

    func testLockoutAfterFiveWrongTries() {
        Lockout.reset()
        for _ in 0..<4 { Lockout.fail() }
        XCTAssertNoThrow(try Lockout.check())
        Lockout.fail()
        XCTAssertThrowsError(try Lockout.check())
        Lockout.reset()
        XCTAssertNoThrow(try Lockout.check())
    }

    func testGeneratorStrength() {
        let words = PasswordGenerator.make(.init())
        XCTAssertGreaterThanOrEqual(words.split(separator: "-").count, 5)
        XCTAssertNotEqual(PasswordGenerator.strength(words), .weak)
        var o = PasswordGenerator.Options(); o.style = .characters; o.length = 24
        let chars = PasswordGenerator.make(o)
        XCTAssertEqual(chars.count, 24)
        XCTAssertEqual(PasswordGenerator.strength("password123"), .weak)
    }
}

/// Builds a minimal one-entry ZIP (deflate) for tests.
enum TestZip {
    static func make(name: String, text: String) -> Data? {
        let raw = Data(text.utf8)
        var dst = Data(count: raw.count + 64)
        let n = dst.withUnsafeMutableBytes { d in raw.withUnsafeBytes { s in
            compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, raw.count + 64,
                                      s.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB) } }
        guard n > 0 else { return nil }
        let comp = dst.prefix(n)
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func le32(_ v: Int) -> Data { le16(v & 0xffff) + le16(v >> 16 & 0xffff) }
        let nameData = Data(name.utf8)
        var z = Data()
        let local: [Data] = [le32(0x04034B50), le16(20), le16(0), le16(8), le16(0), le16(0), le32(0),
                             le32(comp.count), le32(raw.count), le16(nameData.count), le16(0), nameData, Data(comp)]
        local.forEach { z.append($0) }
        let cd = z.count
        let central: [Data] = [le32(0x02014B50), le16(20), le16(20), le16(0), le16(8), le16(0), le16(0), le32(0),
                               le32(comp.count), le32(raw.count), le16(nameData.count), le16(0), le16(0), le16(0), le16(0),
                               le32(0), le32(0), nameData]
        central.forEach { z.append($0) }
        let cdSize = z.count - cd
        let end: [Data] = [le32(0x06054B50), le16(0), le16(0), le16(1), le16(1), le32(cdSize), le32(cd), le16(0)]
        end.forEach { z.append($0) }
        return z
    }
}

import Compression
