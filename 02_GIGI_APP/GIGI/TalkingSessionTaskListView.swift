import SwiftUI

/// Live task list overlay shown alongside ChatView during Talking Session.
/// Reflects GigiTaskExtractor.shared.tasks in real time (#55).
struct TalkingSessionTaskListView: View {
    @ObservedObject var extractor = GigiTaskExtractor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checklist")
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                            if let dl = task.deadline, !dl.isEmpty {
                                Text(dl)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange.opacity(0.8))
                            }
                            if let vip = task.vipContact, !vip.isEmpty {
                                Text("⭐ \(vip)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 200)
        .animation(.easeInOut(duration: 0.25), value: extractor.tasks.count)
    }
}
