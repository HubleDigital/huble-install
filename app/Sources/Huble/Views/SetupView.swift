import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Set up this Mac for Huble")
                .font(.title2.weight(.semibold))
            Text("Installs Obsidian, Node, the GitHub CLI, the Huble platform and the agent CLIs. You will be asked to sign in to GitHub in your browser once. Nothing needs a password.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if let err = model.bootstrapError {
                Text(err).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Button {
                Task { await model.setUpThisMac() }
            } label: {
                if model.bootstrapping {
                    ProgressView().controlSize(.small).frame(width: 140)
                } else {
                    Text("Set up this Mac").frame(width: 140)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.bootstrapping)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
