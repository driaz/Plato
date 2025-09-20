import SwiftUI
import SceneKit

struct AvatarChatView: View {
    @StateObject private var realtimeManager = RealtimeManager()
    @State private var avatarNode: SCNNode?
    @State private var errorMessage: String?
    @State private var isLoadingAvatar = false

    // Using local SceneKit primitives for avatar - no network dependencies

    var body: some View {
        print("🎯 AvatarChatView body - START rendering")

        return VStack {
            Text("Avatar Chat")
                .font(.title)
                .padding()

            // SceneKit view with local avatar
            SceneKitView(avatarNode: $avatarNode, errorMessage: $errorMessage)
                .frame(height: 400)
                .onAppear {
                    print("🎯 SceneKitView appeared")
                }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            }

            Text(statusText)
                .font(.headline)
                .padding()
        }
        .onAppear {
            print("🎯 AvatarChatView onAppear triggered")
            Task {
                print("🎯 About to call createLocalAvatar")
                await createLocalAvatar()
                print("🎯 Returned from createLocalAvatar")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            print("🎯 App became active")
        }
    }

    var statusText: String {
        if realtimeManager.isAISpeaking { return "Speaking..." }
        if realtimeManager.isListening { return "Listening..." }
        return "Connecting..."
    }

    private func createLocalAvatar() async {
        // Prevent multiple simultaneous avatar creations
        let shouldProceed = await MainActor.run {
            guard !isLoadingAvatar else { return false }
            isLoadingAvatar = true
            return true
        }

        guard shouldProceed else { return }

        defer {
            Task { @MainActor in
                isLoadingAvatar = false
            }
        }

        print("🎨 Creating local avatar with SceneKit primitives")

        // Create avatar root node
        let avatarRootNode = SCNNode()
        avatarRootNode.position = SCNVector3(0, -0.5, 0)

        // Create body (blue box)
        let bodyGeometry = SCNBox(width: 0.4, height: 0.6, length: 0.2, chamferRadius: 0.02)
        let bodyMaterial = SCNMaterial()
        bodyMaterial.diffuse.contents = UIColor.systemBlue
        bodyMaterial.specular.contents = UIColor.white
        bodyGeometry.materials = [bodyMaterial]

        let bodyNode = SCNNode(geometry: bodyGeometry)
        bodyNode.position = SCNVector3(0, 0, 0)
        avatarRootNode.addChildNode(bodyNode)

        // Create head (flesh-tone sphere)
        let headGeometry = SCNSphere(radius: 0.15)
        let headMaterial = SCNMaterial()
        headMaterial.diffuse.contents = UIColor.systemPink.withAlphaComponent(0.8)
        headMaterial.specular.contents = UIColor.white
        headGeometry.materials = [headMaterial]

        let headNode = SCNNode(geometry: headGeometry)
        headNode.position = SCNVector3(0, 0.45, 0)
        avatarRootNode.addChildNode(headNode)

        // Create arms (smaller blue boxes)
        let armGeometry = SCNBox(width: 0.1, height: 0.4, length: 0.1, chamferRadius: 0.01)
        let armMaterial = SCNMaterial()
        armMaterial.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.9)
        armGeometry.materials = [armMaterial]

        // Left arm
        let leftArmNode = SCNNode(geometry: armGeometry)
        leftArmNode.position = SCNVector3(-0.3, 0.1, 0)
        avatarRootNode.addChildNode(leftArmNode)

        // Right arm
        let rightArmNode = SCNNode(geometry: armGeometry)
        rightArmNode.position = SCNVector3(0.3, 0.1, 0)
        avatarRootNode.addChildNode(rightArmNode)

        // Create legs (blue cylinders)
        let legGeometry = SCNCylinder(radius: 0.05, height: 0.4)
        let legMaterial = SCNMaterial()
        legMaterial.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.8)
        legGeometry.materials = [legMaterial]

        // Left leg
        let leftLegNode = SCNNode(geometry: legGeometry)
        leftLegNode.position = SCNVector3(-0.1, -0.5, 0)
        avatarRootNode.addChildNode(leftLegNode)

        // Right leg
        let rightLegNode = SCNNode(geometry: legGeometry)
        rightLegNode.position = SCNVector3(0.1, -0.5, 0)
        avatarRootNode.addChildNode(rightLegNode)

        // Add rotation animation
        let rotationAction = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 4.0)
        let repeatAction = SCNAction.repeatForever(rotationAction)
        await MainActor.run {
            avatarRootNode.runAction(repeatAction)
        }

        // Add bouncing animation
        let bounceUp = SCNAction.moveBy(x: 0, y: 0.1, z: 0, duration: 1.0)
        bounceUp.timingMode = .easeInEaseOut
        let bounceDown = bounceUp.reversed()
        let bounceSequence = SCNAction.sequence([bounceUp, bounceDown])
        let bouncingAction = SCNAction.repeatForever(bounceSequence)
        await MainActor.run {
            avatarRootNode.runAction(bouncingAction)
        }

        // Update state on MainActor
        print("🔄 About to update state with MainActor.run")
        await MainActor.run {
            print("🔄 Inside MainActor.run - setting avatarNode")
            avatarNode = avatarRootNode
            print("🔄 Inside MainActor.run - clearing errorMessage")
            errorMessage = nil
            print("🔄 Inside MainActor.run - completed state updates")
        }
        print("🔄 Finished MainActor.run state updates")

        print("✅ Local avatar created successfully with animations")
        print("🔄 About to exit createLocalAvatar function")

        // Add a small delay to see if timing is an issue
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        print("🔄 Completed createLocalAvatar function")
    }
}

// URLSession delegate to handle redirects
class DownloadDelegate: NSObject, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        print("🔄 Redirect from: \(response.url?.absoluteString ?? "unknown")")
        print("🔄 Redirect to: \(request.url?.absoluteString ?? "unknown")")
        print("🔄 HTTP status: \(response.statusCode)")
        completionHandler(request) // Follow the redirect
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            print("📡 Response received: \(httpResponse.statusCode)")
        }
        completionHandler(.allow)
    }
}

struct SceneKitView: UIViewRepresentable {
    @Binding var avatarNode: SCNNode?
    @Binding var errorMessage: String?

    func makeUIView(context: Context) -> SCNView {
        print("🏗️ makeUIView called - creating SceneKit view")

        let scnView = SCNView(frame: .zero)
        print("🏗️ Created SCNView")

        let scene = SCNScene()
        print("🏗️ Created SCNScene")

        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = UIColor.systemBackground
        print("🏗️ Configured SCNView properties")

        // Add camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 3)
        scene.rootNode.addChildNode(cameraNode)
        print("🏗️ Added camera node")

        // Add ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = UIColor.white
        ambientLight.light?.intensity = 300
        scene.rootNode.addChildNode(ambientLight)
        print("🏗️ Added ambient light")

        // Add directional light
        let directionalLight = SCNNode()
        directionalLight.light = SCNLight()
        directionalLight.light?.type = .directional
        directionalLight.light?.color = UIColor.white
        directionalLight.light?.intensity = 500
        directionalLight.position = SCNVector3(2, 2, 2)
        directionalLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(directionalLight)
        print("🏗️ Added directional light")

        print("🏗️ makeUIView completed successfully")
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        print("🔧 updateUIView called")
        print("🔧 avatarNode exists: \(avatarNode != nil)")

        if let avatarNode = avatarNode {
            print("🔧 avatarNode found, parent: \(avatarNode.parent != nil ? "exists" : "nil")")

            if avatarNode.parent == nil {
                print("🔧 About to add avatarNode to scene")

                // Check if scene exists
                guard let scene = uiView.scene else {
                    print("❌ uiView.scene is nil!")
                    return
                }

                let rootNode = scene.rootNode
                print("🔧 Scene and rootNode verified, adding avatar")

                // Wrap in DispatchQueue.main.async for threading safety
                DispatchQueue.main.async {
                    print("🔧 Inside DispatchQueue.main.async")
                    rootNode.addChildNode(avatarNode)
                    print("✅ Avatar node successfully added to scene")
                }
            } else {
                print("🔧 avatarNode already has parent, skipping")
            }
        } else {
            print("🔧 No avatarNode available yet")
        }

        print("🔧 updateUIView completed")
    }

    /*
    // Network-based avatar loading - commented out due to download hanging issues
    private func loadAvatar_NetworkVersion(scene: SCNScene) {
        Task {
            print("🚀 START loadAvatar - \(Date())")

            do {
                // Step 1: Network connectivity test
                print("🌐 Testing network connectivity...")
                let testStartTime = Date()
                do {
                    let testConfig = URLSessionConfiguration.default
                    testConfig.timeoutIntervalForRequest = 10.0
                    testConfig.timeoutIntervalForResource = 10.0
                    let testSession = URLSession(configuration: testConfig)

                    let testURL = URL(string: "https://www.google.com")!
                    let (_, testResponse) = try await testSession.data(from: testURL)
                    let testDuration = Date().timeIntervalSince(testStartTime)

                    if let httpResponse = testResponse as? HTTPURLResponse {
                        print("✅ Network test successful: \(httpResponse.statusCode) in \(String(format: "%.2f", testDuration))s")
                    }
                } catch {
                    let errorMsg = "Network connectivity test failed: \(error.localizedDescription)"
                    print("❌ \(errorMsg)")
                    await MainActor.run {
                        errorMessage = errorMsg
                    }
                    createFallbackSphere(scene: scene)
                    return
                }

                // Step 2: URL validation
                guard let url = URL(string: avatarURL) else {
                    let error = "Invalid avatar URL: \(avatarURL)"
                    print("❌ \(error)")
                    await MainActor.run {
                        errorMessage = error
                    }
                    return
                }
                print("📍 URL: \(url)")

                // Step 3: Download setup with timeout and delegate
                print("📥 Download start with 30s timeout and redirect handling")
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 30.0
                config.timeoutIntervalForResource = 30.0
                config.waitsForConnectivity = false
                let session = URLSession(configuration: config, delegate: downloadDelegate, delegateQueue: nil)

                // Step 4: Download with timeout race condition
                let startTime = Date()
                let downloadResult = try await withTimeout(seconds: 30) {
                    try await session.data(from: url)
                }
                let downloadTime = Date().timeIntervalSince(startTime)
                print("⏱️ Download took \(String(format: "%.2f", downloadTime)) seconds")

                let (data, response) = downloadResult
                print("✅ Bytes downloaded: \(data.count)")

                // Step 5: HTTP status check
                if let httpResponse = response as? HTTPURLResponse {
                    print("📊 HTTP status: \(httpResponse.statusCode)")
                    if httpResponse.statusCode != 200 {
                        let errorMsg = "HTTP error: \(httpResponse.statusCode)"
                        print("❌ \(errorMsg)")
                        await MainActor.run {
                            errorMessage = errorMsg
                        }
                        createFallbackSphere(scene: scene)
                        return
                    }
                } else {
                    print("⚠️ No HTTP response received")
                }

                // Step 6: Save to temp file
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("avatar.usdz")
                print("📂 Temp file path: \(tempURL)")

                do {
                    try data.write(to: tempURL)
                    print("✅ Save success: USDZ file saved to temp directory")
                } catch {
                    let errorMsg = "Failed to save file: \(error.localizedDescription)"
                    print("❌ \(errorMsg)")
                    await MainActor.run {
                        errorMessage = errorMsg
                    }
                    return
                }

                // Step 7: Load SCNScene
                print("🎨 SCNScene load attempt (USDZ format)")
                let sceneLoadStartTime = Date()
                let avatarScene: SCNScene
                do {
                    avatarScene = try SCNScene(url: tempURL, options: nil)
                    let sceneLoadTime = Date().timeIntervalSince(sceneLoadStartTime)
                    print("✅ USDZ model loaded successfully in \(String(format: "%.2f", sceneLoadTime))s")
                } catch {
                    let errorMsg = "USDZ scene loading failed: \(error.localizedDescription)"
                    print("❌ \(errorMsg)")
                    print("❌ Full error: \(error)")
                    await MainActor.run {
                        errorMessage = errorMsg
                    }
                    createFallbackSphere(scene: scene)
                    return
                }

                // Step 8: Add to scene
                await MainActor.run {
                    let avatarRootNode = SCNNode()
                    for child in avatarScene.rootNode.childNodes {
                        avatarRootNode.addChildNode(child)
                    }

                    avatarRootNode.scale = SCNVector3(1.0, 1.0, 1.0)
                    avatarRootNode.position = SCNVector3(0, -1, 0)

                    avatarNode = avatarRootNode
                    scene.rootNode.addChildNode(avatarRootNode)
                    print("✅ Added avatar to scene")
                    errorMessage = nil
                }

                let totalTime = Date().timeIntervalSince(startTime)
                print("🏁 Total avatar loading time: \(String(format: "%.2f", totalTime))s")

            } catch {
                let errorMsg = "Unexpected error: \(error.localizedDescription)"
                print("❌ \(errorMsg)")
                print("❌ Full error details: \(error)")

                await MainActor.run {
                    errorMessage = errorMsg
                }
                createFallbackSphere(scene: scene)
            }
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }

            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }

            group.cancelAll()
            return result
        }
    }

    private func createFallbackSphere(scene: SCNScene) {
        Task {
            await MainActor.run {
                let sphere = SCNSphere(radius: 0.2)
                sphere.firstMaterial?.diffuse.contents = UIColor.green
                let sphereNode = SCNNode(geometry: sphere)
                avatarNode = sphereNode
                scene.rootNode.addChildNode(sphereNode)
                print("✅ Created fallback sphere")
            }
        }
    }
    */
}

// MARK: - Preview
@available(iOS 18.0, *)
#Preview {
    AvatarChatView()
}