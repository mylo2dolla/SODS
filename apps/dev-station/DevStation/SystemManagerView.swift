import SwiftUI

struct SystemManagerView: View {
    @ObservedObject var store: SystemManagerStore

    @State private var showTerminateConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            statRow
            controlsRow

            if let message = store.lastActionMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }

            if let error = store.lastError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            if !store.terminationResults.isEmpty {
                terminationResultsView
            }

            processTableView
        }
        .modifier(Theme.cardStyle())
        .onAppear {
            store.startPolling()
        }
        .onDisappear {
            store.stopPolling()
        }
        .sheet(isPresented: $store.showOptimizeSheet) {
            optimizeSheet
        }
        .alert("Terminate selected processes?", isPresented: $showTerminateConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Terminate", role: .destructive) {
                store.terminateSelectedProcesses()
            }
        } message: {
            Text("This sends SIGTERM only. No force kill.")
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("System Manager")
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            if let last = store.lastRefreshAt {
                Text("Last refresh: \(last.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var statRow: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                StatusChipView(
                    label: "CPU",
                    value: cpuSummary,
                    tint: Theme.accent,
                    monospacedValue: true
                )
                StatusChipView(
                    label: "RAM",
                    value: ramSummary,
                    tint: Theme.accent,
                    monospacedValue: true
                )
                StatusChipView(
                    label: "Swap",
                    value: swapSummary,
                    tint: Theme.muted,
                    monospacedValue: true
                )
                StatusChipView(
                    label: "Processes",
                    value: processSummary,
                    tint: Theme.muted
                )
            }
            .padding(.vertical, 2)
        }
    }

    private var controlsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    TextField("Search process, user, or PID", text: $store.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220, maxWidth: 340)

                    Picker("Sort", selection: $store.sortField) {
                        ForEach(SystemSortField.allCases) { field in
                            Text(fieldLabel(field)).tag(field)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)

                    Toggle("Ascending", isOn: $store.sortAscending)
                        .toggleStyle(SwitchToggleStyle(tint: Theme.accent))

                    actionButtons
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 10) {
                TextField("Search process, user, or PID", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $store.sortField) {
                    ForEach(SystemSortField.allCases) { field in
                        Text(fieldLabel(field)).tag(field)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Ascending", isOn: $store.sortAscending)
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
            }
            HStack(spacing: 8) {
                actionButtons
                Spacer(minLength: 0)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                store.refreshNow()
            } label: {
                Image(systemName: store.isRefreshing ? "hourglass.circle" : "arrow.clockwise.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Refresh stats now")
            .disabled(store.isRefreshing)

            Button {
                showTerminateConfirmation = true
            } label: {
                Image(systemName: "xmark.octagon")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(SecondaryActionButtonStyle())
            .help("Terminate selected processes (SIGTERM)")
            .disabled(store.selectedTerminableCount == 0)

            Button {
                store.optimizeCleanRAMGuided()
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .help("Guided RAM cleanup")
        }
    }

    private var processTableView: some View {
        Table(store.filteredRows, selection: $store.selectedPIDs) {
            TableColumn("PID") { row in
                Text("\(row.pid)")
                    .font(.system(size: 11, design: .monospaced))
            }
            .width(min: 70, ideal: 80, max: 95)

            TableColumn("User") { row in
                Text(row.user)
                    .font(.system(size: 11))
            }
            .width(min: 90, ideal: 120, max: 140)

            TableColumn("CPU %") { row in
                Text(String(format: "%.1f", row.cpuPercent))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
            }
            .width(min: 70, ideal: 80, max: 95)

            TableColumn("Memory") { row in
                Text(memoryString(row.rssBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
            }
            .width(min: 95, ideal: 110, max: 130)

            TableColumn("Command") { row in
                HStack(spacing: 6) {
                    if row.isProtected {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Theme.muted)
                    }
                    Text(row.command)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
        }
        .frame(minHeight: 360)
    }

    private var terminationResultsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Termination Results")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.terminationResults, id: \.pid) { result in
                        Text(result.detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(10)
        .background(Theme.panelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private var optimizeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeaderView(title: "Guided RAM Cleanup", onBack: nil, onClose: {
                store.cancelOptimizeGuided()
            })

            Text("Select high-memory processes to terminate gracefully (SIGTERM only).")
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)

            if store.optimizeCandidates.isEmpty {
                Text("No candidate process available.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            } else {
                List(store.optimizeCandidates, id: \.pid) { row in
                    Toggle(isOn: Binding(
                        get: { store.optimizeSelectedPIDs.contains(row.pid) },
                        set: { store.setOptimizeSelection(pid: row.pid, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PID \(row.pid) • \(memoryString(row.rssBytes)) • \(String(format: "%.1f%% CPU", row.cpuPercent))")
                                .font(.system(size: 11, design: .monospaced))
                            Text(row.command)
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                }
                .frame(minHeight: 220)
            }

            HStack(spacing: 10) {
                Button {
                    store.cancelOptimizeGuided()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("Cancel")

                Button {
                    store.confirmOptimizeGuided()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .help("Run guided cleanup")
                .disabled(store.optimizeSelectedPIDs.isEmpty)

                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 380)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
    }

    private var cpuSummary: String {
        guard let snapshot = store.snapshot else { return "--" }
        return String(format: "U %.1f%% • S %.1f%% • I %.1f%%", snapshot.cpuUserPercent, snapshot.cpuSystemPercent, snapshot.cpuIdlePercent)
    }

    private var ramSummary: String {
        guard let snapshot = store.snapshot else { return "--" }
        return "\(memoryString(snapshot.memUsedBytes)) / \(memoryString(snapshot.memTotalBytes))"
    }

    private var swapSummary: String {
        guard let snapshot = store.snapshot else { return "--" }
        return "\(memoryString(snapshot.swapUsedBytes)) / \(memoryString(snapshot.swapTotalBytes))"
    }

    private var processSummary: String {
        if let snapshot = store.snapshot {
            return "\(snapshot.processCount)"
        }
        return "\(store.processRows.count)"
    }

    private func fieldLabel(_ field: SystemSortField) -> String {
        switch field {
        case .memory:
            return "Memory"
        case .cpu:
            return "CPU"
        case .name:
            return "Name"
        case .pid:
            return "PID"
        }
    }

    private func memoryString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
