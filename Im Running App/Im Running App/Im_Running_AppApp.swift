import SwiftUI
import Combine
import CoreLocation
import AVFoundation
import UIKit
import MapKit

// MARK: - Data Models

struct User: Identifiable, Codable {
    let id: String
    let displayName: String
    let email: String
    var preferences: UserPreferences
    
    struct UserPreferences: Codable {
        var voice: String
        var cheersVolume: Double
        var units: String // "metric" or "imperial"
    }
}

struct Activity: Identifiable, Codable {
    let id: String
    let runnerId: String
    let eventId: String
    var status: String // "planned", "active", "finished", "cancelled"
    var startedAt: Date?
    var endedAt: Date?
    var distance: Double
    var duration: TimeInterval
    var averagePace: String
    var maxHeartRate: Int?
    var averageHeartRate: Int?
    
    var isActive: Bool {
        status == "active"
    }
    
    var isFinished: Bool {
        status == "finished"
    }
}

struct RunningEvent: Identifiable, Equatable, Codable {
    let id = UUID()
    let title: String
    let date: Date
    let location: String
    let latitude: Double?
    let longitude: Double?
    let distance: String?
    let isToday: Bool
    let eventType: String // "race", "custom", etc.
    
    var coordinates: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
    
    static func == (lhs: RunningEvent, rhs: RunningEvent) -> Bool {
        lhs.id == rhs.id
    }
    
    enum CodingKeys: String, CodingKey {
        case id, title, date, location, latitude, longitude, distance, isToday, eventType
    }
}

// MARK: - App Entry

@main
struct ImRunningLiveApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            MapMainView()
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
    @Published var runnerId: String = "usr_yiopd15z"  // Real runner ID from your database
    @Published var lastError: String? = nil
    @Published var showLocationWarning = false
    @Published var showSetupForm = true
    
    // Additional properties needed by MapMainView
    @Published var currentUser: User?
    @Published var selectedEvent: RunningEvent?
    @Published var currentActivity: Activity?
    @Published var activityStartTime: Date?
    @Published var currentDistance: Double = 0.0
    @Published var currentPace: String = "00:00"
    @Published var currentHeartRate: Int = 0
    
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
        print("🚀 Starting activity...")
        print("👤 Runner ID: \(runnerId)")
        print("🏃 Activity ID: \(activityId ?? "act_0arq557d")")
        
        // Check location permissions first
        guard location.authorizationStatus == .authorizedAlways || location.authorizationStatus == .authorizedWhenInUse else {
            print("❌ Location permission required")
            lastError = "Location permission is required. Please enable location access in Settings."
            showLocationWarning = true
            return
        }
        
        // Check if we have current location
        guard let currentLocation = location.currentLocation else {
            print("❌ Waiting for GPS signal...")
            lastError = "Waiting for GPS signal... Please wait a moment and try again."
            return
        }
        
        print("📍 Using real location: \(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude)")
        print("📍 Location accuracy: \(currentLocation.horizontalAccuracy)m")
        
        Task {
            do {
                print("🌐 Making network request to start activity...")
                let start = try await network.startActivity(
                    runnerId: runnerId,
                    activityId: activityId ?? "act_0arq557d", // Real activity ID from your database
                    latitude: currentLocation.coordinate.latitude,
                    longitude: currentLocation.coordinate.longitude
                )
                print("✅ Activity started successfully!")
                print("✅ User: \(start.data.user.displayName)")
                print("✅ Event: \(start.data.event.name)")
                print("✅ Activity ID: \(start.data.activity.id)")
                if let startLocation = start.data.startLocation {
                    print("✅ Start Location: \(startLocation.lat), \(startLocation.lng)")
                } else {
                    print("✅ Start Location: Not provided")
                }
                self.lastError = nil
                self.activityRunning = true
                
                // Start location tracking for the activity
                beginLocationLoop()
            } catch {
                print("❌ Error starting activity: \(error)")
                print("❌ Error details: \(error.localizedDescription)")
                if let nsError = error as NSError? {
                    print("❌ NSURLErrorDomain: \(nsError.domain)")
                    print("❌ NSURLErrorCode: \(nsError.code)")
                }
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
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194), // Default to San Francisco
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01) // ~1km radius
    )
    
    private var locationStatusText: String {
        switch app.location.authorizationStatus {
        case .notDetermined:
            return "Location permission not determined"
        case .denied:
            return "Location access denied"
        case .restricted:
            return "Location access restricted"
        case .authorizedWhenInUse:
            return "Location access granted (When In Use)"
        case .authorizedAlways:
            return "Location access granted (Always)"
        @unknown default:
            return "Unknown location status"
        }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("I’m Running.Live")
                .font(.largeTitle).bold()
            
            // Location permission banner
            if app.showLocationWarning {
                VStack(spacing: 8) {
                    Text("Location permission is required.")
                        .font(.subheadline)
                    Button("Request Location Permission") {
                        app.location.requestPermissionsOnLaunch()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    
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
            
            // Location status info (always show)
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: app.location.authorizationStatus == .authorizedWhenInUse || app.location.authorizationStatus == .authorizedAlways ? "location.fill" : "location.slash")
                        .foregroundColor(app.location.authorizationStatus == .authorizedWhenInUse || app.location.authorizationStatus == .authorizedAlways ? .green : .red)
                    Text("Location Status")
                        .font(.headline)
                }
                
                Text(locationStatusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let location = app.location.currentLocation {
                    Text("📍 \(location.coordinate.latitude, specifier: "%.6f"), \(location.coordinate.longitude, specifier: "%.6f")")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("Accuracy: \(location.horizontalAccuracy, specifier: "%.1f")m")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("No GPS signal yet")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Button("Refresh Location") {
                    print("🔄 Manual location refresh requested")
                    app.location.startUpdating()
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
            
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
        .onAppear {
            // Start location updates when view appears
            print("🔄 MainView appeared - starting location updates")
            app.location.startUpdating()
        }
    }
}

// MARK: - Location Service

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentLocation: CLLocation?
    
    // Additional properties needed by MapMainView
    var showLocationWarning: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }
    
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
        print("📍 Starting location updates...")
        print("📍 Manager authorization status: \(manager.authorizationStatus.rawValue)")
        print("📍 Desired accuracy: \(manager.desiredAccuracy)")
        print("📍 Distance filter: \(manager.distanceFilter)")
        
        // Start location updates for both permission levels
        manager.startUpdatingLocation()
        print("📍 Location updates started")
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
        print("📍 Location update received: \(locations.count) locations")
        if let last = locations.last {
            print("📍 New location: \(last.coordinate.latitude), \(last.coordinate.longitude)")
            print("📍 Accuracy: \(last.horizontalAccuracy)m")
            print("📍 Timestamp: \(last.timestamp)")
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

// MARK: - Network Response Models

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
    let success: Bool
    let message: String
    let data: StartResponseData
    let startTime: String
}

struct StartResponseData: Decodable {
    let user: NetworkUser
    let event: NetworkEvent
    let activity: NetworkActivityData
    let startLocation: StartLocation?
}

struct NetworkUser: Decodable {
    let id: String
    let displayName: String
    let email: String
    let preferences: NetworkUserPreferences
}

struct NetworkUserPreferences: Decodable {
    let voice: String
    let cheersVolume: Double
}

struct NetworkEvent: Decodable {
    let id: String
    let name: String
    let date: String
    let location: EventLocation
    let type: String
    let distance: Int
}

struct EventLocation: Decodable {
    let coordinates: Coordinates
    let city: String
    let country: String
}

struct Coordinates: Decodable {
    let type: String
    let coordinates: [Double]
}

struct NetworkActivityData: Decodable {
    let id: String
    let status: String
    let startedAt: String
    let share: ShareData
    let settings: ActivitySettings
}

struct ShareData: Decodable {
    let isPublic: Bool
    let token: String
    let expiresAt: String?
    
    enum CodingKeys: String, CodingKey {
        case isPublic = "public"
        case token
        case expiresAt
    }
}

struct ActivitySettings: Decodable {
    let pingIntervalSec: Int
    let cheersEnabled: Bool
    let ttsLang: String
}

struct StartLocation: Decodable {
    let lat: Double
    let lng: Double
    let accuracy: Double
}

struct LocationPayload: Codable {
    let activityId: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let timestamp: String
}

final class NetworkService {
    private let baseHTTP = URL(string: "http://192.168.1.108:3000")! // Your Mac's current IP address
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
    func startActivity(runnerId: String, activityId: String, latitude: Double, longitude: Double, eventName: String? = nil, eventType: String? = nil) async throws -> StartResponse {
        let url = baseHTTP.appendingPathComponent("/api/runner/\(runnerId)/activity/\(activityId)/start")
        print("🌐 NetworkService: Making request to URL: \(url)")
        print("🌐 NetworkService: Base HTTP: \(baseHTTP)")
        print("🌐 NetworkService: Runner ID: \(runnerId)")
        print("🌐 NetworkService: Activity ID: \(activityId)")
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude
        ]
        
        // Add event information if provided
        if let eventName = eventName {
            body["eventName"] = eventName
        }
        if let eventType = eventType {
            body["eventType"] = eventType
        }
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        print("🌐 NetworkService: Request body: \(body)")
        
        let (data, resp) = try await session.data(for: req)
        print("🌐 NetworkService: Response received: \(resp)")
        
        // Log the raw response data
        if let responseString = String(data: data, encoding: .utf8) {
            print("🌐 NetworkService: Raw response data: \(responseString)")
        }
        
        try Self.ensureOK(resp)
        
        // Try to decode and log the response
        do {
            let response = try decoder.decode(StartResponse.self, from: data)
            print("🌐 NetworkService: Successfully decoded response:")
            print("   - Success: \(response.success)")
            print("   - Message: \(response.message)")
            print("   - Activity ID: \(response.data.activity.id)")
            return response
        } catch {
            print("❌ NetworkService: Failed to decode response: \(error)")
            print("❌ NetworkService: Decoding error details: \(error)")
            throw error
        }
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
    
    // POST /api/runner/{runnerId}/activity/{activityId}/location (simplified version for development)
    func updateLocation(runnerId: String, activityId: String, latitude: Double, longitude: Double, distance: Double) async throws {
        let url = baseHTTP.appendingPathComponent("/api/runner/\(runnerId)/activity/\(activityId)/location")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "lat": latitude,
            "lng": longitude,
            "distance": distance
        ]
        
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, resp) = try await session.data(for: req)
        try Self.ensureOK(resp)
    }
    
    // WebSocket for live cheers: ws://localhost:3000/api/activity/stream?activityId=...
    func openCheerStream(activityId: String) {
        closeCheerStream()
        guard let wsURL = URL(string: "ws://192.168.1.108:3000/api/activity/stream?activityId=\(activityId)") else { return }
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
    } //test
    
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
