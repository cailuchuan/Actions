import SwiftUI
import Speech
import AVFoundation

struct ContentView: View {
    @State private var isRecording = false
    @State private var recognizedText = "点击下方按钮开始听译..."
    @State private var translatedText = "翻译结果将显示在这里"
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("日文实时翻译").font(.largeTitle).bold()
            VStack(alignment: .leading) {
                Text("识别到的日文：").font(.headline)
                Text(recognizedText).padding().background(Color.gray.opacity(0.2)).cornerRadius(8)
            }
            VStack(alignment: .leading) {
                Text("翻译成中文：").font(.headline)
                Text(translatedText).padding().background(Color.blue.opacity(0.1)).cornerRadius(8)
            }
            Button(action: {
                if isRecording { stopRecording() } else { startRecording() }
            }) {
                Text(isRecording ? "停止听译" : "开始听译")
                    .font(.title2).padding()
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
                    } catch { recognizedText = "启动失败: \(error.localizedDescription)" }
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
                recognizedText = result.bestTranscription.formattedString
                translatedText = "【测试】发现音频：" + recognizedText
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
}

@main
struct TranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
