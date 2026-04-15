import SwiftUI
import GoogleSignIn

struct GigiLoginView: View {
    @ObservedObject var auth = GigiAuthManager.shared
    @State private var animating = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo e titolo
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.purple.opacity(0.15))
                            .frame(width: 100, height: 100)
                            .scaleEffect(animating ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: animating)

                        Text("G")
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }

                    Text("GIGI")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Your AI that replaces Siri")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()

                // Feature list
                VStack(alignment: .leading, spacing: 14) {
                    FeatureRow(icon: "mic.fill", text: "Understands natural language")
                    FeatureRow(icon: "bolt.fill", text: "Controls your iPhone instantly")
                    FeatureRow(icon: "brain", text: "Powered by Gemini AI")
                    FeatureRow(icon: "lock.fill", text: "Your data stays private")
                }
                .padding(.horizontal, 40)

                Spacer()

                // Sign in button
                VStack(spacing: 16) {
                    if auth.isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(height: 54)
                    } else {
                        Button {
                            auth.signIn()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "g.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                                Text("Continue with Google")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Color.purple)
                            .cornerRadius(16)
                        }
                    }

                    if !auth.errorMessage.isEmpty {
                        Text(auth.errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }

                    Text("By continuing you agree to our Terms of Service.\nYour Google account enables Gemini AI.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.3))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 48)
            }
        }
        .onAppear { animating = true }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.purple)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.8))
        }
    }
}
