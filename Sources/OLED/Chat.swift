import Foundation
import Security

/// Stores the Claude API key in the macOS Keychain.
enum KeyStore {
    private static let service = "OLED"
    private static let account = "anthropic-api-key"

    static var apiKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
            return key
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Talks to Claude so OLED can hold a real conversation.
final class ChatClient {
    private var history: [[String: String]] = []
    private let model = "claude-haiku-5-5"

    private let systemPrompt = """
    You are OLED, a voice assistant living on the user's Mac. Your name is always written OLED and \
    always pronounced letter by letter, O-L-E-D. Never describe yourself in terms of screens or televisions. \
    You speak with a calm, polite British manner, a little dry wit, and you address the user directly. \
    Everything you write is spoken aloud, so reply in plain conversational sentences: no lists, no markdown, \
    no emoji, no links. Keep replies short, usually one to three sentences, unless the user asks for more. \
    You can open apps, open websites and press keys on the Mac when the user asks with words like \
    "open", "press" or "type"; if they ask how, tell them to say for example "OLED, open Safari".
    """

    func reset() { history.removeAll() }

    func reply(to message: String, completion: @escaping (String) -> Void) {
        guard let key = KeyStore.apiKey else {
            completion("To chat with me, add your Claude API key in OLED's Settings. You can open them with Command and comma.")
            return
        }
        history.append(["role": "user", "content": message])
        if history.count > 20 { history.removeFirst(history.count - 20) }
        while let first = history.first, first["role"] != "user" { history.removeFirst() }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "system": systemPrompt,
            "messages": history
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var text: String
            var ok = false
            if error != nil {
                text = "I can't reach my brain right now. Please check your internet connection."
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                text = "Your API key wasn't accepted. Please check it in Settings."
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let content = json["content"] as? [[String: Any]] {
                text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ok = !text.isEmpty
                if text.isEmpty { text = "Sorry, I didn't quite get that." }
            } else {
                text = "Sorry, something went wrong on my end. Please try again."
            }
            DispatchQueue.main.async {
                if let self {
                    if ok {
                        self.history.append(["role": "assistant", "content": text])
                    } else if !self.history.isEmpty {
                        self.history.removeLast()
                    }
                }
                completion(text)
            }
        }.resume()
    }
}
