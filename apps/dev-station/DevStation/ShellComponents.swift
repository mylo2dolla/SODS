import SwiftUI

enum CompactActionVariant {
    case primary
    case secondary
}

struct CompactActionButton: View {
    let systemImage: String
    let helpText: String
    let accessibilityTitle: String
    var variant: CompactActionVariant = .secondary
    let action: () -> Void

    var body: some View {
        Group {
            if variant == .primary {
                baseButton
                    .buttonStyle(PrimaryActionButtonStyle())
            } else {
                baseButton
                    .buttonStyle(SecondaryActionButtonStyle())
            }
        }
        .help(helpText)
        .accessibilityLabel(Text(accessibilityTitle))
    }

    private var baseButton: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
        }
    }
}

struct StatusChipView: View {
    let label: String
    let value: String
    var tint: Color? = nil
    var monospacedValue = false

    var body: some View {
        HStack(spacing: 6) {
            if let tint {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: monospacedValue ? .monospaced : .default))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.panelAlt)
        .overlay(
            Capsule()
                .stroke(Theme.border.opacity(0.7), lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}

struct TopControlStripScanProgress: Equatable {
    let scannedHosts: Int
    let totalHosts: Int

    var clampedTotal: Int {
        max(1, totalHosts)
    }
}

struct TopControlStripView<FlashContent: View>: View {
    @Binding var baseURLText: String
    let baseURLValidationMessage: String?
    let baseURLApplyInFlight: Bool
    @Binding var showScanDetails: Bool
    @Binding var showGodMenu: Bool
    @Binding var showFlashPopover: Bool

    let subnetDescription: String?
    let stationHealthLabel: String
    let stationHealthColor: Color
    let opsFeedStatusLabel: String
    let opsFeedStatusColor: Color
    let nodeCount: Int
    let lastIngestText: String?
    let scanStatusLabel: String
    let hostCount: Int
    let bleStatusLabel: String
    let scanProgress: TopControlStripScanProgress?
    let scanStatusMessage: String?
    let bleAvailabilityMessage: String?

    let onApplyBaseURL: () -> Void
    let onResetBaseURL: () -> Void
    let onInspectAPI: () -> Void
    let onOpenSpectrum: () -> Void
    let onPrepareGodMenu: () -> Void
    let godSections: () -> [ActionMenuSection]
    let flashPopoverContent: () -> FlashContent

    private var hasScanDetail: Bool {
        if scanProgress != nil { return true }
        if let scanStatusMessage, !scanStatusMessage.isEmpty { return true }
        if let bleAvailabilityMessage, !bleAvailabilityMessage.isEmpty { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let subnetDescription, !subnetDescription.isEmpty {
                Text("Subnet: \(subnetDescription)")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
            }
            endpointRow
            if let baseURLValidationMessage, !baseURLValidationMessage.isEmpty {
                Text(baseURLValidationMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
            actionRow
            statusChipsRow
            if hasScanDetail {
                scanDetailsRow
            }
        }
        .modifier(Theme.cardStyle())
    }

    private var endpointRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("Base URL")
                    .font(.system(size: 11))
                    .frame(width: 70, alignment: .leading)
                TextField("", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(baseURLApplyInFlight)

                endpointActionButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Base URL")
                        .font(.system(size: 11))
                    TextField("", text: $baseURLText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(baseURLApplyInFlight)
                }
                HStack(spacing: 8) {
                    endpointActionButtons
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                actionButtons
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    actionButtons
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var statusChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                StatusChipView(label: "Station", value: stationHealthLabel, tint: stationHealthColor)
                StatusChipView(label: "Ops Feed", value: opsFeedStatusLabel, tint: opsFeedStatusColor)
                StatusChipView(label: "Nodes", value: "\(nodeCount)")
                if let lastIngestText, !lastIngestText.isEmpty {
                    StatusChipView(label: "Last ingest", value: lastIngestText, monospacedValue: true)
                }
                StatusChipView(
                    label: "Scan",
                    value: scanStatusLabel,
                    tint: scanStatusLabel == "Yes" ? Theme.accent : Theme.muted
                )
                StatusChipView(label: "Hosts", value: "\(hostCount)")
                StatusChipView(label: "BLE", value: bleStatusLabel)
            }
            .padding(.vertical, 2)
        }
    }

    private var endpointActionButtons: some View {
        HStack(spacing: 8) {
            CompactActionButton(
                systemImage: baseURLApplyInFlight ? "hourglass.circle" : "checkmark.circle",
                helpText: baseURLApplyInFlight ? "Validating Base URL" : "Apply",
                accessibilityTitle: baseURLApplyInFlight ? "Validating Base URL" : "Apply",
                variant: .secondary,
                action: onApplyBaseURL
            )
            .disabled(baseURLApplyInFlight)
            CompactActionButton(
                systemImage: "arrow.counterclockwise",
                helpText: "Reset",
                accessibilityTitle: "Reset",
                variant: .secondary,
                action: onResetBaseURL
            )
            .disabled(baseURLApplyInFlight)
            CompactActionButton(
                systemImage: "doc.text.magnifyingglass",
                helpText: "Inspect API",
                accessibilityTitle: "Inspect API",
                variant: .secondary,
                action: onInspectAPI
            )
            .disabled(baseURLApplyInFlight)
        }
    }

    private var actionButtons: some View {
        Group {
            CompactActionButton(
                systemImage: "waveform",
                helpText: "Open Analyzer",
                accessibilityTitle: "Open Analyzer",
                variant: .primary,
                action: onOpenSpectrum
            )
            CompactActionButton(
                systemImage: "sparkles",
                helpText: "God Button",
                accessibilityTitle: "God Button",
                variant: .secondary,
                action: {
                    onPrepareGodMenu()
                    showGodMenu = true
                }
            )
            .popover(isPresented: $showGodMenu, arrowEdge: .bottom) {
                ActionMenuView(sections: godSections())
                    .frame(minWidth: 320)
                    .padding(10)
                    .background(Theme.background)
            }
            CompactActionButton(
                systemImage: "bolt.circle",
                helpText: "Flash",
                accessibilityTitle: "Flash",
                variant: .secondary,
                action: { showFlashPopover = true }
            )
            .popover(isPresented: $showFlashPopover, arrowEdge: .bottom) {
                flashPopoverContent()
            }
        }
    }

    private var scanDetailsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showScanDetails.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showScanDetails ? "chevron.down.circle.fill" : "chevron.right.circle")
                    Text(showScanDetails ? "Hide scan details" : "Show scan details")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if showScanDetails {
                VStack(alignment: .leading, spacing: 6) {
                    if let scanProgress {
                        ProgressView(value: Double(scanProgress.scannedHosts), total: Double(scanProgress.clampedTotal))
                        Text("Scanned \(scanProgress.scannedHosts) of \(scanProgress.totalHosts) hosts")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    if let scanStatusMessage, !scanStatusMessage.isEmpty {
                        Text(scanStatusMessage)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                    if let bleAvailabilityMessage, !bleAvailabilityMessage.isEmpty {
                        Text(bleAvailabilityMessage)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}
