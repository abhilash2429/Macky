//
//  SkillsWindowView.swift
//  leanring-buddy
//
//  SwiftUI content for the Skills window: a searchable, scrolling catalog of
//  SkillRegistry.skills with an enable/disable pill per row. UI-only \u2014 toggling a
//  skill just flips CompanionManager.enabledSkillIDs; it does not touch the realtime
//  session (that wiring is a separate, later milestone).
//
//  Styled to match boring.notch's own SwiftUI (system-adaptive colors/materials),
//  not Macky's DesignSystem.swift \u2014 this window is intentionally exempt so it reads
//  like a boring.notch-native surface.
//

import SwiftUI

struct SkillsWindowView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var searchText = ""

    private var filteredSkills: [SkillIdentity] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SkillRegistry.skills }
        return SkillRegistry.skills.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
                .overlay(Color.white.opacity(0.1))

            if filteredSkills.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredSkills) { skill in
                            SkillRow(
                                skill: skill,
                                isEnabled: companionManager.isSkillEnabled(skill.id),
                                onToggle: { companionManager.toggleSkill(skill.id) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .background(.ultraThinMaterial)
        .navigationTitle("Macky Skills")
    }

    private var header: some View {
        HStack {
            Text("Skills")
                .font(.system(.title2, design: .rounded))
                .fontWeight(.semibold)
                .foregroundColor(.white.opacity(0.9))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.white.opacity(0.4))
            TextField("Search skills", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundColor(.white.opacity(0.9))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .secondarySystemFill))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.3))

            Text("No skills match “\(searchText)”")
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SkillRow: View {
    let skill: SkillIdentity
    let isEnabled: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconTile

            VStack(alignment: .leading, spacing: 4) {
                Text(skill.displayName)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))

                Text(skill.summary)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !skill.connectorSlugs.isEmpty {
                    connectorPills
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            EnableToggleButton(isEnabled: isEnabled, action: onToggle)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .secondarySystemFill))
            .frame(width: 36, height: 36)
            .overlay(
                Image(systemName: skill.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            )
    }

    private var connectorPills: some View {
        HStack(spacing: 6) {
            ForEach(skill.connectorSlugs, id: \.self) { slug in
                if let identity = ConnectorRegistry.identity(forSlug: slug),
                   let logo = NSImage(named: identity.logoAssetName) {
                    HStack(spacing: 4) {
                        Image(nsImage: logo)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 11, height: 11)
                        Text(identity.displayName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
                }
            }
        }
    }
}

private struct EnableToggleButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isEnabled ? "Enabled" : "Enable")
                .font(.system(.footnote, design: .rounded))
                .fontWeight(.semibold)
                .foregroundColor(isEnabled ? .white : .white.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isEnabled ? Color.accentColor : Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }
}
