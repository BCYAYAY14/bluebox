//
//  BBTorrent.mm
//  Bluebox
//
//  Objective-C++ wrapper around libtorrent 2.x. Written for Bluebox from
//  libtorrent's public documentation and headers (libtorrent.org reference,
//  include/libtorrent/*.hpp); see BBTorrent.h for the model.
//
//  Locking: one mutex per session guards the session pointer and every
//  torrent's bookkeeping. libtorrent calls that wait on its network thread
//  may run under it (the network thread never takes it: alerts only wake our
//  queue). Callbacks are collected under the lock and called after it.
//

#import "BBTorrent.h"

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/version.hpp>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>
#include <unistd.h>

namespace lt = libtorrent;

NSErrorDomain const BBTorrentErrorDomain = @"BBTorrentErrorDomain";

static NSError *BBError(BBTorrentError code, NSString *message) {
    return [NSError errorWithDomain:BBTorrentErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

static NSString *BBString(std::string const &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static std::string BBHex(char const *bytes, size_t n) {
    static char const digits[] = "0123456789abcdef";
    std::string out;
    out.reserve(n * 2);
    for (size_t i = 0; i < n; ++i) {
        auto b = static_cast<unsigned char>(bytes[i]);
        out.push_back(digits[b >> 4]);
        out.push_back(digits[b & 15]);
    }
    return out;
}

/// Bluebox's name for a torrent: the v1 hash, or the v2 hash for v2-only torrents.
static std::string BBKey(lt::info_hash_t const &ih) {
    if (ih.has_v1()) return BBHex(ih.v1.data(), ih.v1.size());
    return BBHex(ih.v2.data(), ih.v2.size());
}

// MARK: - Plain value objects

@implementation BBSessionConfiguration

- (instancetype)init {
    if ((self = [super init])) {
        _connectionsLimit = 200;
        _listenPort = 0;
        _uploadRateLimit = 0;
        _downloadRateLimit = 0;
        _enableDHT = YES;
        _enableLSD = YES;
        _enableUTP = YES;
        _enableOutgoingUTP = NO;
        _enablePortMapping = YES;
        _diskQueueBytes = 4 * 1024 * 1024;
        _lowMemory = NO;
        _dhtBootstrapNodes = @[@"dht.libtorrent.org:25401", @"router.bittorrent.com:6881",
                               @"router.utorrent.com:6881", @"dht.transmissionbt.com:6881",
                               @"dht.aelitis.com:6881"];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    BBSessionConfiguration *c = [[BBSessionConfiguration allocWithZone:zone] init];
    c.connectionsLimit = _connectionsLimit;
    c.listenPort = _listenPort;
    c.uploadRateLimit = _uploadRateLimit;
    c.downloadRateLimit = _downloadRateLimit;
    c.enableDHT = _enableDHT;
    c.enableLSD = _enableLSD;
    c.enableUTP = _enableUTP;
    c.enableOutgoingUTP = _enableOutgoingUTP;
    c.enablePortMapping = _enablePortMapping;
    c.diskQueueBytes = _diskQueueBytes;
    c.lowMemory = _lowMemory;
    c.dhtBootstrapNodes = _dhtBootstrapNodes;
    return c;
}

/// The settings this configuration stands for. Values not set here keep
/// libtorrent's defaults.
- (lt::settings_pack)settingsPack {
    lt::settings_pack p;
    p.set_int(lt::settings_pack::alert_mask,
              static_cast<int>(static_cast<std::uint32_t>(lt::alert_category::status | lt::alert_category::error
                                                          | lt::alert_category::storage
                                                          | lt::alert_category::piece_progress)));
    int port = static_cast<int>(MAX(0, MIN(65535, _listenPort)));
    std::string listen = "0.0.0.0:" + std::to_string(port) + ",[::]:" + std::to_string(port);
    p.set_str(lt::settings_pack::listen_interfaces, listen);
    p.set_int(lt::settings_pack::connections_limit, static_cast<int>(MAX(10, _connectionsLimit)));
    p.set_int(lt::settings_pack::upload_rate_limit, static_cast<int>(MAX(0, _uploadRateLimit)));
    p.set_int(lt::settings_pack::download_rate_limit, static_cast<int>(MAX(0, _downloadRateLimit)));
    p.set_bool(lt::settings_pack::enable_dht, _enableDHT);
    p.set_bool(lt::settings_pack::enable_lsd, _enableLSD);
    p.set_bool(lt::settings_pack::enable_upnp, _enablePortMapping);
    p.set_bool(lt::settings_pack::enable_natpmp, _enablePortMapping);
    p.set_bool(lt::settings_pack::enable_outgoing_utp, _enableUTP && _enableOutgoingUTP);
    p.set_bool(lt::settings_pack::enable_incoming_utp, _enableUTP);
    p.set_bool(lt::settings_pack::enable_outgoing_tcp, true);
    p.set_bool(lt::settings_pack::enable_incoming_tcp, true);
    // Don't throttle uTP in favour of TCP: many peers only answer over uTP.
    p.set_int(lt::settings_pack::mixed_mode_algorithm, lt::settings_pack::peer_proportional);
    std::string nodes;
    for (NSString *node in _dhtBootstrapNodes) {
        if (!nodes.empty()) nodes += ",";
        nodes += node.UTF8String;
    }
    p.set_str(lt::settings_pack::dht_bootstrap_nodes, nodes);

    // Start fast: connect to many peers at once, give up on dead ones sooner,
    // and ask every tracker rather than one per tier.
    p.set_int(lt::settings_pack::connection_speed, 120);
    p.set_int(lt::settings_pack::torrent_connect_boost, 60);
    p.set_int(lt::settings_pack::peer_connect_timeout, 7);
    p.set_bool(lt::settings_pack::smooth_connects, false);
    // Streaming wants the earliest pieces first: don't hand peers whole
    // (often 4-16 MiB) pieces, and let idle peers help with pieces already
    // requested elsewhere rather than sit out.
    p.set_int(lt::settings_pack::whole_pieces_threshold, 0);
    p.set_bool(lt::settings_pack::strict_end_game_mode, false);
    p.set_bool(lt::settings_pack::announce_to_all_trackers, true);
    p.set_bool(lt::settings_pack::announce_to_all_tiers, true);
    p.set_int(lt::settings_pack::min_announce_interval, 60);
    p.set_bool(lt::settings_pack::prefer_udp_trackers, true);
    // Torrents run when Bluebox asks, not when a queue allows.
    p.set_int(lt::settings_pack::active_downloads, -1);
    p.set_int(lt::settings_pack::active_seeds, -1);
    p.set_int(lt::settings_pack::active_limit, -1);
    p.set_int(lt::settings_pack::active_checking, 2);
    // Trackers get two seconds to hear "stopped" at shutdown.
    p.set_int(lt::settings_pack::stop_tracker_timeout, 2);
    // Protocol encryption is on (built-in RC4 + Diffie-Hellman; no OpenSSL needed).
    p.set_int(lt::settings_pack::out_enc_policy, lt::settings_pack::pe_enabled);
    p.set_int(lt::settings_pack::in_enc_policy, lt::settings_pack::pe_enabled);
    p.set_int(lt::settings_pack::allowed_enc_level, lt::settings_pack::pe_both);
    p.set_bool(lt::settings_pack::enable_ip_notifier, true);

    p.set_int(lt::settings_pack::max_queued_disk_bytes, static_cast<int>(MAX(1024 * 1024, _diskQueueBytes)));
    if (_lowMemory) {
        p.set_int(lt::settings_pack::send_buffer_watermark, 256 * 1024);
        p.set_int(lt::settings_pack::max_peerlist_size, 1500);
        p.set_int(lt::settings_pack::max_paused_peerlist_size, 300);
        p.set_int(lt::settings_pack::file_pool_size, 20);
        p.set_int(lt::settings_pack::checking_mem_usage, 64);
        p.set_int(lt::settings_pack::aio_threads, 4);
        p.set_int(lt::settings_pack::hashing_threads, 2);
    }
    return p;
}

@end

@implementation BBTorrentFile
- (instancetype)initWithIndex:(NSInteger)index path:(NSString *)path size:(int64_t)size
                       offset:(int64_t)offset padding:(BOOL)padding {
    if ((self = [super init])) {
        _index = index;
        _path = [path copy];
        _size = size;
        _offset = offset;
        _isPadding = padding;
    }
    return self;
}
@end

@interface BBTorrentStatus ()
@property (nonatomic, readwrite) BBTorrentState state;
@property (nonatomic, readwrite) BOOL isPaused;
@property (nonatomic, readwrite) BOOL hasMetadata;
@property (nonatomic, readwrite) NSInteger downloadRate;
@property (nonatomic, readwrite) NSInteger uploadRate;
@property (nonatomic, readwrite) NSInteger peers;
@property (nonatomic, readwrite) NSInteger seeds;
@property (nonatomic, readwrite) NSInteger knownPeers;
@property (nonatomic, readwrite) NSInteger connectCandidates;
@property (nonatomic, readwrite) int64_t wantedDone;
@property (nonatomic, readwrite) int64_t wanted;
@property (nonatomic, readwrite) int64_t downloadedBytes;
@property (nonatomic, readwrite) int64_t uploadedBytes;
@property (nonatomic, readwrite, copy) NSString *savePath;
@property (nonatomic, readwrite, copy, nullable) NSString *errorMessage;
@property (nonatomic, readwrite) NSInteger hashFailures;
@end
@implementation BBTorrentStatus
@end

@interface BBSessionStats ()
@property (nonatomic, readwrite) int64_t bytesReceived;
@property (nonatomic, readwrite) int64_t bytesSent;
@property (nonatomic, readwrite) NSInteger dhtNodes;
@property (nonatomic, readwrite) NSInteger torrents;
@property (nonatomic, readwrite) NSInteger listenPort;
@end
@implementation BBSessionStats
@end

// MARK: - Shared core

@class BBTorrentHandle;

namespace {

/// Files to delete once a removed torrent has closed them.
struct PendingUnlink {
    lt::info_hash_t hashes;
    std::vector<std::string> paths;
};

struct Core {
    std::mutex lock;
    std::unique_ptr<lt::session> session;
    bool closed = false;
    dispatch_queue_t queue = nullptr;
    std::atomic<bool> drainScheduled{false};
    std::map<std::string, BBTorrentHandle *> byKey;          // strong (ARC)
    std::map<lt::torrent_handle, BBTorrentHandle *> byHandle; // strong (ARC)
    std::vector<PendingUnlink> unlinks;
    // Session counters, from session_stats_alert.
    int recvIndex = -1, sentIndex = -1, dhtNodesIndex = -1;
    int64_t bytesReceived = 0, bytesSent = 0, dhtNodes = 0;
};

using Callback = void (^)(void);

}  // namespace

static void BBRun(std::vector<Callback> &callbacks) {
    for (Callback c : callbacks) c();
    callbacks.clear();
}

// MARK: - Torrent handle

@interface BBTorrentHandle () {
@public
    std::weak_ptr<Core> _core;
    lt::torrent_handle _th;
    std::string _key;
    // Everything below is guarded by Core::lock.
    std::vector<std::string> _users;
    std::map<std::string, std::map<int, int>> _priorities;
    std::set<int> _keptFiles;     // a user released these without deleting
    std::set<int> _orphanFiles;   // a user deleted these and nobody else wants them
    std::shared_ptr<const lt::torrent_info> _info;
    std::vector<uint8_t> _have;
    std::vector<int> _focus;      // pieces wanted exclusively, until they're in
    int _hashFailures;
    std::string _name;
    std::string _savePath;
    std::string _error;
    NSMutableArray<BBErrorCompletion> *_metadataWaiters;
    std::map<int, NSMutableArray<BBDataCompletion> *> _reads;
    NSMutableArray<BBDataCompletion> *_resumeWaiters;
    NSMutableDictionary<NSUUID *, BBPieceObserver> *_observers;
    bool _removed;
}
@end

@implementation BBTorrentHandle

- (instancetype)initWithCore:(std::shared_ptr<Core> const &)core handle:(lt::torrent_handle const &)th
                         key:(std::string const &)key savePath:(std::string const &)savePath {
    if ((self = [super init])) {
        _core = core;
        _th = th;
        _key = key;
        _savePath = savePath;
        _metadataWaiters = [NSMutableArray array];
        _resumeWaiters = [NSMutableArray array];
        _observers = [NSMutableDictionary dictionary];
        _removed = false;
    }
    return self;
}

/// Runs `body` under the session lock; returns NO if the session is gone.
- (BOOL)locked:(void (^NS_NOESCAPE)(Core &core))body {
    auto core = _core.lock();
    if (!core) return NO;
    std::lock_guard<std::mutex> guard(core->lock);
    body(*core);
    return YES;
}

- (NSString *)infoHash { return BBString(_key); }

- (BOOL)hasMetadata {
    __block BOOL has = NO;
    [self locked:^(Core &) { has = self->_info != nullptr; }];
    return has;
}

- (NSString *)name {
    __block NSString *name = nil;
    [self locked:^(Core &) {
        if (self->_info) name = BBString(self->_info->name());
        else if (!self->_name.empty()) name = BBString(self->_name);
    }];
    return name;
}

- (int64_t)totalSize {
    __block int64_t size = 0;
    [self locked:^(Core &) { if (self->_info) size = self->_info->total_size(); }];
    return size;
}

- (NSInteger)pieceLength {
    __block NSInteger n = 0;
    [self locked:^(Core &) { if (self->_info) n = self->_info->piece_length(); }];
    return n;
}

- (NSInteger)pieceCount {
    __block NSInteger n = 0;
    [self locked:^(Core &) { if (self->_info) n = self->_info->num_pieces(); }];
    return n;
}

- (NSArray<BBTorrentFile *> *)files {
    __block std::shared_ptr<const lt::torrent_info> info;
    [self locked:^(Core &) { info = self->_info; }];
    if (!info) return @[];
    lt::file_storage const &fs = info->layout();
    NSMutableArray *files = [NSMutableArray arrayWithCapacity:fs.num_files()];
    for (int i = 0; i < fs.num_files(); ++i) {
        lt::file_index_t f(i);
        [files addObject:[[BBTorrentFile alloc] initWithIndex:i path:BBString(fs.file_path(f))
                                                         size:fs.file_size(f) offset:fs.file_offset(f)
                                                      padding:fs.pad_file_at(f)]];
    }
    return files;
}

- (NSArray<NSString *> *)users {
    __block NSMutableArray *users = [NSMutableArray array];
    [self locked:^(Core &) {
        for (auto const &u : self->_users) [users addObject:BBString(u)];
    }];
    return users;
}

- (NSString *)savePath {
    __block NSString *path = @"";
    [self locked:^(Core &) { path = BBString(self->_savePath); }];
    return path;
}

// MARK: Metadata

/// Called under the lock when metadata becomes available.
- (void)metadataArrived:(std::vector<Callback> &)callbacks {
    try {
        auto info = _th.torrent_file();
        if (!info || _info) return;
        _info = info;
        _have.assign(static_cast<size_t>(info->num_pieces()), 0);
        [self applyPriorities];
    } catch (...) {
        return;
    }
    for (BBErrorCompletion c in _metadataWaiters) callbacks.push_back(^{ c(nil); });
    [_metadataWaiters removeAllObjects];
}

- (void)waitForMetadataWithTimeout:(NSTimeInterval)timeout completion:(BBErrorCompletion)completion {
    __block BOOL now = NO;
    __block BOOL closed = YES;
    __block dispatch_queue_t queue = nil;
    BBErrorCompletion waiter = [completion copy];
    [self locked:^(Core &core) {
        closed = core.closed || self->_removed;
        if (closed) return;
        if (!self->_info) {
            std::vector<Callback> ignored;
            [self metadataArrived:ignored];  // it may be in without an alert yet
        }
        if (self->_info) { now = YES; return; }
        [self->_metadataWaiters addObject:waiter];
        queue = core.queue;
    }];
    if (closed) { completion(BBError(BBTorrentErrorSessionClosed, @"The torrent session has closed.")); return; }
    if (now) { completion(nil); return; }
    __weak BBTorrentHandle *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.1, timeout) * NSEC_PER_SEC)), queue, ^{
        BBTorrentHandle *strong = weakSelf;
        __block BOOL pending = NO;
        if (strong) {
            [strong locked:^(Core &) {
                NSUInteger i = [strong->_metadataWaiters indexOfObjectIdenticalTo:waiter];
                if (i != NSNotFound) {
                    pending = YES;
                    [strong->_metadataWaiters removeObjectAtIndex:i];
                }
            }];
        }
        if (pending) waiter(BBError(BBTorrentErrorMetadataTimeout, @"No peer sent the torrent's file list in time."));
    });
}

// MARK: Priorities

/// Piece priorities for a focus: only the focused pieces, at the top (under the lock).
- (void)applyFocus {
    if (!_info || _focus.empty()) return;
    // Everything else wanted drops to the lowest priority rather than 0: with
    // nothing else wanted the torrent would count as finished the moment the
    // focus is in, and libtorrent would drop its connections to seeds.
    std::vector<lt::download_priority_t> pieces = [self derivedPiecePriorities];
    for (auto &p : pieces) if (p != lt::dont_download) p = lt::low_priority;
    for (int p : _focus) {
        if (p >= 0 && p < (int)pieces.size()) pieces[(size_t)p] = lt::top_priority;
    }
    try { _th.prioritize_pieces(pieces); } catch (...) {}
}

/// Every user's file priorities merged: the highest wins (under the lock).
- (std::vector<lt::download_priority_t>)mergedFilePriorities {
    int n = _info ? _info->num_files() : 0;
    std::vector<lt::download_priority_t> merged(static_cast<size_t>(n), lt::dont_download);
    for (auto const &[user, prios] : _priorities) {
        for (auto const &[file, prio] : prios) {
            if (file < 0 || file >= n) continue;
            auto p = lt::download_priority_t(static_cast<std::uint8_t>(MAX(0, MIN(7, prio))));
            if (p > merged[static_cast<size_t>(file)]) merged[static_cast<size_t>(file)] = p;
        }
    }
    return merged;
}

/// Each piece at the highest priority of the files it holds bytes of (under the lock).
- (std::vector<lt::download_priority_t>)derivedPiecePriorities {
    if (!_info) return {};
    std::vector<lt::download_priority_t> merged = [self mergedFilePriorities];
    int n = (int)merged.size();
    lt::file_storage const &fs = _info->layout();
    std::int64_t const pieceLength = _info->piece_length();
    std::vector<lt::download_priority_t> pieces(static_cast<size_t>(_info->num_pieces()), lt::dont_download);
    for (int f = 0; f < n; ++f) {
        lt::download_priority_t const prio = merged[static_cast<size_t>(f)];
        std::int64_t const size = fs.file_size(lt::file_index_t(f));
        if (prio == lt::dont_download || size <= 0) continue;
        std::int64_t const start = fs.file_offset(lt::file_index_t(f));
        auto first = static_cast<size_t>(start / pieceLength);
        auto last = std::min(pieces.size() - 1, static_cast<size_t>((start + size - 1) / pieceLength));
        for (size_t p = first; p <= last; ++p) if (prio > pieces[p]) pieces[p] = prio;
    }
    return pieces;
}

/// Hands the merged priorities to libtorrent, or the focus while there is one (under the lock).
- (void)applyPriorities {
    if (!_info) return;
    if (!_focus.empty()) {
        [self applyFocus];
        return;
    }
    // Piece priorities too: libtorrent only re-derives them when the file
    // priorities change, so ending a focus with unchanged files would leave
    // the unfocused pieces where the focus put them.
    try {
        _th.prioritize_files([self mergedFilePriorities]);
        _th.prioritize_pieces([self derivedPiecePriorities]);
    } catch (...) {}
}

- (void)setFilePriorities:(NSDictionary<NSNumber *, NSNumber *> *)priorities forUser:(NSString *)user {
    std::map<int, int> prios;
    for (NSNumber *file in priorities) prios[file.intValue] = priorities[file].intValue;
    std::string u = user.UTF8String;
    [self locked:^(Core &) {
        self->_priorities[u] = prios;
        for (auto const &[file, prio] : prios) {
            if (prio > 0) self->_orphanFiles.erase(file);
        }
        [self applyPriorities];
    }];
}

// MARK: Streaming

- (void)setSequentialFromPiece:(NSInteger)first toPiece:(NSInteger)last {
    try {
        if (first < 0) {
            _th.unset_flags(lt::torrent_flags::sequential_download);
        } else if (last >= first) {
            _th.set_sequential_range(lt::piece_index_t(static_cast<int>(first)), lt::piece_index_t(static_cast<int>(last)));
        } else {
            _th.set_sequential_range(lt::piece_index_t(static_cast<int>(first)));
        }
    } catch (...) {}
}

- (void)setDeadlines:(NSArray<NSNumber *> *)deadlines forPieces:(NSArray<NSNumber *> *)pieces {
    NSInteger count = MIN(deadlines.count, pieces.count);
    __block int limit = 0;
    [self locked:^(Core &) { if (self->_info) limit = self->_info->num_pieces(); }];
    try {
        for (NSInteger i = 0; i < count; ++i) {
            int piece = pieces[i].intValue;
            if (piece < 0 || piece >= limit) continue;
            _th.set_piece_deadline(lt::piece_index_t(piece), MAX(0, deadlines[i].intValue));
        }
    } catch (...) {}
}

- (void)clearDeadlines {
    try { _th.clear_piece_deadlines(); } catch (...) {}
}

- (void)focusOnPieces:(NSArray<NSNumber *> *)pieces {
    [self locked:^(Core &) {
        std::vector<int> focus;
        for (NSNumber *n in pieces) {
            int p = n.intValue;
            if (p >= 0 && p < (int)self->_have.size() && !self->_have[(size_t)p]) focus.push_back(p);
        }
        bool wasFocused = !self->_focus.empty();
        self->_focus = focus;
        if (!focus.empty() || wasFocused) [self applyPriorities];
    }];
}

- (void)clearFocus {
    [self locked:^(Core &) {
        if (self->_focus.empty()) return;
        self->_focus.clear();
        [self applyPriorities];
    }];
}

- (BOOL)havePiece:(NSInteger)piece {
    __block BOOL have = NO;
    [self locked:^(Core &) {
        if (piece >= 0 && piece < (NSInteger)self->_have.size()) have = self->_have[(size_t)piece] != 0;
    }];
    return have;
}

- (NSData *)pieceMap {
    __block NSData *data = [NSData data];
    [self locked:^(Core &) {
        if (!self->_have.empty()) data = [NSData dataWithBytes:self->_have.data() length:self->_have.size()];
    }];
    return data;
}

/// Refreshes the piece map from libtorrent (after a file check), under the lock.
- (void)refreshHave:(std::vector<Callback> &)callbacks {
    if (!_info) return;
    try {
        lt::torrent_status st = _th.status(lt::torrent_handle::query_pieces);
        std::vector<int> fresh;
        for (int i = 0; i < (int)_have.size() && i < st.pieces.size(); ++i) {
            if (st.pieces.get_bit(lt::piece_index_t(i)) && !_have[(size_t)i]) {
                _have[(size_t)i] = 1;
                fresh.push_back(i);
            }
        }
        if (fresh.empty()) return;
        NSArray<BBPieceObserver> *observers = _observers.allValues;
        callbacks.push_back(^{
            for (int piece : fresh) for (BBPieceObserver o in observers) o(piece);
        });
    } catch (...) {}
}

- (NSUUID *)addPieceObserver:(BBPieceObserver)observer {
    NSUUID *token = [NSUUID UUID];
    BBPieceObserver copy = [observer copy];
    [self locked:^(Core &) { self->_observers[token] = copy; }];
    return token;
}

- (void)removePieceObserver:(NSUUID *)token {
    [self locked:^(Core &) { [self->_observers removeObjectForKey:token]; }];
}

- (void)readPiece:(NSInteger)piece completion:(BBDataCompletion)completion {
    __block NSError *failure = nil;
    BBDataCompletion copy = [completion copy];
    [self locked:^(Core &core) {
        if (core.closed || self->_removed) {
            failure = BBError(BBTorrentErrorRemoved, @"The torrent has stopped.");
            return;
        }
        if (piece < 0 || piece >= (NSInteger)self->_have.size()) {
            failure = BBError(BBTorrentErrorInvalidIndex, @"No such piece.");
            return;
        }
        if (!self->_have[(size_t)piece]) {
            failure = BBError(BBTorrentErrorReadFailed, @"That piece hasn't downloaded yet.");
            return;
        }
        auto &waiting = self->_reads[(int)piece];
        if (waiting == nil) {
            waiting = [NSMutableArray array];
            [waiting addObject:copy];
            try {
                self->_th.read_piece(lt::piece_index_t(static_cast<int>(piece)));
            } catch (std::exception const &e) {
                self->_reads.erase((int)piece);
                failure = BBError(BBTorrentErrorReadFailed, BBString(e.what()));
            }
        } else {
            [waiting addObject:copy];
        }
    }];
    if (failure) completion(nil, failure);
}

// MARK: Status

- (NSArray<NSNumber *> *)fileProgress {
    return [self fileProgressWithFlags:lt::torrent_handle::piece_granularity];
}

- (NSArray<NSNumber *> *)fileProgressIncludingPartialPieces {
    return [self fileProgressWithFlags:{}];
}

- (NSArray<NSNumber *> *)fileProgressWithFlags:(lt::file_progress_flags_t)flags {
    try {
        std::vector<std::int64_t> progress = _th.file_progress(flags);
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:progress.size()];
        for (auto v : progress) [out addObject:@(v)];
        return out;
    } catch (...) {
        return @[];
    }
}

- (BBTorrentStatus *)status {
    BBTorrentStatus *s = [BBTorrentStatus new];
    try {
        lt::torrent_status st = _th.status({});
        s.state = static_cast<BBTorrentState>(st.state);
        s.isPaused = (st.flags & lt::torrent_flags::paused) ? YES : NO;
        s.hasMetadata = st.has_metadata;
        s.downloadRate = st.download_payload_rate;
        s.uploadRate = st.upload_payload_rate;
        s.peers = st.num_peers;
        s.seeds = st.num_seeds;
        s.knownPeers = st.list_peers;
        s.connectCandidates = st.connect_candidates;
        s.wantedDone = st.total_wanted_done;
        s.wanted = st.total_wanted;
        s.downloadedBytes = st.total_payload_download;
        s.uploadedBytes = st.total_payload_upload;
        s.savePath = BBString(st.save_path);
        if (st.errc) s.errorMessage = BBString(st.errc.message());
    } catch (std::exception const &e) {
        s.errorMessage = BBString(e.what());
        s.savePath = @"";
    }
    __block NSString *err = nil;
    __block NSInteger failures = 0;
    [self locked:^(Core &) {
        if (!self->_error.empty()) err = BBString(self->_error);
        failures = self->_hashFailures;
    }];
    if (!s.errorMessage) s.errorMessage = err;
    s.hashFailures = failures;
    return s;
}

// MARK: Control

- (void)pause {
    try { _th.unset_flags(lt::torrent_flags::auto_managed); _th.pause(); } catch (...) {}
}

- (void)resume {
    try { _th.clear_error(); _th.resume(); } catch (...) {}
    [self locked:^(Core &) { self->_error.clear(); }];
}

- (void)reannounce {
    try {
        _th.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
        _th.force_dht_announce();
        _th.force_lsd_announce();
    } catch (...) {}
}

- (void)addTrackers:(NSArray<NSString *> *)urls {
    try {
        for (NSString *url in urls) {
            lt::announce_entry e(url.UTF8String);
            e.tier = 1;
            _th.add_tracker(e);
        }
    } catch (...) {}
}

- (void)setUploadLimit:(NSInteger)bytesPerSecond {
    try { _th.set_upload_limit(static_cast<int>(MAX(0, bytesPerSecond))); } catch (...) {}
}

- (void)moveStorageToPath:(NSString *)path {
    std::string p = path.UTF8String;
    [self locked:^(Core &) { self->_savePath = p; }];
    try { _th.move_storage(p, lt::move_flags_t::dont_replace); } catch (...) {}
}

- (void)saveResumeDataWithCompletion:(BBDataCompletion)completion {
    __block NSError *failure = nil;
    BBDataCompletion copy = [completion copy];
    [self locked:^(Core &core) {
        if (core.closed || self->_removed) {
            failure = BBError(BBTorrentErrorRemoved, @"The torrent has stopped.");
            return;
        }
        [self->_resumeWaiters addObject:copy];
        try {
            self->_th.save_resume_data(lt::torrent_handle::save_info_dict | lt::torrent_handle::flush_disk_cache);
        } catch (std::exception const &e) {
            [self->_resumeWaiters removeLastObject];
            failure = BBError(BBTorrentErrorResumeData, BBString(e.what()));
        }
    }];
    if (failure) completion(nil, failure);
}

/// Fails everything pending (under the lock) once the torrent or session is gone.
- (void)failPending:(NSError *)error into:(std::vector<Callback> &)callbacks {
    _removed = true;
    for (BBErrorCompletion c in _metadataWaiters) callbacks.push_back(^{ c(error); });
    [_metadataWaiters removeAllObjects];
    for (auto &[piece, waiters] : _reads) {
        for (BBDataCompletion c in waiters) callbacks.push_back(^{ c(nil, error); });
    }
    _reads.clear();
    for (BBDataCompletion c in _resumeWaiters) callbacks.push_back(^{ c(nil, error); });
    [_resumeWaiters removeAllObjects];
    [_observers removeAllObjects];
}

@end

// MARK: - Session

@implementation BBTorrentSession {
    std::shared_ptr<Core> _core;
}

+ (NSString *)libtorrentVersion { return @LIBTORRENT_VERSION; }

- (instancetype)initWithConfiguration:(BBSessionConfiguration *)configuration state:(NSData *)state {
    if ((self = [super init])) {
        _core = std::make_shared<Core>();
        _core->queue = dispatch_queue_create("app.bluebox.torrent.alerts", DISPATCH_QUEUE_SERIAL);
        _core->recvIndex = lt::find_metric_idx("net.recv_bytes");
        _core->sentIndex = lt::find_metric_idx("net.sent_bytes");
        _core->dhtNodesIndex = lt::find_metric_idx("dht.dht_nodes");

        lt::session_params params;
        if (state.length > 0) {
            try {
                params = lt::read_session_params({static_cast<char const *>(state.bytes), static_cast<std::ptrdiff_t>(state.length)},
                                                 lt::session_handle::save_dht_state);
            } catch (...) {
                params = lt::session_params();
            }
        }
        params.settings = [configuration settingsPack];
        _core->session = std::make_unique<lt::session>(std::move(params));

        std::weak_ptr<Core> weak = _core;
        _core->session->set_alert_notify([weak] {
            auto core = weak.lock();
            if (!core) return;
            bool expected = false;
            if (!core->drainScheduled.compare_exchange_strong(expected, true)) return;
            dispatch_async(core->queue, ^{
                core->drainScheduled = false;
                [BBTorrentSession drain:core];
            });
        });
        [self scheduleStats];
        [BBTorrentSession registerExitGuard:self];
    }
    return self;
}

- (void)dealloc {
    [self shutdownWithTimeout:0];
}

// MARK: Exit guard

/// If the app never called -shutdownWithTimeout:, shut down from atexit()
/// so libtorrent's threads stop before C++ static destructors run.
static __weak BBTorrentSession *BBLiveSession = nil;

+ (void)registerExitGuard:(BBTorrentSession *)session {
    BBLiveSession = session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        atexit_b(^{ [BBLiveSession shutdownWithTimeout:0.5]; });
    });
}

// MARK: Stats

- (void)scheduleStats {
    std::weak_ptr<Core> weak = _core;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _core->queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    __block dispatch_source_t keep = timer;
    dispatch_source_set_event_handler(timer, ^{
        auto core = weak.lock();
        if (!core) { dispatch_source_cancel(keep); keep = nil; return; }
        std::lock_guard<std::mutex> guard(core->lock);
        if (core->closed || !core->session) { dispatch_source_cancel(keep); keep = nil; return; }
        try { core->session->post_session_stats(); } catch (...) {}
    });
    dispatch_resume(timer);
}

// MARK: Alerts

+ (void)drain:(std::shared_ptr<Core> const &)core {
    std::vector<Callback> callbacks;
    std::vector<std::string> unlinkNow;
    {
        std::lock_guard<std::mutex> guard(core->lock);
        if (core->closed || !core->session) return;
        std::vector<lt::alert *> alerts;
        try { core->session->pop_alerts(&alerts); } catch (...) { return; }
        for (lt::alert *a : alerts) {
            [self handle:a core:*core callbacks:callbacks unlink:unlinkNow];
        }
    }
    BBRun(callbacks);
    for (auto const &path : unlinkNow) ::unlink(path.c_str());
}

+ (BBTorrentHandle *)find:(lt::torrent_handle const &)th core:(Core &)core {
    auto it = core.byHandle.find(th);
    return it == core.byHandle.end() ? nil : it->second;
}

+ (void)handle:(lt::alert *)a core:(Core &)core callbacks:(std::vector<Callback> &)callbacks
        unlink:(std::vector<std::string> &)unlinkNow {
    if (auto *p = lt::alert_cast<lt::piece_finished_alert>(a)) {
        BBTorrentHandle *h = [self find:p->handle core:core];
        int piece = static_cast<int>(p->piece_index);
        if (!h || piece < 0 || piece >= (int)h->_have.size()) return;
        h->_have[(size_t)piece] = 1;
        if (!h->_focus.empty()) {
            auto it = std::find(h->_focus.begin(), h->_focus.end(), piece);
            if (it != h->_focus.end()) {
                h->_focus.erase(it);
                if (h->_focus.empty()) [h applyPriorities];  // focus done: back to the files
            }
        }
        NSArray<BBPieceObserver> *observers = h->_observers.allValues;
        if (observers.count) callbacks.push_back(^{ for (BBPieceObserver o in observers) o(piece); });
    } else if (auto *r = lt::alert_cast<lt::read_piece_alert>(a)) {
        BBTorrentHandle *h = [self find:r->handle core:core];
        if (!h) return;
        int piece = static_cast<int>(r->piece);
        auto it = h->_reads.find(piece);
        if (it == h->_reads.end()) return;
        NSArray<BBDataCompletion> *waiters = it->second;
        h->_reads.erase(it);
        if (r->error || !r->buffer) {
            NSError *error = BBError(BBTorrentErrorReadFailed, BBString(r->error.message()));
            callbacks.push_back(^{ for (BBDataCompletion c in waiters) c(nil, error); });
        } else {
            auto *holder = new boost::shared_array<char>(r->buffer);
            NSData *data = [[NSData alloc] initWithBytesNoCopy:holder->get() length:static_cast<NSUInteger>(r->size)
                                                   deallocator:^(void *, NSUInteger) { delete holder; }];
            callbacks.push_back(^{ for (BBDataCompletion c in waiters) c(data, nil); });
        }
    } else if (auto *m = lt::alert_cast<lt::metadata_received_alert>(a)) {
        BBTorrentHandle *h = [self find:m->handle core:core];
        [h metadataArrived:callbacks];
    } else if (auto *c = lt::alert_cast<lt::torrent_checked_alert>(a)) {
        BBTorrentHandle *h = [self find:c->handle core:core];
        if (h && !h->_info) [h metadataArrived:callbacks];
        [h refreshHave:callbacks];
        // libtorrent re-derives piece priorities from file priorities once the
        // files are checked, which would undo a focus set before that.
        [h applyFocus];
    } else if (auto *fp = lt::alert_cast<lt::file_prio_alert>(a)) {
        // File priorities land after a disk round trip and reset every
        // piece's priority: put the focus back on top of them.
        BBTorrentHandle *h = [self find:fp->handle core:core];
        [h applyFocus];
    } else if (auto *s = lt::alert_cast<lt::save_resume_data_alert>(a)) {
        BBTorrentHandle *h = [self find:s->handle core:core];
        if (!h || h->_resumeWaiters.count == 0) return;
        BBDataCompletion done = h->_resumeWaiters.firstObject;
        [h->_resumeWaiters removeObjectAtIndex:0];
        std::vector<char> buf = lt::write_resume_data_buf(s->params);
        NSData *data = [NSData dataWithBytes:buf.data() length:buf.size()];
        callbacks.push_back(^{ done(data, nil); });
    } else if (auto *f = lt::alert_cast<lt::save_resume_data_failed_alert>(a)) {
        BBTorrentHandle *h = [self find:f->handle core:core];
        if (!h || h->_resumeWaiters.count == 0) return;
        BBDataCompletion done = h->_resumeWaiters.firstObject;
        [h->_resumeWaiters removeObjectAtIndex:0];
        NSError *error = BBError(BBTorrentErrorResumeData, BBString(f->error.message()));
        callbacks.push_back(^{ done(nil, error); });
    } else if (auto *hf = lt::alert_cast<lt::hash_failed_alert>(a)) {
        BBTorrentHandle *h = [self find:hf->handle core:core];
        if (h) h->_hashFailures += 1;
    } else if (auto *e = lt::alert_cast<lt::torrent_error_alert>(a)) {
        BBTorrentHandle *h = [self find:e->handle core:core];
        if (h) h->_error = e->error.message();
    } else if (auto *fe = lt::alert_cast<lt::file_error_alert>(a)) {
        BBTorrentHandle *h = [self find:fe->handle core:core];
        if (h) h->_error = fe->error.message() + " (" + fe->filename() + ")";
    } else if (auto *rm = lt::alert_cast<lt::torrent_removed_alert>(a)) {
        for (auto it = core.unlinks.begin(); it != core.unlinks.end(); ++it) {
            if (it->hashes == rm->info_hashes) {
                unlinkNow.insert(unlinkNow.end(), it->paths.begin(), it->paths.end());
                core.unlinks.erase(it);
                break;
            }
        }
    } else if (auto *st = lt::alert_cast<lt::session_stats_alert>(a)) {
        auto counters = st->counters();
        if (core.recvIndex >= 0) core.bytesReceived = counters[core.recvIndex];
        if (core.sentIndex >= 0) core.bytesSent = counters[core.sentIndex];
        if (core.dhtNodesIndex >= 0) core.dhtNodes = counters[core.dhtNodesIndex];
    }
}

// MARK: Configuration

- (void)applyConfiguration:(BBSessionConfiguration *)configuration {
    lt::settings_pack pack = [configuration settingsPack];
    std::lock_guard<std::mutex> guard(_core->lock);
    if (_core->closed || !_core->session) return;
    try { _core->session->apply_settings(std::move(pack)); } catch (...) {}
}

- (BOOL)setSetting:(NSString *)name integer:(NSInteger)value {
    int index = lt::setting_by_name(name.UTF8String ?: "");
    if (index < 0 || (index & lt::settings_pack::type_mask) != lt::settings_pack::int_type_base) return NO;
    lt::settings_pack p;
    p.set_int(index, static_cast<int>(value));
    std::lock_guard<std::mutex> guard(_core->lock);
    if (_core->closed || !_core->session) return NO;
    try { _core->session->apply_settings(std::move(p)); } catch (...) { return NO; }
    return YES;
}

- (BOOL)setSetting:(NSString *)name boolean:(BOOL)value {
    int index = lt::setting_by_name(name.UTF8String ?: "");
    if (index < 0 || (index & lt::settings_pack::type_mask) != lt::settings_pack::bool_type_base) return NO;
    lt::settings_pack p;
    p.set_bool(index, value);
    std::lock_guard<std::mutex> guard(_core->lock);
    if (_core->closed || !_core->session) return NO;
    try { _core->session->apply_settings(std::move(p)); } catch (...) { return NO; }
    return YES;
}

// MARK: Torrents

- (BBTorrentHandle *)acquireTorrentWithLink:(NSString *)link trackers:(NSArray<NSString *> *)trackers
                                   savePath:(NSString *)savePath resumeData:(NSData *)resumeData
                                       user:(NSString *)user
                                 priorities:(NSDictionary<NSNumber *, NSNumber *> *)priorities
                                      error:(NSError **)error {
    lt::add_torrent_params magnet;
    lt::error_code ec;
    NSString *trimmed = [link stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    std::string uri = trimmed.UTF8String ?: "";
    if (![trimmed.lowercaseString hasPrefix:@"magnet:"]) {
        // A bare hash: 40 hex or 32 base32 characters (v1), or 64 hex (v2).
        uri = (trimmed.length == 64 ? "magnet:?xt=urn:btmh:1220" : "magnet:?xt=urn:btih:") + uri;
    }
    lt::parse_magnet_uri(uri, magnet, ec);
    if (ec || !(magnet.info_hashes.has_v1() || magnet.info_hashes.has_v2())) {
        if (error) *error = BBError(BBTorrentErrorInvalidLink, @"That torrent link isn't valid.");
        return nil;
    }
    std::string key = BBKey(magnet.info_hashes);
    std::string u = user.UTF8String;
    std::map<int, int> userPrios;
    for (NSNumber *file in priorities) userPrios[file.intValue] = priorities[file].intValue;

    std::lock_guard<std::mutex> guard(_core->lock);
    if (_core->closed || !_core->session) {
        if (error) *error = BBError(BBTorrentErrorSessionClosed, @"The torrent session has closed.");
        return nil;
    }

    // Already in the session (streaming and downloading the same torrent): join it.
    auto existing = _core->byKey.find(key);
    if (existing != _core->byKey.end()) {
        BBTorrentHandle *h = existing->second;
        if (std::find(h->_users.begin(), h->_users.end(), u) == h->_users.end()) h->_users.push_back(u);
        if (priorities) {
            h->_priorities[u] = userPrios;
            for (auto const &[file, prio] : userPrios) if (prio > 0) h->_orphanFiles.erase(file);
            [h applyPriorities];
        }
        try { h->_th.resume(); } catch (...) {}
        [h addTrackers:trackers];
        return h;
    }

    lt::add_torrent_params atp;
    bool resumed = false;
    if (resumeData.length > 0) {
        lt::error_code rec;
        atp = lt::read_resume_data({static_cast<char const *>(resumeData.bytes), static_cast<std::ptrdiff_t>(resumeData.length)}, rec);
        resumed = !rec && BBKey(atp.info_hashes) == key;
        if (!resumed) atp = lt::add_torrent_params();
    }
    if (!resumed) atp = magnet;
    for (auto const &t : magnet.trackers) {
        if (std::find(atp.trackers.begin(), atp.trackers.end(), t) == atp.trackers.end()) atp.trackers.push_back(t);
    }
    for (NSString *t in trackers) {
        std::string s = t.UTF8String;
        if (std::find(atp.trackers.begin(), atp.trackers.end(), s) == atp.trackers.end()) atp.trackers.push_back(s);
    }
    if (atp.name.empty()) atp.name = magnet.name;
    atp.save_path = savePath.UTF8String;
    // Nothing downloads until a user asks for a file; torrents start at once,
    // outside libtorrent's queue.
    atp.flags |= lt::torrent_flags::default_dont_download;
    atp.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed
                   | lt::torrent_flags::duplicate_is_error | lt::torrent_flags::sequential_download);
    if (!userPrios.empty()) {
        // A file known up front (a stream whose add-on named it): download it
        // in order from the moment metadata arrives.
        atp.flags |= lt::torrent_flags::sequential_download;
        int top = userPrios.rbegin()->first;
        if (top >= 0 && top < 100000) {
            atp.file_priorities.assign(static_cast<size_t>(top + 1), lt::dont_download);
            for (auto const &[file, prio] : userPrios) {
                if (file >= 0) atp.file_priorities[static_cast<size_t>(file)] =
                    lt::download_priority_t(static_cast<std::uint8_t>(MAX(0, MIN(7, prio))));
            }
        }
    } else if (resumed) {
        atp.file_priorities.clear();
    }

    lt::torrent_handle th;
    try {
        th = _core->session->add_torrent(std::move(atp), ec);
    } catch (std::exception const &e) {
        if (error) *error = BBError(BBTorrentErrorAddFailed, BBString(e.what()));
        return nil;
    }
    if (ec || !th.is_valid()) {
        if (error) *error = BBError(BBTorrentErrorAddFailed, BBString(ec.message()));
        return nil;
    }
    BBTorrentHandle *h = [[BBTorrentHandle alloc] initWithCore:_core handle:th key:key savePath:savePath.UTF8String];
    h->_users.push_back(u);
    if (priorities) h->_priorities[u] = userPrios;
    h->_name = magnet.name;
    _core->byKey[key] = h;
    _core->byHandle[th] = h;
    std::vector<Callback> ignored;
    [h metadataArrived:ignored];  // resume data with the info dictionary
    return h;
}

- (BOOL)releaseTorrent:(BBTorrentHandle *)handle user:(NSString *)user deleteFiles:(BOOL)deleteFiles {
    std::string u = user.UTF8String;
    std::vector<Callback> callbacks;
    BOOL removed = NO;
    {
        std::lock_guard<std::mutex> guard(_core->lock);
        if (_core->closed || !_core->session) return NO;
        auto it = _core->byKey.find(handle->_key);
        if (it == _core->byKey.end() || it->second != handle) return NO;
        BBTorrentHandle *h = handle;
        auto users = std::find(h->_users.begin(), h->_users.end(), u);
        if (users == h->_users.end()) return NO;
        h->_users.erase(users);

        // Files this user wanted that nobody else does.
        std::set<int> mine;
        for (auto const &[file, prio] : h->_priorities[u]) if (prio > 0) mine.insert(file);
        h->_priorities.erase(u);
        for (auto const &[other, prios] : h->_priorities) {
            for (auto const &[file, prio] : prios) if (prio > 0) mine.erase(file);
        }
        // A file another user released keeping it (a finished download) is
        // never deleted by a later user's release.
        for (int file : mine) {
            if (deleteFiles) { if (!h->_keptFiles.count(file)) h->_orphanFiles.insert(file); }
            else { h->_keptFiles.insert(file); h->_orphanFiles.erase(file); }
        }

        if (!h->_users.empty()) {
            [h applyPriorities];
            return NO;
        }

        // Last user: the torrent leaves the session.
        lt::remove_flags_t flags{};
        PendingUnlink pending;
        pending.hashes = h->_th.info_hashes();
        if (deleteFiles && h->_keptFiles.empty()) {
            flags = lt::session_handle::delete_files | lt::session_handle::delete_partfile;
        } else if (h->_info) {
            lt::file_storage const &fs = h->_info->layout();
            for (int file : h->_orphanFiles) {
                if (file >= 0 && file < fs.num_files()) {
                    pending.paths.push_back(fs.file_path(lt::file_index_t(file), h->_savePath));
                }
            }
        }
        if (!pending.paths.empty()) _core->unlinks.push_back(pending);
        try { _core->session->remove_torrent(h->_th, flags); } catch (...) {}
        _core->byKey.erase(h->_key);
        _core->byHandle.erase(h->_th);
        [h failPending:BBError(BBTorrentErrorRemoved, @"The torrent has stopped.") into:callbacks];
        removed = YES;
    }
    BBRun(callbacks);
    return removed;
}

- (BBTorrentHandle *)torrentWithInfoHash:(NSString *)infoHash {
    std::string key = infoHash.lowercaseString.UTF8String;
    std::lock_guard<std::mutex> guard(_core->lock);
    auto it = _core->byKey.find(key);
    return it == _core->byKey.end() ? nil : it->second;
}

- (NSArray<BBTorrentHandle *> *)torrents {
    NSMutableArray *out = [NSMutableArray array];
    std::lock_guard<std::mutex> guard(_core->lock);
    for (auto const &[key, h] : _core->byKey) [out addObject:h];
    return out;
}

- (BBSessionStats *)stats {
    BBSessionStats *s = [BBSessionStats new];
    std::lock_guard<std::mutex> guard(_core->lock);
    s.bytesReceived = _core->bytesReceived;
    s.bytesSent = _core->bytesSent;
    s.dhtNodes = (NSInteger)_core->dhtNodes;
    s.torrents = (NSInteger)_core->byKey.size();
    if (!_core->closed && _core->session) {
        try { s.listenPort = _core->session->is_listening() ? _core->session->listen_port() : 0; } catch (...) {}
    }
    return s;
}

- (NSData *)sessionState {
    std::lock_guard<std::mutex> guard(_core->lock);
    if (_core->closed || !_core->session) return nil;
    try {
        lt::session_params params = _core->session->session_state(lt::session_handle::save_dht_state);
        std::vector<char> buf = lt::write_session_params_buf(params, lt::session_handle::save_dht_state);
        return [NSData dataWithBytes:buf.data() length:buf.size()];
    } catch (...) {
        return nil;
    }
}

- (void)networkChanged {
    std::lock_guard<std::mutex> guard(_core->lock);
    if (_core->closed || !_core->session) return;
    try { _core->session->reopen_network_sockets(); } catch (...) {}
    for (auto const &[key, h] : _core->byKey) [h reannounce];
}

- (BOOL)isShutDown {
    std::lock_guard<std::mutex> guard(_core->lock);
    return _core->closed;
}

- (void)shutdownWithTimeout:(NSTimeInterval)timeout {
    std::unique_ptr<lt::session> session;
    std::vector<Callback> callbacks;
    {
        std::lock_guard<std::mutex> guard(_core->lock);
        if (_core->closed) return;
        _core->closed = true;
        session = std::move(_core->session);
        NSError *closed = BBError(BBTorrentErrorSessionClosed, @"The torrent session has closed.");
        for (auto const &[key, h] : _core->byKey) [h failPending:closed into:callbacks];
        _core->byKey.clear();
        _core->byHandle.clear();
    }
    if (session) {
        try {
            lt::settings_pack p;
            p.set_int(lt::settings_pack::stop_tracker_timeout, static_cast<int>(MAX(0, MIN(10, timeout))));
            session->apply_settings(std::move(p));
            session->set_alert_notify([] {});
            // abort() starts closing (trackers hear "stopped"); destroying the
            // proxy waits for libtorrent's threads to finish.
            lt::session_proxy proxy = session->abort();
            session.reset();
            { lt::session_proxy done = std::move(proxy); }
        } catch (...) {
            session.reset();
        }
    }
    BBRun(callbacks);
}

@end
