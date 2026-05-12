import SwiftUI

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var orchestrator = GigiSmartOrchestrator.shared
    @ObservedObject private var presence = PresenceSessionController.shared
    @ObservedObject private var liveActivity = GigiLiveActivityController.shared

    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "gigi.onboarding.complete")
    @State private var showPresence = false
    @State private var showQuickTalk = false
    @State private var selection: Int = 0
    @State private var showPairingSheet = false
    @State private var harnessConfigured = GigiHarnessClient.shared.pairingState.isConfigured
    @ObservedObject private var quickTalk = QuickTalkController.shared
    // GATE 9.D — Discovery Layer A conversational tour, shown ONCE after
    // permissions onboarding completes (or skipped for upgrade users).
    @ObservedObject private var tourFlow = GigiOnboardingFlow.shared

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selection) {
                // 3-tab layout (2026-05-11): tab Presence removed (D3).
                // Presence Mode is still available — triggered via mic button
                // in ChatView (long-press) or via Siri AppIntent. The
                // PresenceView sheet renders the orb when active.
                ChatView()
                    .tag(0)
                    .tabItem {
                        Image(systemName: "waveform.badge.mic")
                        Text("GIGI")
                    }

                DashboardView()
                    .tag(1)
                    .tabItem {
                        Image(systemName: "square.grid.2x2")
                        Text("Dashboard")
                    }

                SettingsView()
                    .tag(2)
                    .tabItem {
                        Image(systemName: "gearshape.fill")
                        Text("Settings")
                    }
            }
            .tint(.purple)
            .preferredColorScheme(.dark)
            .simultaneousGesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        let h = value.translation.width
                        let v = value.translation.height
                        guard abs(h) > abs(v) * 1.5 else { return }
                        if h < -50 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                selection = min(selection + 1, 2)
                            }
                        } else if h > 50 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                selection = max(selection - 1, 0)
                            }
                        }
                    }
            )

            if !harnessConfigured && !showOnboarding {
                pairingBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(50)
            }

            // Harness reachability banner (#16 sub 3/4) — appears when paired but offline.
            // Sits below the unpaired pairingBanner so the two never overlap visually.
            if harnessConfigured && !showOnboarding {
                HarnessOfflineBanner()
                    .zIndex(48)
            }

            // liveActivityBanner removed from top overlay (2026-05-11) to avoid
            // stacking 3 banners (pairing + harness offline + LA error). LA errors
            // surface via console + GigiDebugLogger; consider a dedicated row in
            // Settings → Debug if needed for diagnosis.

            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .transition(.opacity)
                    .zIndex(99)
            }

            // GATE 9.D — Layer A conversational tour. Mounts AFTER the
            // permissions OnboardingView has dismissed (showOnboarding ==
            // false) and only if `evaluateOnLaunch` decided to show it
            // (fresh user, <5 turns history). zIndex slightly below
            // OnboardingView so it never overlaps if both somehow active.
            if !showOnboarding && tourFlow.shouldShowTour {
                OnboardingTourView()
                    .transition(.opacity)
                    .zIndex(98)
            }

            // Sub #14 3/3: Talking Session task list overlay — sibling of TabView
            // so its DragGesture does not conflict with TabView page swipe.
            // Visible only on Chat tab (selection == 0).
            if presence.isActive && !showOnboarding && selection == 0 {
                HStack {
                    Spacer()
                    TalkingSessionTaskListView()
                        .padding(.top, 120)
                        .padding(.trailing, 12)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(48)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showOnboarding)
        .animation(.easeInOut(duration: 0.3), value: harnessConfigured)
        .animation(.easeInOut(duration: 0.3), value: presence.isActive)
        .animation(.easeInOut(duration: 0.25), value: selection)
        .sheet(isPresented: $showPresence) {
            PresenceView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
        }
        .sheet(isPresented: $showPairingSheet) {
            GigiPairingSheet { _ in
                refreshHarnessConfiguredState()
            }
        }
        // Compact conversation card. Auto-presents whenever the
        // QuickTalkController phase becomes active — covers the deeplink
        // path (`gigi://listen`) and the AppIntent / Action Button path,
        // both of which start the controller without owning UI of their
        // own. The medium detent keeps the rest of the app dim but
        // visible behind the card, mimicking the Siri overlay layout.
        .sheet(isPresented: $showQuickTalk) {
            QuickTalkView()
                .presentationDetents([.fraction(0.55)])
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
        }
        .onChange(of: quickTalk.phase) { _, phase in
            // Open as soon as the controller becomes active and close once
            // the controller drops back to idle. Continuous-mode sessions
            // stay active across listen → think → speak transitions, so
            // the sheet only closes when stop()/exit-phrase fires.
            if phase != .idle && !showQuickTalk {
                showQuickTalk = true
            } else if phase == .idle && showQuickTalk {
                showQuickTalk = false
            }
        }
        .onAppear {
            refreshHarnessConfiguredState()
            // GATE 9.D — Layer A tour only triggers if permissions onboarding
            // is already done. evaluateOnLaunch decides skip-or-show based on
            // persisted flag + turn count threshold.
            if !showOnboarding {
                tourFlow.evaluateOnLaunch()
            }
        }
        .onChange(of: showOnboarding) { _, isShowing in
            // When the permissions OnboardingView dismisses, decide whether
            // to fire Layer A as a follow-up. Same evaluator logic.
            if !isShowing {
                tourFlow.evaluateOnLaunch()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gigiReopenOnboarding)) { _ in
            withAnimation { showOnboarding = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshHarnessConfiguredState() }
        }
        .onChange(of: selection) { _, _ in
            refreshHarnessConfiguredState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gigiHarnessPairingDidChange)) { _ in
            refreshHarnessConfiguredState()
        }
    }


    private func refreshHarnessConfiguredState() {
        // Do not use `isReady` for this banner. `isReady` depends on the
        // in-memory diagnostics cache, which is intentionally lost when the
        // app is killed. The top banner only means "pair this phone with a
        // PC", so persisted Keychain config is the correct source of truth.
        harnessConfigured = GigiHarnessClient.shared.pairingState.isConfigured
    }

    // liveActivityBanner helper removed (2026-05-11) — see top-of-file note.

    private var pairingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect GIGI to your PC")
                    .font(.subheadline.weight(.semibold))
                Text("Tap to set up & pair")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.75))
            }
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 18))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(
            LinearGradient(colors: [Color.purple, Color.purple.opacity(0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(.horizontal, 14)
        .padding(.top, 56)
        .onTapGesture { showPairingSheet = true }
    }
}

// PresenceModeTabView removed (2026-05-11): D3 reduces MainTabView from 4 to
// 3 tabs (Chat / Dashboard / Settings). Presence Mode is still reachable —
// the .sheet(isPresented: $showPresence) above hosts PresenceView. Trigger
// it from ChatView (mic long-press) or via Siri AppIntent / Action Button.
