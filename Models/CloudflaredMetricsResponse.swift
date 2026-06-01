//
//  CloudflaredMetricsResponse.swift
//  SSHSwiftUIDemo
//
//  Created by Jesse Herring on 12/14/25.
//


import Foundation

public struct CloudflaredMetricsResponse: Codable, Equatable {
    public let ok: Bool
    public let timestamp: String?
    public let cloudflaredSeriesCount: Int?
    public let hasCloudflaredMetrics: Bool?
    public let hasByteCounters: Bool?
    public let totalRequests: Int?
    public let totalRequestErrors: Int?

    public enum CodingKeys: String, CodingKey {
        case ok
        case timestamp
        case cloudflaredSeriesCount = "cloudflared_series_count"
        case hasCloudflaredMetrics = "has_cloudflared_metrics"
        case hasByteCounters = "has_byte_counters"
        case totalRequests = "total_requests"
        case totalRequestErrors = "total_request_errors"
    }

    public init(
        ok: Bool,
        timestamp: String? = nil,
        cloudflaredSeriesCount: Int? = nil,
        hasCloudflaredMetrics: Bool? = nil,
        hasByteCounters: Bool? = nil,
        totalRequests: Int? = nil,
        totalRequestErrors: Int? = nil
    ) {
        self.ok = ok
        self.timestamp = timestamp
        self.cloudflaredSeriesCount = cloudflaredSeriesCount
        self.hasCloudflaredMetrics = hasCloudflaredMetrics
        self.hasByteCounters = hasByteCounters
        self.totalRequests = totalRequests
        self.totalRequestErrors = totalRequestErrors
    }
}