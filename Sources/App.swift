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
let APP_VERSION = "1.0.9"

/* 最终方案（网页保持原始全屏渲染）：
   WebView 铺满全屏，页面自己把背景画到状态栏底下、自己处理主题动画；
   壳只在启动时把「安全区像素值」注入页面 CSS 变量 --sat/--sab，
   页面顶栏/底栏据此从正确像素开始渲染。
   注入带多次重试：页面加载早期窗口可能未布局完拿到 0，
   直到回读确认注入成功为止。旋转屏幕后重新注入。 */

/// 观察自身安全区变化（旋转等）→ 重新走注入流程
final class InsetsWebView: WKWebView {
    var injected = false
    var onInsetsChange: (() -> Void)?
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        injected = false
        onInsetsChange?()
    }
}

/// 读取真实安全区（WebView 自身与 keyWindow 取最大值），注入并回读确认
func injectSafeInsets(_ wv: WKWebView, done: @escaping (Bool) -> Void) {
    var top = wv.safeAreaInsets.top
    var bottom = wv.safeAreaInsets.bottom
    if let win = UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
        top = max(top, win.safeAreaInsets.top)
        bottom = max(bottom, win.safeAreaInsets.bottom)
    }
    let t = Int(top), b = Int(bottom)
    guard t > 0 || b > 0 else { done(false); return }
    let js = "var d=document.documentElement.style;" +
             "d.setProperty('--sat','\(t)px');" +
             "d.setProperty('--sab','\(b)px');" +
             "d.getPropertyValue('--sat')"
    wv.evaluateJavaScript(js) { _, _ in done(true) }
}

struct WebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 通话页面需要：内联自动播放 + getUserMedia 免手势
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = false
        // 壳版本标记：页面检测到就 toast（含注入回读值），自证装的是哪个包
        cfg.userContentController.addUserScript(WKUserScript(
            source: "window.__APP_VER='\(APP_VERSION)';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))

        let wv = InsetsWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.onInsetsChange = { [weak wv] in
            guard let wv else { return }
            context.coordinator.injectWithRetries(wv)
        }
        wv.load(URLRequest(url: START_URL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        // 每次页面加载完成 + 旋转后，多次重试注入直到成功
        func injectWithRetries(_ wv: WKWebView) {
            guard let iv = wv as? InsetsWebView else { return }
            for d in [0.05, 0.3, 0.8, 1.6, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak iv] in
                    guard let iv, !iv.injected else { return }
                    injectSafeInsets(iv) { ok in
                        if ok { iv.injected = true }
                    }
                }
            }
        }

        // 页面每次加载完成都注入（页面自检刷新、SPA 跳转均覆盖）
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            injectWithRetries(webView)
        }

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

        // getUserMedia 麦克风/摄像头授权：网页层直接放行（注意参数标签必须是
        // initiatedByFrame——之前写成 initiatedBy 导致协议不匹配、delegate 静默
        // 失效，WebKit 每次都走默认弹窗。系统层 TCC 权限在 App 启动时统一申请）
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }
}

@main
struct SmsBoxApp: App {
    init() {
        // 系统层（TCC）麦克风权限：启动时申请一次。 granted 后网页层
        // requestMediaCapturePermissionFor 的 .grant 才能真正静默生效；
        // 已授权过时此调用无感知，首次安装只会弹这一次系统授权框
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        // 通话场景的音频路由：扬声器+麦克风，蓝牙耳机可用
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
    }
    var body: some Scene {
        WindowGroup {
            // 全屏：状态栏底下就是页面自己的背景色与自己的主题动画，无任何壳层色块
            WebView()
                .ignoresSafeArea()
        }
    }
}
