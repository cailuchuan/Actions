import SwiftUI
import WebKit
import Speech
import AVFoundation

struct ContentView: View {
    @State private var isTranslating = false
    @State private var subtitleText = "等待视频播放..."
    
    // 浏览器状态
    @State private var urlString = "https://www.w3schools.com/html/html5_video.asp"
    @State private var currentURL: URL? = URL(string: "https://www.w3schools.com/html/html5_video.asp")
    @FocusState private var isUrlFocused: Bool
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. 顶部地址栏
            HStack {
                TextField("输入网址", text: $urlString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .focused($isUrlFocused)
                    .onSubmit {
                        loadURL()
                    }
                
                Button("前往") {
                    loadURL()
                }
                .padding(.leading, 5)
            }
            .padding()
            .background(Color(UIColor.systemGray6))
            
            // 2. 浏览器与字幕层
            ZStack(alignment: .bottom) {
                if let url = currentURL {
                    AudioCaptureWebView(url: url, isListening: isTranslating) { audioBuffer in
                        self.recognitionRequest?.append(audioBuffer)
                    }
                    .edgesIgnoringSafeArea(.bottom)
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
            
            // 3. 底部控制栏
            HStack {
                Spacer()
                Button(action: {
                    if isTranslating {
                        stopTranslation()
                    } else {
                        startTranslation()
                    }
                }) {
                    HStack {
                        Image(systemName: isTranslating ? "stop.circle.fill" : "play.circle.fill")
                        Text(isTranslating ? "停止字幕" : "开启内部音频翻译")
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
        var formattedUrl = urlString
        if !formattedUrl.hasPrefix("http://") && !formattedUrl.hasPrefix("https://") {
            formattedUrl = "https://" + formattedUrl
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
                        try self.setupAudioSession()
                        self.setupSpeechRecognition()
                        isTranslating = true
                        subtitleText = "正在监听网页音频..."
                    } catch {
                        subtitleText = "启动失败: \(error.localizedDescription)"
                    }
                } else {
                    subtitleText = "请去设置允许语音识别权限"
                }
            }
        }
    }
    
    func setupAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        // 允许后台和混音，防止网页视频静音
        try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try audioSession.setActive(true)
    }
    
    func setupSpeechRecognition() {
        recognitionTask?.cancel()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result = result {
                let japanese = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.subtitleText = japanese
                }
            }
        }
    }
    
    func stopTranslation() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        isTranslating = false
        subtitleText = "字幕已停止"
    }
}

// 带有 JS 注入抓取音频的 WebView
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
        // 只有当网址不同的时候才重新加载，避免打断视频
        if uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
        }
        
        if isListening {
            let js = """
            (function() {
                var videos = document.getElementsByTagName('video');
                if (videos.length > 0 && !window.isCapturing) {
                    window.isCapturing = true;
                    var video = videos[0];
                    
                    // ⚠️ 如果想边看边听声音，这里改成 false。但是苹果系统不允许同时输出到扬声器和 JS 处理，必须静音。
                    video.muted = true; 
                    
                    var audioCtx = new (window.AudioContext || window.webkitAudioContext)();
                    var source = audioCtx.createMediaElementSource(video);
                    var processor = audioCtx.createScriptProcessor(4096, 1, 1);
                    processor.onaudioprocess = function(e) {
                        var inputData = e.inputBuffer.getChannelData(0);
                        window.webkit.messageHandlers.audioHandler.postMessage(Array.from(inputData));
                    };
                    source.connect(processor);
                    processor.connect(audioCtx.destination);
                }
            })();
            """
            uiView.evaluateJavaScript(js)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onAudioBuffer: onAudioBuffer)
    }
    
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
        
        // 页面加载完成后，如果正在听，自动注入一次
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 可以在这里处理页面加载完的逻辑
        }
    }
}

@main
struct TranslatorApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}