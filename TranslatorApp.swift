import SwiftUI
import AVKit
import Speech
import AVFoundation
import CryptoKit

struct WebDAVFile: Identifiable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
}

// 🔥 终极拦截器：拦住假协议请求，强行加上账号密码，去服务器要数据
class WebDAVResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let originalURL: URL
    let username: String
    let password: String
    
    init(originalURL: URL, username: String, password: String) {
        self.originalURL = originalURL
        self.username = username
        self.password = password
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        var request = URLRequest(url: originalURL)
        if !username.isEmpty {
            let loginString = "\(username):\(password)"
            if let loginData = loginString.data(using: .utf8) {
                request.setValue("Basic \(loginData.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                loadingRequest.finishLoading(with: error)
                return
            }
            if let response = response {
                loadingRequest.response = response
            }
            if let data = data {
                loadingRequest.dataRequest?.respond(with: data)
            }
            loadingRequest.finishLoading()
        }
        task.resume()
        
        return true
    }
}

struct ContentView: View {
    // ⚠️ 填入你的百度翻译 API
    let baiduAppId = ""
    let baiduSecretKey = ""
    
    @State private var serverURL = "http://nas.cctvb.dpdns.org:5055"
    @State private var username = "cailcc"
    @State private var password = ""
    
    @State private var isLoggedIn = false
    @State private var files: [WebDAVFile] = []
    @State private var isLoading = false
    @State private var statusMessage = ""
    
    @State private var pathStack: [String] = []
    
    // 播放状态
    @State private var isPlaying = false
    @State private var player: AVPlayer?
    @State private var subtitleText = "等待提取系统音频..."
    
    // 必须强引用，防止被系统释放导致播放失败
    @State private var resourceLoader: WebDAVResourceLoader?
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    
    var body: some View {
        NavigationView {
            if isPlaying, let player = player {
                // === 原生系统播放器 ===
                ZStack(alignment: .bottom) {
                    VideoPlayer(player: player)
                        .edgesIgnoringSafeArea(.all)
                        .onAppear {
                            startAudioCapture()
                            player.play()
                        }
                    
                    Text(subtitleText)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(8)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 60)
                }
                .navigationBarTitle("正在播放", displayMode: .inline)
                .navigationBarItems(trailing: Button("关闭") {
                    self.isPlaying = false
                    self.player?.pause()
                    self.player = nil
                    self.audioEngine.stop()
                    self.resourceLoader = nil
                })
            } else if isLoggedIn {
                // === 文件列表 ===
                List(files) { file in
                    if file.isDirectory {
                        Button(action: {
                            self.pathStack.append(file.name)
                            self.fetchDirectory()
                        }) {
                            HStack {
                                Image(systemName: "folder.fill").foregroundColor(.blue)
                                Text(file.name).foregroundColor(.primary)
                            }
                        }
                    } else {
                        Button(action: {
                            let base = getBaseURLString()
                            let fullPath = pathStack.joined(separator: "/") + "/" + file.name
                            let encodedPath = fullPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                            if let url = URL(string: base + encodedPath) {
                                playNativeVideo(url: url)
                            }
                        }) {
                            HStack {
                                Image(systemName: "play.rectangle.fill").foregroundColor(.green)
                                Text(file.name).foregroundColor(.primary)
                            }
                        }
                    }
                }
                .navigationBarTitle(pathStack.last ?? "根目录", displayMode: .inline)
                .navigationBarItems(
                    leading: Button("返回上一级") {
                        if !pathStack.isEmpty {
                            pathStack.removeLast()
                            fetchDirectory()
                        }
                    },
                    trailing: Button("退出") {
                        self.isLoggedIn = false
                        self.files = []
                        self.pathStack = []
                    }
                )
            } else {
                // === 登录 ===
                Form {
                    Section(header: Text("WebDAV 账户")) {
                        TextField("服务器地址", text: $serverURL).autocapitalization(.none)
                        TextField("用户名", text: $username).autocapitalization(.none)
                        SecureField("密码", text: $password)
                    }
                    Button(action: { connectWebDAV() }) {
                        HStack {
                            Spacer()
                            if isLoading { ProgressView().padding(.trailing, 5) }
                            Text(isLoading ? "连接中..." : "登录并获取文件")
                            Spacer()
                        }
                    }
                    Text(statusMessage).foregroundColor(.red).font(.footnote)
                }
                .navigationBarTitle("WebDAV 登录", displayMode: .inline)
            }
        }
    }
    
    func getBaseURLString() -> String {
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasSuffix("/") { url += "/" }
        return url
    }
    
    func getCurrentURLString() -> String {
        let base = getBaseURLString()
        let path = pathStack.joined(separator: "/")
        if path.isEmpty { return base }
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return base + encodedPath + "/"
    }
    
    func connectWebDAV() {
        pathStack = []
        fetchDirectory()
    }
    
    func fetchDirectory() {
        isLoading = true
        statusMessage = "加载中..."
        guard let url = URL(string: getCurrentURLString()) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        
        if !username.isEmpty {
            let loginString = "\(username):\(password)"
            if let loginData = loginString.data(using: .utf8) {
                request.setValue("Basic \(loginData.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30.0
        URLSession(configuration: config).dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error = error {
                    statusMessage = "网络错误: \(error.localizedDescription)"
                    return
                }
                guard let data = data else { return }
                let xmlString = String(data: data, encoding: .utf8) ?? ""
                parseXML(xmlString: xmlString)
            }
        }.resume()
    }
    
    func parseXML(xmlString: String) {
        var parsedFiles: [WebDAVFile] = []
        let components = xmlString.components(separatedBy: "<D:href>")
        
        for comp in components.dropFirst() {
            if let hrefEnd = comp.range(of: "</D:href>") {
                let rawHref = String(comp[..<hrefEnd.lowerBound])
                let decodedHref = rawHref.removingPercentEncoding ?? rawHref
                
                let currentPathStr = pathStack.joined(separator: "/")
                if decodedHref == "/" || decodedHref == "/\(currentPathStr)/" { continue }
                
                let isDir = decodedHref.hasSuffix("/")
                let cleanHref = isDir ? String(decodedHref.dropLast()) : decodedHref
                let parts = cleanHref.components(separatedBy: "/").filter({ !$0.isEmpty })
                
                guard let fileName = parts.last else { continue }
                
                if isDir {
                    parsedFiles.append(WebDAVFile(name: fileName, isDirectory: true))
                } else {
                    let ext = (fileName as NSString).pathExtension.lowercased()
                    let videoExts = ["mp4", "mkv", "avi", "mov", "m3u8", "ts", "wmv", "flv"]
                    if videoExts.contains(ext) {
                        parsedFiles.append(WebDAVFile(name: fileName, isDirectory: false))
                    }
                }
            }
        }
        
        parsedFiles.sort {
            if $0.isDirectory == $1.isDirectory { return $0.name < $1.name }
            return $0.isDirectory && !$1.isDirectory
        }
        
        self.files = parsedFiles
        if !self.files.isEmpty || self.pathStack.isEmpty {
            self.isLoggedIn = true
            self.statusMessage = ""
        }
    }
    
    // MARK: - 终极原生播放器：拦截器认证法
    func playNativeVideo(url: URL) {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch { print("音频环境失败") }
        
        // 1. 将真实 URL 伪装成一个系统不认识的假协议（customscheme://...）
        // 这样系统播放器就不会去瞎解析导致崩溃，而是交给我们的拦截器。
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "webdavcustom"
        
        guard let fakeURL = components?.url else { return }
        
        // 2. 初始化拦截器，并强引用它
        let loader = WebDAVResourceLoader(originalURL: url, username: username, password: password)
        self.resourceLoader = loader
        
        // 3. 创建资产，绑定拦截器
        let asset = AVURLAsset(url: fakeURL)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue.global())
        
        // 4. 唤醒原生播放器
        let item = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: item)
        self.isPlaying = true
        self.subtitleText = "正在抓取系统音频..."
    }
    
    // MARK: - 抓取底层音频 (内录)
    func startAudioCapture() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    do { try self.setupAudioEngine() } catch { self.subtitleText = "内录启动失败" }
                }
            }
        }
    }
    
    func setupAudioEngine() throws {
        recognitionTask?.cancel()
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try audioSession.setActive(true)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result = result {
                self.translateWithBaidu(text: result.bestTranscription.formattedString)
            }
        }
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            self.recognitionRequest?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }
    
    func translateWithBaidu(text: String) {
        if text.isEmpty || baiduAppId.isEmpty { return }
        let salt = String(Int(Date().timeIntervalSince1970))
        let signStr = baiduAppId + text + salt + baiduSecretKey
        let sign = Insecure.MD5.hash(data: signStr.data(using: .utf8)!).map { String(format: "%02hhx", $0) }.joined()
        
        var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = "q=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&from=ja&to=zh&appid=\(baiduAppId)&salt=\(salt)&sign=\(sign)"
        request.httpBody = params.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let transResult = json["trans_result"] as? [[String: Any]],
               let dst = transResult.first?["dst"] as? String {
                DispatchQueue.main.async { self.subtitleText = dst }
            }
        }.resume()
    }
}

@main
struct TranslatorApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
