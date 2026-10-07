import SwiftUI

/// Atom: pill toggle switch matching the design's Toggle On/Off components.
struct DSToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(configuration.isOn ? DS.Colors.accent : DS.Colors.toggleOff)
                    .frame(width: 46, height: 28)
                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
                    .padding(3)
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.2), value: configuration.isOn)
            .modifier(DSControlSurface(fill: .clear, border: .clear, cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// The design switch has no visible inline label; callers supply its accessible name.
struct DSSwitch: View {
    let accessibilityName: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.dsSwitch)
            .accessibilityLabel(accessibilityName)
    }
}

extension ToggleStyle where Self == DSToggleStyle {
    static var dsSwitch: DSToggleStyle { DSToggleStyle() }
}

/// Atom: slider matching the design (5pt track, 16pt white knob).
struct DSSlider: View {
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    let label: String

    private let knobSize: CGFloat = 16
    private let trackHeight: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = fractionOfRange
            let knobX = (width - knobSize) * fraction

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(DS.Colors.sliderTrackRest)
                    .frame(height: trackHeight)
                RoundedRectangle(cornerRadius: 3)
                    .fill(DS.Colors.accent)
                    .frame(width: max(knobX + knobSize / 2, trackHeight), height: trackHeight)
                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .overlay(Circle().strokeBorder(DS.Colors.border, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.13), radius: 3, x: 0, y: 1)
                    .offset(x: knobX)
            }
            .frame(height: knobSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled, width > knobSize else { return }
                        let fraction = ((drag.location.x - knobSize / 2) / (width - knobSize))
                            .clamped(to: 0...1)
                        value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: knobSize)
        .focusable(isEnabled)
        .focused($isFocused)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .strokeBorder(DS.Colors.accentDeep, lineWidth: 2)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: adjust(by: -1)
            case .right, .up: adjust(by: 1)
            default: break
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(fractionOfRange * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: 1)
            case .decrement: adjust(by: -1)
            @unknown default: break
            }
        }
    }

    private var fractionOfRange: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return ((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }

    private func adjust(by steps: Double) {
        guard isEnabled else { return }
        let step = (range.upperBound - range.lowerBound) / 10
        value = (value + steps * step).clamped(to: range)
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

/// Atom: dropdown control matching the design (inset capsule with ⌃⌄ chevrons).
/// Wraps a `Menu` so any option list can be presented.
struct DSDropdown<SelectionValue: Hashable>: View {
    @Binding var selection: SelectionValue
    let options: [SelectionValue]
    let title: (SelectionValue) -> String
    let accessibilityName: String
    var isEnabled: Bool = true

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(title(option), systemImage: "checkmark")
                    } else {
                        Text(title(option))
                    }
                }
            }
        } label: {
            DSDropdownLabel(text: title(selection))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(title(selection))
    }
}

/// Atom: the visual label shared by dropdown-like controls.
struct DSDropdownLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(DS.Fonts.ui(13.5, .medium))
                .foregroundStyle(DS.Colors.ink)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .modifier(DSControlSurface(fill: DS.Colors.bgInset))
    }
}

/// Atom: bordered search field (History page).
struct DSSearchField: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let placeholder: String
    @Binding var text: String
    let accessibilityName: String
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Fonts.ui(13))
                .foregroundStyle(DS.Colors.ink)
                .accessibilityLabel(accessibilityName)
                .focused($fieldIsFocused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                    fieldIsFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(accessibilityName)")
                .help("Clear search")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(DS.Colors.bgCard, in: RoundedRectangle(cornerRadius: DS.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(
                    fieldIsFocused ? DS.Colors.accentDeep : contrast == .increased ? DS.Colors.textSecondary : DS.Colors.border,
                    lineWidth: fieldIsFocused ? 2 : 1
                )
        }
    }
}

/// Atom: bordered single-line text field styled like the design's inset controls.
struct DSTextField: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var fieldIsFocused: Bool
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    let accessibilityName: String

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
                    .accessibilityLabel(accessibilityName)
            } else {
                TextField(placeholder, text: $text)
                    .accessibilityLabel(accessibilityName)
            }
        }
        .textFieldStyle(.plain)
        .focused($fieldIsFocused)
        .font(DS.Fonts.ui(13))
        .foregroundStyle(DS.Colors.ink)
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(DS.Colors.bgCard, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(
                    fieldIsFocused ? DS.Colors.accentDeep : contrast == .increased ? DS.Colors.textSecondary : DS.Colors.border,
                    lineWidth: fieldIsFocused ? 2 : 1
                )
        }
    }
}
