import Foundation
import ARKit
import SceneKit
import WebKit

@MainActor
class ARWebCoordinator: NSObject, WKNavigationDelegate, ARSessionDelegate, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var arView: ARSCNView?
    var dataCallbackName: String?
    var isSessionRunning = false

    var onSessionActiveChanged: ((Bool) -> Void)?
    
    var onNavigationChanged: (() -> Void)?


    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onNavigationChanged?()
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onNavigationChanged?()
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onNavigationChanged?()
    }

    // --- AR / Image Processing Properties ---
    
    // Reuse CIContext for performance
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    // Cache the sRGB color space
    let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // Throttling for image sending to maintain FPS
    var frameCounter = 0
    let frameSkip = 15
    
    // --- WKScriptMessageHandler ---
    
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }

        if let errorMsg = body["error_message"] as? String {
            print("JS Error: \(errorMsg)")
            return
        }

        switch message.name {
        case "initAR":
            if let callback = body["callback"] as? String {
                replyToJS(callback: callback, data: "ios-ar-device-id")
            }
        case "requestSession":
            if let options = body["options"] as? [String: Any],
               let callbackName = body["data_callback"] as? String
            {
                self.dataCallbackName = callbackName
                self.startARSession(options: options)
                
                // Notify UI to hide address bar
                self.onSessionActiveChanged?(true)
                
                if let responseCallback = body["callback"] as? String {
                    replyToJS(
                        callback: responseCallback,
                        data: ["cameraAccess": true, "worldAccess": true, "webXRAccess": true])
                }
            }
        case "stopAR":
            // JS requested stop
            self.stopSession(notifyJS: false)
            
        case "hitTest":
            // Handle Hit Testing using modern Raycast API
            if let x = body["x"] as? Double,
               let y = body["y"] as? Double,
               let callback = body["callback"] as? String {
                self.performHitTest(x: x, y: y, callback: callback)
            }
            
        default: break
        }
    }

    func startARSession(options: [String: Any]) {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        arView?.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
    }
    
    // Helper to stop session from either JS or SwiftUI
    func stopSession(notifyJS: Bool = true) {
        guard isSessionRunning else { return }
        
        // 1. Stop Native Session immediately
        isSessionRunning = false
        arView?.session.pause()
        
        // 2. Notify UI to show address bar again
        self.onSessionActiveChanged?(false)
        
        // 3. Force Reload the Page
        print("AR Session stopped. Reloading web page to clean state.")
        webView?.reload()
    }
    
    // --- Hit Test Implementation ---
    func performHitTest(x: Double, y: Double, callback: String) {
        guard let arView = arView else { return }
        
        let point = CGPoint(
            x: CGFloat(x) * arView.bounds.width,
            y: CGFloat(y) * arView.bounds.height
        )
        
        var results: [ARRaycastResult] = []
        
        // 1. Try Existing Plane Geometry
        if let query = arView.raycastQuery(from: point, allowing: .existingPlaneGeometry, alignment: .any) {
            results = arView.session.raycast(query)
        }
        
        // 2. Fallback to Estimated Plane
        if results.isEmpty {
            if let query = arView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any) {
                results = arView.session.raycast(query)
            }
        }
        
        var hitsPayload: [[String: Any]] = []
        
        for result in results {
            let tf = result.worldTransform
            let tfArray = toArray(tf)
            
            var hitData: [String: Any] = [
                "world_transform": tfArray
            ]
            
            if let anchor = result.anchor {
                hitData["uuid"] = anchor.identifier.uuidString
            }
            
            hitsPayload.append(hitData)
        }
        
        replyToJS(callback: callback, data: hitsPayload)
    }

    // --- ARSessionDelegate ---

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated {
            guard isSessionRunning,
                let webView = self.webView,
                let callbackName = self.dataCallbackName
            else { return }

            // Throttle image processing
            frameCounter += 1
            if frameCounter % 2 != 0 { return }

            let orientation: UIInterfaceOrientation = .portrait
            let viewportSize = webView.bounds.size

            let viewMatrix = frame.camera.viewMatrix(for: orientation)
            let cameraTransform = viewMatrix.inverse
            let projMatrix = frame.camera.projectionMatrix(
                for: orientation,
                viewportSize: viewportSize,
                zNear: 0.01,
                zFar: 1000
            )

            // ARKit buffers are usually landscape. Since we rotate to .right (Portrait),
            // we must swap width and height for the JS payload.
            let rawWidth = CVPixelBufferGetWidth(frame.capturedImage)
            let rawHeight = CVPixelBufferGetHeight(frame.capturedImage)

            let finalWidth = rawHeight
            let finalHeight = rawWidth

            var jsCommand = "if(!window.NativeARData){window.NativeARData={};}"
            
            // 1. Direct assignments
            jsCommand += "window.NativeARData.timestamp = \(frame.timestamp * 1000);"
            jsCommand += "window.NativeARData.light_intensity = \(frame.lightEstimate?.ambientIntensity ?? 1000);"
            jsCommand += "window.NativeARData.worldMappingStatus = 'ar_worldmapping_not_available';"
            
            // 2. Matrix Arrays
            jsCommand += "window.NativeARData.camera_transform = \(fastFloatArrayToString(cameraTransform));"
            jsCommand += "window.NativeARData.camera_view = \(fastFloatArrayToString(viewMatrix));"
            jsCommand += "window.NativeARData.projection_camera = \(fastFloatArrayToString(projMatrix));"

            // 3. Native Video
            let pixelBuffer = frame.capturedImage
            if let base64String = convertPixelBufferToBase64(pixelBuffer, quality: 0.6) {
                jsCommand += "window.NativeARData.video_data = '\(base64String)';"
                jsCommand += "window.NativeARData.video_width = \(finalWidth);"
                jsCommand += "window.NativeARData.video_height = \(finalHeight);"
            }

            // 4. Execute callback
            jsCommand += "\(callbackName)();"

            webView.evaluateJavaScript(jsCommand, completionHandler: nil)
        }
    }

    // --- Helpers ---

    private func convertPixelBufferToBase64(_ pixelBuffer: CVPixelBuffer, quality: CGFloat)
        -> String?
    {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        guard
            let cgImage = ciContext.createCGImage(
                ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: sRGBColorSpace)
        else {
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)

        guard let jpegData = uiImage.jpegData(compressionQuality: quality) else { return nil }

        return jpegData.base64EncodedString()
    }

    private func toArray(_ m: simd_float4x4) -> [Float] {
        return [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
        ]
    }

    private func replyToJS(callback: String, data: Any) {
        guard let webView = webView else { return }
        if let str = data as? String {
            webView.evaluateJavaScript("\(callback)('\(str)')")
        } else if let jsonData = try? JSONSerialization.data(withJSONObject: data),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            webView.evaluateJavaScript("\(callback)(\(jsonString))")
        }
    }

    private func fastFloatArrayToString(_ m: simd_float4x4) -> String {
        return "[\(m.columns.0.x),\(m.columns.0.y),\(m.columns.0.z),\(m.columns.0.w)," +
               "\(m.columns.1.x),\(m.columns.1.y),\(m.columns.1.z),\(m.columns.1.w)," +
               "\(m.columns.2.x),\(m.columns.2.y),\(m.columns.2.z),\(m.columns.2.w)," +
               "\(m.columns.3.x),\(m.columns.3.y),\(m.columns.3.z),\(m.columns.3.w)]"
    }
}