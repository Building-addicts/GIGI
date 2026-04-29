import SwiftUI

struct TalkingSessionTaskListView: View {
    @ObservedObject var extractor = GigiTaskExtractor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 13))
                    .foregroundStyle(.cyan)
                Text("Tasks")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if extractor.isExtracting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.cyan)
                }
            }

            if extractor.tasks.isEmpty {
                Text("Listening for tasks…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .italic()
            } else {
                ForEach(extractor.tasks) { task in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                            if let dl = task.deadline, !dl.isEmpty {
                                Text(dl)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange.opacity(0.85))
                            }
                            if let vip = task.vipContact, !vip.isEmpty {
                                Text("⭐ \(vip)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.yellow)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 200, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: extractor.tasks.count)
    }
}

#if DEBUG
#Preview("Empty") {
    ZStack {
        Color.black.ignoresSafeArea()
        TalkingSessionTaskListView()
    }
}
#endif
