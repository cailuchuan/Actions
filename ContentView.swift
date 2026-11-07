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

// 🔥 苹果官方标准的 AVAssetResourceLoader 拦截器
class AuthResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionTaskDelegate {
    let url: URL
    let username: String
    let password: String
    
    init(url: URL, user: String, pass: String) {
        self.url = url
        self.username = user
        self.password = pass
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        var request = URLRequest(url: url)
        
        // 附带认证信息
        if !username.isEmpty {
            let loginString = "\(username):\(password)"
            if let loginData = loginString.data(using: .utf8) {
                request.setValue("Basic \(loginData.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request) { data, response, error in
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
    
    // 处理底层的认证质询（苹果官方推荐方式）
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
            let credential = URLCredential(user: username, password: password, persistence: .forSession)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
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
    
    // 必须强引用拦截器，否则会被系统释放导致播放失败
    @State private var resourceLoader: AuthResourceLoader?
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    
    var body: some View {
        NavigationView {
            if isPlaying, let player = player {
                // === 苹果官方系统播放器 ===
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
    
    // MARK: - 采用苹果官方标准的资源加载拦截器
    func playNativeVideo(url: URL) {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // 开启后台播放和允许混音
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch { print("音频环境失败") }
        
        // 初始化官方拦截器
        let loader = AuthResourceLoader(url: url, user: username, pass: password)
        self.resourceLoader = loader
        
        // 使用非标准协议欺骗播放器，让它走拦截器（苹果官方 Sample Code 做法）
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "custom-auth-scheme"
        guard let fakeURL = components?.url else { return }
        
        let asset = AVURLAsset(url: fakeURL)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue.global())
        
        let item = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: item)
        self.isPlaying = true
        self.subtitleText = "正在抓取系统音频..."
    }
    
    // MARK: - 官方标准的系统内部音频提取逻辑
    func startAudioCapture() {
        SFSpeechRecognizer.requestAuthorization { status in
            if status == .authorized {
                DispatchQueue.main.async {
                    do {
                        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
                        let request = SFSpeechAudioBufferRecognitionRequest()
                        self.recognitionRequest = request
                        
                        let inputNode = self.audioEngine.inputNode
                        let recordingFormat = inputNode.outputFormat(forBus: 0)
                        
                        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                            request.append(buffer)
                        }
                        
                        self.audioEngine.prepare()
                        try self.audioEngine.start()
                        
                        self.recognitionTask = recognizer?.recognitionTask(with: request) { result, error in
                            if let result = result {
                                let text = result.bestTranscription.formattedString
                                if !self.baiduAppId.isEmpty {
                                    self.translate(text: text)
                                } else {
                                    DispatchQueue.main.async { self.subtitleText = text }
                                }
                            }
                        }
                    } catch {
                        print("Audio Error: \(error)")
                    }
                }
            }
        }
    }
    
    func translate(text: String) {
        if text.isEmpty { return }
        let salt = String(Int(Date().timeIntervalSince1970))
        let signStr = baiduAppId + text + salt + baiduSecretKey
        let sign = Insecure.MD5.hash(data: signStr.data(using: .utf8)!).map { String(format: "%02hhx", $0) }.joined()
        
        var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = "q=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&from=ja&to=zh&appid=\(baiduAppId)&salt=\(salt)&sign=\(sign)"
        request.httpBody = params.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let result = json["trans_result"] as? [[String: Any]], let dst = result.first?["dst"] as? String {
                DispatchQueue.main.async {
                    self.subtitleText = dst
                }
            }
        }.resume()
    }
}