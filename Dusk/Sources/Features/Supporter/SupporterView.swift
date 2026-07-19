import StoreKit
import SwiftUI

/// Where the supporter sheet was opened from. The prompt variant softens the
/// headline and adds an equal-weight "Maybe Later" action; content is
/// otherwise identical so the two never drift apart.
enum SupporterViewContext: Equatable {
    case settings
    /// 1-based position within `SupporterPromptGate.milestones`.
    case prompt(number: Int)

    var isPrompt: Bool {
        if case .prompt = self { return true }
        return false
    }

    /// The ladder's last prompt promises to be the last ask — the copy for it
    /// hangs off this, and the gate keeps the promise.
    var isFinalPrompt: Bool {
        if case .prompt(let number) = self {
            return number >= SupporterPromptGate.milestones.count
        }
        return false
    }
}

/// The supporter tier sheet: a pitch before any purchase, a thank-you with a
/// "support again" path after one. Purchases stay on this screen — rows buy
/// directly, and the header flips to the thank-you state on success.
struct SupporterView: View {
    let context: SupporterViewContext

    @Environment(SupporterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @State private var showsManageSubscriptions = false
    #endif

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        iosBody
        #endif
    }

    // MARK: - iOS / iPadOS

    #if !os(tvOS)
    private var iosBody: some View {
        ZStack(alignment: .topTrailing) {
            Color.duskBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    header

                    SupporterIconShowcase()

                    purchaseSections

                    if context.isPrompt {
                        VStack(spacing: 10) {
                            Button("Maybe Later") {
                                dismiss()
                            }
                            .supporterNeutralGlassButtonStyle()
                            .frame(minWidth: 200)

                            if context.isFinalPrompt {
                                Text("This is the last time Dusk asks — promise.")
                                    .font(.caption)
                                    .foregroundStyle(Color.duskTextSecondary)
                            }
                        }
                    }

                    aboutMe

                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 48)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.duskTextSecondary)
                    .padding(10)
                    .background(Color.duskSurface, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .padding(.trailing, 16)
        }
        .presentationDragIndicator(.visible)
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
        #endif
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.duskAccent.opacity(0.14))
                    .frame(width: 64, height: 64)

                Image(systemName: "heart.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.duskAccent)
            }

            Text(headlineText)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.duskTextPrimary)

            Text(bodyText)
                .font(.subheadline)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)

            if let supporterSinceText {
                Text(supporterSinceText)
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var purchaseSections: some View {
        if store.subscriptionProducts.isEmpty && store.tipProducts.isEmpty {
            if store.productsUnavailable {
                VStack(spacing: 12) {
                    Text("The support options couldn't be loaded right now.")
                        .font(.footnote)
                        .foregroundStyle(Color.duskTextSecondary)

                    Button("Try Again") {
                        Task { await store.loadProducts() }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.duskAccent)
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 12)
            } else {
                ProgressView()
                    .tint(Color.duskAccent)
                    .padding(.vertical, 24)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                if !store.hasActiveSubscription && !store.subscriptionProducts.isEmpty {
                    productSection(
                        title: "Recurring",
                        footnote: "Cancel anytime in your App Store settings.",
                        products: store.subscriptionProducts
                    )
                }

                if !store.tipProducts.isEmpty {
                    productSection(
                        title: store.isSupporter ? "Support Again" : "One-Time",
                        footnote: "Tips can be given again anytime.",
                        products: store.tipProducts
                    )
                }

                if let error = store.lastErrorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func productSection(title: String, footnote: String, products: [Product]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.duskTextSecondary)

            VStack(spacing: 10) {
                ForEach(products, id: \.id) { product in
                    SupporterProductRow(
                        product: product,
                        isHighlighted: SupporterProduct(rawValue: product.id) == .yearly,
                        priceSuffix: priceSuffix(for: product),
                        isPurchasing: store.purchasingProductID == product.id
                    ) {
                        Task { await store.purchase(product) }
                    }
                    .disabled(store.purchasingProductID != nil)
                }
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Text("Everything in Dusk stays free either way — supporting just unlocks the app icons, and keeps development going.")
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)

            #if os(iOS)
            if store.hasActiveSubscription {
                Button("Manage Subscription") {
                    showsManageSubscriptions = true
                }
                .font(.subheadline)
                .foregroundStyle(Color.duskAccent)
                .buttonStyle(.plain)
            }
            #endif

            Button {
                Task { await store.restorePurchases() }
            } label: {
                if store.isRestoring {
                    ProgressView()
                        .tint(Color.duskAccent)
                } else {
                    Text("Restore Purchases")
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.duskAccent)
            .buttonStyle(.plain)
            .disabled(store.isRestoring)

            HStack(spacing: 6) {
                Button("Privacy Policy") {
                    openURL(SettingsSupport.privacyPolicyURL)
                }
                Text("·")
                Button("Terms of Use") {
                    openURL(SettingsSupport.termsOfUseURL)
                }
            }
            .font(.caption)
            .foregroundStyle(Color.duskTextSecondary)
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    private var aboutMe: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.duskTextSecondary)

            VStack(spacing: 10) {
                aboutLinkRow(
                    title: "About Me",
                    subtitle: "marvinvr.ch",
                    systemImage: "person.crop.circle",
                    url: SettingsSupport.aboutMeURL
                )

                aboutLinkRow(
                    title: "GitHub",
                    subtitle: "github.com/marvinvr/dusk-player",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    url: SettingsSupport.githubURL
                )
            }
        }
    }

    private func aboutLinkRow(
        title: String,
        subtitle: String,
        systemImage: String,
        url: URL
    ) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.duskAccent.opacity(0.14))
                        .frame(width: 34, height: 34)

                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.duskAccent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.duskTextPrimary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .padding(16)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(headlineText)
                            .font(.title.weight(.bold))
                            .foregroundStyle(Color.duskTextPrimary)

                        Text(bodyText)
                            .foregroundStyle(Color.duskTextSecondary)
                            .frame(maxWidth: 780, alignment: .leading)

                        if let supporterSinceText {
                            Text(supporterSinceText)
                                .font(.caption)
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                    }
                    .padding(.leading, TVSettingsMetrics.contentInset)

                    SupporterIconShowcase()
                        .padding(.leading, TVSettingsMetrics.contentInset)

                    tvPurchaseSections

                    TVSettingsSection(
                        title: "Manage",
                        footer: tvManageFooter
                    ) {
                        TVSettingsActionRow(
                            title: "Restore Purchases",
                            tint: Color.duskAccent,
                            isLoading: store.isRestoring
                        ) {
                            Task { await store.restorePurchases() }
                        }
                        .disabled(store.isRestoring)

                        if context.isPrompt {
                            tvRowDivider

                            TVSettingsActionRow(
                                title: "Maybe Later",
                                tint: Color.duskTextSecondary
                            ) {
                                dismiss()
                            }
                        }
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 60)
                .padding(.top, 48)
                .padding(.bottom, 88)
            }
        }
    }

    @ViewBuilder
    private var tvPurchaseSections: some View {
        if store.subscriptionProducts.isEmpty && store.tipProducts.isEmpty {
            if store.productsUnavailable {
                TVSettingsSection(title: "Support", footer: "The support options couldn't be loaded right now.") {
                    TVSettingsActionRow(title: "Try Again", tint: Color.duskAccent) {
                        Task { await store.loadProducts() }
                    }
                }
            } else {
                ProgressView()
                    .tint(Color.duskAccent)
                    .padding(.leading, TVSettingsMetrics.contentInset)
            }
        } else {
            if !store.hasActiveSubscription && !store.subscriptionProducts.isEmpty {
                TVSettingsSection(title: "Recurring", footer: "Cancel anytime in your App Store settings.") {
                    tvProductRows(store.subscriptionProducts)
                }
            }

            if !store.tipProducts.isEmpty {
                TVSettingsSection(
                    title: store.isSupporter ? "Support Again" : "One-Time",
                    footer: store.lastErrorMessage ?? "Tips can be given again anytime.",
                    footerColor: store.lastErrorMessage == nil ? Color.duskTextSecondary : .red
                ) {
                    tvProductRows(store.tipProducts)
                }
            }
        }
    }

    @ViewBuilder
    private func tvProductRows(_ products: [Product]) -> some View {
        ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
            if index > 0 {
                tvRowDivider
            }

            TVSettingsActionRow(
                title: rowTitle(for: product),
                tint: Color.duskTextPrimary,
                isLoading: store.purchasingProductID == product.id,
                detail: priceText(for: product)
            ) {
                Task { await store.purchase(product) }
            }
            .disabled(store.purchasingProductID != nil)
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }
    #endif

    // MARK: - Shared copy & formatting

    #if os(tvOS)
    private var tvManageFooter: String {
        let footer = "Everything in Dusk stays free either way. Manage or cancel subscriptions in Settings → Users & Accounts → Subscriptions. Privacy policy at getdusk.app/privacy, terms at Apple's standard EULA."
        guard context.isFinalPrompt else { return footer }
        return "This is the last time Dusk asks — promise. " + footer
    }
    #endif

    private var headlineText: String {
        if store.isSupporter {
            return "You're a Supporter ❤️"
        }
        switch context {
        case .settings:
            return "Support Dusk"
        case .prompt(let number):
            return number <= 1 ? "Enjoying Dusk?" : "Still enjoying Dusk?"
        }
    }

    private var bodyText: String {
        if store.isSupporter {
            return "Thank you for supporting Dusk and making it possible — it genuinely helps."
        }
        return "Dusk is free and open source — no ads, no tracking, made by one person. If it's earned a place in your evenings, you can chip in. Everything stays free either way."
    }

    private var supporterSinceText: String? {
        guard store.isSupporter, let since = store.supporterSince else { return nil }
        var text = "Supporter since \(since.formatted(.dateTime.month(.wide).year()))"
        if store.tipCount == 1 {
            text += " · 1 tip"
        } else if store.tipCount > 1 {
            text += " · \(store.tipCount) tips"
        }
        return text
    }

    private func rowTitle(for product: Product) -> String {
        product.displayName.isEmpty ? fallbackName(for: product) : product.displayName
    }

    private func fallbackName(for product: Product) -> String {
        switch SupporterProduct(rawValue: product.id) {
        case .monthly: "Monthly Supporter"
        case .yearly: "Yearly Supporter"
        case .tipCoffee: "Coffee Tip"
        case .tipGenerous: "Generous Tip"
        case .tipLegendary: "Legendary Tip"
        case .tipPatron: "Patron Tip"
        case nil: product.id
        }
    }

    private func priceSuffix(for product: Product) -> String? {
        switch SupporterProduct(rawValue: product.id) {
        case .monthly: "per month"
        case .yearly: "per year"
        default: nil
        }
    }

    private func priceText(for product: Product) -> String {
        switch SupporterProduct(rawValue: product.id) {
        case .monthly: "\(product.displayPrice) / month"
        case .yearly: "\(product.displayPrice) / year"
        default: product.displayPrice
        }
    }
}

// MARK: - iOS product row

#if !os(tvOS)
private struct SupporterProductRow: View {
    let product: Product
    /// Draws the accent border used to gently spotlight the yearly option.
    let isHighlighted: Bool
    let priceSuffix: String?
    let isPurchasing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(product.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.duskTextPrimary)

                    if !product.description.isEmpty {
                        Text(product.description)
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer()

                if isPurchasing {
                    ProgressView()
                        .tint(Color.duskAccent)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(product.displayPrice)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color.duskTextPrimary)

                        if let priceSuffix {
                            Text(priceSuffix)
                                .font(.caption2)
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isHighlighted ? Color.duskAccent.opacity(0.35) : Color.primary.opacity(0.05),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
#endif

// MARK: - Icon showcase

/// Horizontal strip of every app icon variant. Inside the supporter sheet it
/// advertises the perk before purchase; for supporters on iOS it doubles as a
/// quick picker (tap to apply). tvOS shows it as a static showcase since
/// alternate icons only apply on iPhone and iPad.
struct SupporterIconShowcase: View {
    @Environment(SupporterStore.self) private var store
    #if os(iOS)
    @State private var currentIcon: DuskAppIcon = .dusk
    #endif

    private static let tileSpacing: CGFloat = 14

    #if os(tvOS)
    private let tileSize: CGFloat = 116
    #else
    /// Matches the sheet's horizontal content padding; the strip bleeds this
    /// far past the content column so tiles scroll out under the screen edge.
    private static let edgeInset: CGFloat = 20
    @State private var stripWidth: CGFloat = 0

    /// Sized so five tiles fit and a sixth is always cut in half at the
    /// trailing edge — the cut tile is the scroll affordance. A fixed size
    /// can land exactly on the viewport edge on some devices (five 68pt
    /// tiles fill an iPhone Pro Max column to within 4pt) and fake a
    /// complete, non-scrollable row.
    private var tileSize: CGFloat {
        guard stripWidth > 0 else { return 68 }
        return max(52, (stripWidth - Self.edgeInset - 5 * Self.tileSpacing) / 5.5)
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.isSupporter ? "Your App Icons" : "Supporter Perk — App Icons")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.duskTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.tileSpacing) {
                    ForEach(DuskAppIcon.allCases) { icon in
                        tile(for: icon)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            #if os(iOS)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, Self.edgeInset, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                stripWidth = width
            }
            .padding(.horizontal, -Self.edgeInset)
            #endif

            Text(captionText)
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
        }
        #if os(iOS)
        .onAppear { currentIcon = DuskAppIcon.current }
        #endif
    }

    @ViewBuilder
    private func tile(for icon: DuskAppIcon) -> some View {
        VStack(spacing: 6) {
            iconArtwork(for: icon)

            Text(icon.displayName)
                .font(.caption2)
                .foregroundStyle(Color.duskTextSecondary)
        }
        #if os(iOS)
        .onTapGesture {
            guard store.isSupporter || !icon.requiresSupporter else { return }
            apply(icon)
        }
        #endif
    }

    private func iconArtwork(for icon: DuskAppIcon) -> some View {
        let isSelected = isCurrent(icon)
        let shape = RoundedRectangle(cornerRadius: tileSize * 0.22, style: .continuous)

        return Image(icon.previewImageName)
            .resizable()
            .scaledToFit()
            .frame(width: tileSize, height: tileSize)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    isSelected ? Color.duskAccent : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 2 : 1
                )
            }
            .overlay(alignment: .bottomTrailing) {
                if icon.requiresSupporter && !store.isSupporter {
                    Image(systemName: "lock.fill")
                        .font(.system(size: tileSize * 0.14, weight: .semibold))
                        .foregroundStyle(Color.duskTextPrimary)
                        .padding(tileSize * 0.08)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(3)
                }
            }
    }

    private var captionText: String {
        #if os(tvOS)
        return store.isSupporter
            ? "App icons are applied on iPhone and iPad."
            : "Supporting unlocks every alternate app icon on iPhone and iPad."
        #else
        return store.isSupporter
            ? "Tap an icon to apply it."
            : "Supporting unlocks every alternate app icon."
        #endif
    }

    private func isCurrent(_ icon: DuskAppIcon) -> Bool {
        #if os(iOS)
        return currentIcon == icon
        #else
        return false
        #endif
    }

    #if os(iOS)
    private func apply(_ icon: DuskAppIcon) {
        Task {
            try? await DuskAppIcon.select(icon)
            currentIcon = DuskAppIcon.current
        }
    }
    #endif
}

// MARK: - Button style helpers

private extension View {
    /// Neutral Liquid Glass pill per STYLE.md — used for the prompt's
    /// "Maybe Later" so declining reads as a first-class, guilt-free choice.
    @ViewBuilder
    func supporterNeutralGlassButtonStyle() -> some View {
        #if os(tvOS)
        self
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .tint(Color.primary)
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        } else {
            self
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        }
        #else
        self
        #endif
    }
}
