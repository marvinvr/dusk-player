import StoreKit
import SwiftUI

/// Where the supporter sheet was opened from. The prompt variant softens the
/// headline and adds an equal-weight "Maybe Later" action; content is
/// otherwise identical so the two never drift apart.
enum SupporterViewContext: Equatable {
    case settings
    /// 1-based position in the device's supporter prompt sequence.
    case prompt(number: Int)

    var isPrompt: Bool {
        if case .prompt = self { return true }
        return false
    }

}

/// The supporter tier sheet: a pitch before any purchase, a thank-you with a
/// "support again" path after one. Purchases stay on this screen — rows buy
/// directly, and the header flips to the thank-you state on success.
struct SupporterView: View {
    let context: SupporterViewContext

    @Environment(SupporterStore.self) private var store
    // Optional on purpose: reporting must never be able to trap a view that
    // renders before the client is in the environment.
    @Environment(AnalyticsClient.self) private var analytics: AnalyticsClient?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var reportedProductsUnavailable = false
    #if os(iOS)
    @State private var showsManageSubscriptions = false
    #endif

    var body: some View {
        platformBody
            .task {
                report(.supporterSheetShown)
                reportProductsUnavailableIfNeeded()
            }
            .onChange(of: store.productsUnavailable) { _, _ in
                reportProductsUnavailableIfNeeded()
            }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(tvOS)
        tvBody
        #else
        iosBody
        #endif
    }

    // MARK: - Reporting

    /// Every event from this sheet carries where it was opened from, so the
    /// prompt schedule and the Settings entry point can be told apart.
    private var reportingProperties: [String: AnalyticsValue] {
        var properties: [String: AnalyticsValue] = [
            "source": .string(context.isPrompt ? "prompt" : "settings")
        ]
        if case .prompt(let number) = context {
            properties["milestone"] = .int(number)
        }
        return properties
    }

    private func report(_ name: AnalyticsEventName, _ extra: [String: AnalyticsValue] = [:]) {
        analytics?.record(
            AnalyticsEvent(name, reportingProperties.merging(extra) { _, new in new })
        )
    }

    /// Reported once per appearance: the sheet rendered with nothing to buy.
    private func reportProductsUnavailableIfNeeded() {
        guard store.productsUnavailable, !reportedProductsUnavailable else { return }
        reportedProductsUnavailable = true
        report(.supporterProductsUnavailable)
    }

    // MARK: - iOS / iPadOS

    #if !os(tvOS)
    private var iosBody: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SupporterLayout.sectionSpacing) {
                    header

                    SupporterIconShowcase()

                    purchaseSections

                    if context.isPrompt {
                        Button("Maybe Later") {
                            report(.supporterDismissed, ["control": .string("maybe_later")])
                            dismiss()
                        }
                        .supporterNeutralGlassButtonStyle()
                        .frame(minWidth: 200)
                    }

                    aboutMe

                    footer
                }
                .padding(.horizontal, SupporterLayout.pageInset)
                .padding(.top, 4)
                .padding(.bottom, 36)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color.duskBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    closeButton
                }
            }
        }
        .presentationDragIndicator(.visible)
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
        #endif
    }

    /// The system close button, so scrolled content passes under the bar
    /// instead of under a floating circle.
    @ViewBuilder
    private var closeButton: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close) {
                report(.supporterDismissed, ["control": .string("close")])
                dismiss()
            }
        } else {
            Button {
                report(.supporterDismissed, ["control": .string("close")])
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.duskTextSecondary)
                    .padding(8)
                    .background(Color.duskSurface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.duskAccent.opacity(0.14))
                    .frame(width: 64, height: 64)

                Image(systemName: "heart.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.duskAccent)
            }
            .padding(.bottom, 16)

            Text(headlineText)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.duskTextPrimary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            Text(bodyText)
                .font(.subheadline)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if let supporterSinceText {
                Text(supporterSinceText)
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
                    .padding(.top, 10)
            }
            // The plan status lives on the subscription card.
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
                        report(.supporterProductsRetryTapped)
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
            VStack(alignment: .leading, spacing: SupporterLayout.sectionSpacing) {
                if !store.subscriptionProducts.isEmpty || store.hasActiveSubscription {
                    VStack(alignment: .leading, spacing: SupporterLayout.labelSpacing) {
                        sectionLabel("Recurring")

                        SupporterSubscriptionCard(
                            status: subscriptionStatusText,
                            purchase: { product in
                                report(.supporterPurchaseTapped, ["product": .string(product.id)])
                                Task { await store.purchase(product) }
                            },
                            manage: {
                                report(.supporterManageSubscriptionTapped)
                                showsManageSubscriptions = true
                            }
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            sectionFootnote(subscriptionFootnote)

                            // App Review (3.1.2): privacy policy + EULA links
                            // next to the subscription offer itself.
                            legalLinks
                        }
                        .padding(.top, 2)
                    }
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

    /// Section headers and footnotes sit on the same text column as the
    /// content inside the cards below them, like an inset grouped list.
    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Color.duskTextSecondary)
            .padding(.horizontal, SupporterLayout.cardInset)
    }

    private func sectionFootnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.duskTextSecondary)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SupporterLayout.cardInset)
    }

    private func productSection(title: String, footnote: String, products: [Product]) -> some View {
        VStack(alignment: .leading, spacing: SupporterLayout.labelSpacing) {
            sectionLabel(title)

            VStack(spacing: SupporterLayout.rowSpacing) {
                ForEach(products, id: \.id) { product in
                    SupporterProductRow(
                        product: product,
                        isHighlighted: false,
                        priceSuffix: priceSuffix(for: product),
                        perk: SupporterProduct(rawValue: product.id)?.isIconTip == true ? Self.iconTipPerk : nil,
                        isPurchasing: store.purchasingProductID == product.id
                    ) {
                        report(.supporterPurchaseTapped, ["product": .string(product.id)])
                        Task { await store.purchase(product) }
                    }
                    .disabled(store.purchasingProductID != nil)
                }
            }

            sectionFootnote(footnote)
                .padding(.top, 2)
        }
    }

    private var footer: some View {
        VStack(spacing: 16) {
            Text("Everything in Dusk stays free either way — supporting just unlocks app icons, and keeps development going.")
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)

            #if os(iOS)
            // The subscription card carries Manage Subscription; this is the
            // fallback while the products can't load.
            if store.hasActiveSubscription && store.subscriptionProducts.isEmpty {
                Button("Manage Subscription") {
                    report(.supporterManageSubscriptionTapped)
                    showsManageSubscriptions = true
                }
                .font(.subheadline)
                .foregroundStyle(Color.duskAccent)
                .buttonStyle(.plain)
            }
            #endif

            Button {
                report(.supporterRestoreTapped)
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

            if store.subscriptionProducts.isEmpty {
                legalLinks
            }
        }
        .padding(.horizontal, SupporterLayout.cardInset)
    }

    private var legalLinks: some View {
        HStack(spacing: 6) {
            Button("Privacy Policy") {
                report(.supporterLinkTapped, ["link": .string("privacy")])
                openURL(SettingsSupport.privacyPolicyURL)
            }
            Text("·")
            Button("Terms of Use (EULA)") {
                report(.supporterLinkTapped, ["link": .string("terms")])
                openURL(SettingsSupport.termsOfUseURL)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.duskAccent)
        .buttonStyle(.plain)
        .padding(.horizontal, SupporterLayout.cardInset)
    }

    private var aboutMe: some View {
        VStack(alignment: .leading, spacing: SupporterLayout.labelSpacing) {
            sectionLabel("About")

            VStack(spacing: SupporterLayout.rowSpacing) {
                aboutLinkRow(
                    title: "About Me",
                    subtitle: "marvinvr.ch",
                    systemImage: "person.crop.circle",
                    url: SettingsSupport.aboutMeURL,
                    link: "about_me"
                )

                aboutLinkRow(
                    title: "GitHub",
                    subtitle: "github.com/marvinvr/dusk-player",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    url: SettingsSupport.githubURL,
                    link: "github"
                )
            }
        }
    }

    private func aboutLinkRow(
        title: String,
        subtitle: String,
        systemImage: String,
        url: URL,
        link: String
    ) -> some View {
        Button {
            report(.supporterLinkTapped, ["link": .string(link)])
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
            .padding(.horizontal, SupporterLayout.cardInset)
            .padding(.vertical, 14)
            .supporterCardBackground()
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
                VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing + 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(headlineText)
                            .font(DuskFont.TV.pageTitle)
                            .foregroundStyle(Color.duskTextPrimary)
                            .padding(.bottom, 14)

                        Text(bodyText)
                            .font(DuskFont.TV.body)
                            .foregroundStyle(Color.duskTextSecondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 820, alignment: .leading)

                        if supporterSinceText != nil || subscriptionStatusText != nil {
                            VStack(alignment: .leading, spacing: 6) {
                                if let subscriptionStatusText {
                                    Text("Dusk Supporter · \(subscriptionStatusText)")
                                        .font(DuskFont.TV.caption.weight(.semibold))
                                        .foregroundStyle(Color.duskTextPrimary)
                                }

                                if let supporterSinceText {
                                    Text(supporterSinceText)
                                        .font(DuskFont.TV.caption)
                                        .foregroundStyle(Color.duskTextSecondary)
                                }
                            }
                            .padding(.top, 18)
                        }
                    }
                    .padding(.leading, TVSettingsMetrics.contentInset)

                    SupporterIconShowcase()
                        .padding(.leading, TVSettingsMetrics.contentInset)
                        .focusSection()

                    tvPurchaseSections
                        .focusSection()

                    TVSettingsSection(
                        title: "Manage",
                        footer: tvManageFooter
                    ) {
                        TVSettingsActionRow(
                            title: "Restore Purchases",
                            tint: Color.duskAccent,
                            isLoading: store.isRestoring
                        ) {
                            report(.supporterRestoreTapped)
                            Task { await store.restorePurchases() }
                        }
                        .disabled(store.isRestoring)

                        if context.isPrompt {
                            tvRowDivider

                            TVSettingsActionRow(
                                title: "Maybe Later",
                                tint: Color.duskTextSecondary
                            ) {
                                report(.supporterDismissed, ["control": .string("maybe_later")])
                                dismiss()
                            }
                        }
                    }
                    .focusSection()
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 60)
                .padding(.top, 64)
                .padding(.bottom, 96)
            }
        }
    }

    @ViewBuilder
    private var tvPurchaseSections: some View {
        if store.subscriptionProducts.isEmpty && store.tipProducts.isEmpty {
            if store.productsUnavailable {
                TVSettingsSection(title: "Support", footer: "The support options couldn't be loaded right now.") {
                    TVSettingsActionRow(title: "Try Again", tint: Color.duskAccent) {
                        report(.supporterProductsRetryTapped)
                        Task { await store.loadProducts() }
                    }
                }
            } else {
                ProgressView()
                    .tint(Color.duskAccent)
                    .padding(.leading, TVSettingsMetrics.contentInset)
            }
        } else {
            if !store.subscriptionProducts.isEmpty {
                TVSettingsSection(title: "Recurring", footer: tvSubscriptionFooter) {
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
                subtitle: tvSubtitle(for: product),
                tint: store.activeProductID == product.id ? Color.duskTextSecondary : Color.duskTextPrimary,
                isLoading: store.purchasingProductID == product.id,
                detail: tvDetail(for: product)
            ) {
                report(.supporterPurchaseTapped, ["product": .string(product.id)])
                Task { await store.purchase(product) }
            }
            .disabled(store.purchasingProductID != nil || store.activeProductID == product.id)
        }
    }

    private func tvDetail(for product: Product) -> String {
        switch planRowStateText(for: product) {
        case .some(let text): text
        case .none: priceText(for: product)
        }
    }

    /// What a row adds under its name: the yearly savings for the plans,
    /// the StoreKit description (plus the icon perk) for tips.
    private func tvSubtitle(for product: Product) -> String? {
        guard let supporterProduct = SupporterProduct(rawValue: product.id) else {
            return product.description.isEmpty ? nil : product.description
        }
        if supporterProduct.isSubscription {
            let perks = "All nine alternate app icons"
            guard supporterProduct.isYearly, let percent = store.yearlySavingsPercent else { return perks }
            return "\(perks) · saves \(percent)%"
        }
        var parts: [String] = []
        if !product.description.isEmpty { parts.append(product.description) }
        if supporterProduct.isIconTip { parts.append("Includes the six alternate icons, yours to keep.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Sits right under the plans so the renewal terms are next to the offer
    /// (App Review 3.1.2).
    private var tvSubscriptionFooter: String {
        let lead = store.hasActiveSubscription
            ? "Thank you for subscribing. Switching between monthly and yearly takes effect at your next renewal."
            : "App icons apply on iPhone and iPad, including the subscriber-exclusive Velvet, Emerald and Gilded."
        return "\(lead) \(Self.renewalDisclosure) \(Self.subscriptionPerksNote)"
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
        "Everything in Dusk stays free either way. Manage or cancel subscriptions in Settings → Users & Accounts → Subscriptions.\n\nPrivacy Policy: getdusk.app/privacy\nTerms of Use (EULA): apple.com/legal/internet-services/itunes/dev/stdeula"
    }

    /// Plain-text equivalent of the iOS plan-row state for the tvOS detail column.
    private func planRowStateText(for product: Product) -> String? {
        if store.activeProductID == product.id { return "Current Plan" }
        if let plan = store.renewalPlan,
           plan.willAutoRenew,
           plan.nextProductID == product.id,
           plan.nextProductID != store.activeProductID,
           let date = plan.renewalDate {
            return "Starts \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return nil
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
        case .monthly: "Dusk Supporter Monthly"
        case .yearly: "Dusk Supporter Yearly"
        case .tipCoffee: "Coffee Tip"
        case .tipGenerous: "Generous Tip"
        case .tipLegendary: "Legendary Tip"
        case .tipPatron: "Patron Tip"
        case nil: product.id
        }
    }

    private func priceSuffix(for product: Product) -> String? {
        guard let supporterProduct = SupporterProduct(rawValue: product.id),
              supporterProduct.isSubscription else { return nil }
        return supporterProduct.isYearly ? "per year" : "per month"
    }

    private func priceText(for product: Product) -> String {
        guard let supporterProduct = SupporterProduct(rawValue: product.id),
              supporterProduct.isSubscription else { return product.displayPrice }
        return "\(product.displayPrice) / \(supporterProduct.isYearly ? "year" : "month")"
    }

    /// One line about the active subscription: plan plus what happens next.
    private var subscriptionStatusText: String? {
        guard let productID = store.activeProductID else { return nil }
        let plan = SupporterProduct(rawValue: productID)?.isYearly == true ? "Yearly" : "Monthly"
        let renewal = store.renewalPlan
        let date = (renewal?.renewalDate ?? store.activeExpirationDate)?
            .formatted(date: .abbreviated, time: .omitted)
        guard let date else { return plan }
        if let renewal, !renewal.willAutoRenew {
            return "\(plan) · ends on \(date)"
        }
        if let next = renewal?.nextProductID, next != productID,
           let nextProduct = SupporterProduct(rawValue: next) {
            return "\(plan) · switches to \(nextProduct.isYearly ? "yearly" : "monthly") on \(date)"
        }
        return "\(plan) · renews on \(date)"
    }

    /// Auto-renewal disclosure for the subscription offer (App Review 3.1.2).
    private static let renewalDisclosure = "Subscriptions renew automatically at the price shown until cancelled at least 24 hours before the end of the period. Payment is charged to your Apple Account."

    /// One-time tips from Generous up keep their icons; never say this about
    /// a subscription.
    private static let iconTipPerk = "Includes the six alternate icons, yours to keep"

    private static let subscriptionPerksNote = "Subscription perks are available while the subscription is active."

    private var subscriptionFootnote: String {
        Self.renewalDisclosure + " \(Self.subscriptionPerksNote) Cancel anytime in your App Store settings."
    }
}

// MARK: - iOS product row

#if !os(tvOS)
private struct SupporterProductRow: View {
    let product: Product
    /// Draws the accent border used to gently spotlight the yearly option.
    let isHighlighted: Bool
    let priceSuffix: String?
    /// What the purchase includes beyond the thank-you, if anything.
    var perk: String? = nil
    let isPurchasing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
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

                    if let perk {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.duskAccent)

                            Text(perk)
                                .font(.caption)
                                .foregroundStyle(Color.duskTextPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                    }
                }

                Spacer(minLength: 0)

                // The spinner overlays the price so the row never shifts.
                ZStack(alignment: .trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(product.displayPrice)
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.duskTextPrimary)

                        if let priceSuffix {
                            Text(priceSuffix)
                                .font(.caption2)
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                    }
                    .opacity(isPurchasing ? 0 : 1)

                    if isPurchasing {
                        ProgressView()
                    }
                }
            }
            .padding(.horizontal, SupporterLayout.cardInset)
            .padding(.vertical, 14)
            .supporterCardBackground(
                stroke: isHighlighted ? Color.duskAccent.opacity(0.35) : nil
            )
        }
        .buttonStyle(.plain)
    }
}
#endif

// MARK: - iOS subscription card

#if !os(tvOS)
/// The one subscription: what it includes, then its two billing periods side
/// by side. While subscribed (a plan from before 1.7 included — same product
/// IDs) it shows the plan status and Manage Subscription instead; switching
/// between monthly and yearly goes through Manage Subscription.
private struct SupporterSubscriptionCard: View {
    let status: String?
    let purchase: (Product) -> Void
    let manage: () -> Void

    @Environment(SupporterStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dusk Supporter")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.duskTextPrimary)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.duskTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if store.hasActiveSubscription {
                    Text("Active")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(Color.duskAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.duskAccent.opacity(0.14), in: Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                perkRow("All nine alternate app icons")
                exclusiveIconsPerk
                perkRow("Keeps Dusk free, ad-free and independent")
            }

            actions
                .padding(.top, 2)
        }
        .padding(.horizontal, SupporterLayout.cardInset)
        .padding(.vertical, 18)
        .supporterCardBackground(
            cornerRadius: SupporterLayout.featureCornerRadius,
            stroke: store.hasActiveSubscription ? Color.duskAccent.opacity(0.45) : nil
        )
    }

    private var subtitle: String {
        guard store.hasActiveSubscription else { return "Monthly or yearly. Cancel anytime." }
        return status ?? "Thank you for subscribing."
    }

    private func perkRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            checkmark

            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.duskTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.duskAccent)
            .frame(width: 14)
    }

    private var exclusiveIconsPerk: some View {
        HStack(alignment: .center, spacing: 10) {
            checkmark

            Text("Three subscriber exclusives")
                .font(.footnote)
                .foregroundStyle(Color.duskTextPrimary)

            HStack(spacing: 6) {
                ForEach(DuskAppIcon.subscriptionIcons) { icon in
                    Image(icon.previewImageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                        .accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if store.hasActiveSubscription {
            Button("Manage Subscription", action: manage)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(Color.duskAccent)
        } else if !store.subscriptionProducts.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { priceOptions }
                VStack(spacing: 12) { priceOptions }
            }
        }
    }

    /// Each period's button with a short line under it, so the two columns
    /// stay the same height and the savings sit under the yearly price.
    @ViewBuilder
    private var priceOptions: some View {
        ForEach(store.subscriptionProducts, id: \.id) { product in
            let isYearly = SupporterProduct(rawValue: product.id)?.isYearly == true
            VStack(spacing: 6) {
                priceButton(for: product, isYearly: isYearly)

                Text(isYearly ? (savings ?? "Billed yearly") : "Billed monthly")
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
    }

    private func priceButton(for product: Product, isYearly: Bool) -> some View {
        Button {
            purchase(product)
        } label: {
            ZStack {
                Text("\(product.displayPrice) / \(isYearly ? "year" : "month")")
                    .monospacedDigit()
                    .opacity(store.purchasingProductID == product.id ? 0 : 1)

                if store.purchasingProductID == product.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Color.duskAccent)
        .disabled(store.purchasingProductID != nil)
        .accessibilityLabel("Dusk Supporter \(isYearly ? "Yearly" : "Monthly"), \(product.displayPrice) per \(isYearly ? "year" : "month")")
    }

    /// "Saves 30%" from the monthly and yearly prices.
    private var savings: String? {
        store.yearlySavingsPercent.map { "Saves \($0)%" }
    }
}
#endif

// MARK: - Icon showcase

/// Horizontal strip of every app icon variant: the supporter icons, then the
/// subscriber exclusives after a hairline. Inside the supporter sheet it
/// advertises the perks before purchase; on iOS unlocked tiles double as a
/// quick picker (tap to apply). tvOS shows it as a static showcase since
/// alternate icons only apply on iPhone and iPad.
struct SupporterIconShowcase: View {
    @Environment(SupporterStore.self) private var store
    #if os(iOS)
    @State private var currentIcon: DuskAppIcon = .dusk
    #endif

    private static let tileSpacing: CGFloat = 14

    #if os(tvOS)
    /// Matches `TVSettingsSection`'s header-to-card gap.
    private static let labelSpacing: CGFloat = 12
    private static let labelInset: CGFloat = 0
    #else
    private static let labelSpacing = SupporterLayout.labelSpacing
    private static let labelInset = SupporterLayout.cardInset
    #endif

    #if os(tvOS)
    private let tileSize: CGFloat = 116
    #else
    /// Matches the sheet's horizontal content padding; the strip bleeds this
    /// far past the content column so tiles scroll out under the screen edge.
    private static let edgeInset = SupporterLayout.pageInset
    /// Where the label, caption and first tile start: the same text column as
    /// the section labels and card content below.
    private static let textInset = SupporterLayout.cardInset
    @State private var stripWidth: CGFloat = 0

    /// Sized so five tiles fit and a sixth is always cut in half at the
    /// trailing edge — the cut tile is the scroll affordance. A fixed size
    /// can land exactly on the viewport edge on some devices (five 68pt
    /// tiles fill an iPhone Pro Max column to within 4pt) and fake a
    /// complete, non-scrollable row.
    private var tileSize: CGFloat {
        guard stripWidth > 0 else { return 64 }
        let leading = Self.edgeInset + Self.textInset
        return max(52, (stripWidth - leading - 5 * Self.tileSpacing) / 5.5)
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            Text(store.hasIconAccess ? "Your App Icons" : "Supporter Perk — App Icons")
                .font(DuskFont.groupHeader(ios: .footnote.weight(.semibold)))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.duskTextSecondary)
                .padding(.horizontal, Self.labelInset)

            #if os(tvOS)
            // Two labeled rows, each a focus section. The tiles are buttons
            // so Up from the purchase rows always has a focusable target and
            // the scroll view can bring the icons back on screen. Alternate
            // icons still only apply on iPhone and iPad.
            HStack(alignment: .top, spacing: Self.tileSpacing) {
                ForEach(DuskAppIcon.supporterIcons) { icon in
                    tile(for: icon)
                }
            }
            .focusSection()

            Text("Subscriber Exclusives")
                .font(DuskFont.groupHeader(ios: .footnote.weight(.semibold)))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.duskTextSecondary)
                .padding(.top, 22)

            HStack(alignment: .top, spacing: Self.tileSpacing) {
                ForEach(DuskAppIcon.subscriptionIcons) { icon in
                    tile(for: icon)
                }
            }
            .focusSection()
            #else
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Self.tileSpacing) {
                    ForEach(DuskAppIcon.supporterIcons) { icon in
                        tile(for: icon)
                    }

                    Rectangle()
                        .fill(Color.duskTextSecondary.opacity(0.25))
                        .frame(width: 1, height: tileSize * 0.8)
                        .padding(.top, tileSize * 0.1)

                    ForEach(DuskAppIcon.subscriptionIcons) { icon in
                        tile(for: icon)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.leading, Self.edgeInset + Self.textInset, for: .scrollContent)
            .contentMargins(.trailing, Self.edgeInset, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                stripWidth = width
            }
            .padding(.horizontal, -Self.edgeInset)
            #endif

            Text(captionText)
                .font(DuskFont.caption(ios: .caption))
                .foregroundStyle(Color.duskTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.labelInset)
                #if os(tvOS)
                .padding(.top, 4)
                #endif
        }
        #if os(iOS)
        .onAppear { currentIcon = DuskAppIcon.current }
        .onChange(of: store.hasActiveSubscription) { _, _ in
            // Picks up the silent switch back to the default icon on lapse.
            currentIcon = DuskAppIcon.current
        }
        #endif
    }

    private func tileLabel(for icon: DuskAppIcon) -> some View {
        VStack(spacing: 6) {
            iconArtwork(for: icon)

            Text(icon.displayName)
                .font(DuskFont.cardSubtitle(ios: .caption2))
                .foregroundStyle(icon.requiresSubscription ? Color.duskTextPrimary : Color.duskTextSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func tile(for icon: DuskAppIcon) -> some View {
        #if os(tvOS)
        Button(action: {}) {
            tileLabel(for: icon)
        }
        .buttonStyle(.card)
        .buttonBorderShape(.roundedRectangle(radius: tileSize * 0.22))
        .hoverEffect(.highlight)
        .accessibilityLabel("\(icon.displayName) app icon")
        #else
        tileLabel(for: icon)
            .onTapGesture {
                guard store.isUnlocked(icon) else { return }
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
                if !store.isUnlocked(icon) {
                    // White on a dark disc reads on both light and dark
                    // artwork, in either appearance.
                    Image(systemName: "lock.fill")
                        .font(.system(size: tileSize * 0.14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(tileSize * 0.08)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .padding(3)
                }
            }
    }

    private var captionText: String {
        let exclusives = "Velvet, Emerald and Gilded come with the subscription only"
        #if os(tvOS)
        if store.hasActiveSubscription {
            return "App icons are applied on iPhone and iPad — the subscriber exclusives included."
        }
        return store.hasIconAccess
            ? "App icons are applied on iPhone and iPad. \(exclusives)."
            : "Supporting unlocks the alternate app icons on iPhone and iPad. \(exclusives)."
        #else
        if store.hasActiveSubscription {
            return "Tap an icon to apply it."
        }
        return store.hasIconAccess
            ? "Tap an icon to apply it. \(exclusives)."
            : "The subscription unlocks all nine icons, a tip from Generous up the six classic ones."
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

// MARK: - Layout

/// One spacing scale for the iOS sheet so every section, card and footnote
/// keeps the same rhythm.
enum SupporterLayout {
    /// Gap between the page's sections (header, icons, plans, tips, about).
    static let sectionSpacing: CGFloat = 32
    /// Gap between a section label and its first card.
    static let labelSpacing: CGFloat = 10
    /// Gap between stacked cards in one section.
    static let rowSpacing: CGFloat = 10
    /// Horizontal page margin; the icon strip bleeds past it to the edge.
    static let pageInset: CGFloat = 20
    /// Text inset inside every card. Section labels and footnotes share it,
    /// so all text in a section starts on one column.
    static let cardInset: CGFloat = 16
    static let cornerRadius: CGFloat = 16
    static let featureCornerRadius: CGFloat = 22
}

private extension View {
    /// Surface fill + 1pt hairline shared by every card on the sheet.
    func supporterCardBackground(
        cornerRadius: CGFloat = SupporterLayout.cornerRadius,
        stroke: Color? = nil
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Color.duskSurface, in: shape)
            .overlay {
                shape.strokeBorder(stroke ?? Color.primary.opacity(0.05), lineWidth: 1)
            }
            .contentShape(shape)
    }
}

extension SupporterStore {
    /// How much cheaper a year is than twelve months, in whole percent.
    var yearlySavingsPercent: Int? {
        let products = subscriptionProducts
        guard let monthly = products.first(where: { $0.id == SupporterProduct.monthly.rawValue }),
              let yearly = products.first(where: { $0.id == SupporterProduct.yearly.rawValue }),
              monthly.price > 0 else { return nil }
        let ratio = (yearly.price / (monthly.price * 12) as NSDecimalNumber).doubleValue
        let percent = Int(((1 - ratio) * 100).rounded())
        return percent > 0 ? percent : nil
    }
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
