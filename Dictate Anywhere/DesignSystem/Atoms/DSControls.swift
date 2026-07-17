import SwiftUI

/// Atom: pill toggle switch matching the design's Toggle On/Off components.
struct DSToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
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
                .animation(.spring(duration: 0.2), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == DSToggleStyle {
    static var dsSwitch: DSToggleStyle { DSToggleStyle() }
}

/// Atom: slider matching the design (5pt track, 16pt white knob).
struct DSSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

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
                        let fraction = ((drag.location.x - knobSize / 2) / (width - knobSize))
                            .clamped(to: 0...1)
                        value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: knobSize)
        .accessibilityElement()
        .accessibilityValue("\(Int(fractionOfRange * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 10
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private var fractionOfRange: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return ((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
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
        .fixedSize()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
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
        .background(DS.Colors.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Colors.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control))
    }
}

/// Atom: bordered search field (History page).
struct DSSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Fonts.ui(13))
                .foregroundStyle(DS.Colors.ink)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(DS.Colors.bgCard, in: RoundedRectangle(cornerRadius: DS.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.Colors.border, lineWidth: 1))
    }
}

/// Atom: bordered single-line text field styled like the design's inset controls.
struct DSTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(DS.Fonts.ui(13))
        .foregroundStyle(DS.Colors.ink)
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(DS.Colors.bgCard, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Colors.border, lineWidth: 1))
    }
}
