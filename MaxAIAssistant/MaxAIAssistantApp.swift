import SwiftUI
import MWDATCore // The Meta Wearables SDK

@main
struct MaxAIAssistantApp: App {
    
    init() {
        // Boot up the Meta SDK immediately on launch safely
        do {
            try Wearables.configure()
        } catch {
            print("Failed to configure Wearables SDK: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // This catches the callback when the Meta View app kicks you back here
                .onOpenURL { url in
                    // In v0.5.0, handleUrl is asynchronous
                    Task {
                        do {
                            _ = try await Wearables.shared.handleUrl(url)
                        } catch {
                            print("Failed to handle Meta URL: \(error)")
                        }
                    }
                }
        }
    }
}
