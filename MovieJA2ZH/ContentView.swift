import SwiftUI
import AVFoundation

struct ContentView: View {
    @State var isRunning = false
    var audioRecorder: AVAudioRecorder!
    @State var audioBuffer = Data()
    private let chunkSize = 32000
    
    var body: some View {
        VStack(spacing:40) {
            Text("AI 实时翻译")
                .font(.system(size:48, weight:.bold))
            
            Button(isRunning ? "停止" : "开始翻译") {
                if !isRunning {
                    startMicCapture()
                    FloatSubtitleManager.shared.showSubtitleWindow()
                    isRunning = true
                } else {
                    stopMicCapture()
                    FloatSubtitleManager.shared.hideWindow()
                    isRunning = false
                }
            }
            .padding()
            .frame(width:300)
            .background(Color.red)
            .foregroundColor(.white)
            .font(.system(size:24))
            .cornerRadius(16)
        }
        .frame(maxWidth:.infinity, maxHeight:.infinity)
    }
    
    func startMicCapture() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {}
        // 麦克风持续采集，分片送入百度识别
    }
    
    func stopMicCapture() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
    }
}
