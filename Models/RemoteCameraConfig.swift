//
//  RemoteCameraConfig.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 11/6/25.
//


//
//  RemoteCameraConfig.swift
//  SSHSwiftUIDemo
//
//  Defines all CGI endpoints and HLS base paths for a given remote host.
//  Compatible with both direct LAN and tunneled/LTE access.
//
//  Created by Jesse Herring on 11/06/25.
//

import Foundation
import OSLog

struct RemoteCameraConfig: Sendable, Equatable {
    let baseURL: URL
    let host: String
    let username: String
    let port: Int

    // MARK: - Static logger
    private static let log = Logger(subsystem: "com.SSHSwiftUIDemo", category: "RemoteCameraConfig")

    // MARK: - Init
    init(device: Device) {
        self.host = device.host
        self.username = device.username
        self.port = device.port
        self.baseURL = URL(string: "http://\(device.host)")!
       
        //Self.log.debug("[RemoteCameraConfig] created for \(self.host) port=\(self.port)")
        print("[RemoteCameraConfig] created for \(self.host) port=\(self.port)")
    }

    // MARK: - Derived Paths (HLS + CGI)
    var hlsStreamURL: URL {
        (activeBaseURL ?? baseURL).appendingPathComponent("/hls/stream.m3u8")
    }

    var snapshotURL: URL {
        (activeBaseURL ?? baseURL).appendingPathComponent("/cgi-bin/snapshot_hls.cgi")
    }

    var startStreamURL: URL {
        (activeBaseURL ?? baseURL).appendingPathComponent("/cgi-bin/start_hls_stream.cgi")
    }

    var stopStreamURL: URL {
        (activeBaseURL ?? baseURL).appendingPathComponent("/cgi-bin/stop_hls_stream.cgi")
    }

    var startRecordURL: URL {
        (activeBaseURL ?? baseURL).appendingPathComponent("/cgi-bin/start_hls_recording.cgi")
    }

    var stopRecordURL: URL {
        (activeBaseURL ?? baseURL).appendingPathComponent("/cgi-bin/stop_hls_recording.cgi")
    }

    var statusURL: URL {
        (activeBaseURL ?? baseURL).appendingPathComponent("/cgi-bin/health.cgi")
    }

    // MARK: - Active base selector
    private var activeBaseURL: URL? {
        return baseURL
    }

    // MARK: - Utilities
    func describe() -> String {
        """
        RemoteCameraConfig(
          host: \(host),
          port: \(port),
          base: \(baseURL.absoluteString)
        )
        """
    }

    func logAllEndpoints() {
        Self.log.info("""
        [RemoteCameraConfig] Endpoints for \(self.host, privacy: .public):
          HLS stream:  \(self.hlsStreamURL.absoluteString, privacy: .public)
          Snapshot:    \(self.snapshotURL.absoluteString, privacy: .public)
          Start:       \(self.startStreamURL.absoluteString, privacy: .public)
          Stop:        \(self.stopStreamURL.absoluteString, privacy: .public)
          Record:      \(self.startRecordURL.absoluteString, privacy: .public)
          StopRecord:  \(self.stopRecordURL.absoluteString, privacy: .public)
          Health:      \(self.statusURL.absoluteString, privacy: .public)
        """)
    }
}
