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
let APP_VERSION = "1.0.4"

/* 官方方案：WebView 全屏铺到刘海下（页面 viewport-fit=cover +
   env(safe-area-inset-*) 自动避让，主题天然跟随网页自身背景）。
   仅当官方 env 链路失效时（极少数设备/系统组合），用注入兜底：
   读 WKWebView 自身的 safeAreaInsets（UIKit 属性，可靠），
   大于 0 才注入页面 CSS 变量，避免把正常的 env 覆盖成 0。 */

/// 观察自身安全区变化（旋转等）触发重新注入
final class InsetsWebView: WKWebView {
    var onInsetsChange: (() -> Void)?
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onInsetsChange?()
    }
}

func injectSafeInsets(_ wv: WKWebView) {
    let t = Int(wv.safeAreaInsets.top)
    let b = Int(wv.safeAreaInsets.bottom)
    guard t > 0 || b > 0 else { return }        // 官方 env 正常时不动
    let js = "document.documentElement.style.setProperty('--sat','\(t)px');" +
             "document.documentElement.style.setProperty('--sab','\(b)px');"
    wv.evaluateJavaScript(js, completionHandler: nil)
}

struct WebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 通话页面需要：内联自动播放 + getUserMedia 免手势
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = false
        // 壳版本标记：页面检测到就 toast（含实测安全区数值），自证装的是哪个包
        cfg.userContentController.addUserScript(WKUserScript(
            source: "window.__APP_VER='\(APP_VERSION)';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))

        let wv = InsetsWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.onInsetsChange = { [weak wv] in if let wv { injectSafeInsets(wv) } }
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

        // 页面每次加载完成后延迟补一次注入（兜底 env 失效；页面加载早期
        // safeAreaInsets 可能尚未就位，所以延迟到布局稳定后再读）
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak webView] in
                if let wv = webView { injectSafeInsets(wv) }
            }
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
            // 全屏：状态栏底下就是页面自己的背景色，日夜模式无割裂、无填色层
            WebView()
                .ignoresSafeArea()
        }
    }
}
