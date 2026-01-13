import SwiftUI

struct ContentView: View {
    // Navigation State
    @State private var urlString: String = AppConfig.startURL
    @State private var navAction: WebViewNavigationAction = .load(URL(string: AppConfig.startURL)!)
    
    // Web State
    @State private var isARActive: Bool = false
    @State private var canGoBack: Bool = false
    @State private var canGoForward: Bool = false
    
    // Custom Color: #272727 (RGB 39, 39, 39)
    private let safeAreaColor = Color(red: 39/255, green: 39/255, blue: 39/255)
    
    var body: some View {
        ZStack(alignment: .top) {
            
            // 1. Background Color (Covers Safe Areas)
            safeAreaColor
                .edgesIgnoringSafeArea(.all)
            
            // 2. Main Content
            ZStack(alignment: .top) {
                // AR Web View
                ARWebView(
                    action: $navAction,
                    isARActive: $isARActive,
                    currentURLString: $urlString, // Syncs bar when clicking links
                    canGoBack: $canGoBack,
                    canGoForward: $canGoForward
                )
                .edgesIgnoringSafeArea(.all) // Webview takes full screen
                
                // 3. UI Overlay (Address Bar)
                VStack {
                    if !isARActive {
                        controlBar
                            .padding(.top, 50) // Adjust for Dynamic Island/Notch
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    
                    Spacer()
                }
                
                // 4. AR Exit Button
                if isARActive {
                    exitARButton
                        .transition(.opacity)
                }
            }
        }
        .statusBar(hidden: isARActive)
        .animation(.easeInOut, value: isARActive)
    }
    
    // MARK: - Subviews
    
    var controlBar: some View {
        HStack(spacing: 8) {
            // Back Button
            Button(action: { navAction = .goBack }) {
                Image(systemName: "chevron.left")
                    .foregroundColor(canGoBack ? .primary : .secondary.opacity(0.5))
            }
            .disabled(!canGoBack)

            // Forward Button
            Button(action: { navAction = .goForward }) {
                Image(systemName: "chevron.right")
                    .foregroundColor(canGoForward ? .primary : .secondary.opacity(0.5))
            }
            .disabled(!canGoForward)
            
            // Address Field
            HStack {
                Image(systemName: "globe")
                    .foregroundColor(.secondary)
                
                TextField("Search or enter website", text: $urlString)
                    .keyboardType(.webSearch)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .submitLabel(.go)
                    .onSubmit {
                        processAndLoad()
                    }
                
                // Clear text button (optional quality of life)
                if !urlString.isEmpty {
                    Button(action: { urlString = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.8)) // Slightly lighter input field
            .cornerRadius(8)
            
            // Go / Reload Button
            Button(action: {
                processAndLoad()
            }) {
                Text("Go")
                    .bold()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(16)
        .padding(.horizontal)
    }
    
    var exitARButton: some View {
        VStack {
            HStack {
                Button(action: {
                    withAnimation {
                        isARActive = false
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                        Text("Exit AR")
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    .foregroundColor(.primary)
                    .cornerRadius(20)
                    .shadow(radius: 4)
                }
                .padding(.leading)
                .padding(.top, 50)
                
                Spacer()
            }
            Spacer()
        }
    }
    
    // MARK: - Logic
    
    private func processAndLoad() {
        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        let rawInput = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawInput.isEmpty { return }
        
        // Search Logic
        // If it has spaces OR doesn't contain a dot, treat as Google Search
        if rawInput.contains(" ") || !rawInput.contains(".") {
            if let query = rawInput.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchURL = URL(string: "https://www.google.com/search?q=\(query)") {
                navAction = .load(searchURL)
            }
        } else {
            // URL Logic
            var validURLString = rawInput
            if !validURLString.lowercased().hasPrefix("http") {
                validURLString = "https://" + validURLString
            }
            
            if let finalURL = URL(string: validURLString) {
                // If the user hit Go on the exact same URL, we want to reload
                if case .load(let current) = navAction, current == finalURL {
                    navAction = .reload
                } else {
                    navAction = .load(finalURL)
                }
                // Update text field to show the formatted URL
                urlString = validURLString
            }
        }
    }
}