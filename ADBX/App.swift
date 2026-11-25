import SwiftUI
import UniformTypeIdentifiers

struct TV: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16
}
@MainActor final class Model: ObservableObject {
    @Published var devices: [TV] = []
    @Published var connected: TV?
    @Published var busy = false
    @Published var status = "未连接"
    @Published var output = ""
    @Published var installProgress: Double?
    @Published var installing = false
    @Published var installMessage: String?
    @Published var packages: [String] = []
    private let adb = ADB()
    private let queue = DispatchQueue(label: "adbx.connection")
    init() {
        if let d = UserDefaults.standard.data(forKey: "devices"), let list = try? JSONDecoder().decode([TV].self, from: d) { devices = list }
    }
    func save() { if let d = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(d, forKey: "devices") } }
    func connect(_ tv: TV) {
        guard !busy else { return }; busy = true; connected = nil; packages = []; status = "连接中，请在电视上允许调试"
        let client = adb
        queue.async {
            let result = Result { try client.connect(host: tv.host, port: tv.port) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success: self.connected = tv; self.status = "已连接"
                case .failure(let e): self.status = e.localizedDescription
                }
            }
        }
    }
    func disconnect() {
        guard !busy else { return }
        connected = nil; packages = []; status = "未连接"
        let client = adb; queue.async { client.close() }
    }
    func install(_ url: URL) {
        guard !busy, connected != nil else { return }
        busy = true; installing = true; installProgress = 0
        status = "正在上传 APK"
        let client = adb
        queue.async {
            var lastPercent = -1
            let result = Result {
                try client.installAPK(url) { fraction in
                    let percent = fraction.map { Int($0 * 100) } ?? 101
                    guard percent != lastPercent else { return }
                    lastPercent = percent
                    DispatchQueue.main.async {
                        self.installProgress = fraction
                        self.status = fraction == nil ? "电视正在安装 APK" : "正在上传 APK"
                    }
                }
            }
            let stillConnected = client.isConnected
            DispatchQueue.main.async {
                self.busy = false; self.installing = false; self.installProgress = nil
                if !stillConnected { self.connected = nil }
                self.status = stillConnected ? "已连接" : "连接已断开"
                switch result {
                case .success(let message): self.installMessage = "安装成功：" + url.lastPathComponent; self.output += "\n" + message
                case .failure(let error): self.installMessage = error.localizedDescription; self.output += "\n" + error.localizedDescription
                }
            }
        }
    }
    func run(_ command: String, list: Bool = false) {
        guard !busy, connected != nil, !command.isEmpty else { return }
        busy = true; output += "\n$ " + command + "\n"
        let client = adb
        queue.async {
            let result = Result { try client.shell(command) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let s):
                    self.output += s + "\n"
                    if list { self.packages = s.components(separatedBy: .newlines).filter { $0.hasPrefix("package:") }.map { String($0.dropFirst(8)) }.sorted() }
                case .failure(let e): self.output += e.localizedDescription; self.status = e.localizedDescription; self.connected = nil
                }
                if self.output.count > 200000 { self.output = String(self.output.suffix(200000)) }
            }
        }
    }
}
@main struct ADBXApp: App {
    @StateObject private var model = Model()
    var body: some Scene { WindowGroup { Root().environmentObject(model).preferredColorScheme(.dark) } }
}
struct Root: View {
    @EnvironmentObject var model: Model
    @State private var adding = false
    @State private var name = ""
    @State private var host = ""
    @State private var port = "5555"
    @State private var command = ""
    @State private var selectedPackage: String?
    @State private var uninstall = false
    @State private var pickingAPK = false
    var body: some View {
        TabView {
            NavigationStack {
                List {
                    Section("连接状态") {
                        Text(model.status).foregroundStyle(model.connected == nil ? Color.secondary : Color.green)
                        if model.busy { ProgressView() }
                        if model.connected != nil { Button("断开连接", role: .destructive) { model.disconnect() }.disabled(model.busy) }
                    }
                    Section("我的设备") {
                        ForEach(model.devices) { tv in
                            Button { model.connect(tv) } label: {
                                HStack {
                                    Image(systemName: "tv").font(.title2)
                                    VStack(alignment: .leading) { Text(tv.name).foregroundStyle(.primary); Text("\(tv.host):\(tv.port)").font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    if model.connected == tv { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                }
                            }.disabled(model.busy)
                        }.onDelete { indices in model.devices.remove(atOffsets: indices); model.save() }
                        Button("添加设备", systemImage: "plus") { adding = true }
                    }
                    Section("快捷命令") {
                        Button("设备型号") { model.run("getprop ro.product.model") }
                        Button("Android 版本") { model.run("getprop ro.build.version.release") }
                        Button("存储空间") { model.run("df -h") }
                    }.disabled(model.connected == nil || model.busy)
                    Section("APK 安装") {
                        Button("安装 APK 到电视", systemImage: "square.and.arrow.up") { pickingAPK = true }
                            .disabled(model.connected == nil || model.busy)
                        if model.installing {
                            if let value = model.installProgress {
                                ProgressView(value: value) { Text("上传 \(Int(value * 100))%") }
                            } else { ProgressView("电视正在安装") }
                        }
                    }
                    Section("应用管理") {
                        Button("刷新已安装的第三方应用") { model.run("pm list packages -3", list: true) }.disabled(model.connected == nil || model.busy)
                        ForEach(model.packages, id: \.self) { pkg in
                            Menu(pkg) {
                                Button("启动") { model.run("monkey -p " + quoted(pkg) + " -c android.intent.category.LAUNCHER 1") }
                                Button("停止") { model.run("am force-stop " + quoted(pkg)) }
                                Button("卸载", role: .destructive) { selectedPackage = pkg; uninstall = true }
                            }.disabled(model.connected == nil || model.busy)
                        }
                    }
                }.navigationTitle("ADBX").toolbar { Button("添加", systemImage: "plus") { adding = true } }
                .fileImporter(isPresented: $pickingAPK, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data]) { result in
                    switch result {
                    case .success(let url): model.install(url)
                    case .failure(let error): model.installMessage = error.localizedDescription
                    }
                }
                .alert("APK 安装结果", isPresented: Binding(get: { model.installMessage != nil }, set: { if !$0 { model.installMessage = nil } })) {
                    Button("确定") { model.installMessage = nil }
                } message: { Text(model.installMessage ?? "") }
                .confirmationDialog("确认卸载应用？", isPresented: $uninstall, titleVisibility: .visible) {
                    Button("卸载", role: .destructive) { if let p = selectedPackage { model.run("pm uninstall " + quoted(p)) } }
                }
                .sheet(isPresented: $adding) {
                    NavigationStack {
                        Form {
                            TextField("设备名称", text: $name)
                            TextField("IP 地址", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("端口", text: $port).keyboardType(.numberPad)
                        }.navigationTitle("添加电视").toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { adding = false } }
                            ToolbarItem(placement: .confirmationAction) { Button("保存") {
                                if let p = UInt16(port), p > 0 {
                                    model.devices.append(TV(name: name.isEmpty ? "电视" : name, host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: p)); model.save()
                                    name = ""; host = ""; port = "5555"; adding = false
                                }
                            }.disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || UInt16(port) == nil || UInt16(port) == 0) }
                        }
                    }
                }
            }.tabItem { Label("设备", systemImage: "tv") }
            NavigationStack {
                VStack(spacing: 12) {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(model.output.isEmpty ? "ADB Shell" : model.output).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("bottom")
                        }.onChange(of: model.output) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    HStack {
                        TextField("输入 Shell 命令", text: $command).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).onSubmit(execute)
                        Button("执行", action: execute).disabled(model.connected == nil || model.busy || command.isEmpty)
                    }
                }.padding().navigationTitle("终端").toolbar { Button("清空") { model.output = "" } }
            }.tabItem { Label("终端", systemImage: "terminal") }
            NavigationStack {
                VStack(spacing: 22) {
                    Text(model.connected?.name ?? "未连接电视").foregroundStyle(.secondary)
                    HStack { key("house", 3); key("arrow.uturn.backward", 4); key("line.3.horizontal", 82) }
                    key("chevron.up", 19)
                    HStack { key("chevron.left", 21); key("circle.fill", 23); key("chevron.right", 22) }
                    key("chevron.down", 20)
                    HStack { key("speaker.minus", 25); key("speaker.slash", 164); key("speaker.plus", 24) }
                    HStack { key("backward.end", 89); key("playpause", 85); key("forward.end", 90) }
                    Spacer()
                }.padding(.top, 30).disabled(model.connected == nil || model.busy).navigationTitle("遥控")
            }.tabItem { Label("遥控", systemImage: "gamecontroller") }
        }.tint(.mint)
    }
    private func execute() {
        guard model.connected != nil, !model.busy, !command.isEmpty else { return }
        model.run(command); command = ""
    }
    private func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func key(_ icon: String, _ code: Int) -> some View {
        Button { model.run("input keyevent \(code)") } label: {
            Image(systemName: icon).font(.title2).frame(width: 84, height: 64).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}
