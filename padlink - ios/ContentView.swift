import SwiftUI

/// Discovery + pairing screens for the iOS sender.
struct DiscoveryView: View {
    @EnvironmentObject var discovery: Discovery
    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if let err = connection.errorMessage {
                    Text(err).foregroundStyle(.red).padding(.horizontal)
                }
                if discovery.receivers.isEmpty {
                    Spacer()
                    HStack { Spacer(); ProgressView("Searching the local network…"); Spacer() }
                    Spacer()
                } else {
                    List(discovery.receivers) { r in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(r.name).font(.headline)
                                Text(r.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect") { connection.connect(r, wantsScreen: r.screen) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                Toggle(isOn: $connection.useWiredInput) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reliable input (USB / weak Wi-Fi)")
                        Text("Streams input over TCP instead of UDP.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                Text("Make sure your computer and phone are on the same Wi-Fi.")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
            .navigationTitle("PadLink")
        }
    }
}

struct PinView: View {
    @EnvironmentObject var connection: ConnectionManager
    @State private var pin = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Enter the PIN shown on your computer").font(.headline)
            TextField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .frame(width: 180)
                .onChange(of: pin) { _, v in pin = String(v.prefix(4).filter(\.isNumber)) }
            Button("Pair") { connection.submitPin(pin) }
                .buttonStyle(.borderedProminent)
                .disabled(pin.count != 4)
            Button("Cancel", role: .cancel) { connection.disconnect() }
        }
        .padding()
    }
}
