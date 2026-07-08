//
//  AuthView.swift
//  leanring-buddy
//
//  First-launch sign-in screen hosted inside the expanded notch panel. Collects
//  the user's email, asks the Worker for a magic link, then waits for the
//  `Macky://auth?token=…` link to be opened and verified. During early testing,
//  the user can skip this step locally and continue onboarding.
//

import SwiftUI

struct AuthView: View {
    @ObservedObject var authManager: AuthManager
    @State private var email: String = ""
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch authManager.phase {
            case .sent:
                checkEmailState
            case .verifying:
                verifyingState
            default:
                emailInputState
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Email input

    private var emailInputState: some View {
        VStack(spacing: 14) {
            // The glowing blue Macky glyph — the brand identity.
            MackyGlyphLogo(size: 40, glow: true)
                .padding(.bottom, 2)

            VStack(spacing: 6) {
                Text("Welcome to Macky")
                    .font(.system(size: DS.PanelTypography.size(21), weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Sign in with your email to get started.")
                    .font(.system(size: DS.PanelTypography.size(12)))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .multilineTextAlignment(.center)

            TextField("you@example.com", text: $email)
                .textFieldStyle(.plain)
                .font(.system(size: DS.PanelTypography.size(13)))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($emailFocused)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            emailFocused ? DS.Colors.accent : DS.Colors.borderSubtle,
                            lineWidth: emailFocused ? 1.5 : 1
                        )
                        .animation(.smooth(duration: 0.15), value: emailFocused)
                )
                .onSubmit(submit)

            if case let .error(message) = authManager.phase {
                Text(message)
                    .font(.system(size: DS.PanelTypography.size(12)))
                    .foregroundColor(DS.Colors.destructiveText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if authManager.phase == .sending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(DS.Colors.textOnAccent)
                    }
                    Text(authManager.phase == .sending ? "Sending…" : "Send magic link")
                        .font(.system(size: DS.PanelTypography.size(13), weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(isEmailValid ? DS.Colors.accent : DS.Colors.accent.opacity(0.4))
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!isEmailValid || authManager.phase == .sending)

            // Footer privacy reassurance.
            HStack(spacing: 6) {
                Image(systemName: "lock")
                    .font(.system(size: DS.PanelTypography.size(10), weight: .semibold))
                Text("Your mic is on only while you hold the key.")
                    .font(.system(size: DS.PanelTypography.size(10)))
            }
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.top, 2)

            Button("Skip for now") {
                authManager.skipAuthenticationForNow()
            }
            .buttonStyle(.plain)
            .font(.system(size: DS.PanelTypography.size(12), weight: .medium))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
            .pointerCursor()
            .disabled(authManager.phase == .sending)

            Text("You can sign in later when magic-link auth is ready.")
                .font(.system(size: DS.PanelTypography.size(11)))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Check your email

    private var checkEmailState: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge")
                .font(.system(size: DS.PanelTypography.size(30), weight: .light))
                .foregroundColor(DS.Colors.accentText)

            Text("Check your email")
                .font(.system(size: DS.PanelTypography.size(18), weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("We sent a magic link to \(authManager.pendingEmail ?? "your inbox"). Open it to finish signing in.")
                .font(.system(size: DS.PanelTypography.size(13)))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Button("Resend") {
                    if let pendingEmail = authManager.pendingEmail {
                        Task { await authManager.requestMagicLink(email: pendingEmail) }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: DS.PanelTypography.size(12), weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .pointerCursor()

                Button("Use a different email") {
                    authManager.resetToInput()
                }
                .buttonStyle(.plain)
                .font(.system(size: DS.PanelTypography.size(12), weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .pointerCursor()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Verifying

    private var verifyingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Signing you in…")
                .font(.system(size: DS.PanelTypography.size(14), weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private var isEmailValid: Bool {
        email.trimmingCharacters(in: .whitespacesAndNewlines).contains("@")
    }

    private func submit() {
        guard isEmailValid else { return }
        Task { await authManager.requestMagicLink(email: email) }
    }
}
