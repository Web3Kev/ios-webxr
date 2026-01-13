import SwiftUI
import ARKit
import SceneKit
import WebKit

// Enum to control WebView actions from SwiftUI
enum WebViewNavigationAction: Equatable {
    case idle
    case load(URL)
    case goBack
    case goForward
    case reload
}

struct ARWebView: UIViewRepresentable {
    // Control bindings
    @Binding var action: WebViewNavigationAction
    @Binding var isARActive: Bool
    
    // State reporting bindings
    @Binding var currentURLString: String // To update address bar when navigating inside web
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool

    // Helper to determine the correct bundle based on build environment
    private var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.automaticallyUpdatesLighting = true

        let webConfig = WKWebViewConfiguration()
        webConfig.allowsInlineMediaPlayback = true

        let contentController = webConfig.userContentController
        
        // Register script message handlers
        contentController.add(context.coordinator, name: "initAR")
        contentController.add(context.coordinator, name: "requestSession")
        contentController.add(context.coordinator, name: "stopAR")
        contentController.add(context.coordinator, name: "hitTest")

        // 1. Error Handling Injection
        let errorScript = WKUserScript(
            source: """
                    window.onerror = function(message, source, lineno, colno, error) {
                        window.webkit.messageHandlers.initAR.postMessage({
                            "callback": "console_error_bridge",
                            "error_message": message
                        });
                    };
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        contentController.addUserScript(errorScript)

        // 2. Load Polyfill
        if let url = resourceBundle.url(forResource: "webxr-polyfill", withExtension: "js"),
           let polyfillSource = try? String(contentsOf: url)
        {
            let userScript = WKUserScript(
                source: polyfillSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            contentController.addUserScript(userScript)
        }
        
        let webView = WKWebView(frame: .zero, configuration: webConfig)
        
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        webView.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: arView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
        ])

        context.coordinator.webView = webView
        context.coordinator.arView = arView

        webView.navigationDelegate = context.coordinator
        arView.session.delegate = context.coordinator

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        guard let webView = context.coordinator.webView else { return }
        
        // Handle Navigation Actions
        switch action {
        case .idle:
            break
        case .load(let url):
            // Load the URL
            webView.load(URLRequest(url: url))
            // Reset action to idle immediately via the coordinator helper
            DispatchQueue.main.async {
                self.action = .idle
            }
        case .goBack:
            webView.goBack()
            DispatchQueue.main.async { self.action = .idle }
        case .goForward:
            webView.goForward()
            DispatchQueue.main.async { self.action = .idle }
        case .reload:
            webView.reload()
            DispatchQueue.main.async { self.action = .idle }
        }
        
        // If SwiftUI set isARActive to false, but the session is running, force stop it
        if !isARActive && context.coordinator.isSessionRunning {
            context.coordinator.stopSession()
        }
    }

    func makeCoordinator() -> ARWebCoordinator {
        let coordinator = ARWebCoordinator()
        
        // Handle AR State
        coordinator.onSessionActiveChanged = { isActive in
            self.isARActive = isActive
        }
        
        // Handle Navigation State (Update buttons and URL bar)
        coordinator.onNavigationChanged = { [weak coordinator] in
            guard let webView = coordinator?.webView else { return }
            self.canGoBack = webView.canGoBack
            self.canGoForward = webView.canGoForward
            if let currentUrl = webView.url?.absoluteString {
                self.currentURLString = currentUrl
            }
        }
        
        return coordinator
    }
}