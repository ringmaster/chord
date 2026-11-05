import SwiftUI

/// An icon from the Tabler set (https://tabler.io/icons), from `Icons.xcassets`.
///
/// `name` is the Tabler file name, such as "plus", or the name with "-filled"
/// for the filled style, such as "bookmark-filled". Add an icon with
/// `tools/add-tabler-icon`. The icon is a template image, so it takes the
/// foreground style. A font does not change its size; `size` sets it.
struct Icon: View {
    let name: String
    var size: CGFloat = 16

    init(_ name: String, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image("Tabler/\(name)")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
