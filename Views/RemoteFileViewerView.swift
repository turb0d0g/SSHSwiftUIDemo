//
//  RemoteFileViewerView.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/25/25.
//

//
//  RemoteFileManagerView.swift
//  SSHSwiftUIDemo
//
//  SwiftUI front-end for FileManagerViewModel.
//  - Single-tap folders to navigate.
//  - Double-tap files to open viewer.
//

import SwiftUI
import NIOCore
import NIOSSH
import OSLog
import CodeEditor

struct RemoteFileManagerView: View {
    enum Backend {
        case channel(Channel)
        case connection(SFTPConnection)
    }

    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "RemoteFileManagerView")

    private let backend: Backend
    private let initialPath: String

    @StateObject private var vm = FileManagerViewModel()

    // ✅ double-tap file -> open
    @State private var openedFilePath: String? = nil

    // Prefer these two convenience initializers so call sites are explicit and type-safe.
    init(sftpChannel: Channel, initialPath: String) {
        print("[RemoteFileManagerView] init -> channel")
        self.backend = .channel(sftpChannel)
        self.initialPath = initialPath
    }

    init(sftpConnection: SFTPConnection, initialPath: String) {
        print("[RemoteFileManagerView] init -> connection")
        self.backend = .connection(sftpConnection)
        self.initialPath = initialPath
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            listBody
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    log.debug("[RemoteFileManagerView] refresh tapped")
                    vm.refresh()
                } label: { Image(systemName: "arrow.clockwise") }
                .disabled(vm.isLoading)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { openedFilePath != nil },
            set: { if !$0 { openedFilePath = nil } }
        )) {
            // Push a viewer when openedFilePath is set
            if let path = openedFilePath {
                SFTPFileViewerView(
                    backend: backend,
                    remotePath: path,
                    title: (path as NSString).lastPathComponent
                )
            }
        }
        .onAppear {
            // One-time binding
            if vm.entries.isEmpty {
                log.debug("[RemoteFileManagerView] bind initialPath=\(initialPath, privacy: .public)")
                switch backend {
                case .channel(let ch):
                    vm.bind(channel: ch, initialPath: initialPath)
                case .connection(let conn):
                    vm.bind(connection: conn, initialPath: initialPath)
                }
            }
        }
    }

    // MARK: UI

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                log.debug("[RemoteFileManagerView] goUp tapped")
                vm.goUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(vm.currentPath == "/")

            Text(verbatim: vm.currentPath)
                .font(.system(.title3, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var listBody: some View {
        ZStack {
            List {
                ForEach(vm.entries, id: \.filename) { entry in
                    row(for: entry)
                        .contentShape(Rectangle()) // whole row is tappable
                        .onTapGesture(count: 1) {
                            handleSingleTap(entry)
                        }
                        .onTapGesture(count: 2) {
                            handleDoubleTap(entry)
                        }
                }
            }
            .listStyle(.plain)

            if vm.isLoading {
                ProgressView().scaleEffect(1.2)
            }

            if let msg = vm.errorMessage, !vm.isLoading {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(msg)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }

    private func handleSingleTap(_ entry: SFTPName) {
        let isDir = FileManagerViewModel.isDirectory(longname: entry.longname, filename: entry.filename)
        if isDir {
            log.debug("[RemoteFileManagerView] singleTap DIR -> navigateInto \(entry.filename, privacy: .public)")
            vm.navigateInto(entry)
        } else {
            // Intentionally do nothing — allows reliable double-tap to open.
            log.debug("[RemoteFileManagerView] singleTap FILE (noop) \(entry.filename, privacy: .public)")
        }
    }

    private func handleDoubleTap(_ entry: SFTPName) {
        let isDir = FileManagerViewModel.isDirectory(longname: entry.longname, filename: entry.filename)
        if isDir {
            log.debug("[RemoteFileManagerView] doubleTap DIR -> navigateInto \(entry.filename, privacy: .public)")
            vm.navigateInto(entry)
            return
        }

        // Build full remote path
        let fullPath: String
        if vm.currentPath == "/" {
            fullPath = "/" + entry.filename
        } else {
            fullPath = vm.currentPath + "/" + entry.filename
        }

        log.debug("[RemoteFileManagerView] doubleTap FILE -> open \(fullPath, privacy: .public)")
        openedFilePath = fullPath
    }

    @ViewBuilder
    private func row(for entry: SFTPName) -> some View {
        let isDir = FileManagerViewModel.isDirectory(longname: entry.longname, filename: entry.filename)

        HStack(spacing: 12) {
            Image(systemName: isDir ? "folder.fill" : "doc.text")
                .imageScale(.large)

            Text(entry.filename)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            Spacer()

            // Optional tiny hint so users don’t rage-tap:
            if !isDir {
                Text("dbl-tap")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Viewer (wire up your SFTP read here)

private struct SFTPFileViewerView: View {
    private let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "SFTPFileViewerView")

    let backend: RemoteFileManagerView.Backend
    let remotePath: String
    let title: String

    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var text: String = ""

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening…").font(.footnote).foregroundStyle(.secondary)
                    Text(remotePath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                    Text("Couldn’t open file")
                        .font(.headline)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeEditor(
                    source: $text,
                    language: language(for: remotePath),
                    theme: .atelierSavannaLight,
                    flags: [.selectable, .smartIndent]
                )
                .font(.system(.body, design: .monospaced))
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    private func load() async {
        log.debug("[SFTPFileViewerView] load start path=\(remotePath, privacy: .public)")
        isLoading = true
        error = nil

        do {
            switch backend {
            case .connection(let conn):
                // real open
                self.text = try await conn.readTextFile(path: remotePath, maxBytes: 256 * 1024)
            case .channel:
                // cannot read unless we pass the actual SFTP client/connection used by vm
                throw NSError(
                    domain: "SFTPFileViewerView",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "File open requires RemoteFileManagerView(sftpConnection:initialPath:). " +
                        "You initialized with a raw Channel, which can list/navigate but doesn’t provide a reusable SFTP client for downloads."
                    ]
                )
            }

            isLoading = false
            log.debug("[SFTPFileViewerView] load ok path=\(remotePath, privacy: .public) chars=\(text.count)")
        } catch {
            let msg = String(describing: error)
            log.error("[SFTPFileViewerView] load FAIL err=\(msg, privacy: .public)")
            self.error = msg
            isLoading = false
        }
    }

    private func language(for path: String) -> CodeEditor.Language {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "py": return .python
        case "js": return .javascript
        case "json": return .json
        case "md": return .markdown
        case "sh", "bash", "cgi": return .shell
        case "yml", "yaml": return .yaml
        case "xml", "plist": return .xml
        default: return .shell
        }
    }
}
