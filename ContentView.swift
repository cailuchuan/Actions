import SwiftUI
import WebKit
import Speech
import AVFoundation
import CryptoKit

struct ContentView: View {
    @State private var isTranslating = false
    @State private var subtitleText = "等待视频播放..."
    
    // ⚠️ 填入你的 IPv6 地址
    @State private var urlString = "http://[你的IPv6]:8096"
    @State private var currentURL: URL? = nil
    @FocusState private var isUrlFocused: Bool
    
    // ⚠️ 填入你的百度翻译 API
    let baiduAppId = "你的APP_ID"
    let baiduSecretKey = "你的密钥"
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部地址栏
            HStack {
                TextField("输入网址", text: $urlString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .focused($isUrlFocused)
                    .onSubmit { loadURL() }
                
                Button("前往") { loadURL() }
                    .padding(.leading, 5)
            }
            .padding()
            .background(Color(UIColor.systemGray6))
            
            // 浏览器与字幕层
            ZStack(alignment: .bottom) {
                if let url = currentURL {
                    WebView(url: url)
                        .edgesIgnoringSafeArea(.bottom)
                } else {
                    Text("请输入网址并点击前往").foregroundColor(.gray)
                }
                
                // 底部悬浮字幕
                VStack {
                    Spacer()
                    if isTranslating {
                        Text(subtitleText)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(8)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 80)
                    }
                }
            }
            
            // 底部控制栏
            HStack {
                Spacer()
                Button(action: {
                    if isTranslating { stopTranslation() } else { startTranslation() }
                }) {
                    HStack {
                        Image(systemName: isTranslating ? "stop.circle.fill" : "mic.circle.fill")
                        Text(isTranslating ? "停止听译" : "开启麦克风听译")
                    }
                    .font(.headline)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
                    .background(isTranslating ? Color.red.opacity(0.9) : Color.blue.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(25)
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .background(Color(UIColor.systemGray6))
        }
    }
    
    func loadURL() {
        var formattedUrl = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !formattedUrl.hasPrefix("http://") && !formattedUrl.hasPrefix("https://") {
            formattedUrl = "http://" + formattedUrl
        }
        if let url = URL(string: formattedUrl) {
            currentURL = url
            isUrlFocused = false
        }
    }
    
    func startTranslation() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    do {
                        try self.setupMicrophone()
                        self.setupSpeechRecognition()
                        isTranslating = true
                        subtitleText = "正在听麦克风声音..."
                    } catch {
                        subtitleText = "启动失败"
                    }
                }
            }
        }
    }
    
    func setupMicrophone() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)
    }
    
    func setupSpeechRecognition() {
        recognitionTask?.cancel()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result = result {
                let japanese = result.bestTranscription.formattedString
                // 调用百度翻译
                self.translateWithBaidu(text: japanese)
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try? audioEngine.start()
    }
    
    func translateWithBaidu(text: String) {
        if text.isEmpty { return }
        let salt = String(Int(Date().timeIntervalSince1970))
        let signStr = baiduAppId + text + salt + baiduSecretKey
        let sign = Insecure.MD5.hash(data: signStr.data(using: .utf8)!).map { String(format: "%02hhx", $0) }.joined()
        
        var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = "q=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&from=jp&to=zh&appid=\(baiduAppId)&salt=\(salt)&sign=\(sign)"
        request.httpBody = params.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let transResult = json["trans_result"] as? [[String: Any]],
               let dst = transResult.first?["dst"] as? String {
                DispatchQueue.main.async {
                    self.subtitleText = dst
                }
            }
        }.resume()
    }
    
    func stopTranslation() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        isTranslating = false
        subtitleText = "听译已停止"
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
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