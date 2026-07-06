import SwiftUI

struct StatusWindowView: View {
    @ObservedObject var controller: GatewayController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MLX Gateway")
                        .font(.title2.weight(.semibold))
                    Text(controller.statusText)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Button {
                    controller.restartGateway()
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Gateway")
                        .foregroundStyle(.secondary)
                    TextField("Host", text: $controller.gatewayHost)
                        .frame(width: 140)
                    TextField("Port", text: $controller.gatewayPort)
                        .frame(width: 80)
                }
                GridRow {
                    Text("Model")
                        .foregroundStyle(.secondary)
                    TextField("Host", text: $controller.modelHost)
                        .frame(width: 140)
                    TextField("Port", text: $controller.modelPort)
                        .frame(width: 80)
                }
            }
            .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("OpenAI")
                    .font(.headline)
                Text(controller.baseURL)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                Text("Anthropic")
                    .font(.headline)
                    .padding(.top, 4)
                Text(controller.anthropicBaseURL)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Models")
                    .font(.headline)
                ForEach(controller.registry.models) { model in
                    HStack(spacing: 8) {
                        Image(systemName: model.backend == .mlxVLM ? "eye" : "text.bubble")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(model.id)
                            .lineLimit(1)
                        Spacer()
                        Text(model.backend.rawValue)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            if let lastError = controller.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(.regularMaterial)
    }

    private var statusColor: Color {
        switch controller.statusText {
        case "Ready":
            return .green
        case "Failed":
            return .red
        default:
            return .secondary
        }
    }
}
