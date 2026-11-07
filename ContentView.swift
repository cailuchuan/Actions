import SwiftUI
import AVKit
import Speech
import AVFoundation
import CryptoKit
import UIKit

// 🔥 核心：用画中画技术创建一个黑底白字的悬浮字幕条
class SubtitleViewController: UIViewController {
    var label: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        label = UILabel()
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 18)
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
    @State private var subtitleText = "点击下方开启悬浮字幕"
    
    // 画中画控制器
    @State private var pipController: AVPictureInPictureController?
    @State private var pipVC: SubtitleViewController?
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("全屏悬浮字幕神器").font(.largeTitle).bold()
            Text("使用方式：\n1. 点击下方按钮开启\n2. 开启后按 Home 键退出本 App\n3. 打开你的看片 App 全屏观看\n4. 悬浮窗会实时显示中文字幕")
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding()
            
            Button(action: {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }) {
                Text(isRecording ? "停止悬浮字幕" : "开启悬浮字幕")
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
                        self.startPiP() // 启动悬浮窗
                        isRecording = true
                    } catch {
                        subtitleText = "启动失败: \(error.localizedDescription)"
                    }
                } else {
                    subtitleText = "请在系统设置中允许麦克风和语音识别权限"
                }
            }
        }
    }
    
    // MARK: - 启动画中画悬浮窗
    func startPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("设备不支持画中画")
            return
        }
        
        let vc = SubtitleViewController()
        self.pipVC = vc
        
        // 使用 iOS 15+ 的视频通话画中画接口
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
        
        // 延迟一点启动，等待视图加载
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let pip = self.pipController, pip.isPictureInPicturePossible {
                pip.startPictureInPicture()
            } else {
                print("画中画启动失败")
            }
        }
    }
    
    // MARK: - 麦克风收音
    func startAudioEngine() throws {
        recognitionTask?.cancel()
        let audioSession = AVAudioSession.sharedInstance()
        // 允许外放，同时允许麦克风收音
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { result, error in
            if let result = result {
                let japanese = result.bestTranscription.formattedString
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
        subtitleText = "已停止悬浮字幕"
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
                    // 把翻译结果实时塞进悬浮窗里
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