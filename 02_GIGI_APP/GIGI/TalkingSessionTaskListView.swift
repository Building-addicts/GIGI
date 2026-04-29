import SwiftUI

struct TalkingSessionTaskListView: View {
    @ObservedObject var extractor = GigiTaskExtractor.shared

    @AppStorage("gigi.tasklist.collapsed") private var isCollapsed: Bool = false
    @AppStorage("gigi.tasklist.offsetX") private var savedOffsetX: Double = 0
    @AppStorage("gigi.tasklist.offsetY") private var savedOffsetY: Double = 0

    @State private var dragTranslation: CGSize = .zero

    private var totalOffset: CGSize {
        CGSize(width: savedOffsetX + dragTranslation.width,
               height: savedOffsetY + dragTranslation.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if !isCollapsed {
                content
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: isCollapsed ? 130 : 200, alignment: .leading)
        .offset(totalOffset)
        .gesture(dragGesture)
        .animation(.easeInOut(duration: 0.2), value: isCollapsed)
        .animation(.easeInOut(duration: 0.25), value: extractor.tasks.count)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 13))
                .foregroundStyle(.cyan)
            Text("Tasks")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if isCollapsed && !extractor.tasks.isEmpty {
                Text("(\(extractor.tasks.count))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.cyan.opacity(0.8))
            }
            Spacer()
            if extractor.isExtracting {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.cyan)
            }
            Button {
                isCollapsed.toggle()
            } label: {
                Image(systemName: isCollapsed ? "chevron.left" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if extractor.tasks.isEmpty {
            Text("Listening for tasks…")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .italic()
        } else {
            ForEach(extractor.tasks) { task in
                taskRow(task)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }

    private func taskRow(_ task: ExtractedTask) -> some View {
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
    }

    // MARK: - Drag gesture

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragTranslation = value.translation
            }
            .onEnded { value in
                let proposedX = savedOffsetX + value.translation.width
                let proposedY = savedOffsetY + value.translation.height
                // Soft clamp to keep card mostly on screen (assume ~400 px headroom each side)
                savedOffsetX = max(-260, min(40, proposedX))
                savedOffsetY = max(-100, min(500, proposedY))
                dragTranslation = .zero
            }
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
