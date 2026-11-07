import SwiftUI
import AVKit
import Speech
import AVFoundation
import CryptoKit

struct ContentView: View {
    // ⚠️ 填入你的百度翻译 API
    let baiduAppId = ""
    let baiduSecretKey = ""
    
    // ⚠️ 填入你的视频直链（真实的 MP4 路径）
    let videoURLString = "http://nas.cctvb.dpdns.org:5055/你的文件夹/视频.mp4"
    let username = "cailcc"
    let password = "你的密码"

    @State private var player: AVPlayer?
    @State private var subtitleText = "等待播放..."
    @State private var isPlaying = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let player = player {
                VideoPlayer(player: player)
                    .edgesIgnoringSafeArea(.all)
                    .onAppear {
                        startAudioCapture()
                        player.play()
                    }
            } else {
                ProgressView("加载中...")
            }

            if isPlaying {
                Text(subtitleText)
                    .font(.title3.bold())
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(10)
                    .padding(.bottom, 50)
            }
        }
        .onAppear {
            setupPlayer()
        }
    }

    func setupPlayer() {
        guard let url = URL(string: videoURLString) else { return }
        
        var headers: [String: String] = [:]
        if !username.isEmpty {
            let loginString = "\(username):\(password)"
            if let loginData = loginString.data(using: .utf8) {
                headers = ["Authorization": "Basic \(loginData.base64EncodedString())"]
            }
        }
        
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.isPlaying = true
    }

    func startAudioCapture() {
        SFSpeechRecognizer.requestAuthorization { status in
            if status == .authorized {
                DispatchQueue.main.async {
                    do {
                        let audioSession = AVAudioSession.sharedInstance()
                        // 允许后台混音，方便抓取
                        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
                        try audioSession.setActive(true)
                        
                        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
                        let request = SFSpeechAudioBufferRecognitionRequest()
                        let audioEngine = AVAudioEngine()
                        let inputNode = audioEngine.inputNode
                        
                        recognizer?.recognitionTask(with: request) { result, error in
                            if let result = result {
                                let text = result.bestTranscription.formattedString
                                if !self.baiduAppId.isEmpty {
                                    self.translate(text: text)
                                } else {
                                    self.subtitleText = text
                                }
                            }
                        }
                        
                        let recordingFormat = inputNode.outputFormat(forBus: 0)
                        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                            request.append(buffer)
                        }
                        audioEngine.prepare()
                        try audioEngine.start()
                    } catch {
                        print("Audio Error")
                    }
                }
            }
        }
    }

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
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let result = json["trans_result"] as? [[String: Any]], let dst = result.first?["dst"] as? String {
                DispatchQueue.main.async {
                    self.subtitleText = dst
                }
            }
        }.resume()
    }
}
