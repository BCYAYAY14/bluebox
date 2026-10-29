//
//  BBTorrent.h
//  Bluebox
//
//  A small Objective-C interface to libtorrent 2.x for Bluebox's streaming
//  and downloads. Written for Bluebox from libtorrent's public documentation
//  and headers (libtorrent.org, include/libtorrent/*.hpp).
//
//  Model:
//  - One BBTorrentSession per process. It owns the libtorrent session, pumps
//    its alerts on a private queue, and must be shut down (-shutdownWithTimeout:)
//    before the process exits.
//  - One BBTorrentHandle per info hash. Streaming and downloading the same
//    torrent share it: each caller "acquires" it under a user name, sets the
//    files it wants for that user, and releases it when done. File priorities
//    are merged (the highest wins), and the torrent leaves the session when
//    its last user releases it.
//  - Everything is thread-safe. Completion blocks and observers are called
//    on the session's private queue; don't block in them.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const BBTorrentErrorDomain;

typedef NS_ERROR_ENUM(BBTorrentErrorDomain, BBTorrentError) {
    /// The magnet link or info hash couldn't be parsed.
    BBTorrentErrorInvalidLink = 1,
    /// libtorrent refused to add the torrent.
    BBTorrentErrorAddFailed = 2,
    /// No peer sent the file list in time.
    BBTorrentErrorMetadataTimeout = 3,
    /// The call needs the file list, which hasn't arrived yet.
    BBTorrentErrorNoMetadata = 4,
    /// Reading a piece back from disk failed.
    BBTorrentErrorReadFailed = 5,
    /// The torrent left the session while the call was pending.
    BBTorrentErrorRemoved = 6,
    /// The session has shut down.
    BBTorrentErrorSessionClosed = 7,
    /// A piece or file index is out of range.
    BBTorrentErrorInvalidIndex = 8,
    /// Saving resume data failed.
    BBTorrentErrorResumeData = 9,
};

/// libtorrent's torrent states.
typedef NS_ENUM(NSInteger, BBTorrentState) {
    BBTorrentStateCheckingFiles = 1,
    BBTorrentStateDownloadingMetadata = 2,
    BBTorrentStateDownloading = 3,
    BBTorrentStateFinished = 4,
    BBTorrentStateSeeding = 5,
    BBTorrentStateCheckingResumeData = 7,
};

/// Session-wide settings. Apply changes with -[BBTorrentSession applyConfiguration:].
NS_SWIFT_SENDABLE
@interface BBSessionConfiguration : NSObject <NSCopying>
/// Peer connections across all torrents.
@property (nonatomic) NSInteger connectionsLimit;
/// Port to listen on (TCP and uTP); 0 lets the system choose.
@property (nonatomic) NSInteger listenPort;
/// Bytes per second; 0 means unlimited.
@property (nonatomic) NSInteger uploadRateLimit;
/// Bytes per second; 0 means unlimited.
@property (nonatomic) NSInteger downloadRateLimit;
@property (nonatomic) BOOL enableDHT;
/// Local Service Discovery (multicast on the local network).
@property (nonatomic) BOOL enableLSD;
/// Accept uTP (BEP 29) connections from peers.
@property (nonatomic) BOOL enableUTP;
/// Also open uTP connections to peers. Off by default: on Bluebox's start-up
/// measurements TCP connections reach full speed several seconds sooner
/// (uTP's delay-based congestion control ramps slowly); turn it on when a
/// swarm is thin, since some peers can only be reached over uTP.
@property (nonatomic) BOOL enableOutgoingUTP;
/// UPnP and NAT-PMP port mapping.
@property (nonatomic) BOOL enablePortMapping;
/// Bytes of written blocks the disk queue may hold before peers are throttled.
@property (nonatomic) NSInteger diskQueueBytes;
/// Smaller buffers and peer lists, for iPhone and iPad.
@property (nonatomic) BOOL lowMemory;
/// "host:port" DHT bootstrap nodes, used when the saved routing table is empty or stale.
@property (nonatomic, copy) NSArray<NSString *> *dhtBootstrapNodes;
/// Defaults tuned for streaming: uTP, DHT and LSD on, fast connects.
- (instancetype)init NS_DESIGNATED_INITIALIZER;
@end

/// One file in a torrent.
NS_SWIFT_SENDABLE
@interface BBTorrentFile : NSObject
@property (nonatomic, readonly) NSInteger index;
/// Path inside the torrent, including the torrent's folder for multi-file torrents.
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) int64_t size;
/// Byte offset of the file within the torrent's concatenated data.
@property (nonatomic, readonly) int64_t offset;
/// Padding files (BEP 47) hold no data and should be skipped.
@property (nonatomic, readonly) BOOL isPadding;
@end

/// A snapshot of one torrent.
NS_SWIFT_SENDABLE
@interface BBTorrentStatus : NSObject
@property (nonatomic, readonly) BBTorrentState state;
@property (nonatomic, readonly) BOOL isPaused;
@property (nonatomic, readonly) BOOL hasMetadata;
/// Payload bytes per second.
@property (nonatomic, readonly) NSInteger downloadRate;
@property (nonatomic, readonly) NSInteger uploadRate;
/// Connected peers, and how many of them are seeds.
@property (nonatomic, readonly) NSInteger peers;
@property (nonatomic, readonly) NSInteger seeds;
/// Peers known but not connected (from trackers, DHT, PEX).
@property (nonatomic, readonly) NSInteger knownPeers;
@property (nonatomic, readonly) NSInteger connectCandidates;
/// Bytes of the wanted files we have, and their total.
@property (nonatomic, readonly) int64_t wantedDone;
@property (nonatomic, readonly) int64_t wanted;
/// Payload bytes moved this session.
@property (nonatomic, readonly) int64_t downloadedBytes;
@property (nonatomic, readonly) int64_t uploadedBytes;
@property (nonatomic, readonly, copy) NSString *savePath;
/// Set when libtorrent stopped the torrent for an error (disk full, permission…).
@property (nonatomic, readonly, copy, nullable) NSString *errorMessage;
/// Pieces that failed their hash check (bad data from a peer) since the torrent was added.
@property (nonatomic, readonly) NSInteger hashFailures;
@end

/// Totals for the whole session.
NS_SWIFT_SENDABLE
@interface BBSessionStats : NSObject
/// All bytes received and sent since the session started, protocol overhead included.
@property (nonatomic, readonly) int64_t bytesReceived;
@property (nonatomic, readonly) int64_t bytesSent;
@property (nonatomic, readonly) NSInteger dhtNodes;
@property (nonatomic, readonly) NSInteger torrents;
/// The port actually listened on; 0 when not listening.
@property (nonatomic, readonly) NSInteger listenPort;
@end

typedef void (^BBPieceObserver)(int piece) NS_SWIFT_SENDABLE;
typedef void (^BBErrorCompletion)(NSError *_Nullable error) NS_SWIFT_SENDABLE;
typedef void (^BBDataCompletion)(NSData *_Nullable data, NSError *_Nullable error) NS_SWIFT_SENDABLE;

/// A torrent in the session, shared by every user of its info hash.
NS_SWIFT_SENDABLE
@interface BBTorrentHandle : NSObject
- (instancetype)init NS_UNAVAILABLE;

/// v1 info hash in lowercase hex (40 characters), or the v2 hash (64) for v2-only torrents.
@property (nonatomic, readonly, copy) NSString *infoHash;
@property (nonatomic, readonly) BOOL hasMetadata;
/// Torrent name from the metadata (or the magnet's dn until then).
@property (nonatomic, readonly, copy, nullable) NSString *name;
/// Zero before metadata.
@property (nonatomic, readonly) int64_t totalSize;
@property (nonatomic, readonly) NSInteger pieceLength;
@property (nonatomic, readonly) NSInteger pieceCount;
/// Empty before metadata.
@property (nonatomic, readonly, copy) NSArray<BBTorrentFile *> *files;
@property (nonatomic, readonly, copy) NSArray<NSString *> *users;
/// Where the torrent's files live (the save path it was first added with, or the last move).
@property (nonatomic, readonly, copy) NSString *savePath;

/// Calls back once metadata is in (at once if it already is), or with
/// BBTorrentErrorMetadataTimeout after `timeout` seconds.
- (void)waitForMetadataWithTimeout:(NSTimeInterval)timeout completion:(BBErrorCompletion)completion
    NS_SWIFT_NAME(waitForMetadata(timeout:completion:));

/// The files `user` wants, as file index → priority (1 low … 7 top). Files
/// not listed are 0 for this user. The torrent downloads each file at the
/// highest priority any user gives it. Can be set before metadata arrives.
- (void)setFilePriorities:(NSDictionary<NSNumber *, NSNumber *> *)priorities forUser:(NSString *)user
    NS_SWIFT_NAME(setFilePriorities(_:user:));

/// Downloads pieces in order from `first` through `last` (inclusive), ahead
/// of the rest; pieces with deadlines still come first. Pass -1 to turn
/// sequential mode off.
- (void)setSequentialFromPiece:(NSInteger)first toPiece:(NSInteger)last
    NS_SWIFT_NAME(setSequential(from:to:));

/// Time-critical download: libtorrent requests these pieces ahead of all
/// others, earliest deadline first, from the fastest peers. `deadlines` are
/// milliseconds from now, one per piece in `pieces`.
- (void)setDeadlines:(NSArray<NSNumber *> *)deadlines forPieces:(NSArray<NSNumber *> *)pieces
    NS_SWIFT_NAME(setDeadlines(_:pieces:));
- (void)clearDeadlines;

/// Downloads only these pieces (top priority) until -clearFocus, pausing
/// everything else: deadlines alone lose to the deep request queues of fast
/// peers, so the player's first reads (and the reads after a seek) are
/// fetched with the whole swarm's bandwidth. Pieces already in are ignored;
/// the focus ends by itself once every focused piece is in.
- (void)focusOnPieces:(NSArray<NSNumber *> *)pieces NS_SWIFT_NAME(focus(on:));
/// Back to the users' file priorities.
- (void)clearFocus;

- (BOOL)havePiece:(NSInteger)piece;
/// One byte per piece: 1 when the piece is downloaded and checked.
- (NSData *)pieceMap;

/// Every observer is called on each piece that passes its hash check.
- (NSUUID *)addPieceObserver:(BBPieceObserver)observer;
- (void)removePieceObserver:(NSUUID *)token;

/// Reads a downloaded piece back (from libtorrent's cache or disk).
/// Concurrent reads of one piece share a single disk read.
- (void)readPiece:(NSInteger)piece completion:(BBDataCompletion)completion
    NS_SWIFT_NAME(readPiece(_:completion:));

/// Bytes downloaded of each file (pieces that passed their check only).
- (NSArray<NSNumber *> *)fileProgress;
/// Bytes downloaded of each file, counting blocks of pieces still arriving
/// (not checked yet). For showing progress; `fileProgress` decides completion.
- (NSArray<NSNumber *> *)fileProgressIncludingPartialPieces;
- (BBTorrentStatus *)status;

- (void)pause;
- (void)resume;
/// Asks trackers, the DHT and LSD for peers now, ignoring announce intervals.
- (void)reannounce;
- (void)addTrackers:(NSArray<NSString *> *)urls;
/// Bytes per second for this torrent; 0 means only the session limit applies.
- (void)setUploadLimit:(NSInteger)bytesPerSecond;
/// Moves the files to `path` (libtorrent keeps working during the move).
- (void)moveStorageToPath:(NSString *)path;

/// Bencoded resume data (with the info dictionary), for -acquire…resumeData:.
- (void)saveResumeDataWithCompletion:(BBDataCompletion)completion
    NS_SWIFT_NAME(saveResumeData(completion:));
@end

NS_SWIFT_SENDABLE
@interface BBTorrentSession : NSObject
@property (class, nonatomic, readonly, copy) NSString *libtorrentVersion;

/// Starts libtorrent. `state` is data from a previous -sessionState (the DHT
/// node ID and routing table), so the DHT starts warm.
- (instancetype)initWithConfiguration:(BBSessionConfiguration *)configuration
                                state:(nullable NSData *)state NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)applyConfiguration:(BBSessionConfiguration *)configuration;

/// Sets any libtorrent setting by its settings_pack name ("whole_pieces_threshold",
/// "enable_lsd"…), for tuning without rebuilding the wrapper. Returns NO for an
/// unknown name or a value of the wrong type.
- (BOOL)setSetting:(NSString *)name integer:(NSInteger)value NS_SWIFT_NAME(setSetting(_:integer:));
- (BOOL)setSetting:(NSString *)name boolean:(BOOL)value NS_SWIFT_NAME(setSetting(_:boolean:));

/// Adds a torrent for `user`, or joins the one already in the session with
/// the same info hash (then `savePath` and `resumeData` are ignored).
/// `link` is a magnet URI (BEP 9, v1 or v2 hashes) or a bare info hash in hex
/// or base32. `trackers` are added to the magnet's own.
/// `priorities` are the user's file priorities if already known (else none);
/// given at add, they also turn on sequential order, so a stream's first
/// pieces are requested the moment metadata arrives.
- (nullable BBTorrentHandle *)acquireTorrentWithLink:(NSString *)link
                                            trackers:(NSArray<NSString *> *)trackers
                                            savePath:(NSString *)savePath
                                          resumeData:(nullable NSData *)resumeData
                                                user:(NSString *)user
                                          priorities:(nullable NSDictionary<NSNumber *, NSNumber *> *)priorities
                                               error:(NSError **)error
    NS_SWIFT_NAME(acquire(link:trackers:savePath:resumeData:user:priorities:));

/// Drops `user`. Files only that user wanted get priority 0 and, when
/// `deleteFiles` is set, are deleted once the torrent leaves the session
/// (unless an earlier user released them keeping them, like a finished
/// download). The torrent leaves the session when no users remain.
/// Returns YES if the torrent was removed.
- (BOOL)releaseTorrent:(BBTorrentHandle *)handle user:(NSString *)user deleteFiles:(BOOL)deleteFiles
    NS_SWIFT_NAME(release(_:user:deleteFiles:));

- (nullable BBTorrentHandle *)torrentWithInfoHash:(NSString *)infoHash;
- (NSArray<BBTorrentHandle *> *)torrents;
- (BBSessionStats *)stats;

/// The DHT state to pass to the next session, so it starts warm.
- (nullable NSData *)sessionState;

/// After a network change (Wi-Fi to cellular, wake from sleep): reopens the
/// listen sockets on the current interfaces and re-announces every torrent.
- (void)networkChanged;

/// Stops every torrent, waits up to `timeout` seconds for trackers to hear
/// that we stopped, and destroys the session. Blocks until libtorrent's
/// threads have finished. Afterwards every call is a no-op.
- (void)shutdownWithTimeout:(NSTimeInterval)timeout;
@property (nonatomic, readonly) BOOL isShutDown;
@end

NS_ASSUME_NONNULL_END
