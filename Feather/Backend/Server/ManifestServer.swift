//
//  ManifestServer.swift
//  Feather
//
//  Remote servers that generate the install manifest (plist)
//  used by the "Semi Local" server type.
//

import Foundation

// MARK: - Model
struct ManifestServer: Codable, Identifiable, Hashable {
	var id: String
	var name: String
	/// Full endpoint, e.g. `https://api.palera.in/genPlist`.
	/// Query items `bundleid`, `name`, `version` and `fetchurl` are appended to it.
	var url: String
}

// MARK: - Store
enum ManifestServerStore {
	static let serversKey = "Feather.manifestServers"
	static let selectedKey = "Feather.manifestServerSelected"

	static let paleraIn = ManifestServer(
		id: "builtin.palera.in",
		name: "palera.in",
		url: "https://api.palera.in/genPlist"
	)

	static let prism = ManifestServer(
		id: "builtin.prism",
		name: "Prism (kadeslab)",
		url: "https://prism.kadeslab.com/manifest.plist"
	)

	static let defaultServers: [ManifestServer] = [paleraIn, prism]

	// MARK: Persistence
	static func load() -> [ManifestServer] {
		guard
			let data = UserDefaults.standard.data(forKey: serversKey),
			let servers = try? JSONDecoder().decode([ManifestServer].self, from: data)
		else {
			return defaultServers
		}
		return servers
	}

	static func save(_ servers: [ManifestServer]) {
		guard let data = try? JSONEncoder().encode(servers) else { return }
		UserDefaults.standard.set(data, forKey: serversKey)
	}

	static func resetToDefaults() {
		UserDefaults.standard.removeObject(forKey: serversKey)
		UserDefaults.standard.set(paleraIn.id, forKey: selectedKey)
	}

	/// The server currently used for installs. Falls back to the first saved
	/// server, then to palera.in if the list is empty.
	static var selected: ManifestServer {
		let servers = load()
		let selectedId = UserDefaults.standard.string(forKey: selectedKey)
		return servers.first(where: { $0.id == selectedId })
			?? servers.first
			?? paleraIn
	}

	// MARK: URL helpers
	/// Validates and normalizes user input. Returns `nil` when the URL is unusable.
	/// iOS only accepts install manifests served over HTTPS.
	static func normalize(_ input: String) -> String? {
		var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
		if !string.contains("://") {
			string = "https://" + string
		}
		while string.hasSuffix("?") || string.hasSuffix("&") {
			string.removeLast()
		}
		guard
			let comps = URLComponents(string: string),
			comps.scheme?.lowercased() == "https",
			let host = comps.host, !host.isEmpty
		else {
			return nil
		}
		return string
	}

	/// Appends the manifest query to the server endpoint (unencoded, matching
	/// the original palera.in link format; callers handle encoding).
	static func rawLink(
		base: String,
		bundleId: String,
		name: String,
		version: String,
		fetchUrl: String
	) -> String {
		let separator = base.contains("?") ? "&" : "?"
		return "\(base)\(separator)bundleid=\(bundleId)&name=\(name)&version=\(version)&fetchurl=\(fetchUrl)"
	}

	// MARK: Testing
	enum TestResult: Equatable {
		case testing
		case ok(milliseconds: Int)
		case failed(String)
	}

	/// Requests a sample manifest (loopback fetch URL, same as "Only use localhost address")
	/// and checks that a valid install plist comes back.
	static func test(_ server: ManifestServer) async -> TestResult {
		let fetchUrl = "https://127.0.0.1:8080/feather-test.ipa"
		var comps = URLComponents(string: server.url)
		var items = comps?.queryItems ?? []
		items.append(contentsOf: [
			URLQueryItem(name: "bundleid", value: "com.feather.servertest"),
			URLQueryItem(name: "name", value: "Feather Test"),
			URLQueryItem(name: "version", value: "1.0"),
			URLQueryItem(name: "fetchurl", value: fetchUrl)
		])
		comps?.queryItems = items

		guard let url = comps?.url else {
			return .failed(.localized("Invalid URL"))
		}

		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
		request.httpMethod = "GET"

		let start = Date()
		do {
			let (data, response) = try await URLSession.shared.data(for: request)
			let elapsed = Int(Date().timeIntervalSince(start) * 1000)

			guard let http = response as? HTTPURLResponse else {
				return .failed(.localized("Invalid response"))
			}
			guard http.statusCode == 200 else {
				return .failed("HTTP \(http.statusCode)")
			}

			guard
				let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
				let items = plist["items"] as? [[String: Any]],
				let assets = items.first?["assets"] as? [[String: Any]],
				assets.contains(where: { ($0["url"] as? String) == fetchUrl })
			else {
				return .failed(.localized("Not a valid manifest"))
			}

			return .ok(milliseconds: elapsed)
		} catch {
			return .failed(error.localizedDescription)
		}
	}
}
