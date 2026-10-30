import SwiftUI
import SystemSnapshot
import WidgetKit

// Continue Watching and Up Next, from the snapshot the app writes to the App
// Group whenever the library changes (Features/AppModel+System.swift). Builds
// without the App Group (sideloaded ones) show the placeholder: open Bluebox.

struct LibraryEntry: TimelineEntry {
    enum Content {
        case items([LibrarySnapshot.Item])
        /// The app hasn't written a snapshot this widget can read.
        case unavailable
    }

    let date: Date
    let content: Content
    let store: LibrarySnapshotStore?
}

/// Which row a widget shows.
enum LibraryRow {
    case continueWatching, upNext

    func items(_ s: LibrarySnapshot) -> [LibrarySnapshot.Item] {
        switch self {
        case .continueWatching: s.continueWatching + s.upNext
        case .upNext: s.upNext
        }
    }

    var title: String {
        switch self {
        case .continueWatching: "Continue Watching"
        case .upNext: "Up Next"
        }
    }

    var emptyMessage: String {
        switch self {
        case .continueWatching: "Nothing in progress. Start something in Bluebox."
        case .upNext: "No new episodes. Shows you watch appear here."
        }
    }
}

/// One entry, refreshed by the app (`WidgetCenter.reloadAllTimelines`)
/// when the library changes.
struct LibraryProvider: TimelineProvider {
    let row: LibraryRow

    func placeholder(in context: Context) -> LibraryEntry {
        LibraryEntry(date: .now, content: .items(Self.sample), store: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LibraryEntry) -> Void) {
        let entry = load()
        if context.isPreview, case .items(let items) = entry.content, items.isEmpty {
            completion(placeholder(in: context))
        } else {
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LibraryEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .never))
    }

    private func load() -> LibraryEntry {
        guard let store = LibrarySnapshotStore.shared, let snapshot = store.read() else {
            return LibraryEntry(date: .now, content: .unavailable, store: nil)
        }
        return LibraryEntry(date: .now, content: .items(row.items(snapshot)), store: store)
    }

    static let sample: [LibrarySnapshot.Item] = [
        .init(key: "sample:1", titleKey: "sample:1", title: "The Expanse", subtitle: "S2·E4", progress: 0.42,
              minutesLeft: 26, link: SystemLink.myList.url),
        .init(key: "sample:2", titleKey: "sample:2", title: "Arrival", progress: 0.7, minutesLeft: 35, link: SystemLink.myList.url),
        .init(key: "sample:3", titleKey: "sample:3", title: "Severance", subtitle: "S1·E3", isNew: true, link: SystemLink.myList.url),
    ]
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.bluebox.continue-watching", provider: LibraryProvider(row: .continueWatching)) { entry in
            LibraryWidgetView(entry: entry, row: .continueWatching)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.bluebox.up-next", provider: LibraryProvider(row: .upNext)) { entry in
            LibraryWidgetView(entry: entry, row: .upNext)
        }
        .configurationDisplayName("Up Next")
        .description("The next episodes of shows you're watching, new ones first.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct LibraryWidgetView: View {
    let entry: LibraryEntry
    let row: LibraryRow
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if family == .systemSmall || family == .systemMedium { Color.black } else { Color.clear }
            }
    }

    @ViewBuilder private var content: some View {
        switch entry.content {
        case .unavailable:
            message("Open Bluebox to see what you're watching here.")
        case .items(let items) where items.isEmpty:
            message(row.emptyMessage)
        case .items(let items):
            switch family {
            case .systemMedium: MediumRow(row: row, items: Array(items.prefix(3)), store: entry.store)
            case .accessoryRectangular: AccessoryRectangle(row: row, item: items[0]).widgetURL(items[0].link)
            case .accessoryInline: inline(items[0]).widgetURL(items[0].link)
            default: SmallCard(row: row, item: items[0], store: entry.store).widgetURL(items[0].link)
            }
        }
    }

    @ViewBuilder private func message(_ text: String) -> some View {
        switch family {
        case .accessoryInline:
            Text("Bluebox")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(row.title).font(.headline)
                Text(text).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Header(row: row)
                Spacer(minLength: 0)
                Text(text).font(.subheadline).foregroundStyle(secondary).lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func inline(_ item: LibrarySnapshot.Item) -> some View {
        Label(item.subtitle.map { "\(item.title) \($0)" } ?? item.title, systemImage: "play.fill")
    }
}

/// "CONTINUE WATCHING" in brand blue, as Home's row headers read.
private struct Header: View {
    let row: LibraryRow

    var body: some View {
        Text(row.title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(brand)
            .lineLimit(1)
    }
}

/// The next thing: poster, title, episode and what's left.
private struct SmallCard: View {
    let row: LibraryRow
    let item: LibrarySnapshot.Item
    let store: LibrarySnapshotStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Poster(item: item, store: store).frame(width: 44, height: 66)
                Spacer(minLength: 4)
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white)
            }
            Spacer(minLength: 2)
            Text(item.title).font(.subheadline.weight(.bold)).foregroundStyle(.white).lineLimit(2)
            Detail(item: item)
            if let progress = item.progress { ProgressBar(fraction: progress) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Up to three, each opening its own.
private struct MediumRow: View {
    let row: LibraryRow
    let items: [LibrarySnapshot.Item]
    let store: LibrarySnapshotStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(row: row)
            HStack(alignment: .top, spacing: 10) {
                ForEach(items) { item in
                    Link(destination: item.link) {
                        VStack(alignment: .leading, spacing: 3) {
                            Poster(item: item, store: store)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(2 / 3, contentMode: .fit)
                                .frame(maxHeight: 82)
                            Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            Detail(item: item)
                            if let progress = item.progress { ProgressBar(fraction: progress) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(items.count..<3, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AccessoryRectangle: View {
    let row: LibraryRow
    let item: LibrarySnapshot.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.headline).lineLimit(1).widgetAccentable()
            Text(item.subtitle ?? row.title).font(.caption).lineLimit(1)
            if let progress = item.progress {
                Gauge(value: progress) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "S1·E2 · 26 min left", "New Episode".
private struct Detail: View {
    let item: LibrarySnapshot.Item

    var body: some View {
        let parts = [item.subtitle, item.isNew ? "New" : nil, item.minutesLeft.map { "\($0) min left" }].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.caption2.monospacedDigit()).foregroundStyle(secondary).lineLimit(1)
        }
    }
}

/// The app's small poster, or a dark tile with the title's initial.
private struct Poster: View {
    let item: LibrarySnapshot.Item
    let store: LibrarySnapshotStore?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let name = item.thumbnail, let store, let image = UIImage(contentsOfFile: store.thumbnailURL(name).path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(white: 0.14)
                    Text(item.title.prefix(1)).font(.title3.weight(.bold)).foregroundStyle(secondary)
                }
            }
        }
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}
