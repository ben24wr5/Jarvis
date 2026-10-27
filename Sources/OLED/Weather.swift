import Foundation

/// Live weather from Open-Meteo (free, no account or key needed).
enum Weather {
    static let homeTownKey = "homeTown"

    static var homeTown: String? {
        get {
            let t = UserDefaults.standard.string(forKey: homeTownKey)?.trimmingCharacters(in: .whitespaces)
            return (t?.isEmpty ?? true) ? nil : t
        }
        set { UserDefaults.standard.set(newValue, forKey: homeTownKey) }
    }

    private static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear skies"
        case 1: return "mostly clear skies"
        case 2: return "partly cloudy skies"
        case 3: return "overcast skies"
        case 45, 48: return "fog"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rain"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71: return "light snow"
        case 73: return "snow"
        case 75: return "heavy snow"
        case 77: return "snow grains"
        case 80, 81: return "rain showers"
        case 82: return "heavy rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorms"
        case 96, 99: return "thunderstorms with hail"
        default: return "mixed weather"
        }
    }

    private static func getJSON(_ url: URL, completion: @escaping ([String: Any]?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            completion(json)
        }.resume()
    }

    /// Speaks-ready weather report for a place, today or tomorrow.
    static func report(for place: String, tomorrow: Bool, completion: @escaping (String) -> Void) {
        let finish: (String) -> Void = { text in DispatchQueue.main.async { completion(text) } }
        var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geo.queryItems = [URLQueryItem(name: "name", value: place), URLQueryItem(name: "count", value: "1"),
                          URLQueryItem(name: "language", value: "en")]
        getJSON(geo.url!) { json in
            guard let results = json?["results"] as? [[String: Any]], let first = results.first,
                  let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else {
                finish("I couldn't find a place called \(place).")
                return
            }
            let name = first["name"] as? String ?? place
            var f = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            f.queryItems = [
                URLQueryItem(name: "latitude", value: String(lat)),
                URLQueryItem(name: "longitude", value: String(lon)),
                URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
                URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
                URLQueryItem(name: "timezone", value: "auto"),
                URLQueryItem(name: "wind_speed_unit", value: "mph"),
                URLQueryItem(name: "forecast_days", value: "2")
            ]
            getJSON(f.url!) { json in
                guard let json, let daily = json["daily"] as? [String: Any],
                      let highs = daily["temperature_2m_max"] as? [Double],
                      let lows = daily["temperature_2m_min"] as? [Double],
                      let codes = daily["weather_code"] as? [Int] else {
                    finish("I couldn't get the weather right now. Please try again in a moment.")
                    return
                }
                let rain = daily["precipitation_probability_max"] as? [Int] ?? []
                let day = tomorrow ? 1 : 0
                guard highs.count > day, lows.count > day, codes.count > day else {
                    finish("I couldn't get the forecast right now.")
                    return
                }
                let high = Int(highs[day].rounded()), low = Int(lows[day].rounded())
                let chance = rain.count > day ? rain[day] : 0
                let rainText = chance >= 20 ? " There's a \(chance) percent chance of rain." : ""

                if tomorrow {
                    finish("Tomorrow in \(name), expect \(describe(codes[day])), with a high of \(high) and a low of \(low) degrees.\(rainText)")
                } else if let current = json["current"] as? [String: Any],
                          let temp = current["temperature_2m"] as? Double,
                          let code = current["weather_code"] as? Int {
                    let wind = Int(((current["wind_speed_10m"] as? Double) ?? 0).rounded())
                    finish("Right now in \(name) it's \(Int(temp.rounded())) degrees with \(describe(code)) and wind around \(wind) miles an hour. Today's high is \(high) and the low is \(low).\(rainText)")
                } else {
                    finish("Today in \(name), expect \(describe(codes[day])), with a high of \(high) and a low of \(low) degrees.\(rainText)")
                }
            }
        }
    }
}
