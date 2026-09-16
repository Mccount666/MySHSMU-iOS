import Foundation

/// Endpoints and identifiers, ported from the Android build
/// (`service/ShsmuService.kt`, `MainViewModel.kt`, `widget/CurriculumWidget.kt`).
enum AppConfig {
    /// WebVPN gateway that fronts the teaching-affairs system.
    static let webVPNHost = "webvpn2.shsmu.edu.cn"

    /// Encrypted host tokens the gateway uses to pick an upstream service.
    private static let casToken = "77726476706e69737468656265737421f1e25594757e7b586d059ce29d51367b0014"
    private static let homeToken = "77726476706e69737468656265737421fae05288327e7b586d059ce29d51367b9aac"
    private static let jfzxToken = "77726476706e69737468656265737421faf15b8469236043731dc7a99c406d362c"

    private static let webVPNRoot = "https://\(webVPNHost)"

    /// CAS login page. The `service` parameter is already percent-encoded in the
    /// source constant, so the string is used verbatim rather than rebuilt.
    static let loginURL = URL(
        string: "\(webVPNRoot)/https/\(casToken)/cas/login?service=https%3a%2f%2fjwstu.shsmu.edu.cn%2fLogin%2fauthLogin"
    )!

    /// Root of the CAS application, used for the captcha fallback path.
    static let casBaseURL = URL(string: "\(webVPNRoot)/https/\(casToken)/cas")!

    /// Teaching-affairs home application (curriculum, scores).
    static let homeBaseURL = URL(string: "\(webVPNRoot)/https/\(homeToken)")!

    /// Classroom-booking application.
    static let jfzxBaseURL = URL(string: "\(webVPNRoot)/https/\(jfzxToken)")!

    /// Marker the gateway uses to route to the upstream teaching-affairs host.
    /// It travels as a bare query parameter with no value.
    static let upstreamMarker = "vpn-12-o2-jwstu.shsmu.edu.cn"

    static let updateJSONURL = URL(string: "https://myshsmu.reqwey.xyz/api/update.json")!
    static let updateHost = "https://myshsmu.reqwey.xyz"

    /// App Group shared with the widget extension. When the group is not
    /// provisioned the app transparently falls back to standard defaults.
    static let appGroupID = "group.xyz.reqwey.myshsmu"

    /// RSA public key protecting the login password. Shipped as an asset named
    /// `pubkey.pem` on Android; inlined here so no bundle resource is required.
    static let loginPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCMtYFTNc9Ejwflgou1owV7e5g0
    3evAZz4LexXRf7oWHLV7Pd7Hfso4OBdzk/VTGI408/ZMGxh2oOg+dVlvpdfawzFF
    qx8CF7xI1aQldwGPGzVukTb+OK2d7WYoQggfZNLmz1MOAynwpZm3wo5lgWNNEhJZ
    p7yzMtv7s8knxOKoLwIDAQAB
    -----END PUBLIC KEY-----
    """

    /// Version code the update channel is compared against, matching the
    /// Android `versionCode` so both platforms read the same `update.json`.
    static var currentVersionCode: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    static var currentVersionName: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// Joins a base URL and a path without producing a doubled slash. The Kotlin
    /// source concatenates `"$HOME_URL/Home/…"` onto a base that already ends in
    /// `/`; the gateway tolerates the extra slash but the single-slash form is
    /// the canonical one.
    static func url(_ base: URL, _ path: String) -> URL {
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        let tail = path.hasPrefix("/") ? path : "/" + path
        return URL(string: root + tail) ?? base
    }
}
