import SwiftUI
import AVKit
import Speech
import AVFoundation
import CryptoKit
import UIKit

// 🔥 核心：画中画悬浮字幕视图
class SubtitleViewController: UIViewController {
    var label: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        label = UILabel()
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 16)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10)
        ])
    }
}

struct ContentView: View {
    // ⚠️ 填入你的百度翻译 API
    let baiduAppId = ""
    let baiduSecretKey = ""
    
    @State private var isRecording = false
    @State private var subtitleText = "点击下方开启悬浮实时翻译"
    
    // 画中画
    @State private var pipController: AVPictureInPictureController?
    @State private var pipVC: SubtitleViewController?
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    
    var body: some View {
        VStack(spacing: 25) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 60))
                .foregroundColor(isRecording ? .red : .blue)
                .padding(.top, 50)
            
            Text("AI 实时悬浮字幕").font(.largeTitle).bold()
            
            Text("使用说明：\n1. 点击下方按钮开启\n2. 立刻按 Home 键退出本 App\n3. 打开视频 App 并将手机外放音量调大\n4. 悬浮窗会实时显示日译中字幕")
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding()
            
            Spacer()
            
            Button(action: {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }) {
                Text(isRecording ? "停止并关闭悬浮窗" : "开启麦克风与悬浮窗")
                    .font(.title2).padding().frame(maxWidth: .infinity)
                    .background(isRecording ? Color.red : Color.green)
                    .foregroundColor(.white).cornerRadius(12)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 50)
        }
    }
    
    func startRecording() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    do {
                        try self.startAudioEngine()
                        self.startPiP()
                        isRecording = true
                    } catch {
                        subtitleText = "麦克风启动失败"
                    }
                } else {
                    subtitleText = "请允许麦克风和语音识别权限"
                }
            }
        }
    }
    
    // MARK: - 强行拉起悬浮窗（画中画）
    func startPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        
        let vc = SubtitleViewController()
        self.pipVC = vc
        
        let pipVideoCallVC = AVPictureInPictureVideoCallViewController()
        pipVideoCallVC.addChild(vc)
        pipVideoCallVC.view.addSubview(vc.view)
        vc.view.frame = pipVideoCallVC.view.bounds
        vc.didMove(toParent: pipVideoCallVC)
        
        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: vc.view,
            contentViewController: pipVideoCallVC
        )
        
        pipController = AVPictureInPictureController(contentSource: contentSource)
        pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        
        // 延迟 0.5 秒启动，防止视图未加载
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let pip = self.pipController, pip.isPictureInPicturePossible {
                pip.startPictureInPicture()
            }
        }
    }
    
    // MARK: - 麦克风收音
    func startAudioEngine() throws {
        recognitionTask?.cancel()
        let audioSession = AVAudioSession.sharedInstance()
        // 允许后台播放和混音
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result = result {
                let japanese = result.bestTranscription.formattedString
                // 如果有 API 就翻译，没有就显示日文
                if !self.baiduAppId.isEmpty {
                    self.translateWithBaidu(text: japanese)
                } else {
                    DispatchQueue.main.async {
                        self.subtitleText = japanese
                        self.pipVC?.label.text = japanese
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
        subtitleText = "已停止悬浮翻译"
    }
    
    // MARK: - 百度翻译
    func translateWithBaidu(text: String) {
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
                    self.subtitleText = dst
                    // 核心：把翻译结果塞进悬浮窗
                    self.pipVC?.label.text = dst
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