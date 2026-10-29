import SwiftUI

@main
struct AirScreenApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Image(systemName: model.isSharing ? "rectangle.inset.filled.and.person.filled" : "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}
