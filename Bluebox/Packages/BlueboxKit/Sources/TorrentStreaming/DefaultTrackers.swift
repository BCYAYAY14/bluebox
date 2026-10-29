//
//  DefaultTrackers.swift
//  Bluebox
//
//  Public open trackers added to every torrent, so a magnet with few or dead
//  trackers still finds peers quickly. Chosen for Bluebox from public lists
//  (ngosang/trackerslist "best", newTrackon "stable"), keeping only those that
//  answered a BEP 15 connect (UDP) or an announce (HTTP) on 2026-10-28.
//  HTTPS trackers are left out: the engine is built without a TLS library.
//

import Foundation

enum DefaultTrackers {
    static let all: [String] = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://open.tracker.cl:1337/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.qu.ax:6969/announce",
        "udp://tracker-udp.gbitt.info:80/announce",
        "udp://tracker.dler.org:6969/announce",
        "udp://tracker.theoks.net:6969/announce",
        "udp://tracker.bittor.pw:1337/announce",
        "udp://tracker.tryhackx.org:6969/announce",
        "udp://tracker.ducks.party:1984/announce",
        "udp://evan.im:6969/announce",
        "http://tracker.opentrackr.org:1337/announce",
        "http://bt1.archive.org:6969/announce",
    ]

    /// A few more, added to a torrent that has stalled.
    static let fallback: [String] = [
        "udp://tracker.opentrackr.com:6969/announce",
        "http://open.tracker.cl:1337/announce",
        "http://tracker.renfei.net:8080/announce",
        "http://tracker.dler.com:6969/announce",
    ]

    /// `extra` first (the user's and the magnet's), then the defaults, without
    /// duplicates or HTTPS (unsupported without TLS).
    static func merged(_ extra: [String]) -> [String] {
        var seen = Set<String>()
        return (extra + all).filter { url in
            let lower = url.lowercased()
            guard lower.hasPrefix("udp://") || lower.hasPrefix("http://") else { return false }
            return seen.insert(lower).inserted
        }
    }
}
