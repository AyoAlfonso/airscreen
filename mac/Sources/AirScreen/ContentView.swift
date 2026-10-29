import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: model.isSharing ? "rectangle.inset.filled.and.person.filled" : "rectangle.on.rectangle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(model.isSharing ? Color.accentColor : .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AirScreen").font(.headline)
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if !model.isSharing {
                Text("Open AirScreen on your TV · same Wi-Fi")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                HStack {
                    Text(model.deviceName).font(.subheadline)
                    Spacer()
                    Text("Ready").font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                HStack {
                    Text("Quality").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $model.quality) {
                        ForEach(StreamQuality.allCases) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(model.isSharing)
                }

                HStack {
                    Text("Codec").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $model.codec) {
                        ForEach(CodecChoice.allCases) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(model.isSharing)
                }

                HStack {
                    Text("Audio").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $model.audioChoice) {
                        ForEach(AudioChoice.allCases) { a in
                            Text(a.rawValue).tag(a)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(model.isSharing)
                }

                HStack {
                    Text("Bitrate").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $model.bitrate) {
                        ForEach(StreamBitrate.allCases) { b in
                            Text(b.label).tag(b)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(model.isSharing)
                }

                Button {
                    model.start()
                } label: {
                    Text("Share Screen").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                if let request = model.pairingRequest {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(request.name) wants to connect")
                            .font(.caption)
                        Text(Pairing.grouped(request.code))
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .tracking(2)
                        Text("Allow it in the pairing window only if your TV shows this code.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button("Decline") { model.denyPairing() }
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }

                if let audio = model.activeAudioCodec {
                    HStack {
                        Text("Audio").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(audio == "opus" ? "Opus" : "PCM").font(.caption)
                    }
                }

                Button(role: .destructive) {
                    model.stop()
                } label: {
                    Text("Stop Sharing").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if model.pairedDeviceCount > 0 {
                Button("Forget paired TVs (\(model.pairedDeviceCount))") {
                    model.forgetPairedDevices()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
