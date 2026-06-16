//
//  AuthView.swift
//  leanring-buddy
//
//  First-launch sign-in screen hosted inside the expanded notch panel. Collects
//  the user's email, asks the Worker for a magic link, then waits for the
//  `Speed://auth?token=…` link to be opened and verified.
//

import SwiftUI

struct AuthView: View {
    @ObservedObject var authManager: AuthManager
    @State private var email: String = ""

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
        .padding(28)
        .frame(width: 420)
        .background(Color.black)
    }

    // MARK: - Email input

    private var emailInputState: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Speed")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Sign in with your email to get started.")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            TextField("you@example.com", text: $email)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .onSubmit(submit)

            if case let .error(message) = authManager.phase {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.destructiveText)
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(isEmailValid ? DS.Colors.accent : DS.Colors.accent.opacity(0.4))
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!isEmailValid || authManager.phase == .sending)
        }
    }

    // MARK: - Check your email

    private var checkEmailState: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(DS.Colors.accentText)

            Text("Check your email")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("We sent a magic link to \(authManager.pendingEmail ?? "your inbox"). Open it to finish signing in.")
                .font(.system(size: 13))
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .pointerCursor()

                Button("Use a different email") {
                    authManager.resetToInput()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 14, weight: .medium))
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
