import SwiftUI
import AVKit
import RedBridge

private struct Envelope<T: Decodable>: Decodable {
    let data: T?
    let error: String?
}
private struct FeedItem: Decodable, Identifiable {
    let note_id: String
    let type: String
    let title: String
    let nickname: String
    let cover: String?
    let xsec_token: String?
    var id: String { note_id }
}
private struct Note: Decodable {
    struct Picture: Decodable { let url: String }
    struct Movie: Decodable { let masters: [String]? }
    let title: String
    let desc: String
    let nickname: String
    let images: [Picture]?
    let video: Movie?
}
private func httpsURL(_ raw: String?) -> URL? {
    guard let raw, var components = URLComponents(string: raw), components.host != nil else { return nil }
    if components.scheme == "http" { components.scheme = "https" }
    guard components.scheme == "https" else { return nil }
    return components.url
}
private func decode<T: Decodable>(_ type: T.Type, _ raw: String?) throws -> Envelope<T> {
    guard let raw else { throw URLError(.cannotParseResponse) }
    return try JSONDecoder().decode(Envelope<T>.self, from: Data(raw.utf8))
}
@main struct RedXApp: App {
    var body: some Scene { WindowGroup { FeedView() } }
}
@MainActor private struct FeedView: View {
    @State private var items: [FeedItem] = []
    @State private var busy = false
    @State private var message = ""
    @State private var exhausted = false
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink {
                            NoteView(item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    AsyncImage(url: httpsURL(item.cover)) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Rectangle().fill(Color.secondary.opacity(0.12))
                                    }
                                    .frame(height: 195).frame(maxWidth: .infinity).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                    if item.type == "video" {
                                        Image(systemName: "play.circle.fill").foregroundStyle(.white).padding(8)
                                    }
                                }
                                Text(item.title.isEmpty ? "无标题" : item.title).font(.subheadline).lineLimit(2)
                                Text(item.nickname).font(.caption).foregroundStyle(.secondary)
                            }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        .onAppear {
                            if item.id == items.last?.id && !exhausted && !busy {
                                Task { await load(reset: false) }
                            }
                        }
                    }
                }.padding(.horizontal)
                if busy { ProgressView().padding() }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary).padding() }
                if !busy {
                    Button(items.isEmpty ? "重新加载" : "加载更多") {
                        Task { await load(reset: items.isEmpty) }
                    }.padding()
                }
            }
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load(reset: true) }
            .task { if items.isEmpty { await load(reset: true) } }
        }
    }
    private func load(reset: Bool) async {
        guard !busy else { return }
        busy = true; message = ""
        defer { busy = false }
        do {
            let response = try await Task.detached(priority: .userInitiated) {
                try decode([FeedItem].self, RedbridgeFeed(20))
            }.value
            let batch = response.data ?? []
            var seen = Set(reset ? [] : items.map(\.id))
            let unique = batch.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            if reset && !unique.isEmpty { items = unique } else if !reset { items.append(contentsOf: unique) }
            exhausted = unique.isEmpty || response.error != nil
            if let error = response.error { message = error }
            else if unique.isEmpty { message = "没有新的推荐，请稍后下拉刷新。" }
        } catch {
            exhausted = true
            message = error.localizedDescription
        }
    }
}
@MainActor private struct NoteView: View {
    let item: FeedItem
    @State private var note: Note?
    @State private var player: AVPlayer?
    @State private var errorText = ""
    @State private var loading = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let player {
                    VideoPlayer(player: player).frame(height: 310)
                } else if let images = note?.images, !images.isEmpty {
                    TabView {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, picture in
                            AsyncImage(url: httpsURL(picture.url)) { image in
                                image.resizable().scaledToFit()
                            } placeholder: { ProgressView() }
                        }
                    }.tabViewStyle(.page).frame(height: 380)
                }
                Text(note?.title ?? item.title).font(.title3.bold())
                Text(note?.nickname ?? item.nickname).font(.subheadline).foregroundStyle(.secondary)
                if let note { Text(note.desc).frame(maxWidth: .infinity, alignment: .leading) }
                if loading { ProgressView() }
                if !errorText.isEmpty {
                    Text(errorText).font(.footnote).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                }
            }.padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { player?.pause() }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; errorText = ""
        defer { loading = false }
        do {
            let response = try await Task.detached(priority: .userInitiated) {
                try decode(Note.self, RedbridgeNote(item.id, item.xsec_token ?? ""))
            }.value
            guard let result = response.data else {
                errorText = response.error ?? "无法获取笔记"; return
            }
            note = result
            if let url = result.video?.masters?.compactMap({ httpsURL($0) }).first {
                player = AVPlayer(url: url)
            } else if item.type == "video" {
                errorText = "未取得视频播放地址"
            }
        } catch { errorText = error.localizedDescription }
    }
}
