import SwiftUI
import MapKit
import EventKit
import Combine



// MARK: - Running Event Model
// RunningEvent is now defined in Im_Running_AppApp.swift

// MARK: - Calendar Parser
class RunningEventParser: ObservableObject {
    func fetchNearbyEvents(near location: CLLocation, completion: @escaping ([RunningEvent]) -> Void) {
        guard let url = URL(string: "https://aims-worldrunning.org/events.ics") else {
            completion([])
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data, error == nil else {
                print("❌ Failed to fetch events: \(error?.localizedDescription ?? "Unknown error")")
                completion([])
                return
            }
            
            let events = self.parseICSCalendar(data: data, userLocation: location)
            DispatchQueue.main.async {
                completion(events)
            }
        }.resume()
    }
    
    private func parseICSCalendar(data: Data, userLocation: CLLocation) -> [RunningEvent] {
        guard let icsString = String(data: data, encoding: .utf8) else { return [] }
        
        var todayEvents: [RunningEvent] = []
        var upcomingEvents: [RunningEvent] = []
        let today = Calendar.current.startOfDay(for: Date())
        let now = Date()
        
        // Simple ICS parsing (basic implementation)
        let lines = icsString.components(separatedBy: .newlines)
        var currentEvent: [String: String] = [:]
        
        for line in lines {
            if line.hasPrefix("BEGIN:VEVENT") {
                currentEvent.removeAll()
            } else if line.hasPrefix("END:VEVENT") {
                if let event = createEvent(from: currentEvent, userLocation: userLocation, today: today, now: now) {
                    if event.isToday {
                        todayEvents.append(event)
                    } else if event.date > now {
                        upcomingEvents.append(event)
                    }
                }
                currentEvent.removeAll()
            } else if line.contains(":") {
                let components = line.split(separator: ":", maxSplits: 1)
                if components.count == 2 {
                    let key = String(components[0])
                    let value = String(components[1])
                    currentEvent[key] = value
                }
            }
        }
        
        // Sort upcoming events by date
        upcomingEvents.sort { $0.date < $1.date }
        
        // Always return events: prioritize today's nearby events, then fill with upcoming events
        var resultEvents: [RunningEvent] = []
        
        // Add today's events first
        resultEvents.append(contentsOf: todayEvents.sorted { $0.date < $1.date })
        
        // Fill remaining slots with upcoming events
        let remainingSlots = 5 - resultEvents.count
        if remainingSlots > 0 {
            let upcomingToAdd = Array(upcomingEvents.prefix(remainingSlots))
            resultEvents.append(contentsOf: upcomingToAdd)
        }
        
        print("🔍 Parser Debug: todayEvents=\(todayEvents.count), upcomingEvents=\(upcomingEvents.count), result=\(resultEvents.count)")
        
        return resultEvents
    }
    
    private func createEvent(from data: [String: String], userLocation: CLLocation, today: Date, now: Date) -> RunningEvent? {
        guard let summary = data["SUMMARY"],
              let dateString = data["DTSTART"],
              let location = data["LOCATION"] else { return nil }
        
        // Parse date (basic implementation)
        let date = parseICSDate(dateString) ?? Date()
        
        // Check if event is today
        let eventDay = Calendar.current.startOfDay(for: date)
        let isToday = eventDay == today
        
        // For today's events, check if they're nearby
        if isToday {
            let coordinates = parseCoordinates(from: location)
            var distance: String?
            
            if let coords = coordinates {
                let eventLocation = CLLocation(latitude: coords.latitude, longitude: coords.longitude)
                let distanceInMeters = userLocation.distance(from: eventLocation)
                if distanceInMeters < 50000 { // Within 50km
                    distance = formatDistance(distanceInMeters)
                } else {
                    // Event is today but too far away
                    print("🔍 Event '\(summary)' is today but too far: \(Int(distanceInMeters/1000))km")
                    return nil
                }
            } else {
                // Event is today but no coordinates - include it anyway
                distance = "Location unknown"
            }
            
            print("🔍 Added today's event: '\(summary)' at \(location)")
            let coords = coordinates
            return RunningEvent(
                title: summary,
                date: date,
                location: location,
                latitude: coords?.latitude,
                longitude: coords?.longitude,
                distance: distance,
                isToday: true,
                eventType: "race"
            )
        } else if date > now {
            // Future event - include it for upcoming events list
            let coordinates = parseCoordinates(from: location)
            var distance: String?
            
            if let coords = coordinates {
                let eventLocation = CLLocation(latitude: coords.latitude, longitude: coords.longitude)
                let distanceInMeters = userLocation.distance(from: eventLocation)
                distance = formatDistance(distanceInMeters)
            }
            
            print("🔍 Added upcoming event: '\(summary)' on \(date) at \(location)")
            let coords = coordinates
            return RunningEvent(
                title: summary,
                date: date,
                location: location,
                latitude: coords?.latitude,
                longitude: coords?.longitude,
                distance: distance,
                isToday: false,
                eventType: "race"
            )
        }
        
        print("🔍 Skipped event '\(summary)' - not today and not future")
        return nil
    }
    
    private func parseICSDate(_ dateString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        // Try alternative format
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: dateString)
    }
    
    private func parseCoordinates(from location: String) -> CLLocationCoordinate2D? {
        // Simple coordinate parsing (you might need to enhance this based on actual data format)
        let components = location.components(separatedBy: ",")
        if components.count >= 2,
           let lat = Double(components[0].trimmingCharacters(in: .whitespaces)),
           let lon = Double(components[1].trimmingCharacters(in: .whitespaces)) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }
    
    private func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            return "\(Int(meters))m away"
        } else {
            return String(format: "%.1fkm away", meters / 1000)
        }
    }
}

struct MapMainView: View {
    @EnvironmentObject var app: AppState
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818), // Default to Tel Aviv
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01) // ~1km radius
    )
    @State private var developmentLocation = CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818)
    @State private var nearbyEvents: [RunningEvent] = []
    @State private var showingEventSelection = false
    @State private var showingShareMenu = false
    @State private var selectedEvent: RunningEvent?
    @State private var customEventName = ""
    @State private var isLoadingEvents = false
    @State private var currentCheer: String?
    @State private var showingCheer = false
    
    @State private var cancellables = Set<AnyCancellable>()
    
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
        ZStack {
            // Background Map with Runner Tracking
            Map(coordinateRegion: $region, showsUserLocation: false, userTrackingMode: .constant(.none))
                .ignoresSafeArea()
                .onAppear {
                    // Start with current GPS location or fallback to Tel Aviv
                    if let currentLocation = app.location.currentLocation {
                        region.center = currentLocation.coordinate
                        print("🗺️ Map appeared - using current GPS location: \(currentLocation.coordinate.latitude), \(currentLocation.coordinate.longitude)")
                    } else {
                        let telAvivLocation = CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818)
                        region.center = telAvivLocation
                        print("🗺️ Map appeared - using Tel Aviv fallback coordinates: \(telAvivLocation.latitude), \(telAvivLocation.longitude)")
                    }
                }
            
            // Cheer Display Overlay (Top of Screen)
            if showingCheer, let cheer = currentCheer {
                VStack {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Text("💪")
                                .font(.system(size: 40))
                            Text(cheer)
                                .font(.title2.bold())
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.blue.opacity(0.9))
                                .shadow(radius: 10)
                        )
                        Spacer()
                    }
                    .padding(.top, 60)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.5), value: showingCheer)
            }
            
            // Runner Location Marker (Fixed at GPS coordinates)
            if app.activityRunning {
                // Simple runner indicator that will be positioned relative to the map
                VStack(spacing: 0) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 30))
                        .foregroundColor(.green)
                        .background(
                            Circle()
                                .fill(.white)
                                .frame(width: 50, height: 50)
                                .shadow(radius: 3)
                        )
                    
                    // Runner info bubble
                    VStack(spacing: 4) {
                        Text("🏃‍♂️ You")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                        Text("LIVE")
                            .font(.caption2)
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(4)
                    }
                    .padding(6)
                    .background(Color.blue.opacity(0.9))
                    .cornerRadius(8)
                    .shadow(radius: 2)
                }
                .position(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2)
            }
            
            // UI Overlay - Bottom of Screen
            VStack {
                Spacer()
                
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
                    }
                    .padding()
                    .background(Color.white.opacity(0.9))
                    .cornerRadius(12)
                    .shadow(radius: 5)
                }
                
                // Compact Location Status
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: app.location.authorizationStatus == .authorizedWhenInUse || app.location.authorizationStatus == .authorizedAlways ? "location.fill" : "location.slash")
                            .foregroundColor(app.location.authorizationStatus == .authorizedWhenInUse || app.location.authorizationStatus == .authorizedAlways ? .green : .red)
                        Text(locationStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let location = app.location.currentLocation {
                        Text("📍 \(location.coordinate.latitude, specifier: "%.4f"), \(location.coordinate.longitude, specifier: "%.4f")")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.5))
                .cornerRadius(8)
                
                // Activity Control Buttons
                if app.activityRunning {
                    // Pause and Share buttons when activity is running
                    HStack(spacing: 0) {
                        // Pause Button (20% width)
                        Button(action: {
                            app.stopActivity()
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: "pause.fill")
                                    .font(.title2)
                                Text("Pause")
                                    .font(.caption.bold())
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.red.opacity(0.85))
                            .cornerRadius(12)
                        }
                        .frame(width: UIScreen.main.bounds.width * 0.2)
                        .shadow(radius: 3)
                        
                        // Share Button (60% width)
                        Button(action: {
                            shareActivityURL()
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title2)
                                Text("Share")
                                    .font(.caption.bold())
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.blue.opacity(0.85))
                            .cornerRadius(12)
                        }
                        .frame(width: UIScreen.main.bounds.width * 0.6)
                        .shadow(radius: 3)
                    }
                    .padding(.horizontal, UIScreen.main.bounds.width * 0.1) // 10% margin from each side
                } else {
                    // Start Activity Button when not running
                    Button("Start Activity") {
                        if let location = app.location.currentLocation {
                            showingEventSelection = true
                        }
                    }
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .shadow(radius: 3)
                    .disabled(app.location.currentLocation == nil)
                }
                
                // Errors
                if let err = app.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.8))
                        .cornerRadius(6)
                }
            }
            .padding(.bottom, 30)
        }
                        .sheet(isPresented: $showingEventSelection) {
                    EventSelectionView(
                        nearbyEvents: nearbyEvents,
                        selectedEvent: $selectedEvent,
                        customEventName: $customEventName,
                        onStartActivity: startActivityWithEvent
                    )
                    .onAppear {
                        // Fetch events when the sheet appears
                        if let location = app.location.currentLocation {
                            fetchNearbyEvents(for: location)
                        }
                    }
                }
        .sheet(isPresented: $showingShareMenu) {
            ShareMenuView(
                activityURL: app.activityURL,
                selectedEvent: selectedEvent,
                customEventName: customEventName,
                activityId: app.activityId
            )
        }
        .onAppear {
            print("🔄 MapMainView appeared - starting location updates")
            app.location.startUpdating()
            
            // Subscribe to cheers
            setupCheerSubscription()
        }
        .onChange(of: app.location.currentLocation) { _, newLocation in
            if let location = newLocation {
                print("🗺️ Updating map region to user location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
                region = MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func generateNewActivityId() -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let randomSuffix = String(format: "%08x", Int.random(in: 0...0xFFFFFFFF))
        return "act_\(randomSuffix)"
    }
    
    private func setupCheerSubscription() {
        // Subscribe to cheers from the network service
        app.network.cheerPublisher
            .receive(on: DispatchQueue.main)
            .sink { cheer in
                self.showCheer(cheer)
            }
            .store(in: &cancellables)
    }
    
    private func showCheer(_ cheer: String) {
        currentCheer = cheer
        showingCheer = true
        
        // Hide cheer after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation(.easeInOut(duration: 0.5)) {
                showingCheer = false
            }
        }
        
        print("🎉 Received cheer: \(cheer)")
    }
    
    // Development mode: Send location updates every 5 seconds
    private func startDevelopmentLocationUpdates() {
        guard let activityId = app.activityId else { return }
        
        print("🔄 Starting development location updates every 5 seconds")
        
        // Start from current GPS location (real or simulator)
        var currentLat = app.location.currentLocation?.coordinate.latitude ?? 32.0853
        var currentLng = app.location.currentLocation?.coordinate.longitude ?? 34.7818
        var distance = 0.0
        
        print("📍 Starting development location from: \(currentLat), \(currentLng)")
        
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { timer in
            guard self.app.activityRunning else {
                print("🛑 Stopping development location updates - activity stopped")
                timer.invalidate()
                return
            }
            
            // Move 50 meters east (approximately 0.0005 degrees longitude)
            currentLng += 0.0005
            distance += 0.05 // 50 meters = 0.05 km
            
            print("📍 Development location update: \(currentLat), \(currentLng) - Distance: \(String(format: "%.2f", distance)) km")
            
            // Update the map region with smooth animation and center on runner
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 10.0)) {
                    self.developmentLocation = CLLocationCoordinate2D(latitude: currentLat, longitude: currentLng)
                    // Center the map on the runner's current location
                    self.region.center = self.developmentLocation
                    print("🗺️ Map centered on runner at: \(currentLat), \(currentLng)")
                }
            }
            
            // Send location update to backend
            Task {
                do {
                    try await self.app.network.updateLocation(
                        runnerId: self.app.runnerId,
                        activityId: activityId,
                        latitude: currentLat,
                        longitude: currentLng,
                        distance: distance
                    )
                    print("✅ Development location sent to backend")
                } catch {
                    print("❌ Failed to send development location: \(error)")
                }
            }
        }
    }
    
    private func fetchNearbyEvents(for location: CLLocation) {
        isLoadingEvents = true
        let parser = RunningEventParser()
        parser.fetchNearbyEvents(near: location) { events in
            DispatchQueue.main.async {
                self.nearbyEvents = events
                self.isLoadingEvents = false
                print("📍 Found \(events.count) nearby events")
            }
        }
    }
    
    private func startActivityWithEvent() {
        // For development: Use Tel Aviv coordinates instead of simulator location
        let telAvivLatitude: Double = 32.0853
        let telAvivLongitude: Double = 34.7818
        
        // Use selected event or custom name
        let eventName = selectedEvent?.title ?? (customEventName.isEmpty ? "Custom Run" : customEventName)
        let eventType = selectedEvent?.eventType ?? "custom"
        
        print("🚀 Starting activity: \(eventName) (Type: \(eventType))")
        print("📍 Using Tel Aviv coordinates: \(telAvivLatitude), \(telAvivLongitude)")
        print("👤 Runner ID: \(app.runnerId)")
        print("🏃 Activity ID: \(app.activityId ?? "nil")")
        
        Task {
            do {
                print("🌐 Making API request to start activity...")
                let start = try await app.network.startActivity(
                    runnerId: app.runnerId,
                    activityId: app.activityId ?? generateNewActivityId(),
                    latitude: telAvivLatitude,
                    longitude: telAvivLongitude,
                    eventName: eventName,
                    eventType: eventType
                )
                
                print("📡 API Response received:")
                print("   - Success: \(start.success)")
                print("   - Message: \(start.message)")
                print("   - Start Time: \(start.startTime)")
                print("   - Activity ID: \(start.data.activity.id)")
                print("   - User ID: \(start.data.user.id)")
                print("   - Event ID: \(start.data.event.id)")
                
                await MainActor.run {
                    print("✅ Activity started successfully!")
                    print("✅ Event: \(eventName) (Type: \(eventType))")
                    print("✅ New Activity ID: \(start.data.activity.id)")
                    print("✅ Old App Activity ID: \(app.activityId ?? "nil")")
                    
                    // Update the app's activity ID with the one from the response
                    app.activityId = start.data.activity.id
                    print("✅ Updated App Activity ID to: \(app.activityId ?? "nil")")
                    
                    app.lastError = nil
                    app.activityRunning = true
                    showingEventSelection = false
                    
                    // Start development location updates (every 5 seconds)
                    #if DEBUG
                    startDevelopmentLocationUpdates()
                    #endif
                    
                    // Start cheer stream
                    let activityId = start.data.activity.id
                    app.network.openCheerStream(activityId: activityId)
                    print("🎉 Started cheer stream for activity: \(activityId)")
                }
            } catch {
                print("❌ Error starting activity: \(error)")
                print("❌ Error type: \(type(of: error))")
                print("❌ Error description: \(error.localizedDescription)")
                
                await MainActor.run {
                    app.lastError = "Failed to start activity: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func shareActivityURL() {
        guard let activityId = app.activityId else {
            print("❌ No activity ID available for sharing")
            return
        }
        
        let webAppURL = "http://192.168.1.108:3000/\(app.runnerId)/\(activityId)"
        print("🔗 Sharing activity URL: \(webAppURL)")
        
        let activityVC = UIActivityViewController(
            activityItems: [webAppURL],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.rootViewController?.present(activityVC, animated: true)
        }
    }
}

// MARK: - Event Selection View
struct EventSelectionView: View {
    let nearbyEvents: [RunningEvent]
    @Binding var selectedEvent: RunningEvent?
    @Binding var customEventName: String
    let onStartActivity: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Cool Header
                VStack(spacing: 8) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                    
                    Text("Ready to Run? 🏃‍♂️")
                        .font(.title2.bold())
                        .foregroundColor(.primary)
                    
                    let hasNearbyEvents = nearbyEvents.contains { $0.isToday || $0.date < Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date() }
                    Text(hasNearbyEvents ? "What's your event today?" : "Where are you running today?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
                
                // Events List - Always show upcoming events
                VStack(alignment: .leading, spacing: 12) {
                    let hasTodayEvents = nearbyEvents.contains { $0.isToday }
                    let headerText = hasTodayEvents ? "Nearby Events Today" : "Upcoming Events"
                    let subtitleText = hasTodayEvents ? "Events happening near you today" : "Next 5 upcoming events"
                    
                    Text(headerText)
                        .font(.headline)
                        .padding(.horizontal)
                    
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    // Debug info
                    Text("Debug: \(nearbyEvents.count) events loaded")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                    
                    if nearbyEvents.isEmpty {
                        Text("No events found. This might be due to:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        
                        Text("• Network connectivity issues")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        
                        Text("• No events in the calendar")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                        
                        Text("• Location not available")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                    
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(nearbyEvents) { event in
                                EventRow(
                                    event: event,
                                    isSelected: selectedEvent?.id == event.id
                                ) {
                                    selectedEvent = event
                                    customEventName = ""
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                
                // Custom Event Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Or create your own:")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    TextField("Enter activity name...", text: $customEventName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.horizontal)
                        .onChange(of: customEventName) { _ in
                            selectedEvent = nil
                        }
                }
                
                Spacer()
                
                // Go Button
                Button(action: {
                    onStartActivity()
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Go!")
                    }
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                .disabled(selectedEvent == nil && customEventName.isEmpty)
                
                // Cancel Button
                Button("Cancel") {
                    dismiss()
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            }
            .navigationTitle("Event Selection")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Date Formatting Extension
extension View {
    func formatEventDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let now = Date()
        let calendar = Calendar.current
        
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "Today at \(formatter.string(from: date))"
        } else if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) {
            formatter.dateFormat = "HH:mm"
            return "Tomorrow at \(formatter.string(from: date))"
        } else {
            formatter.dateFormat = "MMM dd"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Event Row
struct EventRow: View {
    let event: RunningEvent
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                    
                    Text(event.location)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Distance and Date Row
                    HStack {
                        // Distance
                        if let distance = event.distance {
                            Text(distance)
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                        
                        Spacer()
                        
                        // Date (for upcoming events)
                        if !event.isToday {
                            Text(formatEventDate(event.date))
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                }
            }
            .padding()
            .background(isSelected ? Color.green.opacity(0.1) : Color.gray.opacity(0.1))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.green : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Share Menu View
struct ShareMenuView: View {
    let activityURL: String?
    let selectedEvent: RunningEvent?
    let customEventName: String
    let activityId: String?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppState
    
    private var eventName: String {
        selectedEvent?.title ?? (customEventName.isEmpty ? "Custom Run" : customEventName)
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 50))
                        .foregroundColor(.blue)
                    
                    Text("Share Your Run")
                        .font(.title2.bold())
                    
                    Text("Let others know about your activity!")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
                
                // Event Info
                VStack(spacing: 8) {
                    Text("Event: \(eventName)")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    // Generate web app live map URL
                    let webAppURL = "http://192.168.1.108:3000/\(app.runnerId)/\(app.activityId ?? "unknown")"
                    Text("Web App Live Map")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text(webAppURL)
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    
                    // Show what activity ID we're using
                    if let id = app.activityId {
                        Text("Using Activity ID: \(id)")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.horizontal)
                    } else {
                        Text("⚠️ No Activity ID available")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }
                    
                    // Debug info
                    Text("Debug: Activity ID = \(activityId ?? "nil")")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                    
                    Text("Debug: App Activity ID = \(app.activityId ?? "nil")")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .padding(.horizontal)
                    
                    Text("Debug: Generated ID = \(app.activityId ?? "nil")")
                        .font(.caption2)
                        .foregroundColor(.purple)
                        .padding(.horizontal)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                
                // Share Options
                VStack(spacing: 16) {
                    ShareButton(
                        title: "Share Activity URL",
                        icon: "link",
                        color: .blue
                    ) {
                        // Share web app live map URL
                        let webAppURL = "http://192.168.1.108:3000/\(app.runnerId)/\(app.activityId ?? "unknown")"
                        print("🔗 Sharing URL: \(webAppURL)")
                        print("🔗 Activity ID from parameter: \(activityId ?? "nil")")
                        print("🔗 App State Activity ID: \(app.activityId ?? "nil")")
                        print("🔗 Is Activity Running: \(app.activityRunning)")
                        shareURL(webAppURL)
                    }
                }
                
                Spacer()
                
                // Close Button
                Button("Close") {
                    dismiss()
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            }
            .padding()
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func shareActivityURL() {
        guard let activityId = app.activityId else {
            print("❌ No activity ID available for sharing")
            return
        }
        
        let webAppURL = "http://192.168.1.108:3000/\(app.runnerId)/\(activityId)"
        print("🔗 Sharing activity URL: \(webAppURL)")
        
        let activityVC = UIActivityViewController(
            activityItems: [webAppURL],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.rootViewController?.present(activityVC, animated: true)
        }
    }
    
    private func shareURL(_ url: String) {
        let activityVC = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.rootViewController?.present(activityVC, animated: true)
        }
    }
    

}

// MARK: - Share Button
struct ShareButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                    .frame(width: 24)
                
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
