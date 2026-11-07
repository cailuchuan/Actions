import SwiftUI
import AVKit
import Speech
import AVFoundation
import CryptoKit
import UIKit

struct ContentView: View {
    // ⚠️ 填入你的百度翻译 API
    let baiduAppId = ""
    let baiduSecretKey = ""
    
    @State private var isRecording = false
    @State private var statusText = "点击下方按钮开启悬浮窗"
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    
    // 画中画相关
    @State private var pipController: AVPictureInPictureController?
    @State private var pipView: UIView?
    @State private var pipLabel: UILabel?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("AI 实时翻译").font(.largeTitle).bold()
            
            Text(statusText)
                .foregroundColor(.blue)
                .multilineTextAlignment(.center)
                .padding()
            
            Button(action: {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }) {
                Text(isRecording ? "停止" : "开启麦克风与悬浮窗")
                    .font(.title2).padding().frame(maxWidth: .infinity)
                    .background(isRecording ? Color.red : Color.green)
                    .foregroundColor(.white).cornerRadius(12)
            }
            .padding(.horizontal, 30)
        }
    }
    
    func startRecording() {
        // 1. 申请权限
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    self.statusText = "权限已允许，正在启动悬浮窗..."
                    do {
                        try self.setupAudioEngine()
                        self.startPiP()
                        self.isRecording = true
                    } catch {
                        self.statusText = "启动失败: \(error.localizedDescription)"
                    }
                } else {
                    self.statusText = "请在设置中允许麦克风和语音识别权限！"
                }
            }
        }
    }
    
    // 2. 启动画中画（强行弹窗）
    func startPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            statusText = "设备不支持画中画"
            return
        }
        
        // 构造一个用于画中画的视图
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 60))
        view.backgroundColor = .black
        self.pipView = view
        
        let label = UILabel(frame: view.bounds)
        label.text = "等待字幕..."
        label.textColor = .white
        label.textAlignment = .center
        label.font = .boldSystemFont(ofSize: 16)
        view.addSubview(label)
        self.pipLabel = label
        
        // 必须用 AVPlayerLayer 才能触发画中画
        let playerLayer = AVPlayerLayer()
        playerLayer.frame = view.bounds
        view.layer.addSublayer(playerLayer)
        
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        
        // 延迟 1 秒启动，等待权限注册
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let pip = self.pipController, pip.isPictureInPicturePossible {
                pip.startPictureInPicture()
                self.statusText = "✅ 悬浮窗已弹出！请立刻按上滑退到桌面。"
            } else {
                self.statusText = "❌ 系统拒绝弹出画中画（纯代码环境权限不足）。"
            }
        }
    }
    
    // 3. 麦克风与识别
    func setupAudioEngine() throws {
        recognitionTask?.cancel()
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result = result {
                let text = result.bestTranscription.formattedString
                if !self.baiduAppId.isEmpty {
                    self.translate(text: text)
                } else {
                    DispatchQueue.main.async {
                        self.pipLabel?.text = text
                    }
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
        pipController?.stopPictureInPicture()
        isRecording = false
        statusText = "已停止"
    }
    
    // 4. 百度翻译
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
            guard let data = data else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let transResult = json["trans_result"] as? [[String: Any]],
               let dst = transResult.first?["dst"] as? String {
                DispatchQueue.main.async {
                    self.pipLabel?.text = dst
                }
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