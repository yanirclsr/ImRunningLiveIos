import SwiftUI
import Combine
import CoreLocation
import AVFoundation
import UIKit

// MARK: - App Entry

@main
struct ImRunningLiveApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .onAppear {
                    appState.location.requestPermissionsOnLaunch()
                }
        }
    }
}

// MARK: - App State

final class AppState: ObservableObject {
    @Published var activityRunning = false
    @Published var activityURL: String? = nil
    @Published var activityId: String? = nil
    @Published var runnerId: String = "usr_8pG7dummy"  // Default for testing
    @Published var lastError: String? = nil
    @Published var showLocationWarning = false
    @Published var showSetupForm = true
    
    let location = LocationService()
    let network = NetworkService()
    let tts = TTSService()
    private var cancellables = Set<AnyCancellable>()
    private var locationTimer: AnyCancellable?
    private var cheerTimer: AnyCancellable?
    
    init() {
        // Propagate location auth status to a UI warning banner
        location.$authorizationStatus
            .map { status in
                print("🔍 Location status changed to: \(status.rawValue)")
                switch status {
                case .authorizedAlways, .authorizedWhenInUse: 
                    print("✅ Location permission granted - hiding warning")
                    return false
                default: 
                    print("❌ Location permission denied/restricted - showing warning")
                    return true
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$showLocationWarning)
        
        // Forward cheers from NetworkService to TTS
        network.cheerPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cheerText in
                self?.tts.speak(cheerText)
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    func startActivity() {
        // Accept both "Always" and "When In Use" permissions
        guard location.authorizationStatus == .authorizedAlways || location.authorizationStatus == .authorizedWhenInUse else {
            lastError = "Location permission is required."
            showLocationWarning = true
            return
        }
        
        guard let currentLocation = location.currentLocation else {
            lastError = "Waiting for GPS signal..."
            return
        }
        
        Task {
            do {
                let start = try await network.startActivity(
                    runnerId: runnerId,
                    activityId: activityId ?? "act_7XcQdummy", // Default for testing
                    latitude: currentLocation.coordinate.latitude,
                    longitude: currentLocation.coordinate.longitude
                )
                self.activityURL = start.url
                self.activityId = start.activityId
                self.activityRunning = true
                // Start WebSocket for cheers (optional but recommended)
                if let id = start.activityId {
                    network.openCheerStream(activityId: id)
                }
                // Start cheer polling every 30 seconds
                beginCheerPolling()
                // Start 10s location loop
                beginLocationLoop()
            } catch {
                self.lastError = "Failed to start activity: \(error.localizedDescription)"
            }
        }
    }
    
    @MainActor
    func stopActivity() {
        Task {
            do {
                if let activityId = activityId {
                    try await network.stopActivity(runnerId: runnerId, activityId: activityId)
                }
            } catch {
                // Non-fatal if server stop fails; still shut down locally
                self.lastError = "Stopped locally. Server stop failed: \(error.localizedDescription)"
            }
            cleanupAfterStop()
        }
    }
    
    private func cleanupAfterStop() {
        activityRunning = false
        activityId = nil
        network.closeCheerStream()
        locationTimer?.cancel()
        locationTimer = nil
        cheerTimer?.cancel()
        cheerTimer = nil
    }
    
    private func beginLocationLoop() {
        // Ensure high-accuracy updates
        location.startUpdating()
        
        // Send immediately once, then every 10 seconds
        sendCurrentLocation()
        locationTimer = Timer.publish(every: 10.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.sendCurrentLocation()
            }
    }
    
    private func beginCheerPolling() {
        // Poll for cheers every 30 seconds
        cheerTimer = Timer.publish(every: 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkForNewCheers()
            }
    }
    
    private func checkForNewCheers() {
        guard activityRunning, let activityId else { return }
        
        Task {
            do {
                let cheers = try await network.fetchUnannouncedCheers(runnerId: runnerId, activityId: activityId)
                await MainActor.run {
                    for cheer in cheers {
                        // Announce the cheer
                        tts.speak("\(cheer.fromName) says: \(cheer.message)")
                        
                        // Mark as announced
                        Task {
                            try? await network.markCheerAsAnnounced(
                                runnerId: self.runnerId,
                                activityId: activityId,
                                messageId: cheer.id
                            )
                        }
                    }
                }
            } catch {
                #if DEBUG
                print("Failed to fetch cheers: \(error)")
                #endif
            }
        }
    }
    
    private func sendCurrentLocation() {
        guard activityRunning, let activityId else { return }
        guard let fix = location.currentLocation else {
            // No GPS fix yet; skip this tick
            return
        }
        
        // Get battery level
        let batteryLevel = UIDevice.current.batteryLevel
        let battery = batteryLevel >= 0 ? Double(batteryLevel) : 0.5 // Default if unknown
        
        let payload = LocationPing(
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            speedMps: fix.speed >= 0 ? fix.speed : 0.0,
            elevM: fix.altitude,
            battery: battery
        )
        
        Task {
            do {
                try await network.sendLocation(runnerId: runnerId, activityId: activityId, payload: payload)
            } catch {
                // Soft-fail; don't spam the UI
                #if DEBUG
                print("Send location failed: \(error)")
                #endif
            }
        }
    }
}

// MARK: - UI

struct MainView: View {
    @EnvironmentObject var app: AppState
    @State private var copied = false
    @State private var runnerIdInput = ""
    @State private var activityIdInput = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("I’m Running.Live")
                .font(.largeTitle).bold()
            
            // Location permission banner
            if app.showLocationWarning {
                VStack(spacing: 8) {
                    Text("Location permission is required.")
                        .font(.subheadline)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    
                    // Debug info
                    VStack(spacing: 4) {
                        Text("Debug: Status = \(app.location.authorizationStatus.rawValue)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Refresh Permission Check") {
                            app.location.refreshPermissionStatus()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)
                }
                .padding()
                .background(Color.yellow.opacity(0.2))
                .cornerRadius(12)
            }
            
            // Start/Stop button
            Button(app.activityRunning ? "Stop Activity" : "Start Activity") {
                if app.activityRunning {
                    app.stopActivity()
                } else {
                    app.startActivity()
                }
            }
            .font(.title2.weight(.semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(app.activityRunning ? Color.red.opacity(0.85) : Color.green.opacity(0.85))
            .foregroundColor(.white)
            .cornerRadius(14)
            
            // Returned URL section
            if let url = app.activityURL {
                VStack(spacing: 8) {
                    Text("Activity URL")
                        .font(.headline)
                    Text(url)
                        .font(.callout)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .onTapGesture {
                            UIPasteboard.general.string = url
                            withAnimation {
                                copied = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                withAnimation { copied = false }
                            }
                        }
                    if copied {
                        Text("Copied!")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 8)
            }
            
            // Errors
            if let err = app.lastError {
                Text(err)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // Location status info
            if app.activityRunning {
                VStack(spacing: 4) {
                    Text("Location tracking active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if app.location.authorizationStatus == .authorizedWhenInUse {
                        Text("(When In Use - app must stay open)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.top, 8)
            }
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - Location Service

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentLocation: CLLocation?
    
    private let manager: CLLocationManager = {
        let m = CLLocationManager()
        m.desiredAccuracy = kCLLocationAccuracyBest
        m.distanceFilter = kCLDistanceFilterNone
        m.pausesLocationUpdatesAutomatically = false
        return m
    }()
    
    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }
    
    func requestPermissionsOnLaunch() {
        print("🔍 Current authorization status: \(authorizationStatus.rawValue)")
        // Request When In Use permission first
        if authorizationStatus == .notDetermined {
            print("📱 Requesting When In Use authorization...")
            manager.requestWhenInUseAuthorization()
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            print("❌ Location denied/restricted")
            // UI will surface a banner to open Settings
        } else if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            print("✅ Location permission already granted")
            // Ready - both permission levels work
        }
    }
    
    func startUpdating() {
        // Start location updates for both permission levels
        manager.startUpdatingLocation()
        // Note: With "When In Use" permission, location updates only work while app is active
    }
    
    func refreshPermissionStatus() {
        let currentStatus = manager.authorizationStatus
        print("🔄 Refreshing permission status: \(currentStatus.rawValue)")
        authorizationStatus = currentStatus
    }
    
    func stopUpdating() {
        manager.stopUpdatingLocation()
    }
    
    // CLLocationManagerDelegate
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        print("🔄 Authorization changed from \(authorizationStatus.rawValue) to \(newStatus.rawValue)")
        authorizationStatus = newStatus
        // No need to request Always permission - When In Use is sufficient
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last {
            currentLocation = last
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        #if DEBUG
        print("Location error: \(error)")
        #endif
    }
}

// MARK: - Networking

// MARK: - Data Models

struct Runner {
    let id: String           // Format: "usr_8pG7..."
    let email: String
    let displayName: String
}

struct Activity {
    let id: String           // Format: "act_7XcQ..."
    let runnerId: String
    let status: String       // "planned", "active", "finished"
    let startedAt: Date?
    let shareToken: String   // Format: "sh_7LrZ..."
}

struct LocationPing: Codable {
    let latitude: Double
    let longitude: Double
    let speedMps: Double
    let elevM: Double
    let battery: Double
}

struct CheerMessage: Decodable {
    let id: String
    let fromName: String
    let message: String
    let createdAt: Date
    let deliveredAt: Date?
    let spokenAt: Date?
}

struct StartResponse: Decodable {
    let url: String
    let activityId: String?
}

struct LocationPayload: Codable {
    let activityId: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let timestamp: String
}

final class NetworkService {
    private let baseHTTP = URL(string: "http://localhost:3000")!
    private var webSocket: URLSessionWebSocketTask?
    private let session: URLSession
    private let decoder = JSONDecoder()
    
    // Emits cheer text either from HTTP response or WebSocket messages
    let cheerPublisher = PassthroughSubject<String, Never>()
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }
    
    // POST /api/runner/{runnerId}/activity/{activityId}/start
    func startActivity(runnerId: String, activityId: String, latitude: Double, longitude: Double) async throws -> StartResponse {
        let url = baseHTTP.appendingPathComponent("/api/runner/\(runnerId)/activity/\(activityId)/start")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "latitude": latitude,
            "longitude": longitude
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, resp) = try await session.data(for: req)
        try Self.ensureOK(resp)
        return try decoder.decode(StartResponse.self, from: data)
    }
    
    // POST /api/runner/{runnerId}/activity/{activityId}/stop
    func stopActivity(runnerId: String, activityId: String) async throws {
        let url = baseHTTP.appendingPathComponent("/api/runner/\(runnerId)/activity/\(activityId)/stop")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await session.data(for: req)
        try Self.ensureOK(resp)
    }
    
    // GET /api/runner/{runnerId}/activity/{activityId}/messages/unannounced
    func fetchUnannouncedCheers(runnerId: String, activityId: String) async throws -> [CheerMessage] {
        let url = baseHTTP.appendingPathComponent("/api/runner/\(runnerId)/activity/\(activityId)/messages/unannounced")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        
        let (data, resp) = try await session.data(for: req)
        try Self.ensureOK(resp)
        return try decoder.decode([CheerMessage].self, from: data)
    }
    
    // POST /api/runner/{runnerId}/activity/{activityId}/messages/{messageId}/announce
    func markCheerAsAnnounced(runnerId: String, activityId: String, messageId: String) async throws {
        let url = baseHTTP.appendingPathComponent("/api/runner/\(runnerId)/activity/\(activityId)/messages/\(messageId)/announce")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (_, resp) = try await session.data(for: req)
        try Self.ensureOK(resp)
    }
    
    // Open cheer stream (placeholder for WebSocket setup)
    func openCheerStream(activityId: String) {
        // WebSocket setup would go here if using WebSockets
        // For now, just a placeholder since we're using HTTP polling
    }
    
    // Close cheer stream (placeholder for WebSocket cleanup)
    func closeCheerStream() {
        // WebSocket cleanup would go here if using WebSockets
        // For now, just a placeholder since we're using HTTP polling
    }
    
    // POST /api/runner/{runnerId}/activity/{activityId}/location
    func sendLocation(runnerId: String, activityId: String, payload: LocationPing) async throws {
        let url = baseHTTP.appendingPathComponent("/api/runner/\(runnerId)/activity/\(activityId)/location")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)
        
        let (_, resp) = try await session.data(for: req)
        try Self.ensureOK(resp)
    }
    
    // WebSocket for live cheers: ws://localhost:3000/api/activity/stream?activityId=...
    func openCheerStream(activityId: String) {
        closeCheerStream()
        guard let wsURL = URL(string: "ws://localhost:3000/api/activity/stream?activityId=\(activityId)") else { return }
        webSocket = session.webSocketTask(with: wsURL)
        webSocket?.resume()
        listenForMessages()
    }
    
    func closeCheerStream() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
    }
    
    private func listenForMessages() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .failure(let err):
                #if DEBUG
                print("WebSocket error: \(err)")
                #endif
            case .success(let msg):
                switch msg {
                case .string(let text):
                    // Expect either plain text or JSON {"cheer":"..."}
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let cheer = json["cheer"] as? String {
                        self?.cheerPublisher.send(cheer)
                    } else {
                        self?.cheerPublisher.send(text)
                    }
                case .data(let data):
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let cheer = json["cheer"] as? String {
                        self?.cheerPublisher.send(cheer)
                    }
                @unknown default:
                    break
                }
                // Continue listening
                self?.listenForMessages()
            }
        }
    }
    
    private static func ensureOK(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

// MARK: - Text-To-Speech

final class TTSService {
    private let synth = AVSpeechSynthesizer()
    
    init() {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, options: [.duckOthers])
        try? audio.setActive(true)
    }
    
    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utter = AVSpeechUtterance(string: text)
        // Fine to adjust rate/pitch as needed
        utter.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utter)
    }
}
