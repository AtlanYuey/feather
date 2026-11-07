//
//  ManifestServersView.swift
//  Feather
//
//  Manage the remote servers that generate install manifests
//  for the "Semi Local" server type.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct ManifestServersView: View {
	@AppStorage(ManifestServerStore.selectedKey) private var _selectedId: String = ManifestServerStore.paleraIn.id

	@State private var _servers: [ManifestServer] = ManifestServerStore.load()
	@State private var _results: [String: ManifestServerStore.TestResult] = [:]
	@State private var _isTesting = false

	@State private var _isAddPresenting = false
	@State private var _newName = ""
	@State private var _newUrl = ""
	@State private var _isInvalidUrlPresenting = false
	@State private var _isResetPresenting = false

	private var _effectiveSelectedId: String? {
		_servers.first(where: { $0.id == _selectedId })?.id ?? _servers.first?.id
	}

	// MARK: Body
	var body: some View {
		NBList(.localized("Manifest Server")) {
			Section {
				ForEach(_servers) { server in
					_cell(for: server)
				}
				.onDelete(perform: _delete)

				if _servers.isEmpty {
					Text(.localized("No servers, palera.in will be used."))
						.foregroundStyle(.secondary)
				}
			} header: {
				Text(.localized("Servers"))
			} footer: {
				Text(.localized("Tap a server to use it. Swipe left to delete.\n\nThe server only generates the install manifest, your app is still sent from this device. Some servers (e.g. Prism) only accept the localhost address, so enable \"Only use localhost address\" when using them."))
			}

			Section {
				Button {
					_testAll()
				} label: {
					HStack {
						Label(.localized("Test All Servers"), systemImage: "network")
						if _isTesting {
							Spacer()
							ProgressView()
						}
					}
				}
				.disabled(_isTesting || _servers.isEmpty)

				Button(.localized("Use Fastest Working Server"), systemImage: "bolt") {
					_selectFastest()
				}
				.disabled(_isTesting || !_results.values.contains(where: { if case .ok = $0 { return true }; return false }))

				Button(.localized("Add Server"), systemImage: "plus") {
					_newName = ""
					_newUrl = ""
					_isAddPresenting = true
				}

				Button(.localized("Restore Default Servers"), systemImage: "arrow.counterclockwise", role: .destructive) {
					_isResetPresenting = true
				}
			}
		}
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					_newName = ""
					_newUrl = ""
					_isAddPresenting = true
				} label: {
					Image(systemName: "plus")
				}
			}
		}
		.alert(.localized("Add Server"), isPresented: $_isAddPresenting) {
			TextField(.localized("Name (Optional)"), text: $_newName)
			TextField("https://example.com/genPlist", text: $_newUrl)
				.keyboardType(.URL)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("Add")) {
				_add()
			}
		} message: {
			Text(.localized("Enter the full endpoint URL. bundleid, name, version and fetchurl will be appended as query parameters."))
		}
		.alert(.localized("Invalid URL"), isPresented: $_isInvalidUrlPresenting) {
			Button(.localized("OK"), role: .cancel) { }
		} message: {
			Text(.localized("The URL must be a valid HTTPS address."))
		}
		.alert(.localized("Restore Default Servers"), isPresented: $_isResetPresenting) {
			Button(.localized("Cancel"), role: .cancel) { }
			Button(.localized("Restore"), role: .destructive) {
				ManifestServerStore.resetToDefaults()
				_servers = ManifestServerStore.load()
				_selectedId = ManifestServerStore.paleraIn.id
				_results = [:]
			}
		} message: {
			Text(.localized("Custom servers will be removed."))
		}
	}
}

// MARK: - Extension: View
extension ManifestServersView {
	@ViewBuilder
	private func _cell(for server: ManifestServer) -> some View {
		Button {
			_selectedId = server.id
		} label: {
			HStack(spacing: 12) {
				Image(systemName: "checkmark")
					.font(.body.weight(.semibold))
					.foregroundStyle(Color.accentColor)
					.opacity(server.id == _effectiveSelectedId ? 1 : 0)

				VStack(alignment: .leading, spacing: 2) {
					Text(server.name)
						.foregroundStyle(.primary)
					Text(server.url)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}

				Spacer(minLength: 8)

				_status(for: server)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.swipeActions(edge: .trailing, allowsFullSwipe: true) {
			Button(role: .destructive) {
				if let index = _servers.firstIndex(of: server) {
					_delete(IndexSet(integer: index))
				}
			} label: {
				Label(.localized("Delete"), systemImage: "trash")
			}

			Button {
				Task { await _test(server) }
			} label: {
				Label(.localized("Test"), systemImage: "network")
			}
			.tint(.blue)
		}
	}

	@ViewBuilder
	private func _status(for server: ManifestServer) -> some View {
		switch _results[server.id] {
		case .testing:
			ProgressView()
		case .ok(let ms):
			HStack(spacing: 4) {
				Text("\(ms) ms")
					.font(.footnote)
					.foregroundStyle(.secondary)
				Image(systemName: "checkmark.circle.fill")
					.foregroundStyle(.green)
			}
		case .failed(let reason):
			HStack(spacing: 4) {
				Text(reason)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				Image(systemName: "xmark.circle.fill")
					.foregroundStyle(.red)
			}
		case .none:
			EmptyView()
		}
	}
}

// MARK: - Extension: Actions
extension ManifestServersView {
	private func _add() {
		guard let url = ManifestServerStore.normalize(_newUrl) else {
			_isInvalidUrlPresenting = true
			return
		}

		let trimmedName = _newName.trimmingCharacters(in: .whitespacesAndNewlines)
		let name = trimmedName.isEmpty
			? (URLComponents(string: url)?.host ?? url)
			: trimmedName

		let server = ManifestServer(id: UUID().uuidString, name: name, url: url)
		_servers.append(server)
		ManifestServerStore.save(_servers)

		Task { await _test(server) }
	}

	private func _delete(_ offsets: IndexSet) {
		for index in offsets {
			_results[_servers[index].id] = nil
		}
		_servers.remove(atOffsets: offsets)
		ManifestServerStore.save(_servers)

		if !_servers.contains(where: { $0.id == _selectedId }) {
			_selectedId = _servers.first?.id ?? ManifestServerStore.paleraIn.id
		}
	}

	private func _testAll() {
		_isTesting = true
		let servers = _servers

		Task {
			await withTaskGroup(of: Void.self) { group in
				for server in servers {
					group.addTask { await _test(server) }
				}
			}
			await MainActor.run { _isTesting = false }
		}
	}

	private func _test(_ server: ManifestServer) async {
		await MainActor.run { _results[server.id] = .testing }
		let result = await ManifestServerStore.test(server)
		await MainActor.run { _results[server.id] = result }
	}

	private func _selectFastest() {
		let fastest = _servers
			.compactMap { server -> (ManifestServer, Int)? in
				if case .ok(let ms) = _results[server.id] { return (server, ms) }
				return nil
			}
			.min(by: { $0.1 < $1.1 })

		if let fastest {
			_selectedId = fastest.0.id
		}
	}
}
