//
//  ServiceTriple.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 8/10/25.
//


/// Holds the SSH/HTTP/HLS statuses for a device.
struct ServiceTriple {
    var ssh: DeviceServiceStatus
    var http: DeviceServiceStatus
    var hls: DeviceServiceStatus

    init(ssh: DeviceServiceStatus = .unknown,
         http: DeviceServiceStatus = .unknown,
         hls: DeviceServiceStatus = .unknown) {
        self.ssh = ssh
        self.http = http
        self.hls = hls
    }
}