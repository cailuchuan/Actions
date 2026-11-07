import UIKit

class FloatSubtitleManager: NSObject {
    static let shared = FloatSubtitleManager()
    private var subtitleWindow: UIWindow?
    private var textLabel: UILabel?
    private var panGesture: UIPanGestureRecognizer!
    
    override init() {
        super.init()
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(dragWindow(_:)))
    }
    
    func showSubtitleWindow() {
        guard subtitleWindow == nil else { return }
        let startFrame = CGRect(x: 30, y: 220, width: 340, height: 130)
        subtitleWindow = UIWindow(frame: startFrame)
        subtitleWindow?.windowLevel = UIWindow.Level(rawValue: 10000)
        subtitleWindow?.isHidden = false
        subtitleWindow?.backgroundColor = .clear
        
        textLabel = UILabel(frame: subtitleWindow!.bounds.insetBy(dx: 10, dy: 8))
        textLabel?.numberOfLines = 0
        textLabel?.textColor = .white
        textLabel?.backgroundColor = UIColor.black.withAlphaComponent(0.68)
        textLabel?.font = UIFont.systemFont(ofSize: 21, weight: .medium)
        textLabel?.layer.cornerRadius = 10
        textLabel?.clipsToBounds = true
        subtitleWindow?.addSubview(textLabel!)
        subtitleWindow?.addGestureRecognizer(panGesture)
    }
    
    func updateText(_ text: String) {
        textLabel?.text = text
    }
    
    func hideWindow() {
        subtitleWindow?.isHidden = true
        subtitleWindow = nil
    }
    
    @objc func dragWindow(_ gesture:UIPanGestureRecognizer) {
        guard let win = subtitleWindow else {return}
        let trans = gesture.translation(in: win)
        win.center.x += trans.x
        win.center.y += trans.y
        gesture.setTranslation(.zero, in: win)
    }
}
