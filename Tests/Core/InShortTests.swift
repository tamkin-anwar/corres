import Foundation
import Testing
@testable import CorresCore

/// The In short card over a varied set of made-up emails: what each one
/// says, and that it says nothing rather than something wrong.
struct InShortTests {
    static let now = Date(timeIntervalSince1970: 1_793_000_000) // Oct 26, 2026

    struct Fixture: CustomTestStringConvertible {
        var name: String
        var subject: String
        var sender = "Sender"
        var email = "someone@example.com"
        var body: String
        var html: String?
        var bulk = false
        var promotion = false
        var labels: [String] = []
        var topic: InShort.Topic?
        /// Words the headline or quote must contain; nil: there must be none.
        var says: [String]?
        var notSays: [String] = []
        var testDescription: String { name }
    }

    static func card(_ fixture: Fixture, now: Date = now) -> InShort {
        let whole = MailDigest.readableText(body: fixture.body, html: fixture.html)
        let cleaned = MailDigest.clean(whole)
        let blocks = MailDigest.clean(MailDigest.readableText(body: fixture.body, html: fixture.html, cellBreaks: true))
        let kind: MailDigest.Kind = fixture.promotion ? .newsletter
            : MailDigest.kind(subject: fixture.subject, text: cleaned, senderEmail: fixture.email, isBulk: fixture.bulk,
                              looksAutomated: fixture.bulk, hasEvent: false, labelIds: fixture.labels)
        return InShort.make(subject: fixture.subject, sender: fixture.sender, senderEmail: fixture.email, whole: whole,
                            cleaned: cleaned, blocks: blocks, html: fixture.html, kind: kind, isBulk: fixture.bulk,
                            isPromotion: fixture.promotion, receivedAt: now.addingTimeInterval(-3_600), now: now)
    }

    @Test(arguments: fixtures) func says(_ fixture: Fixture) {
        let card = Self.card(fixture)
        let line = [card.headline, card.quote].compactMap { $0 }.joined(separator: " ")
        if let topic = fixture.topic { #expect(card.topic == topic, "\(card.lines)") }
        if let says = fixture.says {
            for words in says { #expect(line.localizedCaseInsensitiveContains(words), "\(fixture.name): \(card.lines)") }
        } else {
            #expect(line.isEmpty, "\(fixture.name) should say nothing: \(card.lines)")
        }
        for words in fixture.notSays { #expect(!line.localizedCaseInsensitiveContains(words), "\(fixture.name): \(card.lines)") }
    }

    /// Every quoted sentence is the email's own, word for word.
    @Test(arguments: fixtures) func quotesOnlyTheEmail(_ fixture: Fixture) {
        guard let quote = Self.card(fixture).quote else { return }
        let source = MailDigest.readableText(body: fixture.body, html: fixture.html, cellBreaks: true)
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(source.contains(quote), "\(fixture.name): \(quote)")
    }

    /// Most of this varied set gets a line. The rest are meant to say
    /// nothing: a short note from a person reads in full right below, and
    /// a promotion without an offer has nothing true to add.
    @Test func coverage() {
        let cards = Self.fixtures.map { Self.card($0) }
        let saying = cards.filter { !$0.saysOnlyWhereItIs }.count
        #expect(Double(saying) / Double(cards.count) >= 0.65, "\(saying) of \(cards.count)")
    }

    static let fixtures: [Fixture] = personal + work + money + deliveries + codes + alerts + sales + newsletters + world + more

    // MARK: More

    static let more: [Fixture] = [
        Fixture(name: "your own sent note", subject: "Notes from today", body: "Here are my notes from today's call. We agreed to ship on the 4th.",
                says: nil),
        Fixture(name: "account welcome", subject: "Welcome to Cloudflare", email: "noreply@cloud.example",
                body: "Welcome to Cloudflare! We're excited to have you.\nGet started\nExplore the dashboard", bulk: true,
                labels: ["CATEGORY_UPDATES"], says: nil),
        Fixture(name: "signed document attached", subject: "File 4400127 has been signed", email: "services@sign.example",
                body: "The signed version of the document is attached to this email.\nYou may also view the signed document by accessing your account.",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["is attached to this email"], notSays: ["You may also"]),
        Fixture(name: "footnote fine print", subject: "Beat football FOMO", email: "no-reply@video.example",
                body: "Every game, every Sunday.\n3 Free trial is for 7 days, then users will be charged the full price in effect at the time the trial starts.",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: nil),
        Fixture(name: "legal footer", subject: "Your September spending report is here", email: "support@credit.example",
                body: "See where your money went in September.\nBanking services provided by Community Federal Savings Bank, Member FDIC.",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: nil),
        Fixture(name: "inquiry received", subject: "Thanks for your inquiry", email: "info@shop.example",
                body: "Thank you for contacting us.\nOur team is reviewing your inquiry, and one of our associates will be in touch as soon as possible.",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["reviewing your inquiry"]),
        Fixture(name: "survey with a deadline", subject: "Survey: help us improve", email: "research@agency.example.gov",
                body: "Complete the survey by October 30 to make sure your experience is included in this important research.\nTake the survey",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["by October 30"]),
        Fixture(name: "Japanese code", subject: "認証コードのお知らせ", email: "no-reply@line.example",
                body: "認証コード：583920\nこのコードの有効期限は10分です。", bulk: true, topic: .code, says: ["583920"]),
    ]

    // MARK: People

    static let personal: [Fixture] = [
        Fixture(name: "short note", subject: "Lunch?", body: "Are you free for lunch on Thursday? Maya", topic: .personal, says: nil),
        Fixture(name: "long note with a buried ask", subject: "Trip planning",
                body: """
                Hi Sam,

                We had such a good time last weekend at the lake. The kids still talk about the boat, and Dad keeps sending photos of the fish he swears was bigger than it looks. I think we should do it again next summer, maybe for a whole week this time, with the cabins by the north shore.

                I've been looking at a few places and the prices look reasonable if we book early. There's one with a dock and a fire pit that sleeps ten.

                Could you send me your dates for July by Friday so I can hold the cabin?

                Love,
                Ana
                """, topic: .personal, says: nil),
        Fixture(name: "thank-you note", subject: "Thank you!", body: "Thank you so much for dinner last night. It was lovely to see you both.\n\nBest,\nJo",
                topic: .personal, says: nil),
        Fixture(name: "a reply in a thread", subject: "Re: Budget for Q4",
                body: "Sounds good, let's go with option B.\n\nOn Mon, Oct 20, 2026 at 9:14 AM Priya <priya@example.com> wrote:\n> Option A or B?",
                topic: .personal, says: nil),
    ]

    // MARK: Work

    static let work: [Fixture] = [
        Fixture(name: "job offer, as Amazon writes it", subject: "Your Amazon Offer Details – Please Read", sender: "Amazon Recruiting",
                email: "no-reply@amazon.jobs",
                body: """
                Congratulations Sam, you got the job!

                We are thrilled to extend you an offer to join Amazon as an Area Manager. Please review your offer letter, attached. Reply to this email with any questions or needs.

                Access your documents at atoz.

                Review your Placement
                Site
                PSP1
                Address
                1010 West Fourth Street, Beaumont, CA
                Building type
                NACF
                Start Date
                Monday, January 11, 2027
                """, bulk: true, topic: .jobOffer,
                says: ["Area Manager at Amazon", "Starts Monday, January 11, 2027"]),
        Fixture(name: "job offer letter", subject: "Offer of employment", sender: "Lena Ortiz", email: "lena@brightpath.io",
                body: "Dear Sam,\n\nI'm delighted to offer you the position of Senior Designer at Brightpath. Your start date is March 2, 2027.\n\nPlease sign and return the attached letter by Friday.\n\nLena",
                topic: .jobOffer, says: ["Senior Designer"]),
        Fixture(name: "job alert from LinkedIn", subject: "Stripe is hiring a Product Operations Manager", sender: "LinkedIn Job Alerts",
                email: "jobalerts-noreply@linkedin.com",
                body: "Your job alert for operations manager\nProduct Operations Manager\nStripe\nSan Francisco, CA\n$150,000 - $190,000 a year\nView job",
                bulk: true, topic: .jobAlert, says: ["not a reply from an employer"]),
        Fixture(name: "job alert from Indeed with a pay filter", subject: "Director of Operations at Acme. 29 more $5000 A Month jobs",
                email: "donotreply@jobalert.indeed.com",
                body: "29 more $5000 A Month jobs in Los Angeles\nDirector of Operations\nAcme\nFrom $250 a day\nApply now",
                bulk: true, topic: .jobAlert, says: ["Indeed"]),
        Fixture(name: "interview scheduling", subject: "Interview with Northwind", sender: "Kim Lee", email: "kim@northwind.com",
                body: "Hi Sam,\n\nThanks for applying. We'd like to invite you to a 30-minute interview with our design lead. Could you share three times that work for you next week?\n\nKim",
                topic: .personal, says: nil),
        Fixture(name: "a document is ready", subject: "Your data is ready for download", email: "no-reply@mail.example.com",
                body: "Your data is ready for download The requested data export has been processed and is now available.\nDownload data\nThis link expires in 7 days.",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["has been processed"]),
        Fixture(name: "project paused", subject: "Your project atlas has been paused.", email: "team@supa.example",
                body: "Hi there,\n\nTo optimize cloud resources, we automatically pause free-tier projects after 7 days of inactivity.\n\nYour project atlas from your organization\nhas been paused.\n\nYou can unpause your project from the dashboard within 90 days.",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: nil),
        Fixture(name: "a calendar invitation", subject: "Invitation: Design review @ Thu Oct 29, 2026 3pm - 4pm (PDT)", email: "calendar-notification@google.com",
                body: "Design review\nThursday Oct 29, 2026 3pm – 4pm (Pacific Time)\nJoin with Google Meet\nGoing? Yes No Maybe",
                bulk: true, topic: .invitation, says: nil),
    ]

    // MARK: Money

    static let money: [Fixture] = [
        Fixture(name: "receipt", subject: "Your receipt from Render #2910-3801", email: "receipts@stripe.com",
                body: "Receipt from Render\nAmount paid $18.50\nDate paid Oct 2, 2026\nReceipt number 2910-3801\nPayment method Visa - 4242",
                bulk: true, topic: .receipt, says: nil),
        Fixture(name: "failed payment", subject: "Your payment has failed", email: "no-reply@doordash.com",
                body: "We were unable to process your recent payment of $9.99 for DashPass. Please update your payment method.",
                bulk: true, topic: .receipt, says: nil),
        Fixture(name: "bill due", subject: "Your bill is ready", email: "billing@power.example",
                body: "Your statement is ready.\nAmount due $84.20\nDue date Nov 12, 2026\nPay now",
                bulk: true, topic: .receipt, says: nil),
        Fixture(name: "card charge alert", subject: "Sam, review your weekly financial alerts", email: "alerts@bank.example",
                body: "Weekly alerts\n$45.00 was charged to your checking account on 10/12.\nReview alerts",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["$45.00 was charged"]),
        Fixture(name: "subscription renewal", subject: "We hope you're enjoying Premium Student", email: "no-reply@music.example",
                body: "We wanted to send you a reminder.\nOn 2026-11-15 and each month thereafter, until you cancel, you will automatically be charged $5.99 a month.\nManage plan",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["charged $5.99 a month"]),
        Fixture(name: "autopay change run into a heading", subject: "A courtesy update regarding your account.", email: "no-reply@carrier.example",
                body: "",
                html: "<table><tr><td>Profile</td><td>Your Autopay date will change next month</td></tr></table><p>Hi Sam, Your scheduled automatic payment date will move to 6 days prior to your due date next month to ensure you have enough time to review your bill.</p>",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["will move to 6 days"], notSays: ["Hi Sam"]),
        Fixture(name: "rent reminder", subject: "Rent Payment Reminder", email: "office@apartments.example",
                body: "Dear Sam, This email is a friendly reminder that rent is due on the first of each month.\nThank you,\nThe Office",
                bulk: true, says: ["rent is due on the first"]),
        Fixture(name: "tax return due", subject: "IMPORTANT DUE DATE REMINDER", email: "noreply@tax.example.gov",
                body: "We are sending you an important due date reminder that you may have a return or report for the following account(s) due no later than 11/2/2026.\n<style>td{border:0}</style><table><tr><td>Sales and Use Tax</td></tr></table>",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["due no later than 11/2/2026"], notSays: ["style"]),
    ]

    // MARK: Deliveries

    static let deliveries: [Fixture] = [
        Fixture(name: "shipped", subject: "Your order has shipped", email: "ship@store.example",
                body: "Good news! Your order has shipped.\nEstimated delivery Thu, Oct 29\nTracking number 1Z999AA10123456784\nTrack package",
                bulk: true, topic: .delivery, says: nil),
        Fixture(name: "delivered", subject: "Delivered: your package", email: "ship@store.example",
                body: "Your package was delivered on Oct 21 at 2:14 PM.\nOrder 112-4471-2234",
                bulk: true, topic: .delivery, says: nil),
        Fixture(name: "order confirmed with only prose", subject: "Thank you for your order #CPX26284", email: "orders@parts.example",
                body: "Dear Sam Lee, We got your order! We will update you when it's ready to roll your way. Credit card purchases will reflect an authorization hold.",
                bulk: true, topic: .receipt, says: ["update you when"]),
    ]

    // MARK: Codes

    static let codes: [Fixture] = [
        Fixture(name: "sign-in code", subject: "Your verification code", email: "no-reply@accounts.example",
                body: "Your verification code is 482913. It expires in 10 minutes. Don't share it with anyone.",
                bulk: true, topic: .code, says: ["482913", "10"]),
        Fixture(name: "code that will expire", subject: "Verify Your Email Address", email: "notifications@patient.example",
                body: "Your verification code is 9214.\nThis code will expire in 20 minutes.",
                bulk: true, topic: .code, says: ["9214", "20"]),
        Fixture(name: "Indian bank OTP", subject: "OTP for transaction", email: "alerts@bank.example.in",
                body: "482913 is your OTP for a transaction of Rs. 1,500 at Amazon. Valid for 5 minutes. Do not share it.",
                bulk: true, topic: .code, says: ["482913"]),
    ]

    // MARK: Alerts

    static let alerts: [Fixture] = [
        Fixture(name: "app given access", subject: "Security alert", email: "no-reply@accounts.google.com",
                body: "You allowed Corres access to some of your Google Account data\n\nsam@example.com\n\nIf you didn't allow Corres access to some of your Google Account data, someone else may be trying to access your Google Account data.\n\nCheck activity",
                bulk: true, labels: ["CATEGORY_UPDATES"], topic: .securityAlert, says: ["You allowed Corres access"]),
        Fixture(name: "new login run together", subject: "New login to your account", email: "noreply@x.example",
                body: "", html: "<table><tr><td>Your account has been accessed from a new IP address</td><td>We've noticed a new login Hi Sam, We're notifying you by email of a new login to your account: Time: Sat, 26 Sep 2026</td></tr></table>",
                bulk: true, labels: ["CATEGORY_UPDATES"], topic: .securityAlert, says: ["accessed from a new IP address"], notSays: ["Hi Sam"]),
        Fixture(name: "lock update", subject: "Important Security Update: Please Update Your Front Door Lock", email: "noreply@lock.example",
                body: "Hello Sam,\n\nWe’re asking you to install an important security update on your Acme Smart Lock® 2 as soon as possible. This email explains how.\n\nStart the update",
                bulk: true, labels: ["CATEGORY_UPDATES"], topic: .securityAlert, says: ["asking you to install"]),
        Fixture(name: "credit inquiry", subject: "A hard credit check was just added to your credit report", email: "notifications@credit.example",
                body: "A new inquiry was just added to your Transunion credit report.<sup>*</sup>\nSee details",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["new inquiry was just added"], notSays: ["<sup>"]),
        Fixture(name: "health portal update", subject: "Health portal update", email: "noreply@health.example",
                body: "Hi Sam, Northside Clinic has updated clinical information in your patient portal account.\nSign in to view it.",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["has updated clinical information"], notSays: ["Hi Sam"]),
        Fixture(name: "hard-wrapped plain text", subject: "Your temporary access code", email: "info@account.example",
                body: "Hi Lee Family,\n\nWe received a request for a temporary access code from the\ndevice below.\n\nGet Code",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["from the device below"]),
        Fixture(name: "appointment reminder", subject: "Your appointment is tomorrow", email: "patient@labs.example",
                body: "It's almost time for your appointment.\nTuesday, October 27, 2026 at 2:45 PM\n200 Main St, Springfield, IL 62701\nConfirmation number: 5550001234",
                bulk: true, labels: ["CATEGORY_UPDATES"], topic: .appointment, says: ["Oct 27"]),
        Fixture(name: "appointment with escaped entities", subject: "Your New Class Is Starting Soon", email: "advisor@school.example",
                body: "** This is a system generated message ** Hello Sam Lee, I hope you&#39;re doing well!\nYour next class starts on November 2. Review the schedule in the student portal.",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: ["starts on November 2"], notSays: ["&#39;", "system generated", "I hope"]),
    ]

    // MARK: Sales and promotions

    static let sales: [Fixture] = [
        Fixture(name: "sitewide sale", subject: "🍂 20% OFF SITEWIDE ends tomorrow!", email: "petco@e.store.example",
                body: "Fall into savings. Shop now.", bulk: true, promotion: true, topic: .sale, says: ["20% off sitewide"]),
        Fixture(name: "sale with schema.org offer", subject: "20% OFF Sitewide", email: "deals@e.store.example",
                body: "Shop now",
                html: #"<div itemscope itemtype="http://schema.org/DiscountOffer"><meta itemprop="description" content="20% OFF"/><meta itemprop="discountCode" content="FALLFEELS"/><meta itemprop="availabilityEnds" content="2026-11-02T23:59:59-0800"/></div><p>Shop now</p>"#,
                bulk: true, promotion: true, topic: .sale, says: ["20% off", "FALLFEELS", "Ends"]),
        Fixture(name: "pizza deal with JSON-LD code", subject: "Mix & Match Deal", email: "offers@pizza.example",
                body: "Order now",
                html: #"<script type="application/ld+json">[{"@context":"https://schema.org/","@type":"DiscountOffer","description":"50% OFF ALL PIZZAS AT MENU PRICE","discountCode":"9413"}]</script><p>Order now</p>"#,
                bulk: true, promotion: true, topic: .sale, says: ["50% off", "9413"]),
        Fixture(name: "standing free shipping banner", subject: "117 MINUTES LEFT!", email: "info@watches.example",
                body: "Free Shipping on Orders $100+\nOMEGA\nBREITLING\nShop now", bulk: true, promotion: true, says: nil),
        Fixture(name: "promotion with no offer", subject: "The Atlas GMT Is Back", email: "hello@watch.example",
                body: "Three zones, one icon. The Atlas GMT returns in two colorways.\nShop the collection",
                bulk: true, promotion: true, topic: .promotion, says: nil),
        Fixture(name: "promo code", subject: "Your wallet will love this", email: "hi@grocer.example",
                body: "Get 40% off your first order. Use code TRYPANDA at checkout.", bulk: true, promotion: true,
                topic: .sale, says: ["40% off", "TRYPANDA"]),
        Fixture(name: "marketing slogan in Updates", subject: "Don't go anywhere without your favorite tunes", email: "no-reply@music.example",
                body: "Stay connected to the music you love\nEnjoy best-in-class music recommendations based on your music taste –\nTry it",
                bulk: true, labels: ["CATEGORY_UPDATES"], says: nil),
        Fixture(name: "referral pitch", subject: "Thanks for Shopping With Us!", email: "no-reply@parts.example",
                body: "Hi Sam,\n\nThanks for choosing us!\n\nWant to share the love and earn 10% off for you and your crew?\n\nJoin our referral program today.",
                bulk: true, promotion: true, says: nil),
    ]

    // MARK: Newsletters

    static let newsletters: [Fixture] = [
        Fixture(name: "long newsletter", subject: "☕ Shuffled around", email: "crew@morningbrew.com",
                body: (0..<24).map { "Story \($0): Markets moved today as investors weighed a new report on prices, wages and what the central bank might do next week, while the biggest tech companies reported earnings that beat what analysts expected." }.joined(separator: "\n\n"),
                bulk: true, labels: ["CATEGORY_UPDATES"], topic: .newsletter, says: ["minutes to read"]),
        Fixture(name: "news digest never quoted", subject: "Your Morning Digest: a storm moves north", email: "no-reply@e.smartnews.com",
                body: "Man shot in downtown dispute dies, police say.\nFederal Reserve was warned about savings rates.\nRead more",
                bulk: true, labels: ["CATEGORY_UPDATES"], topic: .newsletter, notSays: ["shot", "Federal"]),
        Fixture(name: "short newsletter", subject: "▽ Hands-on with a new tablet", email: "vergedaily@theverge.com",
                body: "The Alexa line is also Amazon's first tablet to run full Android.\nRead more", bulk: true,
                labels: ["CATEGORY_UPDATES"], topic: .newsletter, says: nil),
        Fixture(name: "placeholder plain part", subject: "☕ Think local", email: "itbrew@morningbrew.com",
                body: "Looks like your email provider is scrambling the email :( Click here to read it in full online",
                html: "<p>" + (0..<8).map { _ in "Cities are rethinking how they buy software, and local IT teams say the change has been slow but steady across the region this year." }.joined(separator: "</p><p>") + "</p>",
                bulk: true, labels: ["CATEGORY_UPDATES"], topic: .newsletter, notSays: ["scrambling"]),
    ]

    // MARK: Around the world

    static let world: [Fixture] = [
        Fixture(name: "Spanish shipping", subject: "Tu pedido ha sido enviado", email: "envios@tienda.example",
                body: "¡Hola! Tu pedido ha sido enviado.\nEntrega estimada: 12 de noviembre\nNúmero de seguimiento: 1Z999AA1",
                bulk: true, topic: .delivery, says: nil),
        Fixture(name: "Bengali OTP", subject: "আপনার ওটিপি", email: "alerts@bkash.example",
                body: "আপনার যাচাইকরণ কোড 482913। এটি কাউকে দেবেন না।", bulk: true, topic: .code, says: ["482913"]),
        Fixture(name: "Japanese shipping", subject: "ご注文の商品を発送しました", email: "shop@rakuten.example",
                body: "ご注文の商品を発送しました。\nお届け予定日：11月12日\nお問い合わせ伝票番号：1234-5678-9012",
                bulk: true, topic: .delivery, says: nil),
        Fixture(name: "Spanish personal note", subject: "¿Cenamos el viernes?", sender: "Lucía", email: "lucia@example.com",
                body: "¡Hola! ¿Te apetece cenar el viernes en casa? Avísame. Lucía", topic: .personal, says: nil),
        Fixture(name: "Bengali notice", subject: "বিল পরিশোধের অনুস্মারক", email: "billing@desco.example",
                body: "প্রিয় গ্রাহক, আপনার বিদ্যুৎ বিল ৳1,250 পরিশোধের শেষ তারিখ ১৫ নভেম্বর।", bulk: true),
        Fixture(name: "Japanese newsletter", subject: "今週のニュース", email: "news@media.example",
                body: String(repeating: "今週は新しい製品が発表され、多くの人が注目しています。市場の反応も大きく、専門家はさらに成長すると見ています。", count: 20),
                bulk: true, labels: ["CATEGORY_UPDATES"], topic: .newsletter, says: ["minutes"], notSays: ["今週は"]),
    ]
}
