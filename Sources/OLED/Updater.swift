import Foundation
import AppKit

/// Keeps OLED up to date by itself: checks the GitHub release, downloads the new build,
/// swaps it into place and reopens — no DMG needed.
final class Updater {
    private let releaseAPI = URL(string: "https://api.github.com/repos/ben24wr5/Jarvis/releases/tags/latest")!
    private var timer: Timer?
    private(set) var isUpdating = false
    private(set) var status = "Up to date"

    /// Called just before OLED quits to install an update (so it can say so).
    var willInstall: ((_ newBuild: Int, _ proceed: @escaping () -> Void) -> Void)?
    var onStatus: ((String) -> Void)?

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    func startAutomaticChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.check(userAsked: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 60 * 60, repeats: true) { [weak self] _ in
            self?.check(userAsked: false)
        }
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async {
            self.status = s
            self.onStatus?(s)
        }
    }

    /// Looks for a newer build. `done` gets a sentence to say when the user asked.
    func check(userAsked: Bool, done: ((String) -> Void)? = nil) {
        guard !isUpdating else { done?("I'm already updating."); return }
        var request = URLRequest(url: releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OLED-updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let dmg = assets.first(where: { ($0["name"] as? String) == "OLED.dmg" }),
                  let urlString = dmg["browser_download_url"] as? String,
                  let url = URL(string: urlString) else {
                self.setStatus("Couldn't check for updates")
                DispatchQueue.main.async { done?("I couldn't check for updates right now.") }
                return
            }
            let latest = Self.buildNumber(in: name)
            guard latest > Self.currentBuild else {
                self.setStatus("Up to date (version \(Self.currentBuild))")
                DispatchQueue.main.async { done?("I'm already up to date.") }
                return
            }
            DispatchQueue.main.async {
                done?("There's an update for me. Installing it now.")
                self.download(url, build: latest, announced: userAsked)
            }
        }.resume()
    }

    private static func buildNumber(in name: String) -> Int {
        guard let r = name.range(of: "#\\d+", options: .regularExpression) else { return 0 }
        return Int(name[r].dropFirst()) ?? 0
    }

    private func download(_ url: URL, build: Int, announced: Bool) {
        isUpdating = true
        setStatus("Downloading update…")
        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self else { return }
            guard let tempURL, error == nil else {
                self.isUpdating = false
                self.setStatus("Update download failed – will try again later")
                return
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("OLED-update-\(build)", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmg = work.appendingPathComponent("OLED.dmg")
            do {
                try FileManager.default.moveItem(at: tempURL, to: dmg)
            } catch {
                self.isUpdating = false
                self.setStatus("Couldn't save the update – will try again later")
                return
            }
            DispatchQueue.main.async {
                let proceed = { self.install(dmg: dmg, work: work) }
                if let willInstall = self.willInstall, !announced {
                    willInstall(build, proceed)
                } else {
                    proceed()
                }
            }
        }.resume()
    }

    private func install(dmg: URL, work: URL) {
        let dest = Bundle.main.bundleURL.path
        let mount = work.appendingPathComponent("mnt").path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        mkdir -p "\(mount)"
        hdiutil attach -nobrowse -noverify -noautoopen -mountpoint "\(mount)" "\(dmg.path)" >/dev/null 2>&1 || { open "\(dest)"; exit 1; }
        if [ -d "\(mount)/OLED.app" ]; then
          rm -rf "\(dest).old"
          mv "\(dest)" "\(dest).old" && ditto "\(mount)/OLED.app" "\(dest)" && rm -rf "\(dest).old" || { rm -rf "\(dest)"; mv "\(dest).old" "\(dest)"; }
          xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null
        fi
        hdiutil detach "\(mount)" -quiet >/dev/null 2>&1
        open "\(dest)"
        rm -rf "\(work.path)"
        """
        let scriptURL = work.appendingPathComponent("install.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "nohup /bin/bash '\(scriptURL.path)' >/dev/null 2>&1 &"]
            try p.run()
            p.waitUntilExit()
        } catch {
            isUpdating = false
            setStatus("Couldn't install the update – will try again later")
            return
        }
        setStatus("Installing update…")
        NSApp.terminate(nil)
    }
}
