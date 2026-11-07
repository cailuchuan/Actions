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
    let baiduAppId = ""
    let baiduSecretKey = ""
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    
    // ⚠️ 必须用 @State 强引用，否则闪退！
    @State private var audioEngine = AVAudioEngine()
    
    // 用来刷新 WebView 的标识
    @State private var refreshID = UUID()
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("输入网址", text: $urlString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .focused($isUrlFocused)
                    .onSubmit { loadURL() }
                Button("前往") { loadURL() }.padding(.leading, 5)
            }
            .padding().background(Color(UIColor.systemGray6))
            
            ZStack(alignment: .bottom) {
                if let url = currentURL {
                    AudioCaptureWebView(url: url, isListening: isTranslating) { audioBuffer in
                        // 收到网页传来的音频，丢给语音识别
                        self.recognitionRequest?.append(audioBuffer)
                    }
                    .id(refreshID) // 强制刷新
                    .edgesIgnoringSafeArea(.bottom)
                }
                
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
            
            HStack {
                Spacer()
                Button(action: {
                    if isTranslating { stopTranslation() } else { startTranslation() }
                }) {
                    HStack {
                        Image(systemName: isTranslating ? "stop.circle.fill" : "waveform.circle.fill")
                        Text(isTranslating ? "停止抓取" : "开启内部音频抓取")
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
            .padding(.vertical, 10).background(Color(UIColor.systemGray6))
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
            refreshID = UUID() // 刷新网页
        }
    }
    
    func startTranslation() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    do {
                        self.setupSpeechRecognition()
                        self.isTranslating = true
                        self.refreshID = UUID() // 刷新 WebView 以注入 JS
                        self.subtitleText = "正在抓取内部音频..."
                    }
                }
            }
        }
    }
    
    func setupSpeechRecognition() {
        recognitionTask?.cancel()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result = result {
                let japanese = result.bestTranscription.formattedString
                if self.baiduAppId.isEmpty {
                    DispatchQueue.main.async { self.subtitleText = japanese }
                } else {
                    self.translateWithBaidu(text: japanese)
                }
            }
        }
    }
    
    func stopTranslation() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        isTranslating = false
        refreshID = UUID()
        subtitleText = "已停止"
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

// MARK: - 注入 JS 抓取音频的 WebView
struct AudioCaptureWebView: UIViewRepresentable {
    let url: URL
    let isListening: Bool
    let onAudioBuffer: (AVAudioPCMBuffer) -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "audioHandler")
        config.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
        
        if isListening {
            // 终极 JS 脚本：遍历所有可能的音视频标签，强行截获
            let js = """
            (function() {
                if (window.isCapturing) return;
                
                function captureMedia() {
                    var media = document.querySelectorAll('video, audio');
                    if (media.length === 0) return false;
                    
                    var target = null;
                    for (var i = 0; i < media.length; i++) {
                        if (!media[i].paused) { target = media[i]; break; }
                    }
                    if (!target) target = media[0];
                    
                    try {
                        window.isCapturing = true;
                        // 必须静音原视频，否则系统不允许抓取
                        target.muted = true; 
                        
                        var audioCtx = new (window.AudioContext || window.webkitAudioContext)({sampleRate: 44100});
                        var source = audioCtx.createMediaElementSource(target);
                        var processor = audioCtx.createScriptProcessor(4096, 1, 1);
                        
                        processor.onaudioprocess = function(e) {
                            var inputData = e.inputBuffer.getChannelData(0);
                            window.webkit.messageHandlers.audioHandler.postMessage(Array.from(inputData));
                        };
                        
                        source.connect(processor);
                        processor.connect(audioCtx.destination);
                        console.log("Audio capture started successfully");
                    } catch(e) {
                        console.log("Capture failed: " + e.message);
                    }
                    return true;
                }
                
                if (!captureMedia()) {
                    // 如果页面还没加载出视频，每2秒尝试一次
                    var interval = setInterval(function() {
                        if (captureMedia()) clearInterval(interval);
                    }, 2000);
                }
            })();
            """
            uiView.evaluateJavaScript(js)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onAudioBuffer: onAudioBuffer)
    }
    
    class Coordinator: NSObject, WKScriptMessageHandler {
        let onAudioBuffer: (AVAudioPCMBuffer) -> Void
        init(onAudioBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
            self.onAudioBuffer = onAudioBuffer
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let array = message.body as? [Float] else { return }
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(array.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(array.count)
            for i in 0..<array.count {
                buffer.floatChannelData?[0][i] = array[i]
            }
            self.onAudioBuffer(buffer)
        }
    }
}

@main
struct TranslatorApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}