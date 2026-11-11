import SwiftUI

struct ContentView: View {
    @State private var store = CapsuleStore()
    @State private var draft = ""
    @State private var duration: SealDuration = .tenSeconds
    @State private var isSealing = false
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    composeCard

                    if let notice = store.lockedNotice {
                        Text("\(Image(systemName: "lock.fill")) \(notice)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.red.gradient, in: .capsule)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .accessibilityIdentifier("lockedBanner")
                    }

                    if let error = store.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(12)
                            .glassEffect(.regular.tint(.red), in: .rect(cornerRadius: 14))
                            .accessibilityIdentifier("errorBanner")
                    }

                    capsuleList
                }
                .padding()
                .animation(.snappy, value: store.lockedNotice)
                .animation(.snappy, value: store.capsules)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Backdrop())
            .navigationTitle("Time Capsule")
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
            .sheet(item: $store.revealed) { capsule in
                RevealView(capsule: capsule)
            }
        }
    }

    private var composeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Write to future you")
                .font(.headline)

            TextField("Something worth remembering…", text: $draft)
                .textFieldStyle(.plain)
                .padding(12)
                .background(.background.opacity(0.6), in: .rect(cornerRadius: 12))
                .focused($editing)
                .submitLabel(.done)
                .accessibilityIdentifier("messageField")

            Picker("Opens in", selection: $duration) {
                ForEach(SealDuration.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("durationPicker")

            Button {
                Task {
                    isSealing = true
                    if await store.seal(draft, for: duration) {
                        draft = ""
                        editing = false
                    }
                    isSealing = false
                }
            } label: {
                Label(isSealing ? "Sealing…" : "Seal it", systemImage: "seal.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Color(red: 0.62, green: 0.08, blue: 0.12))
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isSealing)
            .accessibilityIdentifier("sealButton")
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    @ViewBuilder
    private var capsuleList: some View {
        if store.capsules.isEmpty && store.errorMessage == nil {
            Text("No capsules yet. Seal one and come back later.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 24)
        } else {
            VStack(spacing: 12) {
                ForEach(store.capsules) { capsule in
                    CapsuleRow(capsule: capsule, store: store)
                }
            }
        }
    }
}

struct CapsuleRow: View {
    let capsule: Capsule
    let store: CapsuleStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = store.remaining(for: capsule, at: context.date)
            let state = capsule.status == "opened" ? "opened" : (remaining > 0 ? "sealed" : "ready")

            Button {
                Task { await store.open(capsule) }
            } label: {
                HStack(spacing: 14) {
                    WaxSeal(state: state)
                        .frame(width: 46, height: 46)

                    VStack(alignment: .leading, spacing: 3) {
                        switch state {
                        case "opened":
                            Text(capsule.message ?? "Opened")
                                .font(.body.weight(.medium))
                                .lineLimit(2)
                            Text("Sealed \(Text(capsule.sealedAt, style: .relative)) ago")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case "ready":
                            Text("Ready to open")
                                .font(.headline)
                            Text("Tap to break the seal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        default:
                            Text("Sealed")
                                .font(.headline)
                            Text("Opens in \(CapsuleStore.countdown(remaining))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("capsuleRow")
            .accessibilityValue(state)
        }
    }
}

struct WaxSeal: View {
    let state: String

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    state == "opened"
                        ? AnyShapeStyle(.gray.opacity(0.35))
                        : AnyShapeStyle(
                            RadialGradient(
                                colors: [Color(red: 0.86, green: 0.2, blue: 0.2), Color(red: 0.45, green: 0.04, blue: 0.08)],
                                center: .topLeading, startRadius: 2, endRadius: 46
                            )
                        )
                )
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)

            switch state {
            case "opened":
                Image(systemName: "envelope.open.fill").foregroundStyle(.white)
            case "ready":
                Image(systemName: "sparkles").foregroundStyle(.white).symbolEffect(.pulse)
            default:
                Image(systemName: "lock.fill").foregroundStyle(.white.opacity(0.9))
            }
        }
        .font(.title3)
    }
}

struct RevealView: View {
    let capsule: Capsule
    @State private var cracked = false

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                Text("A message from your past self")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Text(capsule.message ?? "")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("revealedMessage")

                Text("Sealed \(Text(capsule.sealedAt, style: .relative)) ago")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding()
            .scaleEffect(cracked ? 1 : 0.85)
            .opacity(cracked ? 1 : 0)

            SealHalf(isLeft: true)
                .offset(x: cracked ? -260 : 0, y: cracked ? 60 : 0)
                .rotationEffect(.degrees(cracked ? -35 : 0))
                .opacity(cracked ? 0 : 1)
            SealHalf(isLeft: false)
                .offset(x: cracked ? 260 : 0, y: cracked ? 60 : 0)
                .rotationEffect(.degrees(cracked ? 35 : 0))
                .opacity(cracked ? 0 : 1)
        }
        .presentationDetents([.medium])
        .presentationBackground(.thinMaterial)
        .sensoryFeedback(.success, trigger: cracked)
        .onAppear {
            withAnimation(.spring(duration: 0.9, bounce: 0.3).delay(0.35)) {
                cracked = true
            }
        }
    }
}

/// Half of a wax seal, so the seal can crack apart when a capsule opens.
struct SealHalf: View {
    let isLeft: Bool

    var body: some View {
        Image(systemName: "seal.fill")
            .font(.system(size: 130))
            .foregroundStyle(
                RadialGradient(
                    colors: [Color(red: 0.86, green: 0.2, blue: 0.2), Color(red: 0.45, green: 0.04, blue: 0.08)],
                    center: .topLeading, startRadius: 4, endRadius: 140
                )
            )
            .mask {
                HStack(spacing: 0) {
                    if isLeft {
                        Rectangle()
                        Color.clear
                    } else {
                        Color.clear
                        Rectangle()
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

struct Backdrop: View {
    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.6, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                .indigo, .purple, .pink,
                .blue, .purple, .orange,
                .teal, .indigo, .orange,
            ]
        )
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
