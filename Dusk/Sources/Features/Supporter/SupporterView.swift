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
    /// prompt ladder and the Settings entry point can be told apart.
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
        ZStack(alignment: .topTrailing) {
            Color.duskBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
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
                .padding(.horizontal, 20)
                .padding(.top, 48)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }

            Button {
                report(.supporterDismissed, ["control": .string("close")])
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

            if let subscriptionStatusText {
                Text(subscriptionStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.duskTextPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.duskSurface, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.duskAccent.opacity(0.35), lineWidth: 1)
                    }
                    .padding(.top, 2)
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
            VStack(alignment: .leading, spacing: 24) {
                if !store.subscriptionProducts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel(store.hasActiveSubscription ? "Your Subscription" : "Recurring")

                        VStack(spacing: 14) {
                            ForEach(SupporterTier.allCases) { tier in
                                let products = store.products(for: tier)
                                if !products.isEmpty {
                                    tierCard(tier, products: products)
                                }
                            }
                        }

                        Text(subscriptionFootnote)
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)

                        // App Review (3.1.2): privacy policy + EULA links next
                        // to the subscription offer itself.
                        legalLinks
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

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Color.duskTextSecondary)
    }

    private func tierCard(_ tier: SupporterTier, products: [Product]) -> some View {
        SupporterTierCard(
            tier: tier,
            isCurrent: store.activeTier == tier,
            note: tierNote(for: tier)
        ) {
            ForEach(products, id: \.id) { product in
                SupporterPlanRow(
                    title: SupporterProduct(rawValue: product.id)?.isYearly == true ? "Yearly" : "Monthly",
                    price: product.displayPrice,
                    priceSuffix: priceSuffix(for: product),
                    state: planRowState(for: product),
                    isHighlighted: SupporterProduct(rawValue: product.id)?.isYearly == true
                ) {
                    report(.supporterPurchaseTapped, ["product": .string(product.id)])
                    Task { await store.purchase(product) }
                }
                .disabled(store.purchasingProductID != nil || store.activeProductID == product.id)
            }
        }
    }

    private func planRowState(for product: Product) -> SupporterPlanRow.RowState {
        if store.purchasingProductID == product.id { return .purchasing }
        if store.activeProductID == product.id { return .current }
        if let plan = store.renewalPlan,
           plan.willAutoRenew,
           plan.nextProductID == product.id,
           plan.nextProductID != store.activeProductID,
           let date = plan.renewalDate {
            return .scheduled(date.formatted(date: .abbreviated, time: .omitted))
        }
        return .available
    }

    private func productSection(title: String, footnote: String, products: [Product]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(title)

            VStack(spacing: 10) {
                ForEach(products, id: \.id) { product in
                    SupporterProductRow(
                        product: product,
                        isHighlighted: false,
                        priceSuffix: priceSuffix(for: product),
                        isPurchasing: store.purchasingProductID == product.id
                    ) {
                        report(.supporterPurchaseTapped, ["product": .string(product.id)])
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
            Text("Everything in Dusk stays free either way — supporting just unlocks app icons, and keeps development going.")
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)

            #if os(iOS)
            if store.hasActiveSubscription {
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
        .padding(.top, 4)
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
                    VStack(alignment: .leading, spacing: 12) {
                        Text(headlineText)
                            .font(DuskFont.TV.pageTitle)
                            .foregroundStyle(Color.duskTextPrimary)

                        Text(bodyText)
                            .font(DuskFont.TV.body)
                            .foregroundStyle(Color.duskTextSecondary)
                            .frame(maxWidth: 780, alignment: .leading)

                        if let supporterSinceText {
                            Text(supporterSinceText)
                                .font(DuskFont.TV.caption)
                                .foregroundStyle(Color.duskTextSecondary)
                        }

                        if let subscriptionStatusText {
                            Text(subscriptionStatusText)
                                .font(DuskFont.TV.caption.weight(.semibold))
                                .foregroundStyle(Color.duskTextPrimary)
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
            ForEach(SupporterTier.allCases) { tier in
                let products = store.products(for: tier)
                if !products.isEmpty {
                    TVSettingsSection(
                        title: store.activeTier == tier ? "\(tier.displayName) · Current" : tier.displayName,
                        footer: tvTierFooter(for: tier)
                    ) {
                        tvProductRows(products)
                    }
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

    private func tvTierFooter(for tier: SupporterTier) -> String {
        var text = tierPerksSentence(for: tier)
        if let note = tierNote(for: tier) {
            text += " " + note
        }
        return text
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
        "Everything in Dusk stays free either way. \(Self.renewalDisclosure) Upgrades start right away; switching down takes effect at the next renewal. Manage or cancel subscriptions in Settings → Users & Accounts → Subscriptions. Privacy Policy: getdusk.app/privacy · Terms of Use (EULA): apple.com/legal/internet-services/itunes/dev/stdeula"
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

    private func tierPerksSentence(for tier: SupporterTier) -> String {
        switch tier {
        case .frontRow:
            "Six alternate app icons on iPhone and iPad, and supporter status for good — even if you cancel."
        case .directorsCut:
            "Everything in Front Row, plus the exclusive Eclipse and Velvet icons on iPhone and iPad while it's active — and the biggest boost for Dusk's development."
        }
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
        case .monthly: "Front Row Monthly"
        case .yearly: "Front Row Yearly"
        case .directorsCutMonthly: "Director's Cut Monthly"
        case .directorsCutYearly: "Director's Cut Yearly"
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

    /// One line about the active subscription: level plus what happens next.
    private var subscriptionStatusText: String? {
        guard let tier = store.activeTier else { return nil }
        let plan = store.renewalPlan
        let date = (plan?.renewalDate ?? store.activeExpirationDate)?
            .formatted(date: .abbreviated, time: .omitted)
        if let downgrade = store.pendingDowngradeTier, let date {
            return "\(tier.displayName) · switches to \(downgrade.displayName) on \(date)"
        }
        if let plan, !plan.willAutoRenew, let date {
            return "\(tier.displayName) · ends on \(date)"
        }
        if let date {
            return "\(tier.displayName) · renews on \(date)"
        }
        return tier.displayName
    }

    /// Context under a tier card while a subscription is active: how moving
    /// to this level would work.
    private func tierNote(for tier: SupporterTier) -> String? {
        guard let active = store.activeTier, active != tier else { return nil }
        if tier > active {
            return "Upgrading starts right away; the App Store credits what's left of your current period."
        }
        if store.pendingDowngradeTier == tier {
            return "Your switch to \(tier.displayName) is scheduled for the next renewal."
        }
        return "Switching to \(tier.displayName) takes effect at your next renewal."
    }

    /// Auto-renewal disclosure for the subscription offer (App Review 3.1.2).
    private static let renewalDisclosure = "Subscriptions renew automatically at the price shown until cancelled at least 24 hours before the end of the period. Payment is charged to your Apple Account."

    private var subscriptionFootnote: String {
        // While subscribed, each card already explains how its switch applies.
        let switching = store.hasActiveSubscription
            ? ""
            : " Upgrades start right away; switching down takes effect at the next renewal."
        return Self.renewalDisclosure + switching + " Cancel anytime in your App Store settings."
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

// MARK: - iOS tier card

#if !os(tvOS)
/// One subscription level: name, what it gets you, and its monthly/yearly
/// plan rows. Director's Cut gets a warm coral-to-gold hairline so the two
/// levels read as distinct at a glance without a pushy badge.
private struct SupporterTierCard<Rows: View>: View {
    let tier: SupporterTier
    let isCurrent: Bool
    let note: String?
    @ViewBuilder let rows: Rows

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tier.displayName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.duskTextPrimary)

                if isCurrent {
                    Text("Current")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(Color.duskAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.duskAccent.opacity(0.14), in: Capsule())
                }

                Spacer(minLength: 0)
            }

            Text(tagline)
                .font(.subheadline)
                .foregroundStyle(Color.duskTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(perks, id: \.self) { perk in
                    perkRow(perk)
                }

                if tier == .directorsCut {
                    exclusiveIconsPerk
                }
            }

            VStack(spacing: 8) {
                rows
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(Color.duskSurface, in: shape)
        .overlay {
            switch tier {
            case .frontRow:
                shape.strokeBorder(
                    isCurrent ? Color.duskAccent.opacity(0.45) : Color.primary.opacity(0.05),
                    lineWidth: 1
                )
            case .directorsCut:
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.duskAccent.opacity(isCurrent ? 0.9 : 0.55), gold.opacity(isCurrent ? 0.9 : 0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
        }
    }

    private var gold: Color { Color(red: 0.91, green: 0.72, blue: 0.36) }

    private var tagline: String {
        switch tier {
        case .frontRow: "The classic supporter seat."
        case .directorsCut: "For the biggest fans — the most support for Dusk's development."
        }
    }

    private var perks: [String] {
        switch tier {
        case .frontRow:
            ["Six alternate app icons", "Supporter for good — even if you cancel"]
        case .directorsCut:
            ["Everything in Front Row"]
        }
    }

    private func perkRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.duskAccent)

            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.duskTextPrimary)
        }
    }

    private var exclusiveIconsPerk: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.duskAccent)

            Text("Exclusive Eclipse & Velvet icons")
                .font(.footnote)
                .foregroundStyle(Color.duskTextPrimary)

            HStack(spacing: 5) {
                ForEach(DuskAppIcon.directorsCutIcons) { icon in
                    Image(icon.previewImageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// A monthly or yearly plan inside a tier card.
private struct SupporterPlanRow: View {
    enum RowState: Equatable {
        case available
        case purchasing
        case current
        /// The subscription renews into this plan on the given (formatted) date.
        case scheduled(String)
    }

    let title: String
    let price: String
    let priceSuffix: String?
    let state: RowState
    /// Accent border used to gently spotlight the yearly option.
    let isHighlighted: Bool
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.duskTextPrimary)

                Spacer()

                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.04), in: shape)
            .overlay {
                shape.strokeBorder(
                    isHighlighted && state == .available ? Color.duskAccent.opacity(0.35) : Color.primary.opacity(0.05),
                    lineWidth: 1
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .purchasing:
            ProgressView()
                .tint(Color.duskAccent)
        case .current:
            Label("Current Plan", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.duskAccent)
        case .scheduled(let date):
            Text("Starts \(date)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.duskTextSecondary)
        case .available:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(price)
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
}
#endif

// MARK: - Icon showcase

/// Horizontal strip of every app icon variant: the supporter icons, then the
/// Director's Cut exclusives after a hairline. Inside the supporter sheet it
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
                .font(DuskFont.groupHeader(ios: .footnote.weight(.semibold)))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.duskTextSecondary)

            #if os(tvOS)
            // Not focusable on tvOS, so it can't scroll: the exclusives get
            // their own row instead of hiding past the trailing edge.
            HStack(alignment: .top, spacing: Self.tileSpacing) {
                ForEach(DuskAppIcon.supporterIcons) { icon in
                    tile(for: icon)
                }
            }

            Text("Director's Cut Exclusives")
                .font(DuskFont.groupHeader(ios: .footnote.weight(.semibold)))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.duskTextSecondary)
                .padding(.top, 8)

            HStack(alignment: .top, spacing: Self.tileSpacing) {
                ForEach(DuskAppIcon.directorsCutIcons) { icon in
                    tile(for: icon)
                }
            }
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

                    ForEach(DuskAppIcon.directorsCutIcons) { icon in
                        tile(for: icon)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
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
                .font(DuskFont.caption(ios: .caption))
                .foregroundStyle(Color.duskTextSecondary)
        }
        #if os(iOS)
        .onAppear { currentIcon = DuskAppIcon.current }
        .onChange(of: store.activeTier) { _, _ in
            // Picks up the silent switch back to the default icon on lapse.
            currentIcon = DuskAppIcon.current
        }
        #endif
    }

    @ViewBuilder
    private func tile(for icon: DuskAppIcon) -> some View {
        VStack(spacing: 6) {
            iconArtwork(for: icon)

            Text(icon.displayName)
                .font(DuskFont.cardSubtitle(ios: .caption2))
                .foregroundStyle(icon.requiresDirectorsCut ? Color.duskTextPrimary : Color.duskTextSecondary)
                .lineLimit(1)
        }
        #if os(iOS)
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
        let exclusives = "Eclipse and Velvet are Director's Cut exclusives"
        #if os(tvOS)
        if store.hasDirectorsCut {
            return "App icons are applied on iPhone and iPad — the Director's Cut exclusives included."
        }
        return store.isSupporter
            ? "App icons are applied on iPhone and iPad. \(exclusives)."
            : "Supporting unlocks the alternate app icons on iPhone and iPad. \(exclusives)."
        #else
        if store.hasDirectorsCut {
            return "Tap an icon to apply it."
        }
        return store.isSupporter
            ? "Tap an icon to apply it. \(exclusives)."
            : "Any support unlocks six icons for good. \(exclusives)."
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
