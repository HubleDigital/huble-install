import SwiftUI

@main
struct HubleApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Huble") {
            RootView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 440)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.installerPresent {
                MainView()
            } else {
                SetupView()
            }
        }
        .sheet(item: $model.activeRun) { run in
            ProgressSheet(run: run) {
                model.activeRun = nil
                model.refresh()
            }
        }
        .onAppear { model.refresh() }
    }
}
