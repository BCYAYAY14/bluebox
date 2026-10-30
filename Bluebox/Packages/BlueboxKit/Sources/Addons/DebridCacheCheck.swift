//
//  DebridCacheCheck.swift
//  Bluebox
//
//  Written for Bluebox from public documentation: TorBox's API reference
//  (GET /v1/api/torrents/checkcached, comma-separated `hash`, `format=list`,
//  Bearer key) and Premiumize's (POST /api/cache/check with `items[]`,
//  answering parallel `response` booleans) and Debrid-Link's (GET
//  /api/v2/seedbox/cached with comma-separated hashes in `url`, Bearer key,
//  answering `value` keyed by the hashes it holds). Real-Debrid and AllDebrid
//  no longer publish an availability endpoint, so their add-ons' markers are
//  trusted instead.
//

import Foundation

/// Asks the debrid service which torrents it already holds, so "Cached" means cached.
public enum DebridCacheCheck {
    /// Hashes the service holds, out of `hashes` (lowercased hex). nil when
    /// the service can't be asked or didn't answer.
    public static func cached(_ hashes: [String], service: DebridProvider, key: String,
                              client: AddonClient, timeout: TimeInterval = 4) async -> Set<String>? {
        let unique = Array(Set(hashes.map { $0.lowercased() })).sorted()
        guard !unique.isEmpty, !key.isEmpty, service.canCheckCache else { return nil }
        var found = Set<String>()
        // Both services take about 100 at a time.
        for start in stride(from: 0, to: unique.count, by: 100) {
            let chunk = Array(unique[start..<min(start + 100, unique.count)])
            let request: URLRequest
            switch service {
            case .torBox: request = torBoxRequest(chunk, key: key, timeout: timeout)
            case .premiumize: request = premiumizeRequest(chunk, key: key, timeout: timeout)
            case .debridLink: request = debridLinkRequest(chunk, key: key, timeout: timeout)
            default: return nil
            }
            do {
                let transport = client.transport
                let data = try await AddonClient.withDeadline(seconds: timeout) {
                    let (data, response) = try await transport.data(for: request)
                    guard (200..<300).contains(response.statusCode) else { throw AddonError.badStatus(response.statusCode) }
                    return data
                }
                switch service {
                case .torBox: found.formUnion(parseTorBox(data))
                case .premiumize: found.formUnion(parsePremiumize(data, asked: chunk))
                case .debridLink: found.formUnion(parseDebridLink(data))
                default: break
                }
            } catch {
                return nil
            }
        }
        return found
    }

    static func torBoxRequest(_ hashes: [String], key: String, timeout: TimeInterval) -> URLRequest {
        var components = URLComponents(string: "https://api.torbox.app/v1/api/torrents/checkcached")!
        components.queryItems = [URLQueryItem(name: "hash", value: hashes.joined(separator: ",")),
                                 URLQueryItem(name: "format", value: "list")]
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// `{"success": true, "data": [{"hash": "…", "name": "…", "size": 123}, …]}`
    /// (or, with `format=object`, `data` keyed by hash). Hashes not listed aren't cached.
    static func parseTorBox(_ data: Data) -> Set<String> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let list = json["data"] as? [[String: Any]] {
            return Set(list.compactMap { ($0["hash"] as? String)?.lowercased() })
        }
        if let object = json["data"] as? [String: Any] {
            return Set(object.keys.map { $0.lowercased() })
        }
        return []
    }

    static func premiumizeRequest(_ hashes: [String], key: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.premiumize.me/api/cache/check")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = hashes.map { URLQueryItem(name: "items[]", value: $0) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        return request
    }

    /// `{"status": "success", "response": [true, false, …]}`, in the order asked.
    static func parsePremiumize(_ data: Data, asked: [String]) -> Set<String> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["status"] as? String == "success",
              let answers = json["response"] as? [Bool] else { return [] }
        return Set(zip(asked, answers).compactMap { $1 ? $0 : nil })
    }

    static func debridLinkRequest(_ hashes: [String], key: String, timeout: TimeInterval) -> URLRequest {
        var components = URLComponents(string: "https://debrid-link.com/api/v2/seedbox/cached")!
        components.queryItems = [URLQueryItem(name: "url", value: hashes.joined(separator: ","))]
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// `{"success": true, "value": {"<hash>": {"name": "…", "files": […]}, …}}`.
    /// Hashes not listed aren't cached; an empty `value` may come as `[]`.
    static func parseDebridLink(_ data: Data) -> Set<String> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["success"] as? Bool == true,
              let value = json["value"] as? [String: Any] else { return [] }
        return Set(value.keys.map { $0.lowercased() })
    }

    /// Marks debrid links whose hash the service reported. Links it didn't
    /// list become uncached; torrents and hash-less links keep their markers.
    public static func apply(_ cached: Set<String>, checked: Set<String>, to releases: [AddonRelease]) -> [AddonRelease] {
        releases.map { release in
            guard release.isDebrid, let hash = release.contentHash, checked.contains(hash) else { return release }
            var copy = release
            copy.cache = cached.contains(hash) ? .cached : .uncached
            return copy
        }
    }
}
