import Domain
import SwiftUI
import WebKit

/// Plays a YouTube video inline through the IFrame player API in a web view
/// (AVPlayer can't play YouTube). Related videos, annotations and the
/// keyboard are off, captions follow the viewer's YouTube settings, and when
/// the video ends (or fails) `onEnd` is called and the player stops before
/// YouTube's end screen appears.
///
///     TrailerPlayerView(youtubeKey: video.youtubeKey, muted: true, showsControls: false) { showTrailer = false }
public struct TrailerPlayerView: View {
    let youtubeKey: String
    let muted: Bool
    let showsControls: Bool
    let onReady: () -> Void
    let onEnd: () -> Void
    @State private var isPlaying = false

    /// - Parameters:
    ///   - muted: start muted (Home's hero). Changing it later mutes or unmutes in place.
    ///   - showsControls: YouTube's own controls (off for the hero).
    ///   - onReady: the video started playing; fade it in over the artwork now.
    ///   - onEnd: the video ended or couldn't play; show the artwork again.
    public init(youtubeKey: String, muted: Bool = false, showsControls: Bool = true,
                onReady: @escaping () -> Void = {}, onEnd: @escaping () -> Void = {}) {
        self.youtubeKey = youtubeKey; self.muted = muted; self.showsControls = showsControls
        self.onReady = onReady; self.onEnd = onEnd
    }

    public var body: some View {
        YouTubeWebView(youtubeKey: youtubeKey, muted: muted, showsControls: showsControls,
                       onEvent: { event in
                           switch event {
                           case .playing: if !isPlaying { isPlaying = true; onReady() }
                           case .ended, .failed: isPlaying = false; onEnd()
                           }
                       })
            .opacity(isPlaying ? 1 : 0)  // no YouTube loading chrome before the first frame
            .animation(.easeInOut(duration: 0.35), value: isPlaying)
            .background(Color.black)
            .accessibilityLabel("Trailer")
    }
}

/// A trailer in a sheet with a close button, for Extras.
public struct TrailerSheet: View {
    let video: TitleVideo
    @Environment(\.dismiss) private var dismiss

    public init(video: TitleVideo) { self.video = video }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(video.kind.label).font(.caption).foregroundStyle(Color(white: 0.64))
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(Circle().fill(Color(white: 0.137)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(16)
            TrailerPlayerView(youtubeKey: video.youtubeKey, muted: false, showsControls: true, onEnd: { dismiss() })
                .aspectRatio(16 / 9, contentMode: .fit)
            Spacer(minLength: 0)
        }
        .background(Color.black.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 470)
        #endif
    }
}

// MARK: - Web view

enum YouTubeEvent { case playing, ended, failed }

/// The IFrame player page. Kept apart for testing.
enum YouTubeEmbed {
    /// Page origin: YouTube refuses embeds without a referrer (error 153).
    static let origin = URL(string: "https://bluebox.app/")!

    static func html(key: String, muted: Bool, controls: Bool) -> String {
        let safeKey = key.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}#p{position:absolute;top:0;left:0;width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script>
        function post(m){try{window.webkit.messageHandlers.bluebox.postMessage(m)}catch(e){}}
        var player;
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{videoId:'\(safeKey)',host:'https://www.youtube-nocookie.com',
            playerVars:{autoplay:1,mute:\(muted ? 1 : 0),controls:\(controls ? 1 : 0),playsinline:1,rel:0,modestbranding:1,
              iv_load_policy:3,fs:\(controls ? 1 : 0),disablekb:1,enablejsapi:1,origin:'\(origin.absoluteString.dropLast())'},
            events:{
              onReady:function(e){\(muted ? "e.target.mute();" : "")e.target.playVideo();},
              onStateChange:function(e){
                if(e.data===1){post('playing')}
                else if(e.data===0){e.target.stopVideo();post('ended')}
              },
              onError:function(e){post('error')}
            }});
        }
        function setMuted(m){if(!player||!player.mute)return;if(m){player.mute()}else{player.unMute()}}
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="post('error')"></script>
        </body></html>
        """
    }
}

#if os(iOS)
private typealias PlatformViewRepresentable = UIViewRepresentable
#else
private typealias PlatformViewRepresentable = NSViewRepresentable
#endif

private struct YouTubeWebView: PlatformViewRepresentable {
    let youtubeKey: String
    let muted: Bool
    let showsControls: Bool
    let onEvent: (YouTubeEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        #endif
        config.websiteDataStore = .nonPersistent()  // no YouTube cookies kept
        config.userContentController.add(WeakMessageHandler(coordinator), name: "bluebox")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.backgroundColor = .black
        #else
        web.setValue(false, forKey: "drawsBackground")
        #endif
        coordinator.load(web, key: youtubeKey, muted: muted, controls: showsControls)
        return web
    }

    private func update(_ web: WKWebView, _ coordinator: Coordinator) {
        coordinator.onEvent = onEvent
        if coordinator.key != youtubeKey {
            coordinator.load(web, key: youtubeKey, muted: muted, controls: showsControls)
        } else if coordinator.muted != muted {
            coordinator.muted = muted
            web.evaluateJavaScript("setMuted(\(muted))")
        }
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { coordinator.tearDown(web) }
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { coordinator.tearDown(web) }
    #endif

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onEvent: (YouTubeEvent) -> Void
        var key: String?
        var muted = false

        init(onEvent: @escaping (YouTubeEvent) -> Void) { self.onEvent = onEvent }

        func load(_ web: WKWebView, key: String, muted: Bool, controls: Bool) {
            self.key = key; self.muted = muted
            web.loadHTMLString(YouTubeEmbed.html(key: key, muted: muted, controls: controls), baseURL: YouTubeEmbed.origin)
        }

        func received(_ message: String) {
            switch message {
            case "playing": onEvent(.playing)
            case "ended": onEvent(.ended)
            default: onEvent(.failed)
            }
        }

        func tearDown(_ web: WKWebView) {
            web.evaluateJavaScript("if(player&&player.stopVideo){player.stopVideo()}")
            web.configuration.userContentController.removeScriptMessageHandler(forName: "bluebox")
            web.stopLoading()
        }

        /// Only the player page and YouTube load here; links (the YouTube logo) open in the browser.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { return .allow }
            #if os(iOS)
            await UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
            return .cancel
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onEvent(.failed) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onEvent(.failed)
        }
    }
}

/// The content controller holds its handlers strongly; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: AnyObject?
    private let deliver: @MainActor (String) -> Void

    @MainActor
    init(_ coordinator: YouTubeWebView.Coordinator) {
        target = coordinator
        deliver = { [weak coordinator] in coordinator?.received($0) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        MainActor.assumeIsolated { deliver(body) }
    }
}
