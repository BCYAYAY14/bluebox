//
//  SwarmStats.swift
//  Bluebox
//
//  What the player's stats overlay and the buffering screen show about the
//  torrent that's playing. Written for Bluebox.
//

import Foundation

public struct SwarmStats: Sendable, Equatable {
    public var connectedPeers: Int
    public var seeds: Int
    /// Peers known from trackers, the DHT and PEX but not connected.
    public var knownPeers: Int
    /// Payload bytes per second.
    public var downloadRate: Double
    public var uploadRate: Double
    /// Payload bytes moved for this torrent since it started.
    public var downloadedBytes: Int64
    public var uploadedBytes: Int64
    /// 0…1 of the file being played.
    public var fileProgress: Double

    public init(connectedPeers: Int = 0, seeds: Int = 0, knownPeers: Int = 0, downloadRate: Double = 0,
                uploadRate: Double = 0, downloadedBytes: Int64 = 0, uploadedBytes: Int64 = 0, fileProgress: Double = 0) {
        self.connectedPeers = connectedPeers
        self.seeds = seeds
        self.knownPeers = knownPeers
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
        self.fileProgress = fileProgress
    }
}

/// Bytes the torrent engine has moved since launch, for data-usage accounting.
public struct TorrentTransferTotals: Sendable, Equatable {
    /// Everything received and sent, protocol overhead included.
    public var received: Int64
    public var sent: Int64
    /// The part of the above moved while the network was expensive (cellular, a hotspot).
    public var receivedOnExpensiveNetwork: Int64
    public var sentOnExpensiveNetwork: Int64

    public init(received: Int64 = 0, sent: Int64 = 0, receivedOnExpensiveNetwork: Int64 = 0, sentOnExpensiveNetwork: Int64 = 0) {
        self.received = received
        self.sent = sent
        self.receivedOnExpensiveNetwork = receivedOnExpensiveNetwork
        self.sentOnExpensiveNetwork = sentOnExpensiveNetwork
    }
}

/// Which bytes of a streaming file are on disk, for the player's scrub bar.
public struct TorrentFileRanges: Sendable, Equatable {
    public var length: Int64
    /// Downloaded byte ranges, sorted and merged.
    public var ranges: [Range<Int64>]

    public init(length: Int64, ranges: [Range<Int64>]) {
        self.length = length
        self.ranges = ranges
    }

    /// The same as fractions of the file (0…1).
    public var fractions: [ClosedRange<Double>] {
        guard length > 0 else { return [] }
        return ranges.map { Double($0.lowerBound) / Double(length)...Double($0.upperBound) / Double(length) }
    }
}
