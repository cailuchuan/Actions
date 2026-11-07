import SwiftUI
import Speech
import AVFoundation
import CryptoKit // 用于生成百度 API 要求的 MD5 签名

struct ContentView: View {
    @State private var isRecording = false
    @State private var recognizedText = "等待识别..."
    @State private var translatedText = "等待翻译..."
    
    // ⚠️ 替换成你自己的百度翻译 API 信息
    let baiduAppId = "20220331001153003"
    let baiduSecretKey = "a5vWHtKiWyDBgaWmkvlg"
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    var body: some View {
        VStack(spacing: 15) {
            Text("日文实时翻译").font(.title).bold()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("日文识别：").font(.headline).foregroundColor(.gray)
                    Text(recognizedText)
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.1)).cornerRadius(8)
                    
                    Text("中文翻译：").font(.headline).foregroundColor(.blue)
                    Text(translatedText)
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1)).cornerRadius(8)
                }
            }
            
            Button(action: {
                if isRecording { stopRecording() } else { startRecording() }
            }) {
                Text(isRecording ? "停止听译" : "开始听译")
                    .font(.title2).padding().frame(maxWidth: .infinity)
                    .background(isRecording ? Color.red : Color.green)
                    .foregroundColor(.white).cornerRadius(10)
            }
        }.padding()
    }
    
    func startRecording() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    do {
                        try self.startAudioEngine()
                        isRecording = true
                        recognizedText = "正在听声音..."
                    } catch { recognizedText = "启动失败: \(error.localizedDescription)" }
                } else {
                    recognizedText = "请允许麦克风和语音识别权限"
                }
            }
        }
    }
    
    func startAudioEngine() throws {
        recognitionTask?.cancel()
        self.recognitionTask = nil
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                let japanese = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.recognizedText = japanese
                    // 调用百度翻译
                    self.translateWithBaidu(text: japanese)
                }
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
    }
    
    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false
    }
    
    // MARK: - 百度翻译核心逻辑
    func translateWithBaidu(text: String) {
        // 简单的防抖：如果文字没变或者太短就不请求
        if text.isEmpty { return }
        
        let salt = String(Int(Date().timeIntervalSince1970)) // 随机数
        // 百度要求：appid + 文本 + 随机数 + 密钥 的 MD5
        let signStr = baiduAppId + text + salt + baiduSecretKey
        let sign = Insecure.MD5.hash(data: signStr.data(using: .utf8)!).map { String(format: "%02hhx", $0) }.joined()
        
        var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = "q=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&from=jp&to=zh&appid=\(baiduAppId)&salt=\(salt)&sign=\(sign)"
        request.httpBody = params.data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let transResult = json["trans_result"] as? [[String: Any]],
               let firstResult = transResult.first,
               let dst = firstResult["dst"] as? String {
                DispatchQueue.main.async {
                    self.translatedText = dst
                }
            }
        }.resume()
    }
}

@main
struct TranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
