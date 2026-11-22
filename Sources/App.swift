import SwiftUI
import WebKit
import AVFoundation
import UIKit

/// 启动地址：改成自己的部署地址即可。App 只是个壳，页面内容全部来自线上，
/// 服务器上的网页更新 = App 内容即时更新（天然热更新，无需重新打包签名）。
let START_URL = URL(string: "https://box.1000.yun/")!

/// 仅对这些主机允许自签名/无效证书（自建域名用 Let's Encrypt 可清空此集合）
let TRUSTED_HOSTS: Set<String> = ["box.1000.yun"]

/// 与网页侧 toast 自证的版本号一致
let APP_VERSION = "1.0.6"

struct WebView: UIViewRepresentable {
    var pageDark: Binding<Bool>

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var pageDark: Binding<Bool>?
        var timer: Timer?

        /// 轮询页面主题：直接执行 JS 读 <html data-theme>，
        /// 不依赖消息注册等任何链路，必然可靠（0.6s 一次，开销可忽略）
        func startPolling(_ wv: WKWebView) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self, weak wv] _ in
                guard let self, let wv else { return }
                wv.evaluateJavaScript("document.documentElement.dataset.theme||''") { res, _ in
                    let dark = (res as? String) == "dark"
                    DispatchQueue.main.async {
                        if self.pageDark?.wrappedValue != dark { self.pageDark?.wrappedValue = dark }
                    }
                }
            }
        }

        deinit { timer?.invalidate() }

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
        // 壳版本标记：页面检测到就 toast，证明装的是哪个版本的壳
        cfg.userContentController.addUserScript(WKUserScript(
            source: "window.__APP_VER='\(APP_VERSION)';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        context.coordinator.pageDark = pageDark
        context.coordinator.startPolling(wv)
        wv.load(URLRequest(url: START_URL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.pageDark = pageDark
    }
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
                // 刘海/Home 条露出的窄条：颜色由轮询到的页面主题驱动（同页面底色）
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
