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
    @State private var serverURL = "http://[你的IPv6]:端口"
    @State private var username = ""
    @State private var password = ""
    
    @State private var isLoggedIn = false
    @State private var files: [WebDAVFile] = []
    @State private var isLoading = false
    @State private var statusMessage = "请输入 WebDAV 信息"
    
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
                .navigationBarTitle("系统播放器", displayMode: .inline)
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
                    if !file.isDirectory {
                        Button(action: {
                            playVideo(urlStr: file.url)
                        }) {
                            HStack {
                                Image(systemName: "play.circle.fill").foregroundColor(.blue)
                                Text(file.name)
                            }
                        }
                    } else {
                        HStack {
                            Image(systemName: "folder.fill").foregroundColor(.gray)
                            Text(file.name).foregroundColor(.gray)
                        }
                    }
                }
                .navigationBarTitle("WebDAV 文件", displayMode: .inline)
                .navigationBarItems(trailing: Button("退出") {
                    self.isLoggedIn = false
                    self.files = []
                })
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
    
    // MARK: - 登录并获取文件
    func connectWebDAV() {
        isLoading = true
        statusMessage = "正在请求服务器..."
        
        guard let url = URL(string: serverURL.hasSuffix("/") ? serverURL : serverURL + "/") else {
            statusMessage = "网址格式错误"
            isLoading = false
            return
        }
        
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
        
        // ⚠️ 关键：使用自定义的 URLSession 强制绕过安全拦截
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // 强制允许不安全连接（针对纯代码环境）
        config.tlsMinimumSupportedProtocolVersion = .TLSv10 
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
                if xmlString.isEmpty {
                    statusMessage = "返回数据为空，可能是认证失败"
                    return
                }
                
                parseWebDAVXML(xmlString: xmlString, baseURL: url)
            }
        }.resume()
    }
    
    // MARK: - 解析 XML
    func parseWebDAVXML(xmlString: String, baseURL: URL) {
        var parsedFiles: [WebDAVFile] = []
        let components = xmlString.components(separatedBy: "<D:href>")
        
        for comp in components.dropFirst() {
            if let hrefEnd = comp.range(of: "</D:href>") {
                let rawHref = String(comp[..<hrefEnd.lowerBound])
                let decodedHref = rawHref.removingPercentEncoding ?? rawHref
                
                if decodedHref == "/" || decodedHref == baseURL.path { continue }
                
                let isDir = decodedHref.hasSuffix("/")
                let name = decodedHref.components(separatedBy: "/").filter({ !$0.isEmpty }).last ?? "未知"
                
                // 拼接完整 URL
                var fullURLString = baseURL.absoluteString
                if !fullURLString.hasSuffix("/") && !decodedHref.hasPrefix("/") {
                    fullURLString += "/"
                }
                fullURLString += decodedHref
                
                parsedFiles.append(WebDAVFile(name: name, url: fullURLString, isDirectory: isDir))
            }
        }
        
        if parsedFiles.isEmpty {
            statusMessage = "登录成功，但未解析到文件"
        } else {
            self.files = parsedFiles
            self.isLoggedIn = true
            self.statusMessage = ""
        }
    }
    
    // MARK: - 播放视频并启动系统内部音频监听
    func playVideo(urlStr: String) {
        guard let url = URL(string: urlStr) else { return }
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 允许视频播放的同时，开启音频引擎监听
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch { print("音频环境失败") }
        
        // 使用系统原生 AVPlayer
        let newPlayer = AVPlayer(url: url)
        self.player = newPlayer
        self.isPlaying = true
        self.subtitleText = "正在尝试抓取系统音频..."
    }
    
    // MARK: - 语音识别与百度翻译
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