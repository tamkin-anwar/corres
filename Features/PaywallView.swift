import StoreKit
import SwiftUI

enum CorresLinks {
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacy = URL(string: "https://anwarcreativestudio.com/corres/privacy/")!
}

/// Corres Pro: annual (with the free trial) chosen by default, monthly,
/// and lifetime. Prices, trial length and currency all come from the App
/// Store, never hard-coded, so they're right in every country.
struct PaywallView: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = EntitlementStore.ProductID.annual

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    header
                    benefits
                    plans
                    purchaseButton
                    footer
                }
                .padding(.horizontal, CorresSpace.page).padding(.bottom, 28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background {
                ZStack {
                    CorresPalette.canvas
                    RadialGradient(colors: [CorresPalette.accent.opacity(0.14), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.05), startRadius: 0, endRadius: 420)
                }
                .ignoresSafeArea()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .task { await entitlements.loadProducts() }
            .onChange(of: entitlements.isPro) { _, isPro in if isPro { dismiss() } }
            .alert("Corres Pro", isPresented: Binding(
                get: { entitlements.errorMessage != nil },
                set: { if !$0 { entitlements.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { entitlements.errorMessage = nil }
            } message: { Text(entitlements.errorMessage ?? "") }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            CorrespondenceMark(glow: true).frame(width: 84, height: 84)
            Text("Corres Pro").font(CorresType.display)
            Text("Everything that makes Corres Corres.")
                .font(.system(.title3, design: .serif).italic())
                .foregroundStyle(CorresPalette.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefit("text.alignleft", "Brief, Needs You and Waiting", "What needs you first, with the reason for each.")
            benefit("sparkle", "Apple Intelligence, on this iPhone", "Summaries, replies in your voice, rewrites and Ask your mail.")
            benefit("rectangle.stack", "Widgets, Siri and iPad", "Needs You on your Home Screen and Lock Screen.")
            benefit("lock", "Private by design", "Your mail is never sent to our servers or an AI company.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(CorresPalette.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Plans

    @ViewBuilder
    private var plans: some View {
        if entitlements.products.isEmpty && entitlements.productsUnavailable {
            VStack(spacing: 10) {
                Text("Plans couldn't load")
                    .font(.headline).foregroundStyle(CorresPalette.ink)
                Text("Check your connection and try again.")
                    .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                Button("Try Again") { Task { await entitlements.loadProducts() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CorresPalette.accent)
                    .padding(.top, 4)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if entitlements.products.isEmpty {
            ProgressView().frame(height: 180)
        } else {
            VStack(spacing: 10) {
                ForEach(entitlements.products, id: \.id) { product in planCard(product) }
            }
        }
    }

    private func planCard(_ product: Product) -> some View {
        let selected = selectedID == product.id
        return Button { selectedID = product.id } label: {
            HStack(spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? CorresPalette.accent : CorresPalette.tertiary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(planName(product)).font(.body.weight(.semibold)).foregroundStyle(CorresPalette.ink)
                        if let badge = badge(product) {
                            Text(badge).font(.caption2.weight(.bold)).tracking(0.6).textCase(.uppercase)
                                .foregroundStyle(CorresPalette.accentInk)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(CorresPalette.accent, in: Capsule())
                        }
                    }
                    Text(planDetail(product)).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(product.displayPrice).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(CorresPalette.ink)
                    Text(period(product)).font(.caption).foregroundStyle(CorresPalette.tertiary)
                }
            }
            .padding(16)
            .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? CorresPalette.accent : CorresPalette.line, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(CorresRowButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func planName(_ product: Product) -> String {
        switch product.id {
        case EntitlementStore.ProductID.annual: "Annual"
        case EntitlementStore.ProductID.monthly: "Monthly"
        default: "Lifetime"
        }
    }

    private func badge(_ product: Product) -> String? {
        switch product.id {
        case EntitlementStore.ProductID.annual: savings.map { "Save \($0)%" }
        case EntitlementStore.ProductID.lifetime: "Family"
        default: nil
        }
    }

    private func planDetail(_ product: Product) -> String {
        switch product.id {
        case EntitlementStore.ProductID.lifetime:
            return "Pay once. Shared with up to five family members."
        default:
            if let trial = trialText(product) { return "\(trial) free, then renews. Cancel anytime." }
            return "Renews automatically. Cancel anytime."
        }
    }

    private func period(_ product: Product) -> String {
        switch product.subscription?.subscriptionPeriod.unit {
        case .year: "per year"
        case .month: "per month"
        default: "once"
        }
    }

    /// The annual plan's saving against twelve monthly payments.
    private var savings: Int? {
        guard let annual = entitlements.product(EntitlementStore.ProductID.annual),
              let monthly = entitlements.product(EntitlementStore.ProductID.monthly), monthly.price > 0 else { return nil }
        let yearly = monthly.price * 12
        let saved = (yearly - annual.price) / yearly * 100
        let value = NSDecimalNumber(decimal: saved).doubleValue
        return value >= 5 ? Int(value.rounded()) : nil
    }

    private func trialText(_ product: Product) -> String? {
        guard entitlements.isEligibleForTrial, let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let period = offer.period
        switch period.unit {
        case .day: return period.value == 7 ? "1 week" : "\(period.value) days"
        case .week: return period.value == 2 ? "14 days" : "\(period.value) weeks"
        case .month: return period.value == 1 ? "1 month" : "\(period.value) months"
        default: return nil
        }
    }

    // MARK: - Purchase

    private var selectedProduct: Product? { entitlements.product(selectedID) }

    private var purchaseButton: some View {
        VStack(spacing: 10) {
            Button {
                if let product = selectedProduct { Task { await entitlements.purchase(product) } }
            } label: {
                if entitlements.isPurchasing {
                    ProgressView()
                } else {
                    Text(buttonTitle)
                }
            }
            .buttonStyle(CorresButtonStyle())
            .disabled(selectedProduct == nil || entitlements.isPurchasing)
            Text(finePrint)
                .font(.footnote).foregroundStyle(CorresPalette.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttonTitle: String {
        guard let product = selectedProduct else { return "Continue" }
        if let trial = trialText(product) { return "Start \(trial) free" }
        return product.id == EntitlementStore.ProductID.lifetime ? "Buy Lifetime · \(product.displayPrice)" : "Subscribe · \(product.displayPrice)"
    }

    private var finePrint: String {
        guard let product = selectedProduct else { return "" }
        if product.id == EntitlementStore.ProductID.lifetime {
            return "One payment of \(product.displayPrice). No subscription."
        }
        let per = product.subscription?.subscriptionPeriod.unit == .year ? "year" : "month"
        if let trial = trialText(product) {
            return "Free for \(trial), then \(product.displayPrice) a \(per). Cancel anytime in Settings before the trial ends and you won't be charged."
        }
        return "\(product.displayPrice) a \(per), renewing automatically. Cancel anytime in Settings."
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 22) {
                Button("Restore") { Task { await entitlements.restore() } }
                Button("Redeem code") {
                    // Close this sheet first so Apple's sheet isn't stacked on it.
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        await entitlements.presentRedeemSheet()
                    }
                }
            }
            .font(.subheadline.weight(.medium))
            HStack(spacing: 16) {
                Link("Terms of Use", destination: CorresLinks.terms)
                Text("·").foregroundStyle(CorresPalette.tertiary)
                Link("Privacy Policy", destination: CorresLinks.privacy)
            }
            .font(.caption)
            .foregroundStyle(CorresPalette.secondary)
        }
    }
}

/// Stands in for a Pro screen when Pro isn't active: what it does, and one
/// way in. Mail itself always stays usable.
struct ProLockView: View {
    let destination: Destination
    let onUnlock: () -> Void
    let onOpenMail: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            Image(systemName: destination.systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(CorresPalette.accent)
            Text(destination.rawValue).font(CorresType.title)
            Text(pitch)
                .font(.body).foregroundStyle(CorresPalette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Corres Pro free", action: onUnlock)
                .buttonStyle(CorresButtonStyle())
                .padding(.top, 6)
            Button("Go to Mail", action: onOpenMail)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CorresPalette.canvas)
    }

    private var pitch: String {
        switch destination {
        case .brief: "A one-sentence brief of your day, and what needs you first."
        case .needsYou: "The conversations that ask something of you, with the reason for each."
        case .waiting: "Everyone who owes you a reply, and for how long."
        case .ask: "Ask a question, get the answer from your own email, on this iPhone."
        case .mail: ""
        }
    }
}
