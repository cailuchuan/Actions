import SwiftUI
import WebKit
import Speech
import AVFoundation

struct ContentView: View {
    @State private var isTranslating = false
    @State private var subtitleText = "等待视频播放..."
    
    // 默认填入一个占位提示
    @State private var urlString = "http://[你的IPv6地址]:8096"
    @State private var currentURL: URL? = nil
    @FocusState private var isUrlFocused: Bool
    
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
                    // ⚠️ 注意：这里我们去掉了 JS 强行抓音频的逻辑！
                    // 因为 IPv6 和 Jellyfin 的流媒体加密，JS 100% 抓不到，还会导致网页崩溃
                    AudioCaptureWebView(url: url, isListening: isTranslating) { audioBuffer in
                        self.recognitionRequest?.append(audioBuffer)
                    }
                    .edgesIgnoringSafeArea(.bottom)
                } else {
                    Text("请输入 Jellyfin 地址").foregroundColor(.gray)
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
        
        // 针对 IPv6 的特殊处理，千万别乱加 https，不然会报错
        if !formattedUrl.hasPrefix("http://") && !formattedUrl.hasPrefix("https://") {
            formattedUrl = "http://" + formattedUrl
        }
        
        if let url = URL(string: formattedUrl) {
            currentURL = url
            isUrlFocused = false
        } else {
            subtitleText = "网址格式错误，请检查 IPv6 格式"
        }
    }
    
    // MARK: - 麦克风听译逻辑（回到最稳的方案）
    func startTranslation() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    do {
                        try self.setupMicrophone()
                        self.setupSpeechRecognition()
                        isTranslating = true
                        subtitleText = "正在听麦克风声音（请外放视频）..."
                    } catch {
                        subtitleText = "启动失败，请检查权限"
                    }
                } else {
                    subtitleText = "请去设置允许麦克风和语音识别权限"
                }
            }
        }
    }
    
    func setupMicrophone() throws {
        let audioSession = AVAudioSession.sharedInstance()
        // 要求使用麦克风，并且允许混音（这样视频外放的声音也能被录进去）
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)
    }
    
    func setupSpeechRecognition() {
        recognitionTask?.cancel()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        // 开启麦克风硬件底层收音
        let inputNode = AVAudioEngine().inputNode
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result = result {
                let japanese = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.subtitleText = japanese
                }
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            self.recognitionRequest?.append(buffer)
        }
        
        let audioEngine = AVAudioEngine()
        audioEngine.attach(inputNode)
        audioEngine.prepare()
        try? audioEngine.start()
    }
    
    func stopTranslation() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        isTranslating = false
        subtitleText = "听译已停止"
    }
}

// 纯净版 WebView（去掉了那些会拦截网页的 JS）
struct AudioCaptureWebView: UIViewRepresentable {
    let url: URL
    let isListening: Bool
    let onAudioBuffer: (AVAudioPCMBuffer) -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
    }
}

@main
struct TranslatorApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}