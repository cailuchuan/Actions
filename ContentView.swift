import SwiftUI
import AVKit
import WebKit
import Speech
import AVFoundation
import CryptoKit

struct WebDAVFile: Identifiable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
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
    @State private var playingURL: URL?
    @State private var subtitleText = "等待视频播放..."
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    
    var body: some View {
        NavigationView {
            if isPlaying, let videoURL = playingURL {
                // === 防闪退系统级播放器 ===
                ZStack(alignment: .bottom) {
                    NativeSystemPlayer(url: videoURL, username: username, password: password)
                        .edgesIgnoringSafeArea(.all)
                    
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
                .navigationBarTitle("播放", displayMode: .inline)
                .navigationBarItems(trailing: Button("关闭") {
                    self.isPlaying = false
                    self.playingURL = nil
                    self.audioEngine.stop()
                })
                .onAppear {
                    // ⚠️ 注意：网页播放时内部音频抓取会被彻底锁死，这里只能用麦克风。
                    // 因为苹果底层代码限制，不完整包工程无法获取 WebKit 音频。
                    startMicrophoneCapture()
                }
                .onDisappear {
                    self.audioEngine.stop()
                }
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
                                self.playingURL = url
                                self.isPlaying = true
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
    
    // MARK: - 麦克风收音与翻译
    func startMicrophoneCapture() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    do { try self.setupMicrophone() } catch { self.subtitleText = "麦克风启动失败" }
                }
            }
        }
    }
    
    func setupMicrophone() throws {
        recognitionTask?.cancel()
        let audioSession = AVAudioSession.sharedInstance()
        // 允许外放 + 麦克风混音
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
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

// 🔥 终极防闪退包装：加载 HTML5 视频并调用苹果系统面板
struct NativeSystemPlayer: UIViewRepresentable {
    let url: URL
    let username: String
    let password: String
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: config)
        
        // 用账号密码拼接认证头，防止服务器拒绝
        var authStr = ""
        if !username.isEmpty {
            let loginString = "\(username):\(password)"
            if let loginData = loginString.data(using: .utf8) {
                authStr = "Basic \(loginData.base64EncodedString())"
            }
        }
        
        // HTML5 视频标签，添加了 playsinline 强制调用苹果自带的全屏播放器
        let html = """
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                body { margin: 0; background-color: black; display: flex; justify-content: center; align-items: center; height: 100vh; }
                video { width: 100%; height: 100%; object-fit: contain; }
            </style>
        </head>
        <body>
            <video src="\(url.absoluteString)" controls autoplay playsinline webkit-playsinline>
            </video>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@main
struct TranslatorApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}