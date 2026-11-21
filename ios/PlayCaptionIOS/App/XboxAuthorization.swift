import Foundation
import Combine
import Security

struct XboxConsole: Identifiable, Hashable {
    let id: String
    let name: String
    let powerState: String
}

struct MicrosoftDeviceCode {
    let userCode: String
    let verificationURL: String
    let deviceCode: String
    let interval: Int
    let expiry: Date
}

struct XboxStreamingAccess {
    let token: String
    let baseURL: String
    let expires: Date
}

enum XboxError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let s) = self { return s }
        return "Neznámá chyba Xboxu"
    }
}

/// Tokeny zůstávají pouze na zařízení, nikdy se neposílají do GitHub logu.
private enum SecureTokenStore {
    private static let account = "microsoft_refresh"
    private static let service = "cz.caseycz.playcaption.ios"

    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var data: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess,
              let d = data as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func put(_ token: String) {
        let search: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(search as CFDictionary)
        var attributes = search
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clear() {
        let search: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(search as CFDictionary)
    }
}

@MainActor
final class XboxAuthorization: ObservableObject {
    // Stejný veřejný OAuth client ID jako v referenční Android implementaci.
    // Před veřejným vydáním musí být nahrazen vlastním registrovaným Microsoft App ID.
    private let clientID = "1f907974-e22b-4810-a9de-d9647380c97e"
    private let scope = "xboxlive.signin openid profile offline_access"
    @Published private(set) var signedIn = SecureTokenStore.get() != nil
    @Published private(set) var status = "Nepřihlášeno"
    @Published private(set) var currentCode: MicrosoftDeviceCode?
    @Published private(set) var consoles: [XboxConsole] = []

    private var cachedAccess: (token: String, expires: Date)?
    private var cachedStreaming: XboxStreamingAccess?
    private var cancelled = false

    func signOut() {
        cancelled = true
        SecureTokenStore.clear()
        cachedAccess = nil
        cachedStreaming = nil
        currentCode = nil
        consoles = []
        signedIn = false
        status = "Odhlášeno"
    }

    private func encode(_ parameters: [String: String]) -> Data {
        parameters.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    func request(_ address: String,
                 method: String = "GET",
                 json: [String: Any]? = nil,
                 form: [String: String]? = nil,
                 headers: [String: String] = [:]) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw XboxError.message("Neplatná URL Xboxu") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 35
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form {
            request.httpBody = encode(form)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(status) else {
            let description = (dict["error_description"] as? String) ??
                              (dict["error"] as? String) ??
                              ((dict["errorDetails"] as? [String: Any])?["message"] as? String) ??
                              "HTTP \(status)"
            throw XboxError.message("Xbox/Microsoft: \(description)")
        }
        return dict
    }

    func beginLogin() async {
        cancelled = false
        status = "Získávám přihlašovací kód…"
        do {
            let response = try await request(
                "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode",
                method: "POST", form: ["client_id": clientID, "scope": scope])
            guard let userCode = response["user_code"] as? String,
                  let deviceCode = response["device_code"] as? String else {
                throw XboxError.message("Microsoft nevrátil přihlašovací kód")
            }
            let code = MicrosoftDeviceCode(
                userCode: userCode,
                verificationURL: response["verification_uri"] as? String ?? "https://www.microsoft.com/link",
                deviceCode: deviceCode,
                interval: max(5, response["interval"] as? Int ?? 5),
                expiry: Date().addingTimeInterval(TimeInterval(response["expires_in"] as? Int ?? 900)))
            currentCode = code
            status = "Zadej kód na stránce Microsoftu"
            var interval = code.interval
            while !cancelled && Date() < code.expiry {
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if cancelled { return }
                let result = try await tokenResponse([
                    "client_id": clientID,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": code.deviceCode
                ])
                if let access = result["access_token"] as? String {
                    saveTokens(result)
                    cachedAccess = (access, Date().addingTimeInterval(TimeInterval(result["expires_in"] as? Int ?? 3600) - 60))
                    signedIn = true
                    currentCode = nil
                    status = "Přihlášeno. Načítám konzole…"
                    await refreshConsoles()
                    return
                }
                switch result["error"] as? String ?? "" {
                case "authorization_pending": break
                case "slow_down": interval += 5
                default:
                    throw XboxError.message("Microsoft přihlášení: \(result["error"] as? String ?? "neznámá chyba")")
                }
            }
            status = cancelled ? "Přihlášení zrušeno" : "Platnost přihlašovacího kódu vypršela"
        } catch {
            currentCode = nil
            status = error.localizedDescription
        }
    }

    private func tokenResponse(_ form: [String: String]) async throws -> [String: Any] {
        let url = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = encode(form)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func saveTokens(_ response: [String: Any]) {
        if let refresh = response["refresh_token"] as? String, !refresh.isEmpty {
            SecureTokenStore.put(refresh)
        }
    }

    private func microsoftToken() async throws -> String {
        if let cache = cachedAccess, cache.expires > Date() { return cache.token }
        guard let refresh = SecureTokenStore.get() else { throw XboxError.message("Nejsi přihlášen k Microsoftu") }
        let result = try await tokenResponse([
            "client_id": clientID, "grant_type": "refresh_token",
            "refresh_token": refresh, "scope": scope
        ])
        guard let token = result["access_token"] as? String else {
            throw XboxError.message("Microsoft obnovu přihlášení odmítl. Přihlas se znovu.")
        }
        saveTokens(result)
        cachedAccess = (token, Date().addingTimeInterval(TimeInterval(result["expires_in"] as? Int ?? 3600) - 60))
        return token
    }

    func transferToken() async throws -> String {
        _ = try await microsoftToken()
        guard let refresh = SecureTokenStore.get() else { throw XboxError.message("Chybí přihlášení") }
        let result = try await tokenResponse([
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh,
            "scope": "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN"
        ])
        guard let value = result["access_token"] as? String else {
            throw XboxError.message("Xbox nevrátil token pro připojení ke konzoli")
        }
        return value
    }

    func streamingAccess() async throws -> XboxStreamingAccess {
        if let access = cachedStreaming, access.expires > Date() { return access }
        let token = try await microsoftToken()
        let xbl = try await request("https://user.auth.xboxlive.com/user/authenticate",
            method: "POST",
            json: ["Properties": ["AuthMethod": "RPS", "RpsTicket": "d=\(token)", "SiteName": "user.auth.xboxlive.com"],
                   "RelyingParty": "http://auth.xboxlive.com", "TokenType": "JWT"],
            headers: ["x-xbl-contract-version": "1"])
        guard let userToken = xbl["Token"] as? String else { throw XboxError.message("Xbox Live token chybí") }
        let xsts = try await request("https://xsts.auth.xboxlive.com/xsts/authorize",
            method: "POST",
            json: ["Properties": ["SandboxId": "RETAIL", "UserTokens": [userToken]],
                   "RelyingParty": "http://gssv.xboxlive.com/", "TokenType": "JWT"],
            headers: ["x-xbl-contract-version": "1"])
        guard let xstsToken = xsts["Token"] as? String else { throw XboxError.message("Xbox XSTS token chybí") }
        let home = try await request("https://xhome.gssv-play-prod.xboxlive.com/v2/login/user",
            method: "POST", json: ["token": xstsToken, "offeringId": "xhome"],
            headers: ["x-gssv-client": "XboxComBrowser"])
        guard let gsToken = home["gsToken"] as? String,
              let offering = home["offeringSettings"] as? [String: Any],
              let regions = offering["regions"] as? [[String: Any]],
              let region = regions.first(where: { ($0["isDefault"] as? Bool) == true }) ?? regions.first,
              let baseURL = region["baseUri"] as? String else {
            throw XboxError.message("Xbox neposkytl xHome region a přístup")
        }
        let result = XboxStreamingAccess(
            token: gsToken,
            baseURL: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            expires: Date().addingTimeInterval(TimeInterval(home["durationInSeconds"] as? Int ?? 3600) - 120))
        cachedStreaming = result
        return result
    }

    func streamHeaders(_ access: XboxStreamingAccess) -> [String: String] {
        let info: [String: Any] = [
            "appInfo": ["env": ["clientAppId": "www.xbox.com", "clientAppType": "browser",
                                  "clientAppVersion": "29.9.35", "clientSdkVersion": "10.6.8",
                                  "httpEnvironment": "prod", "sdkInstallId": ""]],
            "dev": ["hw": ["make": "Microsoft", "model": "unknown", "platformType": "desktop", "sdktype": "web"],
                    "os": ["name": "android", "ver": "22631.2715", "platform": "desktop"],
                    "displayInfo": ["dimensions": ["widthInPixels": 1280, "heightInPixels": 720],
                                    "pixelDensity": ["dpiX": 1, "dpiY": 1]],
                    "browser": ["browserName": "edge", "browserVersion": "140.0.3485.66"]]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: info)) ?? Data()
        return ["Authorization": "Bearer \(access.token)",
                "X-MS-Device-Info": String(data: data, encoding: .utf8) ?? "{}",
                "X-Gssv-Client": "XboxComBrowser"]
    }

    func refreshConsoles() async {
        status = "Načítám Xbox konzole…"
        do {
            let access = try await streamingAccess()
            let data = try await request("\(access.baseURL)/v6/servers/home?mr=50",
                                         headers: streamHeaders(access))
            let items = data["results"] as? [[String: Any]] ?? []
            consoles = items.compactMap { item in
                guard let id = item["serverId"] as? String else { return nil }
                return XboxConsole(id: id,
                                  name: item["deviceName"] as? String ?? "Xbox",
                                  powerState: item["powerState"] as? String ?? "")
            }
            status = consoles.isEmpty ? "Nenalezena žádná konzole. Zkontroluj vzdálené funkce." :
                "Nalezeno konzolí: \(consoles.count)"
        } catch {
            status = error.localizedDescription
        }
    }
}
