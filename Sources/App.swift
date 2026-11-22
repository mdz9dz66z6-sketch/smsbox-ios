import SwiftUI
import WebKit
import AVFoundation
import UIKit

/// 启动地址：改成自己的部署地址即可。App 只是个壳，页面内容全部来自线上，
/// 服务器上的网页更新 = App 内容即时更新（天然热更新，无需重新打包签名）。
let START_URL = URL(string: "https://box.1000.yun/")!

/// 仅对这些主机允许自签名/无效证书（自建域名用 Let's Encrypt 可清空此集合）
let TRUSTED_HOSTS: Set<String> = ["box.1000.yun"]

/// 把窗口安全区（刘海/状态栏高度、Home 指示条）注入页面的 CSS 变量。
/// 不走 WKWebView 的 env()（部分环境不透传），由壳直接注入，日夜模式
/// 由页面自己控制（页面背景一直画到状态栏底下，跟随主题无割裂）。
func injectSafeInsets(_ wv: WKWebView) {
    let window = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first
    let top = window?.safeAreaInsets.top ?? 0
    let bottom = window?.safeAreaInsets.bottom ?? 0
    let js = "document.documentElement.style.setProperty('--sat','\(Int(top))px');" +
             "document.documentElement.style.setProperty('--sab','\(Int(bottom))px');"
    wv.evaluateJavaScript(js, completionHandler: nil)
}

/// 观察自身安全区变化（旋转屏幕等）触发重新注入
final class InsetsWebView: WKWebView {
    var onInsetsChange: (() -> Void)?
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onInsetsChange?()
    }
}

struct WebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 通话页面需要：内联自动播放 + getUserMedia 免手势
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = false
        let wv = InsetsWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.onInsetsChange = { [weak wv] in
            if let wv { injectSafeInsets(wv) }
        }
        wv.load(URLRequest(url: START_URL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
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

        // 每次页面加载完成注入一次（SPA 内部跳转不刷新页面，无需重复）
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            injectSafeInsets(webView)
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
            // 全屏铺到刘海下：状态栏底下是页面自己的背景色，日夜模式无割裂；
            // 刘海高度由壳注入 --sat，页面顶栏自动下移
            WebView()
                .ignoresSafeArea()
        }
    }
}
