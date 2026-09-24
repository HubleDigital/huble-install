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
            // Fresh Mac = no platform. A missing ~/.huble/install.sh on a Mac
            // that has the platform is handled inside MainView (banner + silent fetch).
            if model.platformPresent {
                MainView()
            } else {
                SetupView()
            }
        }
        .sheet(item: $model.activeRun) { run in
            ProgressSheet(
                run: run,
                onClose: {
                    model.activeRun = nil
                    model.refresh(forceCheck: true)
                },
                onRemoveAnyway: run.action.removePath.map { path in
                    { model.run(.removeVault(path: path, force: true)) }
                })
        }
        .onAppear { model.refresh() }
    }
}
