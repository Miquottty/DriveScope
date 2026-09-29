import SwiftUI

struct QualityView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quality")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }
}
