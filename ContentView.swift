import SwiftUI
import WebKit
import Speech
import AVFoundation
import CryptoKit

// ⚠️ 把 AVAudioEngine 放在外面作为全局单例，彻底解决纯脚本编译的闪退和报错问题
class AudioManager {
    static let shared = AudioManager()
    let engine = AVAudioEngine()
    
    func startRecording() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            SpeechManager.shared.recognitionRequest?.append(buffer)
        }
        
        engine.prepare()
        try? engine.start()
    }
    
    func stopRecording() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}

class SpeechManager {
    static let shared = SpeechManager()
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var recognitionTask: SFSpeechRecognitionTask?
    
    func start(onResult: @escaping (String) -> Void) {
        recognitionTask?.cancel()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        recognitionTask = recognizer?.recognitionTask(with: request) { result, error in
            if let result = result {
                onResult(result.bestTranscription.formattedString)
            }
        }
    }
    
    func stop() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
    }
}

struct ContentView: View {
    @State private var isTranslating = false
    @State private var subtitleText = "等待视频播放..."
    
    // ⚠️ 这里换成你的 Jellyfin 地址
    @State private var urlString = "http://[你的IPv6]:8096"
    @State private var currentURL: URL? = nil
    @FocusState private var isUrlFocused: Bool
    
    // ⚠️ 百度 API 如果不需要可以留空，留空就只显示日文
    let baiduAppId = ""
    let baiduSecretKey = ""
    
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
                        SpeechManager.shared.recognitionRequest?.append(audioBuffer)
                    }
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
        }
    }
    
    func startTranslation() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    SpeechManager.shared.start { japanese in
                        if !self.baiduAppId.isEmpty {
                            self.translateWithBaidu(text: japanese)
                        } else {
                            DispatchQueue.main.async { self.subtitleText = japanese }
                        }
                    }
                    self.isTranslating = true
                    self.subtitleText = "正在抓取网页音频..."
                }
            }
        }
    }
    
    func stopTranslation() {
        SpeechManager.shared.stop()
        isTranslating = false
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

// MARK: - 已修复报错的 WebView 组件
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
        // 修复报错点：将 Coordinator 设置为 navigationDelegate
        webView.navigationDelegate = context.coordinator 
        webView.load(URLRequest(url: url))
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
        
        if isListening {
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
                    } catch(e) {}
                    return true;
                }
                if (!captureMedia()) {
                    var interval = setInterval(function() { if (captureMedia()) clearInterval(interval); }, 2000);
                }
            })();
            """
            uiView.evaluateJavaScript(js)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onAudioBuffer: onAudioBuffer)
    }
    
    // 修复报错点：让 Coordinator 遵守 WKNavigationDelegate 协议
    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
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