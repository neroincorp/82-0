import Foundation
import WebKit

final class GameSchemeHandler: NSObject, WKURLSchemeHandler {
    private let service = NFLDataService.shared

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, "Bad URL")
            return
        }

        if url.path == "/api/health" {
            sendJSON(urlSchemeTask, data: Data("{\"ok\":true}".utf8))
            return
        }

        if url.path == "/api/preload" {
            if let body = urlSchemeTask.request.httpBody,
               let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let rolls = obj["rolls"] as? [[String: Any]] {
                service.preload(rolls)
            }
            sendJSON(urlSchemeTask, data: Data("{\"ok\":true}".utf8))
            return
        }

        if url.path == "/api/players" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let q = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            guard let franchise = q["franchise"],
                  let start = Int(q["start"] ?? ""),
                  let end = Int(q["end"] ?? "") else {
                fail(urlSchemeTask, "Invalid player request")
                return
            }
            Task {
                do {
                    let data = try await service.playersJSON(franchise: franchise, start: start, end: end)
                    sendJSON(urlSchemeTask, data: data)
                } catch {
                    let obj: [String: Any] = ["ok": false, "error": error.localizedDescription]
                    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{\"ok\":false}".utf8)
                    sendJSON(urlSchemeTask, data: data)
                }
            }
            return
        }

        serveStatic(urlSchemeTask, path: url.path)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func serveStatic(_ task: WKURLSchemeTask, path: String) {
        let resource = path == "/" ? "index.html" : String(path.dropFirst())
        let file = URL(fileURLWithPath: resource)
        let name = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext.isEmpty ? nil : ext) else {
            fail(task, "Missing bundled file: \(resource)")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let mime: String
            switch ext.lowercased() {
            case "html": mime = "text/html"
            case "css": mime = "text/css"
            case "js": mime = "application/javascript"
            case "json": mime = "application/json"
            case "png": mime = "image/png"
            case "jpg", "jpeg": mime = "image/jpeg"
            default: mime = "application/octet-stream"
            }
            let response = URLResponse(url: task.request.url!, mimeType: mime, expectedContentLength: data.count, textEncodingName: ext == "html" || ext == "css" || ext == "js" ? "utf-8" : nil)
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        } catch {
            fail(task, error.localizedDescription)
        }
    }

    private func sendJSON(_ task: WKURLSchemeTask, data: Data) {
        guard let url = task.request.url else { return }
        let response = URLResponse(url: url, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, _ message: String) {
        task.didFailWithError(NSError(domain: "SeventeenZero", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
