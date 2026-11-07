import SwiftUI
import AVKit
import Speech
import AVFoundation
import CryptoKit

struct WebDAVFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String // 只记录相对路径
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
    
    // 核心：记录当前路径栈，比如 ["机械硬盘", "电影"]，用于返回上一级
    @State private var pathStack: [String] = []
    
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
                // === 原生播放器界面 ===
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
                    self.subtitleText = "等待提取音频..."
                })
            } else if isLoggedIn {
                // === 文件列表界面 ===
                List(files) { file in
                    if file.isDirectory {
                        Button(action: {
                            // 进入下一级
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
                            // 拼接完整播放地址
                            let base = getBaseURLString()
                            let fullPath = pathStack.joined(separator: "/") + "/" + file.name
                            let encodedPath = fullPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                            self.playVideo(urlStr: base + encodedPath)
                        }) {
                            HStack {
                                Image(systemName: "play.circle.fill").foregroundColor(.green)
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
                // === 登录界面 ===
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
    
    // 辅助函数：获取基础 URL (处理末尾斜杠)
    func getBaseURLString() -> String {
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasSuffix("/") { url += "/" }
        return url
    }
    
    // 组合当前要请求的完整 URL
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
    
    // MARK: - 核心：请求目录
    func fetchDirectory() {
        isLoading = true
        statusMessage = "加载中..."
        
        guard let url = URL(string: getCurrentURLString()) else {
            statusMessage = "URL 格式错误"
            isLoading = false
            return
        }
        
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
        let session = URLSession(configuration: config)
        
        session.dataTask(with: request) { data, response, error in
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
    
    // MARK: - 解析 XML
    func parseXML(xmlString: String) {
        var parsedFiles: [WebDAVFile] = []
        
        // 提取所有 <D:href> 标签
        let components = xmlString.components(separatedBy: "<D:href>")
        
        for comp in components.dropFirst() {
            if let hrefEnd = comp.range(of: "</D:href>") {
                let rawHref = String(comp[..<hrefEnd.lowerBound])
                let decodedHref = rawHref.removingPercentEncoding ?? rawHref
                
                // 过滤掉当前目录自己
                let currentPathStr = pathStack.joined(separator: "/")
                if decodedHref == "/" || decodedHref == "/\(currentPathStr)/" { continue }
                
                // 获取文件名和是否目录
                let isDir = decodedHref.hasSuffix("/")
                let cleanHref = isDir ? String(decodedHref.dropLast()) : decodedHref
                let parts = cleanHref.components(separatedBy: "/").filter({ !$0.isEmpty })
                
                guard let fileName = parts.last else { continue }
                
                // 记录名字和相对路径（其实这里用名字就够了，因为我们是拼接的）
                parsedFiles.append(WebDAVFile(name: fileName, path: fileName, isDirectory: isDir))
            }
        }
        
        // 排序
        parsedFiles.sort {
            if $0.isDirectory == $1.isDirectory { return $0.name < $1.name }
            return $0.isDirectory && !$1.isDirectory
        }
        
        self.files = parsedFiles
        if !self.files.isEmpty || self.pathStack.isEmpty {
            self.isLoggedIn = true
            self.statusMessage = ""
        } else {
            // 如果点进去空了，可能是路径拼错了
            statusMessage = "当前目录为空或加载失败"
        }
    }
    
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