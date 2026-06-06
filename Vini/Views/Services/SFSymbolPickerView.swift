import SwiftUI

struct SFSymbolPickerView: View {
    @Binding var selection: String
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 10)]

    private var filteredSymbols: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allSymbols = Self.logisticsSymbols + Self.symbols
        guard !trimmed.isEmpty else { return allSymbols }
        return allSymbols.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: selection)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group Icon")
                        .font(.headline)
                    Text(selection)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            TextField("Search SF Symbols", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(filteredSymbols, id: \.self) { symbol in
                        Button {
                            selection = symbol
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: symbol)
                                    .font(.system(size: 20, weight: .medium))
                                    .frame(height: 24)
                                Text(symbol)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(symbol == selection ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(symbol == selection ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(width: 420, height: 520)
    }

    private static let logisticsSymbols: [String] = [
        "truck.box", "truck.box.fill", "truck.pickup.side", "truck.pickup.side.fill",
        "box.truck", "box.truck.fill", "box.truck.badge.clock", "box.truck.badge.clock.fill",
        "forklift", "forklift.fill", "shippingbox", "shippingbox.fill", "archivebox", "archivebox.fill",
        "tray", "tray.fill", "externaldrive", "externaldrive.fill", "fuelpump", "fuelpump.fill",
        "road.lanes", "road.lanes.curved.left", "signpost.right", "signpost.right.fill",
        "map", "map.fill", "mappin", "mappin.circle", "mappin.circle.fill",
        "location", "location.fill", "location.north", "location.north.fill",
        "sailboat", "sailboat.fill", "ferry", "ferry.fill",
        "airplane", "airplane.departure", "airplane.arrival", "train.side.front.car",
        "bus", "bus.fill", "car", "car.fill"
    ]

    private static let symbols: [String] = [
        "rectangle.3.group", "square.stack.3d.up", "arrow.right.to.line", "folder", "folder.fill", "tray", "shippingbox", "shippingbox.fill", "server.rack", "externaldrive", "externaldrive.fill", "internaldrive", "archivebox", "archivebox.fill", "terminal", "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces", "hammer", "hammer.fill", "wrench.and.screwdriver", "wrench.and.screwdriver.fill", "gear", "gearshape", "gearshape.fill", "gearshape.2", "gearshape.2.fill", "slider.horizontal.3", "switch.2", "power", "power.circle", "power.circle.fill", "play", "play.fill", "play.circle", "play.circle.fill", "stop", "stop.fill", "stop.circle", "stop.circle.fill", "restart", "arrow.clockwise", "arrow.triangle.2.circlepath", "bolt", "bolt.fill", "bolt.circle", "bolt.circle.fill", "flame", "flame.fill", "drop", "drop.fill", "leaf", "leaf.fill", "ladybug", "ladybug.fill", "ant", "ant.fill", "network", "network.badge.shield.half.filled", "point.3.connected.trianglepath.dotted", "point.3.filled.connected.trianglepath.dotted", "dot.radiowaves.left.and.right", "antenna.radiowaves.left.and.right", "wifi", "wifi.router", "wifi.router.fill", "globe", "globe.americas", "globe.europe.africa", "globe.asia.australia", "link", "link.circle", "link.circle.fill", "cloud", "cloud.fill", "cloud.bolt", "cloud.bolt.fill", "cloud.sun", "cloud.sun.fill", "database", "cylinder", "cylinder.fill", "cylinder.split.1x2", "cylinder.split.1x2.fill", "memorychip", "memorychip.fill", "cpu", "cpu.fill", "desktopcomputer", "display", "display.2", "laptopcomputer", "macmini", "macstudio", "xserve", "apps.iphone", "app.connected.to.app.below.fill", "app.badge", "app.badge.fill", "square.grid.2x2", "square.grid.2x2.fill", "square.grid.3x3", "square.grid.3x3.fill", "rectangle.grid.1x2", "rectangle.grid.1x2.fill", "rectangle.grid.2x2", "rectangle.grid.2x2.fill", "list.bullet", "list.bullet.rectangle", "list.bullet.rectangle.fill", "checklist", "checkmark.seal", "checkmark.seal.fill", "clock", "clock.fill", "timer", "stopwatch", "stopwatch.fill", "calendar", "calendar.badge.clock", "chart.bar", "chart.bar.fill", "chart.line.uptrend.xyaxis", "chart.line.downtrend.xyaxis", "waveform.path.ecg", "waveform.path", "gauge.with.dots.needle.33percent", "gauge.with.dots.needle.50percent", "gauge.with.dots.needle.67percent", "speedometer", "lock", "lock.fill", "lock.shield", "lock.shield.fill", "shield", "shield.fill", "shield.lefthalf.filled", "key", "key.fill", "person", "person.fill", "person.2", "person.2.fill", "person.3", "person.3.fill", "house", "house.fill", "building.2", "building.2.fill", "briefcase", "briefcase.fill", "case", "case.fill", "bag", "bag.fill", "cart", "cart.fill", "creditcard", "creditcard.fill", "dollarsign.circle", "dollarsign.circle.fill", "number", "number.square", "number.square.fill", "at", "questionmark.circle", "questionmark.circle.fill", "exclamationmark.triangle", "exclamationmark.triangle.fill", "info.circle", "info.circle.fill", "star", "star.fill", "heart", "heart.fill", "bookmark", "bookmark.fill", "tag", "tag.fill", "flag", "flag.fill", "pin", "pin.fill", "mappin", "mappin.circle", "mappin.circle.fill", "paperplane", "paperplane.fill", "scope", "location", "location.fill", "safari", "safari.fill", "compass.drawing", "map", "map.fill", "sparkles", "wand.and.stars", "wand.and.stars.inverse", "paintbrush", "paintbrush.fill", "paintpalette", "paintpalette.fill", "eyedropper", "camera", "camera.fill", "video", "video.fill", "mic", "mic.fill", "speaker.wave.2", "speaker.wave.2.fill", "headphones", "gamecontroller", "gamecontroller.fill", "cup.and.saucer", "cup.and.saucer.fill", "fork.knife", "takeoutbag.and.cup.and.straw", "car", "car.fill", "bus", "bus.fill", "bicycle", "figure.run", "figure.walk", "figure.strengthtraining.traditional", "mountain.2", "mountain.2.fill", "tree", "tree.fill", "fossil.shell", "fossil.shell.fill", "atom", "cross.case", "cross.case.fill", "pills", "pills.fill", "stethoscope", "book", "book.fill", "books.vertical", "books.vertical.fill", "graduationcap", "graduationcap.fill", "newspaper", "newspaper.fill", "doc", "doc.fill", "doc.text", "doc.text.fill", "doc.richtext", "clipboard", "clipboard.fill", "paperclip", "scissors", "pencil", "pencil.circle", "pencil.circle.fill", "highlighter", "signature", "envelope", "envelope.fill", "message", "message.fill", "bubble.left", "bubble.left.fill", "phone", "phone.fill", "bell", "bell.fill", "bell.badge", "bell.badge.fill", "megaphone", "megaphone.fill", "radio", "radio.fill", "music.note", "music.note.list", "film", "film.fill", "photo", "photo.fill", "gift", "gift.fill", "cube", "cube.fill", "cube.box", "cube.box.fill", "puzzlepiece", "puzzlepiece.fill", "command", "option", "control", "escape", "keyboard", "keyboard.fill", "printer", "printer.fill", "scanner", "scanner.fill"
    ]
}

#if DEBUG
#Preview {
    SFSymbolPickerView(selection: .constant("rectangle.3.group"))
}
#endif
