import SwiftUI

struct MenuView: View {
    @ObservedObject var model: StatsModel
    var onRefresh: () -> Void
    var onQuit: () -> Void

    private let width: CGFloat = 360

    /// Keep the popover inside the screen; scroll if the content is taller.
    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 24
    }

    var body: some View {
        ScrollView {
            content
        }
        .frame(width: width)
        .frame(maxHeight: maxHeight)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            limitsSection
            Divider()
            spendSection
            Divider()
            modelsSection
            if !model.monthly.isEmpty {
                Divider()
                monthsSection
            }
            Divider()
            footer
        }
        .padding(14)
    }

    // MARK: - Subscription limits

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(L10n.s("Лимиты подписки", "Subscription limits"))
            if let snapshot = model.snapshot, !snapshot.windows.isEmpty {
                ForEach(snapshot.windows) { window in
                    LimitRow(
                        window: window,
                        resetStyle: model.resetStyle,
                        onToggleResetStyle: model.toggleResetStyle)
                }
                if let used = snapshot.extraUsedCredits, let limit = snapshot.extraLimit, limit > 0 {
                    caption("Extra usage: \(Format.money(used)) / \(Format.money(limit))")
                }
            } else if model.usageError == nil {
                caption(L10n.s("Загрузка…", "Loading…"))
            }
            if let error = model.usageError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Spend

    private var spendSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            header(L10n.s("Стоимость по API-ценам", "Cost at API prices"))
            columnHeader
            StatRow(title: L10n.s("Сегодня", "Today"), stats: model.today)
            StatRow(title: L10n.s("7 дней", "7 days"), stats: model.week)
            StatRow(title: L10n.s("30 дней", "30 days"), stats: model.month)
            StatRow(title: L10n.s("Всё время", "All time"), stats: model.allTime)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text("IN").frame(width: Columns.input, alignment: .trailing)
            Text("OUT").frame(width: Columns.output, alignment: .trailing)
            Text(L10n.s("КЭШ", "CACHE")).frame(width: Columns.cache, alignment: .trailing)
            Text(L10n.s("ИТОГО", "TOTAL")).frame(width: Columns.money, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
    }

    // MARK: - Models

    private var modelsSection: some View {
        let stats = model.month
        return VStack(alignment: .leading, spacing: 5) {
            header(L10n.s("Модели · 30 дней", "Models · 30 days"))
            if stats.byModel.isEmpty {
                caption(L10n.s("Нет данных", "No data"))
            } else {
                ForEach(stats.byModel.prefix(5), id: \.model) { item in
                    StatRow(
                        title: Pricing.displayName(item.model),
                        tokens: item.tokens,
                        cost: item.cost)
                }
            }
        }
    }

    // MARK: - Months

    private var monthsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            header(L10n.s("По месяцам", "By month"))
            ForEach(model.monthly.prefix(6), id: \.label) { item in
                StatRow(title: item.label, stats: item.stats)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.s("Запускать при входе", "Launch at login"), isOn: Binding(
                get: { model.launchAtLogin },
                set: { _ in model.toggleLaunchAtLogin() }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            HStack(spacing: 10) {
                caption(L10n.s("Сброс", "Resets"))
                Spacer(minLength: 0)
                Segments(
                    options: ResetStyle.allCases,
                    selection: model.resetStyle,
                    title: \.title,
                    onSelect: model.setResetStyle)
            }

            HStack(spacing: 10) {
                Segments(
                    options: Language.allCases,
                    selection: model.language,
                    title: \.title,
                    onSelect: model.setLanguage)
                Spacer(minLength: 0)
                Segments(
                    options: Currency.allCases,
                    selection: model.currency,
                    title: \.title,
                    onSelect: model.setCurrency)
            }

            HStack {
                Button(model.isRefreshing
                    ? L10n.s("Обновление…", "Refreshing…")
                    : L10n.s("Обновить", "Refresh"), action: onRefresh)
                    .disabled(model.isRefreshing)
                Spacer()
                Button(L10n.s("Выйти", "Quit"), action: onQuit)
            }
            .font(.system(size: 12))

            if let snapshot = model.snapshot {
                let time = Format.time(snapshot.fetchedAt)
                // Worth saying when the numbers came off the CLI's own screen instead of the API.
                let via = snapshot.source == .cli ? L10n.s(" · через CLI", " · via the CLI") : ""
                caption(L10n.s("Обновлено в \(time)\(via)", "Updated at \(time)\(via)"))
            }
        }
    }

    // MARK: - Bits

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// Plain buttons instead of a Picker: pickers are unreliable inside a status-bar popover.
private struct Segments<Option: Hashable & Identifiable>: View {
    let options: [Option]
    let selection: Option
    let title: KeyPath<Option, String>
    let onSelect: (Option) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    onSelect(option)
                } label: {
                    Text(option[keyPath: title])
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .frame(minWidth: 22)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected
                                    ? Color.accentColor.opacity(0.3)
                                    : Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private enum Columns {
    static let input: CGFloat = 52
    static let output: CGFloat = 52
    static let cache: CGFloat = 58
    static let money: CGFloat = 76
}

/// One line of the table. Strings are formatted by the caller so that a currency or
/// language switch always changes the view's value and triggers a redraw.
private struct StatRow: View {
    let title: String
    let input: String
    let output: String
    let cache: String
    let cost: String

    init(title: String, stats: PeriodStats) {
        self.init(title: title, tokens: stats.tokens, cost: stats.cost)
    }

    init(title: String, tokens: TokenTotals, cost: Double) {
        self.title = title
        self.input = Format.tokens(tokens.input)
        self.output = Format.tokens(tokens.output)
        self.cache = Format.tokens(tokens.cacheRead + tokens.cacheWrite5m + tokens.cacheWrite1h)
        self.cost = Format.money(cost)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            column(input, width: Columns.input)
            column(output, width: Columns.output)
            column(cache, width: Columns.cache)
            Text(cost)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(width: Columns.money, alignment: .trailing)
        }
    }

    private func column(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: width, alignment: .trailing)
    }
}

private struct LimitRow: View {
    let window: UsageWindow
    let resetStyle: ResetStyle
    let onToggleResetStyle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.title)
                    .font(.system(size: 12))
                Spacer(minLength: 4)
                if let resets = Format.reset(window.resetsAt, style: resetStyle) {
                    Text(resets)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        // The whole row toggles, but only the reset text hints at it.
                        .help(L10n.s("Нажмите, чтобы переключить формат",
                                     "Click to switch the format"))
                }
                Text(Format.percent(window.percent))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * min(window.percent, 100) / 100)
                }
            }
            .frame(height: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleResetStyle)
    }

    private var color: Color {
        switch window.percent {
        case ..<60: .accentColor
        case ..<85: .orange
        default: .red
        }
    }
}
