import SwiftUI
import WebKit
import AVFoundation
import UIKit

/// 启动地址：改成自己的部署地址即可。App 只是个壳，页面内容全部来自线上，
/// 服务器上的网页更新 = App 内容即时更新（天然热更新，无需重新打包签名）。
let START_URL = URL(string: "https://box.1000.yun/")!

/// 仅对这些主机允许自签名/无效证书（自建域名用 Let's Encrypt 可清空此集合）
let TRUSTED_HOSTS: Set<String> = ["box.1000.yun"]

/// 与网页 side 的 __APP_VER 保持一致（页面启动时会 toast 出来，自证装的是新包）
let APP_VERSION = "1.0.3"

/// 页面主题上报桥：网页切日/夜时 postMessage 通知壳，安全区填色跟随页面主题。
/// 页面没上报时（桥未生效）回退到系统外观，不会黑/白错乱。
final class ThemeBridge: NSObject, WKScriptMessageHandler {
    var onTheme: ((Bool) -> Void)?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "native",
              let d = message.body as? [String: Any],
              let t = d["theme"] as? String else { return }
        onTheme?(t == "dark")
    }
}

struct WebView: UIViewRepresentable {
    @Binding var pageDark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let bridge = ThemeBridge()

        // 自签名证书兜底（仅限 TRUSTED_HOSTS）
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  TRUSTED_HOSTS.contains(challenge.protectionSpace.host) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        // getUserMedia 麦克风授权请求：交给系统权限弹窗（Info.plist 已声明用途）
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedBy frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 通话页面需要：内联自动播放 + getUserMedia 免手势
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = false

        let bridge = context.coordinator.bridge
        bridge.onTheme = { dark in
            DispatchQueue.main.async { self.pageDark = dark }
        }
        cfg.userContentController.add(bridge, name: "native")
        // 壳版本标记：页面检测到就 toast，证明装的是哪个版本的壳
        cfg.userContentController.addUserScript(WKUserScript(
            source: "window.__APP_VER='\(APP_VERSION)';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.load(URLRequest(url: START_URL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@main
struct SmsBoxApp: App {
    init() {
        // 通话场景的音频路由：扬声器+麦克风，蓝牙耳机可用
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
    }
    var body: some Scene {
        WindowGroup {
            ZStack {
                // 刘海/Home 条露出的窄条：颜色跟随页面主题（页面通过桥上报），
                // 页面未上报前先用系统外观兜底
                (pageDark ? Color(red: 0x1f/255, green: 0x24/255, blue: 0x2b/255)
                          : Color(red: 0xf1/255, green: 0xf3/255, blue: 0xf5/255))
                    .ignoresSafeArea()
                // WebView 完整放在安全区内：几何上不可能与刘海/状态栏/Home 条重叠
                WebView(pageDark: $pageDark)
            }
        }
    }
    @State private var pageDark = UITraitCollection.current.userInterfaceStyle == .dark
}
