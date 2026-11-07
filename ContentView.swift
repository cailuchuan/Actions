import SwiftUI
import AVKit
import Speech
import AVFoundation
import CryptoKit

struct WebDAVFile: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let isDirectory: Bool
}

struct ContentView: View {
    // ⚠️ 填入你的百度翻译 API
    let baiduAppId = ""
    let baiduSecretKey = ""
    
    // 登录信息
    @State private var serverURL = "http://nas.cctvb.dpdns.org:5055"
    @State private var username = "cailcc"
    @State private var password = ""
    
    @State private var isLoggedIn = false
    @State private var files: [WebDAVFile] = []
    @State private var isLoading = false
    @State private var statusMessage = ""
    
    // 当前路径记录（用于多级目录跳转）
    @State private var currentPathURL: URL?
    
    // 播放器状态
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var subtitleText = "等待提取音频..."
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    
    var body: some View {
        NavigationView {
            if isPlaying, let player = player {
                // === 原生系统播放器界面 ===
                ZStack(alignment: .bottom) {
                    VideoPlayer(player: player)
                        .edgesIgnoringSafeArea(.all)
                        .onAppear {
                            startAudioCapture()
                            player.play()
                        }
                    
                    // 中文字幕层
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
                    self.subtitleText = "等待提取音频..."
                })
            } else if isLoggedIn {
                // === 文件列表界面 ===
                List(files) { file in
                    if file.isDirectory {
                        // 点击文件夹，进入下一级
                        Button(action: {
                            if let targetURL = URL(string: file.url) {
                                currentPathURL = targetURL
                                fetchDirectory(url: targetURL)
                            }
                        }) {
                            HStack {
                                Image(systemName: "folder.fill").foregroundColor(.blue)
                                Text(file.name).foregroundColor(.primary)
                            }
                        }
                    } else {
                        // 点击视频文件，进行播放
                        Button(action: {
                            playVideo(urlStr: file.url)
                        }) {
                            HStack {
                                Image(systemName: "play.circle.fill").foregroundColor(.green)
                                Text(file.name).foregroundColor(.primary)
                            }
                        }
                    }
                }
                .navigationBarTitle("WebDAV 文件", displayMode: .inline)
                .navigationBarItems(
                    leading: Button("返回上一级") {
                        if let current = currentPathURL {
                            // 截取上一级路径
                            var path = current.absoluteString
                            if path.hasSuffix("/") { path.removeLast() }
                            if let lastSlash = path.lastIndex(of: "/") {
                                let parentPath = String(path[..<lastSlash]) + "/"
                                if let parentURL = URL(string: parentPath) {
                                    currentPathURL = parentURL
                                    fetchDirectory(url: parentURL)
                                }
                            }
                        }
                    },
                    trailing: Button("退出") {
                        self.isLoggedIn = false
                        self.files = []
                        self.statusMessage = ""
                        self.currentPathURL = nil
                    }
                )
            } else {
                // === 登录界面 ===
                Form {
                    Section(header: Text("WebDAV 账户")) {
                        TextField("服务器地址 (http://...)", text: $serverURL)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                        TextField("用户名", text: $username)
                            .autocapitalization(.none)
                        SecureField("密码", text: $password)
                    }
                    
                    Button(action: {
                        connectWebDAV()
                    }) {
                        HStack {
                            Spacer()
                            if isLoading { ProgressView().padding(.trailing, 5) }
                            Text(isLoading ? "连接中..." : "登录并获取文件")
                            Spacer()
                        }
                    }
                    .disabled(isLoading)
                    
                    Text(statusMessage).foregroundColor(.red).font(.footnote)
                }
                .navigationBarTitle("WebDAV 登录", displayMode: .inline)
            }
        }
    }
    
    // MARK: - 初次登录
    func connectWebDAV() {
        isLoading = true
        statusMessage = "正在请求服务器..."
        
        var formattedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !formattedURL.hasSuffix("/") { formattedURL += "/" }
        
        guard let url = URL(string: formattedURL) else {
            statusMessage = "网址格式错误"
            isLoading = false
            return
        }
        
        currentPathURL = url
        fetchDirectory(url: url, isInitialLogin: true)
    }
    
    // MARK: - 核心：获取目录数据
    func fetchDirectory(url: URL, isInitialLogin: Bool = false) {
        isLoading = true
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        
        if !username.isEmpty {
            let loginString = "\(username):\(password)"
            if let loginData = loginString.data(using: .utf8) {
                let base64LoginString = loginData.base64EncodedString()
                request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
            }
        }
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        let session = URLSession(configuration: config)
        
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                if let error = error {
                    statusMessage = "连接失败: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data else {
                    statusMessage = "未收到数据"
                    return
                }
                
                let xmlString = String(data: data, encoding: .utf8) ?? ""
                parseWebDAVXML(xmlString: xmlString, baseURL: url, isInitialLogin: isInitialLogin)
            }
        }.resume()
    }
    
    // MARK: - 解析 XML（过滤掉当前目录本身和上级目录）
    func parseWebDAVXML(xmlString: String, baseURL: URL, isInitialLogin: Bool) {
        var parsedFiles: [WebDAVFile] = []
        let components = xmlString.components(separatedBy: "<D:href>")
        
        for comp in components.dropFirst() {
            if let hrefEnd = comp.range(of: "</D:href>") {
                let rawHref = String(comp[..<hrefEnd.lowerBound])
                let decodedHref = rawHref.removingPercentEncoding ?? rawHref
                
                // 过滤掉当前目录本身的返回
                let pathWithoutSlash = decodedHref.hasSuffix("/") ? String(decodedHref.dropLast()) : decodedHref
                let basePathWithoutSlash = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
                if pathWithoutSlash == basePathWithoutSlash || decodedHref == "/" { continue }
                
                let isDir = decodedHref.hasSuffix("/")
                let name = decodedHref.components(separatedBy: "/").filter({ !$0.isEmpty }).last ?? "未知"
                
                // 拼接完整 URL
                var fullURLString = baseURL.absoluteString
                if !fullURLString.hasSuffix("/") && !decodedHref.hasPrefix("/") {
                    fullURLString += "/"
                }
                // 如果服务器返回的是根目录绝对路径，就直接拼接域名
                if decodedHref.hasPrefix("/") {
                    let rootUrl = "\(baseURL.scheme ?? "http")://\(baseURL.host ?? "")\(baseURL.port != nil ? ":\(baseURL.port!)" : "")"
                    fullURLString = rootUrl + decodedHref
                } else {
                    fullURLString += decodedHref
                }
                
                // 避免重复添加
                if !parsedFiles.contains(where: { $0.url == fullURLString }) {
                    parsedFiles.append(WebDAVFile(name: name, url: fullURLString, isDirectory: isDir))
                }
            }
        }
        
        // 排序：文件夹在前，文件在后
        parsedFiles.sort {
            if $0.isDirectory == $1.isDirectory {
                return $0.name < $1.name
            }
            return $0.isDirectory && !$1.isDirectory
        }
        
        if parsedFiles.isEmpty {
            statusMessage = "目录为空"
        } else {
            self.files = parsedFiles
            if isInitialLogin {
                self.isLoggedIn = true
            }
            self.statusMessage = ""
        }
    }
    
    // MARK: - 播放视频
    func playVideo(urlStr: String) {
        guard let url = URL(string: urlStr) else { return }
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch { print("音频环境失败") }
        
        let newPlayer = AVPlayer(url: url)
        self.player = newPlayer
        self.isPlaying = true
        self.subtitleText = "正在抓取系统音频..."
    }
    
    // MARK: - 内录与翻译
    func startAudioCapture() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    do { try self.setupAudioEngine() } catch { self.subtitleText = "识别启动失败" }
                }
            }
        }
    }
    
    func setupAudioEngine() throws {
        recognitionTask?.cancel()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.translateWithBaidu(text: text)
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