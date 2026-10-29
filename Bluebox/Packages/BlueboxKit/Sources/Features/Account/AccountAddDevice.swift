import CoreImage
import CoreImage.CIFilterBuiltins
import DesignSystem
import SwiftUI
import Sync

/// Signed in: a QR code and a link that connect another device to the same
/// server, so it goes straight to Sign In. They carry only the server's
/// address and its publishable key, which are public by design.
struct AccountAddDeviceRows: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if let link = app.account.connectLink {
            AccountSectionHeader(title: "Add Another Device")
            Hairline()
            let layout = sizeClass == .compact
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.l))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.xl))
            layout {
                AccountQRCode(text: link.absoluteString)
                    .frame(width: 168, height: 168)
                    .accessibilityLabel("QR code for this server's link")
                    .accessibilityIdentifier("connectQRCode")
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(instructions)
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CopyButton("Copy Link", text: link.absoluteString)
                        .accessibilityIdentifier("copyConnectLinkButton")
                    Text("The link holds only your server's address and its public key: no password or token.")
                        .font(.footnote)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, Spacing.l)
            Hairline()
        }
    }

    private var instructions: String {
        "On an iPhone or iPad, point the Camera at this code. On a Mac, copy the link and open it there, or paste it into Settings › Account. Then sign in with your username and password."
    }
}

/// A QR code drawn crisp at any size, black on a white tile.
struct AccountQRCode: View {
    let text: String

    var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.black)
            }
        }
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: AccountTheme.fieldRadius, style: .continuous))
    }

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent)
    }
}
