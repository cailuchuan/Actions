import SwiftUI
import Speech
import AVFoundation

struct ContentView: View {
    @State private var isRecording = false
    @State private var statusText = "点击开始，然后切到后台播放视频"
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("日文实时听译测试").font(.title).bold()
            
            ScrollView {
                Text(statusText)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
            }
            
            Button(action: {
                if isRecording { stopRecording() } else { startRecording() }
            }) {
                Text(isRecording ? "停止翻译" : "开启后台翻译")
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
                        statusText = "正在后台听译，请打开视频 App..."
                    } catch {
                        statusText = "启动失败: \(error.localizedDescription)"
                    }
                } else {
                    statusText = "请去设置允许麦克风和语音识别权限"
                }
            }
        }
    }
    
    func startAudioEngine() throws {
        recognitionTask?.cancel()
        self.recognitionTask = nil
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                let japanese = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.statusText = "识别到: " + japanese
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
        statusText = "已停止听译。"
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
