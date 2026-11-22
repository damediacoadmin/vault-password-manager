import SwiftUI

/// Length and character choices for a new password. Changes are remembered for next time.
struct GeneratorControls: View {
    @Binding var options: PasswordGenerator.Options

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(PasswordGenerator.Options.Style.allCases, id: \.self) { s in
                    Button { options.style = s } label: {
                        Text(s.rawValue).font(.plex(14, .medium)).foregroundStyle(options.style == s ? Ink.text : Ink.mid)
                            .frame(maxWidth: .infinity).frame(height: 40).background(options.style == s ? Ink.panelHi : .clear)
                    }
                    .buttonStyle(.plain)
                    if s == .words { Rectangle().fill(Ink.line).frame(width: 1) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
            .padding(.bottom, 6)
            if options.style == .characters {
                stepper("Length", $options.length, 8...64)
                toggle("Special characters  ! # $ %", $options.symbols)
                toggle("Numbers", $options.digits)
            } else {
                stepper("Words", $options.wordCount, 3...10)
                toggle("Special characters  ! # $ %", $options.symbols)
                toggle("Capital letters", $options.capitals)
                toggle("Add a number", $options.number)
            }
        }
        .onChange(of: options) { _, o in PasswordGenerator.saved = o }
    }

    private func stepper(_ label: String, _ v: Binding<Int>, _ r: ClosedRange<Int>) -> some View {
        HStack(spacing: 0) {
            Text(label).font(.plex(15)).foregroundStyle(Ink.text)
            Spacer()
            Button { if v.wrappedValue > r.lowerBound { v.wrappedValue -= 1 } } label: { Text("−").font(.mono(20)).frame(width: 44, height: 44) }
                .accessibilityLabel("Less")
            Text("\(v.wrappedValue)").font(.mono(16, .medium)).frame(minWidth: 28)
            Button { if v.wrappedValue < r.upperBound { v.wrappedValue += 1 } } label: { Text("+").font(.mono(20)).frame(width: 44, height: 44) }
                .accessibilityLabel("More")
        }
        .foregroundStyle(Ink.text).buttonStyle(.plain)
    }

    private func toggle(_ label: String, _ v: Binding<Bool>) -> some View {
        InkToggle(isOn: v, label: label).frame(minHeight: 44)
    }
}
