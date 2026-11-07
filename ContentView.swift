import SwiftUI
import Speech
import AVFoundation
import AVKit
import CryptoKit
import UIKit

// 用于画中画的字幕视图
class SubtitleViewController: UIViewController {
    var label: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        label = UILabel()
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 24)
        label.textAlignment = .center
        label.numberOfLines = 0
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
    @State private var isRecording = false
    @State private var recognizedText = "等待日文..."
    @State private var translatedText = "等待翻译..."
    
    // ⚠️ 替换成你自己的百度 API
    let baiduAppId = "你的APP_ID填这里"
    let baiduSecretKey = "你的密钥填这里"
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    // 画中画控制器和视图
    @State private var pipController: AVPictureInPictureController?
    @State private var pipVC: SubtitleViewController?
    
    var body: some View {
        VStack(spacing: 15) {
            Text("日文悬浮翻译").font(.title).bold()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("日文：").font(.headline)
                    Text(recognizedText).padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.gray.opacity(0.2)).cornerRadius(8)
                    
                    Text("中文：").font(.headline).foregroundColor(.blue)
                    Text(translatedText).padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.1)).cornerRadius(8)
                }
            }
            
            Button(action: {
                if isRecording { stopRecording() } else { startRecording() }
            }) {
                Text(isRecording ? "停止并关闭悬浮窗" : "开启听译并悬浮")
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
                        self.startPiP() // 启动画中画
                        isRecording = true
                    } catch { recognizedText = "启动失败" }
                }
            }
        }
    }
    
    // MARK: - 核心：启动画中画
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let pip = self.pipController, pip.isPictureInPicturePossible {
                pip.startPictureInPicture()
            } else {
                print("画中画启动失败")
            }
        }
    }
    
    // MARK: - 音频与翻译
    func startAudioEngine() throws {
        recognitionTask?.cancel()
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                let japanese = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.recognizedText = japanese }
                self.translateWithBaidu(text: japanese)
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
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let transResult = json["trans_result"] as? [[String: Any]],
               let dst = transResult.first?["dst"] as? String {
                DispatchQueue.main.async {
                    self.translatedText = dst
                    // 把翻译结果实时塞进悬浮窗的 UILabel 里！
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
