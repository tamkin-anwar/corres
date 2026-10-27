import json, sys

# Each language: subtitle, keywords, promo (ios/mac), and description parts.
# Lists of (ios, mac) pairs; None means the line is left out on that platform.
L = {}

L["ja"] = dict(
 subtitle="要対応がひと目でわかるメール",
 keywords="受信トレイ,メール,電子メール,優先,ニュースレター,要約,返信,フォローアップ,整理,集中,プライバシー,オフライン,迷惑メール",
 promo=("Gmail、Outlook、iCloudなどを1つの受信ボックスに。Corresはあなたへの用件から開き、その理由を示し、メールをiPhoneに保ちます。",
        "Gmail、Outlook、iCloudなどを1つの受信ボックスに。Corresはあなたへの用件から開き、その理由を示し、メールをMacに保ちます。"),
 intro=("Corresは「要対応」から開きます。Gmail、Outlook、iCloud、そのほかほとんどのメールアカウントを1つの受信ボックスにまとめ、iPhone上で読み、振り分けます。あなたに何かを求めるメールが先頭に並び、それぞれに理由が添えられます。ほかのメールはタップひとつ先で、準備ができるまで静かに待っています。",
        "Corresは「要対応」から開きます。Gmail、Outlook、iCloud、そのほかほとんどのメールアカウントを1つの受信ボックスにまとめ、Mac上で読み、振り分けます。あなたに何かを求めるメールが先頭に並び、それぞれに理由が添えられます。ほかのメールはクリックひとつ先で、準備ができるまで静かに待っています。"),
 sections=[
  (None, ("本物のMacアプリ", [
     "メールのキーボードショートカット、⌘Kでどのメールボックスやコマンドも開け、ドラッグで整理。",
     "会話を別ウインドウで、ラベルとフォルダをサイドバーに、メールはSpotlightで検索。",
     "1回の購入でiPhone、iPad、MacのCorresが使えます。"])),
  (("要対応と返信待ち（Corres Pro）", [
     "「要対応」には、あなたへの質問、判断、期限があるメールが「まもなく期限」と「時間のあるときに」に分かれて入ります。",
     "「返信待ち」には、返信がまだのメールが並び、フォローアップの時期をお知らせします。",
     "済んだメールはスワイプで片付け。長押しで移動すれば、Corresが学びます。"]),
   ("要対応と返信待ち（Corres Pro）", [
     "「要対応」には、あなたへの質問、判断、期限があるメールが「まもなく期限」と「時間のあるときに」に分かれて入ります。",
     "「返信待ち」には、返信がまだのメールが並び、フォローアップの時期をお知らせします。",
     "済んだメールはキーひとつでアーカイブ。移動すれば、Corresが学びます。"])),
  (("すべてのアカウント", [
     "Gmail、Google Workspace、Outlook.com、Microsoft 365、iCloudメールに加え、Yahoo、AOL、Fastmail、Zoho、職場のサーバも、アドレスとパスワードで使えます。",
     "メイン、プロモーション、ソーシャル、更新をCorresが振り分け、あなたが移したメールから学びます。",
     "アカウントごとに色、名前、署名、通知を設定できます。",
     "ルールは届いたメールを振り分けます。GmailやOutlookの側でも動くので、Corresを閉じていても働きます。",
     "Outlookの新着メールは数秒で通知されます。iCloudも「即時通知」をオンにすれば同様です。"]), "same-drop-last"),
  (("新しい差出人", [
     "初めての人からのメールの扱いは、「すべて確認する」「企業だけ確認する」「『新規』として表示」「すべて受け入れる」から選べます。",
     "会社ごとまとめて許可やブロックができ、気が変わったら取り消せます。"]), "same"),
  (("答えてくれる検索", [
     "すべてのアカウントをまとめて検索。アーカイブ済みのメールも含み、from:、has:attachment、is:unreadなどで絞り込めます。",
     "Corres Proなら、「フライトはいつ？」のように質問すると、あなた自身のメールから答えが返ってきます。",
     "ホーム画面の検索からも会話を探せます。"]),
   ("答えてくれる検索", [
     "すべてのアカウントをまとめて検索。アーカイブ済みのメールも含み、from:、has:attachment、is:unreadなどで絞り込めます。",
     "Corres Proなら、「フライトはいつ？」のように質問すると、あなた自身のメールから答えが返ってきます。",
     "Spotlightからも会話を探せます。"])),
  (("招待", [
     "あなたのタイムゾーンでの時刻、場所、参加するビデオ通話、その時間が空いているかがわかります。",
     "メールから承諾、未定、辞退を選び、タップひとつでカレンダーに追加できます。"]),
   ("招待", [
     "あなたのタイムゾーンでの時刻、場所、参加するビデオ通話、その時間が空いているかがわかります。",
     "メールから承諾、未定、辞退を選び、クリックひとつでカレンダーに追加できます。"])),
  (("作成", [
     "下書き、あとで送信、送信の取り消し、テンプレート、返信がないときのリマインダー。",
     "複数の署名、別の送信アドレス、太字、リスト、リンク。",
     "返信の候補と書き直し（Corres Pro）は、送信済みメールから学んだあなたの挨拶、結び、長さで書かれます。あなたが送るまで何も送信されません。",
     "Siriに頼んで、Corresでメールを書く、送る、探すことができます。",
     "どのアプリからでも共有ボタンでメールを書けます。"]),
   ("作成", [
     "下書き、あとで送信、送信の取り消し、テンプレート、返信がないときのリマインダー。",
     "複数の署名、別の送信アドレス、太字、リスト、リンク。",
     "返信の候補と書き直し（Corres Pro）は、送信済みメールから学んだあなたの挨拶、結び、長さで書かれます。あなたが送るまで何も送信されません。",
     "Siriに頼んで、Corresでメールを書く、送る、探すことができます。"])),
  (("オフライン対応と同期", [
     "電波がなくてもアーカイブ、削除、フラグ付けができます。変更はオンラインに戻ったときに反映されます。",
     "振り分け、スヌーズ、ピン、許可、ブロックはiCloudでほかのデバイスにも反映されます。メール自体は送られません。"]),
   ("オフライン対応と同期", [
     "接続がなくてもアーカイブ、削除、フラグ付けができます。変更はオンラインに戻ったときに反映されます。",
     "振り分け、スヌーズ、ピン、許可、ブロックはiCloudでiPhone、iPad、Macの間で共有されます。メール自体は送られません。"])),
  (("Apple Watch", [
     "Corres Proなら、「要対応」のメールとその理由を、手首の上とウォッチフェイスで確認できます。",
     "音声、スクリブル、用意された返事で返信するか、「対応済み」にできます。返信はiPhoneから送信されます。"]), None),
  (("世界中で", [
     "Corresは日本語、英語、簡体字中国語、韓国語、ドイツ語、フランス語、スペイン語、ポルトガル語、ベンガル語に対応しています。",
     "期限、領収書、配達、確認コード、予定をこの9つの言語で読み取り、週末はお住まいの地域に合わせます。"]), "same"),
  (("Apple Intelligenceの有無にかかわらず", [
     "「要対応」とその理由、金額、日付、注文番号などの重要な情報は、どのiPhoneとiPadでも使えます。",
     "Apple Intelligenceがあれば、Corres Proは要約と返信の候補もiPhone上で作成し、表示する前にメールと照らし合わせて確認します。"]),
   ("Apple Intelligenceの有無にかかわらず", [
     "「要対応」とその理由、金額、日付、注文番号などの重要な情報は、どのMacでも使えます。",
     "Apple Intelligenceがあれば、Corres Proは要約と返信の候補もMac上で作成し、表示する前にメールと照らし合わせて確認します。"])),
  (("プライバシー", [
     "メールはプロバイダからiPhoneへ直接届きます。私たちのサーバに届くことはありません。",
     "リモート画像とトラッキングピクセルは許可するまでブロックされ、配信停止はワンタップです。",
     "広告はありません。データが販売されたり、AIの学習に使われたりすることはありません。"]),
   ("プライバシー", [
     "メールはプロバイダからMacへ直接届きます。私たちのサーバに届くことはありません。",
     "リモート画像とトラッキングピクセルは許可するまでブロックされ、配信停止はワンクリックです。",
     "広告はありません。データが販売されたり、AIの学習に使われたりすることはありません。"])),
 ],
 pro=("無料とPro", "メールは無料です。すべてのアカウントで閲覧、作成、検索、整理ができます。Corres Proでは「要対応」「返信待ち」、検索での回答、要約、返信の候補が使えます。Proは無料トライアルから始まり、その後は月額または年額で自動更新されます。期間終了の24時間前までに{cancel}でキャンセルしない限り更新されます。",
      {"ios": "iPhoneの設定", "mac": "Apple Accountの設定"}),
 terms="利用規約", privacy="プライバシー",
)

L["zh-Hans"] = dict(
 subtitle="知道什么需要你处理的邮件",
 keywords="邮件,电子邮件,收件箱,优先,邮件管理,摘要,回复,跟进,筛选,专注,隐私,离线,订阅,邮箱",
 promo=("Gmail、Outlook、iCloud 等邮箱汇集在一个收件箱。Corres 先显示需要你处理的邮件并说明原因，你的邮件只保留在 iPhone 上。",
        "Gmail、Outlook、iCloud 等邮箱汇集在一个收件箱。Corres 先显示需要你处理的邮件并说明原因，你的邮件只保留在 Mac 上。"),
 intro=("Corres 打开时先显示需要你处理的邮件。Gmail、Outlook、iCloud 以及几乎所有其他邮件账户都在一个收件箱里，在你的 iPhone 上阅读和分类。向你提出请求的邮件排在最前，每封都附上原因。其余邮件轻点即达，安静地等你准备好。",
        "Corres 打开时先显示需要你处理的邮件。Gmail、Outlook、iCloud 以及几乎所有其他邮件账户都在一个收件箱里，在你的 Mac 上阅读和分类。向你提出请求的邮件排在最前，每封都附上原因。其余邮件就在一次点按之外，安静地等你准备好。"),
 sections=[
  (None, ("真正的 Mac App", [
     "沿用“邮件”的键盘快捷键，⌘K 可打开任意邮箱或命令，拖移即可归档。",
     "对话可在独立窗口中打开，标签和文件夹在边栏中，邮件可在“聚焦”中找到。",
     "一次购买，即可在 iPhone、iPad 和 Mac 上使用 Corres。"])),
  (("需要你与等待中（Corres Pro）", [
     "“需要你”收纳带有问题、决定或截止日期的邮件，分为“即将到期”和“有空再看”。",
     "“等待中”列出你发出但尚未收到回复的邮件，并在该跟进时提醒你。",
     "处理完的邮件轻扫即可移走。按住可移动邮件，Corres 会学习。"]),
   ("需要你与等待中（Corres Pro）", [
     "“需要你”收纳带有问题、决定或截止日期的邮件，分为“即将到期”和“有空再看”。",
     "“等待中”列出你发出但尚未收到回复的邮件，并在该跟进时提醒你。",
     "处理完的邮件按一个键即可归档。移动邮件，Corres 会学习。"])),
  (("你的所有账户", [
     "Gmail、Google Workspace、Outlook.com、Microsoft 365 和 iCloud 邮件，以及 Yahoo、AOL、Fastmail、Zoho 或工作服务器，用你的地址和密码添加。",
     "Corres 将邮件分为主要、促销、社交和动态，并从你移动的邮件中学习。",
     "每个账户都有自己的颜色、名称、签名和通知设置。",
     "规则会在邮件到达时自动整理，还能直接在 Gmail 和 Outlook 中运行，即使 Corres 关闭也照常生效。",
     "Outlook 的新邮件几秒内就会通知你，开启“即时通知”后 iCloud 也一样。"]), "same-drop-last"),
  (("新发件人", [
     "陌生人的第一封邮件如何处理由你决定：全部先审核、只审核公司、显示并标为新，或全部接收。",
     "可一次允许或屏蔽整家公司，改变主意也能撤销。"]), "same"),
  (("会回答问题的搜索", [
     "一次搜索所有账户，包括已归档的邮件，支持 from:、has:attachment 和 is:unread 等筛选。",
     "有了 Corres Pro，问一句“我的航班是什么时候？”，就能从你自己的邮件中得到答案。",
     "也能在主屏幕的搜索中找到任意对话。"]),
   ("会回答问题的搜索", [
     "一次搜索所有账户，包括已归档的邮件，支持 from:、has:attachment 和 is:unread 等筛选。",
     "有了 Corres Pro，问一句“我的航班是什么时候？”，就能从你自己的邮件中得到答案。",
     "也能在“聚焦”中找到任意对话。"])),
  (("邀请", [
     "查看你所在时区的时间、地点、要加入的视频通话，以及你是否有空。",
     "直接在邮件中接受、待定或拒绝，轻点一下即可添加到日历。"]),
   ("邀请", [
     "查看你所在时区的时间、地点、要加入的视频通话，以及你是否有空。",
     "直接在邮件中接受、待定或拒绝，点按一下即可添加到日历。"])),
  (("写邮件", [
     "草稿、稍后发送、撤销发送、模板，以及无人回复时的提醒。",
     "多个签名、其他发件地址，以及粗体、列表和链接。",
     "建议回复和改写（Corres Pro）会沿用你的问候语、结尾和篇幅，这些都从你发出的邮件中学习。在你发送之前，什么都不会发出。",
     "让 Siri 在 Corres 中撰写、发送或查找邮件。",
     "在任何 App 中都能通过共享按钮写邮件。"]),
   ("写邮件", [
     "草稿、稍后发送、撤销发送、模板，以及无人回复时的提醒。",
     "多个签名、其他发件地址，以及粗体、列表和链接。",
     "建议回复和改写（Corres Pro）会沿用你的问候语、结尾和篇幅，这些都从你发出的邮件中学习。在你发送之前，什么都不会发出。",
     "让 Siri 在 Corres 中撰写、发送或查找邮件。"])),
  (("离线与同步", [
     "没有信号也能归档、删除和加旗标。恢复联网后，更改会自动完成。",
     "你的分类、稍后提醒、置顶、允许和屏蔽会通过 iCloud 同步到你的其他设备。你的邮件不会。"]),
   ("离线与同步", [
     "没有网络也能归档、删除和加旗标。恢复联网后，更改会自动完成。",
     "你的分类、稍后提醒、置顶、允许和屏蔽会通过 iCloud 在 iPhone、iPad 和 Mac 之间同步。你的邮件不会。"])),
  (("Apple Watch", [
     "有了 Corres Pro，可在手腕上和表盘上查看“需要你”的邮件及其原因。",
     "用语音、随手写或现成的回复来回复，或标为“已处理”。回复通过你的 iPhone 发送。"]), None),
  (("面向全球", [
     "Corres 支持简体中文、英语、日语、韩语、德语、法语、西班牙语、葡萄牙语和孟加拉语。",
     "截止日期、收据、快递、验证码和日程在这九种语言中都能识别，周末按你所在的地区计算。"]), "same"),
  (("无论有没有 Apple 智能", [
     "“需要你”、其原因，以及金额、日期和订单号等关键信息，在每台 iPhone 和 iPad 上都能使用。",
     "有了 Apple 智能，Corres Pro 还会在 iPhone 本机上生成摘要和建议回复，并在显示前对照邮件核实。"]),
   ("无论有没有 Apple 智能", [
     "“需要你”、其原因，以及金额、日期和订单号等关键信息，在每台 Mac 上都能使用。",
     "有了 Apple 智能，Corres Pro 还会在 Mac 本机上生成摘要和建议回复，并在显示前对照邮件核实。"])),
  (("隐私", [
     "你的邮件从服务商直接传到你的 iPhone。我们的服务器从不接收。",
     "远程图片和追踪像素在你允许前一律拦截，退订只需轻点一下。",
     "没有广告。你的数据绝不会被出售或用于训练 AI。"]),
   ("隐私", [
     "你的邮件从服务商直接传到你的 Mac。我们的服务器从不接收。",
     "远程图片和追踪像素在你允许前一律拦截，退订只需点按一下。",
     "没有广告。你的数据绝不会被出售或用于训练 AI。"])),
 ],
 pro=("免费与 Pro", "“邮件”免费：可阅读、撰写、搜索和整理所有账户。Corres Pro 新增“需要你”、“等待中”、搜索中的回答、摘要和建议回复。Pro 从免费试用开始，之后按月或按年自动续订，除非你在当期结束前至少 24 小时在{cancel}中取消。",
      {"ios": "iPhone 的“设置”", "mac": "Apple 账户设置"}),
 terms="条款", privacy="隐私",
)

L["de-DE"] = dict(
 subtitle="Mail, die mitdenkt",
 keywords="posteingang,email,mail,priorität,newsletter,zusammenfassung,antworten,nachfassen,fokus,privat",
 promo=("Gmail, Outlook, iCloud und mehr in einem Eingang. Corres öffnet mit den E-Mails, die dich brauchen, sagt warum und hält deine E-Mails auf deinem iPhone.",
        "Gmail, Outlook, iCloud und mehr in einem Eingang. Corres öffnet mit den E-Mails, die dich brauchen, sagt warum und hält deine E-Mails auf deinem Mac."),
 intro=("Corres öffnet mit dem, was dich braucht. Gmail, Outlook, iCloud und fast jeder andere E-Mail-Account landen in einem Eingang, gelesen und sortiert auf deinem iPhone. Die E-Mails, die etwas von dir wollen, stehen oben, jeweils mit dem Grund. Der Rest wartet einen Tipp entfernt, ruhig, bis du so weit bist.",
        "Corres öffnet mit dem, was dich braucht. Gmail, Outlook, iCloud und fast jeder andere E-Mail-Account landen in einem Eingang, gelesen und sortiert auf deinem Mac. Die E-Mails, die etwas von dir wollen, stehen oben, jeweils mit dem Grund. Der Rest wartet einen Klick entfernt, ruhig, bis du so weit bist."),
 sections=[
  (None, ("EINE ECHTE MAC-APP", [
     "Die Tastaturkurzbefehle von Mail, ⌘K zum Öffnen jedes Postfachs oder Befehls und Ziehen zum Ablegen.",
     "Konversationen in eigenen Fenstern, Labels und Ordner in der Seitenleiste und deine E-Mails in Spotlight.",
     "Ein Kauf gilt für Corres auf iPhone, iPad und Mac."])),
  (("BRAUCHT DICH UND WARTET (CORRES PRO)", [
     "„Braucht dich“ sammelt E-Mails mit einer Frage, einer Entscheidung oder einer Frist für dich, aufgeteilt in „Bald fällig“ und „Wenn du Zeit hast“.",
     "„Wartet“ zeigt E-Mails, die du gesendet hast und auf die noch keine Antwort kam, und erinnert dich ans Nachfassen.",
     "Streich eine E-Mail weg, wenn sie erledigt ist. Lange drücken zum Bewegen, und Corres lernt dazu."]),
   ("BRAUCHT DICH UND WARTET (CORRES PRO)", [
     "„Braucht dich“ sammelt E-Mails mit einer Frage, einer Entscheidung oder einer Frist für dich, aufgeteilt in „Bald fällig“ und „Wenn du Zeit hast“.",
     "„Wartet“ zeigt E-Mails, die du gesendet hast und auf die noch keine Antwort kam, und erinnert dich ans Nachfassen.",
     "Archiviere eine E-Mail mit einer Taste, wenn sie erledigt ist. Bewege eine, und Corres lernt dazu."])),
  (("ALLE DEINE ACCOUNTS", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365 und iCloud Mail, dazu Yahoo, AOL, Fastmail, Zoho oder ein Server bei der Arbeit, mit Adresse und Passwort.",
     "Allgemein, Werbung, Soziale Netzwerke und Updates, sortiert von Corres, das aus den E-Mails lernt, die du bewegst.",
     "Jeder Account hat eigene Farbe, eigenen Namen, eigene Signaturen und Mitteilungen.",
     "Regeln sortieren neue E-Mails und laufen auf Wunsch direkt in Gmail und Outlook, auch wenn Corres geschlossen ist.",
     "Neue E-Mails von Outlook melden sich in Sekunden, die von iCloud ebenso mit „Sofortige Mitteilungen“."]), "same-drop-last"),
  (("NEUE ABSENDER", [
     "Du entscheidest, wie erste E-Mails von Neuen ankommen, und erlaubst oder blockierst eine ganze Firma auf einmal."]), "same"),
  (("SUCHE, DIE ANTWORTET", [
     "Durchsuche alle Accounts auf einmal, archivierte E-Mails eingeschlossen.",
     "Mit Corres Pro stellst du eine Frage wie „Wann geht mein Flug?“ und bekommst die Antwort aus deinen eigenen E-Mails."]),
   ("SUCHE, DIE ANTWORTET", [
     "Durchsuche alle Accounts auf einmal, archivierte E-Mails eingeschlossen.",
     "Mit Corres Pro stellst du eine Frage wie „Wann geht mein Flug?“ und bekommst die Antwort aus deinen eigenen E-Mails.",
     "Finde jede Konversation auch über Spotlight."])),
  (("SCHREIBEN", [
     "Entwürfe, Später senden, Senden widerrufen, Vorlagen und eine Erinnerung, wenn niemand antwortet.",
     "Mehrere Signaturen, weitere Absenderadressen sowie Fett, Listen und Links.",
     "Antwortvorschläge und Umformulierungen mit Corres Pro, in deinem Stil, gelernt aus deinen gesendeten E-Mails. Nichts wird gesendet, bevor du es sendest.",
     "Bitte Siri, in Corres eine E-Mail zu schreiben, zu senden oder zu finden.",
     "Schreib eine E-Mail aus jeder App über die Teilen-Taste."]),
   ("SCHREIBEN", [
     "Entwürfe, Später senden, Senden widerrufen, Vorlagen und eine Erinnerung, wenn niemand antwortet.",
     "Mehrere Signaturen, weitere Absenderadressen sowie Fett, Listen und Links.",
     "Antwortvorschläge und Umformulierungen mit Corres Pro, in deinem Stil, gelernt aus deinen gesendeten E-Mails. Nichts wird gesendet, bevor du es sendest.",
     "Bitte Siri, in Corres eine E-Mail zu schreiben, zu senden oder zu finden."])),
  (("OFFLINE UND SYNCHRON", [
     "Archivieren, löschen und markieren ohne Netz. Deine Änderungen gehen durch, sobald du wieder online bist.",
     "Was du sortierst, erinnern lässt, anheftest, erlaubst und blockierst, folgt dir über iCloud auf deine anderen Geräte. Deine E-Mails nie."]),
   ("OFFLINE UND SYNCHRON", [
     "Archivieren, löschen und markieren ohne Verbindung. Deine Änderungen gehen durch, sobald du wieder online bist.",
     "Was du sortierst, erinnern lässt, anheftest, erlaubst und blockierst, folgt dir über iCloud zwischen iPhone, iPad und Mac. Deine E-Mails nie."])),
  (("APPLE WATCH", [
     "Mit Corres Pro: was dich braucht und warum, am Handgelenk und auf dem Zifferblatt.",
     "Antworte per Sprache, Kritzeln oder fertiger Antwort, oder markiere die E-Mail als erledigt. Gesendet wird über dein iPhone."]), None),
  (("WELTWEIT", [
     "Corres gibt es in neun Sprachen, und es erkennt in jeder davon Fristen, Belege, Lieferungen, Einmalcodes und Termine. Das Wochenende richtet sich nach deiner Region."]), "same"),
  (("MIT ODER OHNE APPLE INTELLIGENCE", [
     "„Braucht dich“, die Gründe dafür und wichtige Details wie Beträge, Termine und Bestellnummern funktionieren auf jedem iPhone und iPad.",
     "Mit Apple Intelligence schreibt Corres Pro außerdem Zusammenfassungen und Antwortvorschläge, direkt auf dem iPhone, und prüft jede davon an der E-Mail, bevor du sie siehst."]),
   ("MIT ODER OHNE APPLE INTELLIGENCE", [
     "„Braucht dich“, die Gründe dafür und wichtige Details wie Beträge, Termine und Bestellnummern funktionieren auf jedem Mac.",
     "Mit Apple Intelligence schreibt Corres Pro außerdem Zusammenfassungen und Antwortvorschläge, direkt auf dem Mac, und prüft jede davon an der E-Mail, bevor du sie siehst."])),
  (("DATENSCHUTZ", [
     "Deine E-Mails kommen von deinem Anbieter direkt auf dein iPhone. Unsere Server erhalten sie nie.",
     "Externe Bilder und Tracking-Pixel bleiben blockiert, bis du sie erlaubst, und Abmelden ist ein Tipp.",
     "Keine Werbung. Deine Daten werden nie verkauft oder zum Trainieren von KI verwendet."]),
   ("DATENSCHUTZ", [
     "Deine E-Mails kommen von deinem Anbieter direkt auf deinen Mac. Unsere Server erhalten sie nie.",
     "Externe Bilder und Tracking-Pixel bleiben blockiert, bis du sie erlaubst, und Abmelden ist ein Klick.",
     "Keine Werbung. Deine Daten werden nie verkauft oder zum Trainieren von KI verwendet."])),
 ],
 pro=("KOSTENLOS UND PRO", "„E-Mail“ ist kostenlos: lesen, schreiben, suchen und ordnen in jedem Account. Corres Pro bietet „Braucht dich“, „Wartet“, Antworten in der Suche, Zusammenfassungen und Antwortvorschläge. Pro beginnt mit einem kostenlosen Test und verlängert sich dann monatlich oder jährlich, sofern du nicht mindestens 24 Stunden vor Ende des Zeitraums in {cancel} kündigst.",
      {"ios": "den Einstellungen deines iPhone", "mac": "den Einstellungen deines Apple Accounts"}),
 terms="Nutzungsbedingungen", privacy="Datenschutz",
)

L["ko"] = dict(
 subtitle="꼭 필요한 메일을 먼저",
 keywords="이메일,메일,받은편지함,우선순위,뉴스레터,요약,답장,후속조치,정리,집중,개인정보,오프라인,스팸",
 promo=("Gmail, Outlook, iCloud 등을 하나의 받은 편지함에서. Corres는 나에게 필요한 메일부터 이유와 함께 보여주고, 메일은 iPhone에만 둡니다.",
        "Gmail, Outlook, iCloud 등을 하나의 받은 편지함에서. Corres는 나에게 필요한 메일부터 이유와 함께 보여주고, 메일은 Mac에만 둡니다."),
 intro=("Corres는 나에게 필요한 것부터 엽니다. Gmail, Outlook, iCloud를 비롯한 거의 모든 이메일 계정을 하나의 받은 편지함에 모아 iPhone에서 읽고 분류합니다. 나에게 무언가를 요청하는 메일이 이유와 함께 맨 위에 오고, 나머지 메일은 한 번 탭하면 닿는 곳에서 조용히 기다립니다.",
        "Corres는 나에게 필요한 것부터 엽니다. Gmail, Outlook, iCloud를 비롯한 거의 모든 이메일 계정을 하나의 받은 편지함에 모아 Mac에서 읽고 분류합니다. 나에게 무언가를 요청하는 메일이 이유와 함께 맨 위에 오고, 나머지 메일은 한 번 클릭하면 닿는 곳에서 조용히 기다립니다."),
 sections=[
  (None, ("진짜 Mac 앱", [
     "Mail의 키보드 단축키, 어느 메일함이나 명령이든 여는 ⌘K, 드래그로 정리.",
     "대화를 별도 윈도우로, 레이블과 폴더는 사이드바에, 메일은 Spotlight에서.",
     "한 번 구입으로 iPhone, iPad, Mac의 Corres를 모두 사용합니다."])),
  (("나에게 필요와 대기 중 (Corres Pro)", [
     "'나에게 필요'에는 질문, 결정, 마감이 있는 메일이 '곧 마감'과 '여유 있을 때'로 나뉘어 담깁니다.",
     "'대기 중'에는 보냈지만 아직 답장이 없는 메일이 모이고, 후속 조치할 때를 알려줍니다.",
     "끝난 메일은 쓸어넘겨 정리하세요. 길게 눌러 옮기면 Corres가 배웁니다."]),
   ("나에게 필요와 대기 중 (Corres Pro)", [
     "'나에게 필요'에는 질문, 결정, 마감이 있는 메일이 '곧 마감'과 '여유 있을 때'로 나뉘어 담깁니다.",
     "'대기 중'에는 보냈지만 아직 답장이 없는 메일이 모이고, 후속 조치할 때를 알려줍니다.",
     "끝난 메일은 키 하나로 보관하세요. 옮기면 Corres가 배웁니다."])),
  (("모든 계정", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365, iCloud 메일은 물론 Yahoo, AOL, Fastmail, Zoho, 회사 서버도 주소와 암호로 사용할 수 있습니다.",
     "기본, 프로모션, 소셜, 업데이트로 Corres가 분류하고, 내가 옮긴 메일에서 배웁니다.",
     "계정마다 색상, 이름, 서명, 알림을 따로 설정합니다.",
     "규칙이 도착한 메일을 분류하고, Gmail과 Outlook에서도 직접 실행되므로 Corres를 닫아 두어도 작동합니다.",
     "Outlook의 새로운 메일은 몇 초 안에 알림이 오고, iCloud도 '즉시 알림'을 켜면 마찬가지입니다."]), "same-drop-last"),
  (("새 보낸 사람", [
     "처음 보는 사람의 첫 이메일을 받는 방식을 고르세요: 모두 먼저 확인, 회사만 확인, 새로 표시해서 보기, 모두 받기.",
     "회사 전체를 한 번에 허용하거나 차단하고, 마음이 바뀌면 되돌릴 수 있습니다."]), "same"),
  (("답을 주는 검색", [
     "보관된 메일을 포함해 모든 계정을 한 번에 검색하고, from:, has:attachment, is:unread 같은 필터를 사용하세요.",
     "Corres Pro에서는 '내 항공편이 언제지?'처럼 물으면 내 메일에서 답을 찾아줍니다.",
     "홈 화면의 검색에서도 대화를 찾을 수 있습니다."]),
   ("답을 주는 검색", [
     "보관된 메일을 포함해 모든 계정을 한 번에 검색하고, from:, has:attachment, is:unread 같은 필터를 사용하세요.",
     "Corres Pro에서는 '내 항공편이 언제지?'처럼 물으면 내 메일에서 답을 찾아줍니다.",
     "Spotlight에서도 대화를 찾을 수 있습니다."])),
  (("초대", [
     "내 시간대 기준 시간, 장소, 참여할 화상 통화, 그 시간에 비어 있는지 확인하세요.",
     "메일에서 바로 수락, 미정, 거절하고, 한 번 탭으로 캘린더에 추가합니다."]),
   ("초대", [
     "내 시간대 기준 시간, 장소, 참여할 화상 통화, 그 시간에 비어 있는지 확인하세요.",
     "메일에서 바로 수락, 미정, 거절하고, 한 번 클릭으로 캘린더에 추가합니다."])),
  (("작성", [
     "임시 저장, 나중에 보내기, 보내기 취소, 템플릿, 답장이 없을 때 알림.",
     "여러 서명, 다른 보내는 주소, 굵게, 목록, 링크.",
     "추천 답장과 다시 쓰기(Corres Pro)는 보낸 메일에서 배운 나의 인사말, 맺음말, 길이를 따릅니다. 직접 보내기 전에는 아무것도 전송되지 않습니다.",
     "Siri에게 Corres에서 이메일을 쓰거나 보내거나 찾아 달라고 하세요.",
     "어느 앱에서든 공유 버튼으로 이메일을 쓸 수 있습니다."]),
   ("작성", [
     "임시 저장, 나중에 보내기, 보내기 취소, 템플릿, 답장이 없을 때 알림.",
     "여러 서명, 다른 보내는 주소, 굵게, 목록, 링크.",
     "추천 답장과 다시 쓰기(Corres Pro)는 보낸 메일에서 배운 나의 인사말, 맺음말, 길이를 따릅니다. 직접 보내기 전에는 아무것도 전송되지 않습니다.",
     "Siri에게 Corres에서 이메일을 쓰거나 보내거나 찾아 달라고 하세요."])),
  (("오프라인과 동기화", [
     "신호가 없어도 보관, 삭제, 깃발 표시가 됩니다. 다시 온라인이 되면 변경 사항이 반영됩니다.",
     "분류, 다시 알림, 고정, 허용, 차단은 iCloud로 다른 기기에도 이어집니다. 메일 자체는 이동하지 않습니다."]),
   ("오프라인과 동기화", [
     "연결이 없어도 보관, 삭제, 깃발 표시가 됩니다. 다시 온라인이 되면 변경 사항이 반영됩니다.",
     "분류, 다시 알림, 고정, 허용, 차단은 iCloud로 iPhone, iPad, Mac 사이에 이어집니다. 메일 자체는 이동하지 않습니다."])),
  (("Apple Watch", [
     "Corres Pro에서는 '나에게 필요'한 메일과 그 이유를 손목 위와 워치 페이스에서 확인하세요.",
     "음성, 손글씨 또는 준비된 답장으로 답하거나 '처리됨'으로 표시하세요. 답장은 iPhone을 통해 보내집니다."]), None),
  (("전 세계에서", [
     "Corres는 한국어, 영어, 일본어, 중국어 간체, 독일어, 프랑스어, 스페인어, 포르투갈어, 벵골어를 지원합니다.",
     "마감, 영수증, 배송, 인증 코드, 일정을 이 9개 언어 모두에서 알아보고, 주말은 사는 지역에 맞춥니다."]), "same"),
  (("Apple Intelligence가 있든 없든", [
     "'나에게 필요', 그 이유, 금액, 날짜, 주문 번호 같은 주요 정보는 모든 iPhone과 iPad에서 작동합니다.",
     "Apple Intelligence가 있으면 Corres Pro가 iPhone에서 직접 요약과 추천 답장도 작성하고, 보여주기 전에 메일과 대조해 확인합니다."]),
   ("Apple Intelligence가 있든 없든", [
     "'나에게 필요', 그 이유, 금액, 날짜, 주문 번호 같은 주요 정보는 모든 Mac에서 작동합니다.",
     "Apple Intelligence가 있으면 Corres Pro가 Mac에서 직접 요약과 추천 답장도 작성하고, 보여주기 전에 메일과 대조해 확인합니다."])),
  (("개인정보 보호", [
     "메일은 제공업체에서 iPhone으로 바로 전달됩니다. 저희 서버는 메일을 받지 않습니다.",
     "원격 이미지와 추적 픽셀은 허용할 때까지 차단되고, 수신 거부는 한 번 탭이면 됩니다.",
     "광고가 없습니다. 데이터를 판매하거나 AI 학습에 사용하지 않습니다."]),
   ("개인정보 보호", [
     "메일은 제공업체에서 Mac으로 바로 전달됩니다. 저희 서버는 메일을 받지 않습니다.",
     "원격 이미지와 추적 픽셀은 허용할 때까지 차단되고, 수신 거부는 한 번 클릭이면 됩니다.",
     "광고가 없습니다. 데이터를 판매하거나 AI 학습에 사용하지 않습니다."])),
 ],
 pro=("무료와 Pro", "메일은 무료입니다. 모든 계정에서 읽고, 쓰고, 검색하고, 정리하세요. Corres Pro는 '나에게 필요', '대기 중', 검색의 답변, 요약, 추천 답장을 추가합니다. Pro는 무료 체험으로 시작해 이후 월간 또는 연간으로 자동 갱신되며, 기간 종료 최소 24시간 전에 {cancel}에서 취소하지 않으면 갱신됩니다.",
      {"ios": "iPhone 설정", "mac": "Apple 계정 설정"}),
 terms="이용 약관", privacy="개인정보 처리방침",
)

L["fr-FR"] = dict(
 subtitle="Le mail qui sait ce qui compte",
 keywords="boîte de réception,email,mail,priorité,newsletter,résumé,répondre,relance,tri,focus,privé",
 promo=("Gmail, Outlook, iCloud et plus dans une seule boîte. Corres s’ouvre sur les e-mails qui vous attendent, dit pourquoi, et garde vos e-mails sur votre iPhone.",
        "Gmail, Outlook, iCloud et plus dans une seule boîte. Corres s’ouvre sur les e-mails qui vous attendent, dit pourquoi, et garde vos e-mails sur votre Mac."),
 intro=("Corres s’ouvre sur ce qui vous attend. Gmail, Outlook, iCloud et presque tous les autres comptes de messagerie réunis dans une seule boîte, lus et triés sur votre iPhone. Les e-mails qui vous demandent quelque chose passent en premier, chacun avec sa raison. Le reste attend à un toucher, au calme, jusqu’à ce que vous soyez prêt.",
        "Corres s’ouvre sur ce qui vous attend. Gmail, Outlook, iCloud et presque tous les autres comptes de messagerie réunis dans une seule boîte, lus et triés sur votre Mac. Les e-mails qui vous demandent quelque chose passent en premier, chacun avec sa raison. Le reste attend à un clic, au calme, jusqu’à ce que vous soyez prêt."),
 sections=[
  (None, ("UNE VRAIE APP MAC", [
     "Les raccourcis clavier de Mail, ⌘K pour ouvrir n’importe quelle boîte ou commande, et le glisser pour classer.",
     "Les conversations dans leur propre fenêtre, libellés et dossiers dans la barre latérale, et vos e-mails dans Spotlight.",
     "Un seul achat pour Corres sur iPhone, iPad et Mac."])),
  (("POUR VOUS ET EN ATTENTE (CORRES PRO)", [
     "Pour vous rassemble les e-mails avec une question, une décision ou une échéance pour vous, répartis entre Bientôt dus et Quand vous pouvez.",
     "En attente liste les e-mails envoyés restés sans réponse, et vous prévient quand il est temps de relancer.",
     "Balayez un e-mail une fois traité. Maintenez-le appuyé pour le déplacer, et Corres apprend."]),
   ("POUR VOUS ET EN ATTENTE (CORRES PRO)", [
     "Pour vous rassemble les e-mails avec une question, une décision ou une échéance pour vous, répartis entre Bientôt dus et Quand vous pouvez.",
     "En attente liste les e-mails envoyés restés sans réponse, et vous prévient quand il est temps de relancer.",
     "Archivez un e-mail d’une touche une fois traité. Déplacez-en un, et Corres apprend."])),
  (("TOUS VOS COMPTES", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365 et iCloud Mail, plus Yahoo, AOL, Fastmail, Zoho ou un serveur professionnel, avec adresse et mot de passe.",
     "Principale, Promotions, Réseaux sociaux et Mises à jour, triés par Corres qui apprend des e-mails que vous déplacez.",
     "Chaque compte a sa couleur, son nom, ses signatures et ses notifications.",
     "Les règles trient les e-mails à l’arrivée et peuvent tourner dans Gmail et Outlook, même Corres fermé.",
     "Les nouveaux e-mails Outlook vous notifient en quelques secondes, ceux d’iCloud aussi avec Notifications instantanées."]), "same-drop-last"),
  (("NOUVEAUX EXPÉDITEURS", [
     "Choisissez comment arrivent les premiers e-mails d’une nouvelle personne, et autorisez ou bloquez toute une entreprise d’un coup."]), "same"),
  (("UNE RECHERCHE QUI RÉPOND", [
     "Cherchez dans tous vos comptes à la fois, e-mails archivés compris.",
     "Avec Corres Pro, posez une question comme « quand est mon vol ? » et obtenez la réponse à partir de vos propres e-mails."]),
   ("UNE RECHERCHE QUI RÉPOND", [
     "Cherchez dans tous vos comptes à la fois, e-mails archivés compris.",
     "Avec Corres Pro, posez une question comme « quand est mon vol ? » et obtenez la réponse à partir de vos propres e-mails."])),
  (("RÉDACTION", [
     "Brouillons, Envoyer plus tard, Annuler l’envoi, modèles, et un rappel si personne ne répond.",
     "Plusieurs signatures, d’autres adresses d’envoi, et gras, listes et liens.",
     "Réponses suggérées et reformulations avec Corres Pro, dans votre style, apprises de vos e-mails envoyés. Rien n’est envoyé tant que vous ne l’envoyez pas.",
     "Demandez à Siri d’écrire, d’envoyer ou de trouver un e-mail dans Corres."]),
   ("RÉDACTION", [
     "Brouillons, Envoyer plus tard, Annuler l’envoi, modèles, et un rappel si personne ne répond.",
     "Plusieurs signatures, d’autres adresses d’envoi, et gras, listes et liens.",
     "Réponses suggérées et reformulations avec Corres Pro, dans votre style, apprises de vos e-mails envoyés. Rien n’est envoyé tant que vous ne l’envoyez pas.",
     "Demandez à Siri d’écrire, d’envoyer ou de trouver un e-mail dans Corres."])),
  (("HORS LIGNE ET SYNCHRONISÉ", [
     "Archivez, supprimez et signalez sans réseau. Vos changements sont appliqués dès votre retour en ligne.",
     "Ce que vous triez, rappelez plus tard, épinglez, autorisez et bloquez vous suit sur vos autres appareils via iCloud. Vos e-mails, jamais."]),
   ("HORS LIGNE ET SYNCHRONISÉ", [
     "Archivez, supprimez et signalez sans connexion. Vos changements sont appliqués dès votre retour en ligne.",
     "Ce que vous triez, rappelez plus tard, épinglez, autorisez et bloquez vous suit entre iPhone, iPad et Mac via iCloud. Vos e-mails, jamais."])),
  (("APPLE WATCH", [
     "Avec Corres Pro, ce qui vous attend et pourquoi, au poignet et sur le cadran.",
     "Répondez à la voix, avec Griffonner ou une réponse toute prête, ou marquez-le comme traité. L’envoi passe par votre iPhone."]), None),
  (("DANS LE MONDE ENTIER", [
     "Corres existe en neuf langues et repère dans chacune échéances, reçus, livraisons, codes à usage unique et événements. Le week-end suit votre région."]), "same"),
  (("AVEC OU SANS APPLE INTELLIGENCE", [
     "Pour vous, ses raisons, et les détails clés comme les montants, les dates et les numéros de commande fonctionnent sur tous les iPhone et iPad.",
     "Avec Apple Intelligence, Corres Pro rédige aussi des résumés et des réponses suggérées, sur l’iPhone lui-même, et vérifie chacun d’eux avec l’e-mail avant de vous le montrer."]),
   ("AVEC OU SANS APPLE INTELLIGENCE", [
     "Pour vous, ses raisons, et les détails clés comme les montants, les dates et les numéros de commande fonctionnent sur tous les Mac.",
     "Avec Apple Intelligence, Corres Pro rédige aussi des résumés et des réponses suggérées, sur le Mac lui-même, et vérifie chacun d’eux avec l’e-mail avant de vous le montrer."])),
  (("CONFIDENTIALITÉ", [
     "Vos e-mails vont de votre fournisseur directement sur votre iPhone. Nos serveurs ne les reçoivent jamais.",
     "Les images distantes et les pixels de suivi sont bloqués jusqu’à ce que vous les autorisiez, et le désabonnement se fait d’un toucher.",
     "Aucune publicité. Vos données ne sont jamais vendues ni utilisées pour entraîner une IA."]),
   ("CONFIDENTIALITÉ", [
     "Vos e-mails vont de votre fournisseur directement sur votre Mac. Nos serveurs ne les reçoivent jamais.",
     "Les images distantes et les pixels de suivi sont bloqués jusqu’à ce que vous les autorisiez, et le désabonnement se fait d’un clic.",
     "Aucune publicité. Vos données ne sont jamais vendues ni utilisées pour entraîner une IA."])),
 ],
 pro=("GRATUIT ET PRO", "Messagerie est gratuite : lire, écrire, rechercher et organiser tous vos comptes. Corres Pro ajoute Pour vous, En attente, les réponses dans la recherche, les résumés et les réponses suggérées. Pro commence par un essai gratuit, puis se renouvelle chaque mois ou chaque année, sauf résiliation au moins 24 heures avant la fin de la période, dans {cancel}.",
      {"ios": "les Réglages de votre iPhone", "mac": "les réglages de votre compte Apple"}),
 terms="Conditions", privacy="Confidentialité",
)

L["es-ES"] = dict(
 subtitle="El correo que sabe qué importa",
 keywords="bandeja de entrada,correo,email,prioridad,boletín,resumen,responder,seguimiento,enfoque,privado",
 promo=("Gmail, Outlook, iCloud y más en una sola bandeja. Corres se abre en los correos que te necesitan, te dice por qué y mantiene tu correo en tu iPhone.",
        "Gmail, Outlook, iCloud y más en una sola bandeja. Corres se abre en los correos que te necesitan, te dice por qué y mantiene tu correo en tu Mac."),
 intro=("Corres se abre en lo que te necesita. Gmail, Outlook, iCloud y casi cualquier otra cuenta de correo en una sola bandeja, leída y clasificada en tu iPhone. Los correos que te piden algo van primero, cada uno con su motivo. El resto de tu correo espera a un toque, en calma hasta que estés listo.",
        "Corres se abre en lo que te necesita. Gmail, Outlook, iCloud y casi cualquier otra cuenta de correo en una sola bandeja, leída y clasificada en tu Mac. Los correos que te piden algo van primero, cada uno con su motivo. El resto de tu correo espera a un clic, en calma hasta que estés listo."),
 sections=[
  (None, ("UNA APP DE MAC DE VERDAD", [
     "Los atajos de teclado de Mail, ⌘K para abrir cualquier buzón o comando, y arrastrar para archivar.",
     "Conversaciones en su propia ventana, etiquetas y carpetas en la barra lateral, y tu correo en Spotlight.",
     "Una sola compra sirve para Corres en iPhone, iPad y Mac."])),
  (("TE NECESITA Y EN ESPERA (CORRES PRO)", [
     "Te necesita reúne los correos con una pregunta, una decisión o una fecha límite para ti, en Vence pronto y Cuando puedas.",
     "En espera muestra los correos que enviaste sin respuesta, y te avisa cuando toca hacer seguimiento.",
     "Desliza un correo cuando esté listo. Mantenlo pulsado para moverlo, y Corres aprende."]),
   ("TE NECESITA Y EN ESPERA (CORRES PRO)", [
     "Te necesita reúne los correos con una pregunta, una decisión o una fecha límite para ti, en Vence pronto y Cuando puedas.",
     "En espera muestra los correos que enviaste sin respuesta, y te avisa cuando toca hacer seguimiento.",
     "Archiva un correo con una tecla cuando esté listo. Mueve uno, y Corres aprende."])),
  (("TODAS TUS CUENTAS", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365 e iCloud Mail, además de Yahoo, AOL, Fastmail, Zoho o un servidor del trabajo, con tu dirección y contraseña.",
     "Principal, Promociones, Social y Novedades, clasificados por Corres, que aprende de los correos que mueves.",
     "Cada cuenta tiene su color, nombre, firmas y avisos.",
     "Las reglas clasifican el correo al llegar y pueden funcionar en el propio Gmail y Outlook, incluso con Corres cerrado.",
     "El correo nuevo de Outlook te avisa en segundos, y el de iCloud, con Notificaciones al instante."]), "same-drop-last"),
  (("REMITENTES NUEVOS", [
     "Elige cómo llegan los primeros correos de alguien nuevo: Revisar a todos, Revisar solo empresas, Mostrar como nuevo o Aceptar a todos.",
     "Permite o bloquea una empresa entera de una vez, y deshazlo si cambias de idea."]), "same"),
  (("UNA BÚSQUEDA QUE RESPONDE", [
     "Busca en todas las cuentas a la vez, correo archivado incluido, con filtros como from:, has:attachment e is:unread.",
     "Con Corres Pro, haz una pregunta como «¿cuándo es mi vuelo?» y obtén la respuesta de tu propio correo.",
     "Encuentra cualquier conversación también desde la búsqueda de la pantalla de inicio."]),
   ("UNA BÚSQUEDA QUE RESPONDE", [
     "Busca en todas las cuentas a la vez, correo archivado incluido, con filtros como from:, has:attachment e is:unread.",
     "Con Corres Pro, haz una pregunta como «¿cuándo es mi vuelo?» y obtén la respuesta de tu propio correo.",
     "Encuentra cualquier conversación también desde Spotlight."])),
  (("ESCRIBIR", [
     "Borradores, Enviar más tarde, Deshacer envío, plantillas y un recordatorio si nadie responde.",
     "Varias firmas, otras direcciones de envío, y negrita, listas y enlaces.",
     "Con Corres Pro, respuestas sugeridas y reescrituras con tu saludo, tu despedida y tu extensión, aprendidos de tus correos enviados. No se envía nada hasta que tú lo envías.",
     "Pide a Siri que escriba, envíe o busque un correo en Corres.",
     "Escribe un correo desde el botón Compartir de cualquier app."]),
   ("ESCRIBIR", [
     "Borradores, Enviar más tarde, Deshacer envío, plantillas y un recordatorio si nadie responde.",
     "Varias firmas, otras direcciones de envío, y negrita, listas y enlaces.",
     "Con Corres Pro, respuestas sugeridas y reescrituras con tu saludo, tu despedida y tu extensión, aprendidos de tus correos enviados. No se envía nada hasta que tú lo envías.",
     "Pide a Siri que escriba, envíe o busque un correo en Corres."])),
  (("SIN CONEXIÓN Y SINCRONIZADO", [
     "Archiva, elimina y marca sin cobertura. Tus cambios se aplican cuando vuelves a estar en línea.",
     "Lo que clasificas, pospones, fijas, permites y bloqueas te sigue a tus otros dispositivos con iCloud. Tu correo nunca."]),
   ("SIN CONEXIÓN Y SINCRONIZADO", [
     "Archiva, elimina y marca sin conexión. Tus cambios se aplican cuando vuelves a estar en línea.",
     "Lo que clasificas, pospones, fijas, permites y bloqueas te sigue entre iPhone, iPad y Mac con iCloud. Tu correo nunca."])),
  (("APPLE WATCH", [
     "Con Corres Pro, lo que te necesita y por qué, en la muñeca y en la esfera del reloj.",
     "Responde por voz, con Garabatear o con una respuesta lista, o márcalo como resuelto. Las respuestas salen desde tu iPhone."]), None),
  (("EN TODO EL MUNDO", [
     "Corres está en nueve idiomas y en todos ellos lee fechas límite, recibos, entregas, códigos de un solo uso y eventos. El fin de semana sigue tu región."]), "same"),
  (("CON O SIN APPLE INTELLIGENCE", [
     "Te necesita, sus motivos y datos clave como importes, fechas y números de pedido funcionan en cualquier iPhone y iPad.",
     "Con Apple Intelligence, Corres Pro también escribe resúmenes y respuestas sugeridas, en el propio iPhone, y comprueba cada uno con el correo antes de mostrártelo."]),
   ("CON O SIN APPLE INTELLIGENCE", [
     "Te necesita, sus motivos y datos clave como importes, fechas y números de pedido funcionan en cualquier Mac.",
     "Con Apple Intelligence, Corres Pro también escribe resúmenes y respuestas sugeridas, en el propio Mac, y comprueba cada uno con el correo antes de mostrártelo."])),
  (("PRIVACIDAD", [
     "Tu correo va de tu proveedor directo a tu iPhone. Nuestros servidores nunca lo reciben.",
     "Las imágenes remotas y los píxeles de rastreo se bloquean hasta que los permites, y darse de baja es un toque.",
     "Sin anuncios. Tus datos nunca se venden ni se usan para entrenar IA."]),
   ("PRIVACIDAD", [
     "Tu correo va de tu proveedor directo a tu Mac. Nuestros servidores nunca lo reciben.",
     "Las imágenes remotas y los píxeles de rastreo se bloquean hasta que los permites, y darse de baja es un clic.",
     "Sin anuncios. Tus datos nunca se venden ni se usan para entrenar IA."])),
 ],
 pro=("GRATIS Y PRO", "Correo es gratis: lee, escribe, busca y organiza todas tus cuentas. Corres Pro añade Te necesita, En espera, respuestas en la búsqueda, resúmenes y respuestas sugeridas. Pro empieza con una prueba gratuita y después se renueva cada mes o cada año, salvo que canceles al menos 24 horas antes del final del periodo en {cancel}.",
      {"ios": "los Ajustes de tu iPhone", "mac": "los ajustes de tu cuenta de Apple"}),
 terms="Condiciones", privacy="Privacidad",
)

L["pt-BR"] = dict(
 # App Store Connect refused plain "Corres" here: another app uses it.
 name="Corres E-mail",
 subtitle="E-mail que sabe o que importa",
 keywords="caixa de entrada,email,correio,prioridade,newsletter,resumo,responder,acompanhar,foco,privado",
 promo=("Gmail, Outlook, iCloud e mais em uma só caixa. O Corres abre nos e-mails que precisam de você, diz por quê e mantém seus e-mails no seu iPhone.",
        "Gmail, Outlook, iCloud e mais em uma só caixa. O Corres abre nos e-mails que precisam de você, diz por quê e mantém seus e-mails no seu Mac."),
 intro=("O Corres abre no que precisa de você. Gmail, Outlook, iCloud e quase qualquer outra conta de e-mail em uma só caixa de entrada, lidos e classificados no seu iPhone. Os e-mails que pedem algo a você vêm primeiro, cada um com o motivo. O resto espera a um toque, em silêncio até você estar pronto.",
        "O Corres abre no que precisa de você. Gmail, Outlook, iCloud e quase qualquer outra conta de e-mail em uma só caixa de entrada, lidos e classificados no seu Mac. Os e-mails que pedem algo a você vêm primeiro, cada um com o motivo. O resto espera a um clique, em silêncio até você estar pronto."),
 sections=[
  (None, ("UM APP DE MAC DE VERDADE", [
     "Os atalhos de teclado do Mail, ⌘K para abrir qualquer caixa ou comando, e arrastar para arquivar.",
     "Conversas em janelas próprias, etiquetas e pastas na barra lateral, e seus e-mails no Spotlight.",
     "Uma única compra vale para o Corres no iPhone, iPad e Mac."])),
  (("PRECISA DE VOCÊ E AGUARDANDO (CORRES PRO)", [
     "Precisa de Você reúne os e-mails com uma pergunta, uma decisão ou um prazo para você, em Vence em breve e Quando puder.",
     "Aguardando lista os e-mails que você enviou e ainda não tiveram resposta, e avisa quando é hora de acompanhar.",
     "Deslize um e-mail quando terminar. Mantenha pressionado para mover, e o Corres aprende."]),
   ("PRECISA DE VOCÊ E AGUARDANDO (CORRES PRO)", [
     "Precisa de Você reúne os e-mails com uma pergunta, uma decisão ou um prazo para você, em Vence em breve e Quando puder.",
     "Aguardando lista os e-mails que você enviou e ainda não tiveram resposta, e avisa quando é hora de acompanhar.",
     "Arquive um e-mail com uma tecla quando terminar. Mova um, e o Corres aprende."])),
  (("TODAS AS SUAS CONTAS", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365 e E-mail do iCloud, além de Yahoo, AOL, Fastmail, Zoho ou um servidor do trabalho, com seu endereço e senha.",
     "Principal, Promoções, Social e Atualizações, classificados pelo Corres, que aprende com os e-mails que você move.",
     "Cada conta tem sua cor, nome, assinaturas e notificações.",
     "Regras classificam os e-mails na chegada e podem rodar no próprio Gmail e Outlook, mesmo com o Corres fechado.",
     "E-mails novos do Outlook notificam você em segundos, e os do iCloud, com Notificações instantâneas."]), "same-drop-last"),
  (("NOVOS REMETENTES", [
     "Escolha como chegam os primeiros e-mails de alguém novo: Revisar todos, Revisar só empresas, Mostrar como novo ou Aceitar todos.",
     "Permita ou bloqueie uma empresa inteira de uma vez, e desfaça se mudar de ideia."]), "same"),
  (("UMA BUSCA QUE RESPONDE", [
     "Busque em todas as contas de uma vez, incluindo e-mails arquivados, com filtros como from:, has:attachment e is:unread.",
     "Com o Corres Pro, faça uma pergunta como “quando é meu voo?” e receba a resposta dos seus próprios e-mails.",
     "Encontre qualquer conversa também pela Busca na Tela de Início."]),
   ("UMA BUSCA QUE RESPONDE", [
     "Busque em todas as contas de uma vez, incluindo e-mails arquivados, com filtros como from:, has:attachment e is:unread.",
     "Com o Corres Pro, faça uma pergunta como “quando é meu voo?” e receba a resposta dos seus próprios e-mails.",
     "Encontre qualquer conversa também pelo Spotlight."])),
  (("ESCRITA", [
     "Rascunhos, Enviar depois, Desfazer envio, modelos e um lembrete se ninguém responder.",
     "Várias assinaturas, outros endereços de envio, e negrito, listas e links.",
     "Com o Corres Pro, respostas sugeridas e reescritas com sua saudação, sua despedida e seu tamanho de texto, aprendidos com os e-mails que você enviou. Nada é enviado até você enviar.",
     "Peça à Siri para escrever, enviar ou encontrar um e-mail no Corres.",
     "Escreva um e-mail pelo botão Compartilhar de qualquer app."]),
   ("ESCRITA", [
     "Rascunhos, Enviar depois, Desfazer envio, modelos e um lembrete se ninguém responder.",
     "Várias assinaturas, outros endereços de envio, e negrito, listas e links.",
     "Com o Corres Pro, respostas sugeridas e reescritas com sua saudação, sua despedida e seu tamanho de texto, aprendidos com os e-mails que você enviou. Nada é enviado até você enviar.",
     "Peça à Siri para escrever, enviar ou encontrar um e-mail no Corres."])),
  (("OFFLINE E SINCRONIZADO", [
     "Arquive, apague e sinalize sem sinal. Suas alterações são aplicadas quando você volta a ficar online.",
     "O que você classifica, adia, fixa, permite e bloqueia acompanha você nos seus outros dispositivos pelo iCloud. Seus e-mails, nunca."]),
   ("OFFLINE E SINCRONIZADO", [
     "Arquive, apague e sinalize sem conexão. Suas alterações são aplicadas quando você volta a ficar online.",
     "O que você classifica, adia, fixa, permite e bloqueia acompanha você entre iPhone, iPad e Mac pelo iCloud. Seus e-mails, nunca."])),
  (("APPLE WATCH", [
     "Com o Corres Pro, o que precisa de você e por quê, no pulso e no mostrador.",
     "Responda por voz, com Rabiscar ou com uma resposta pronta, ou marque como resolvido. As respostas saem pelo seu iPhone."]), None),
  (("NO MUNDO TODO", [
     "O Corres está em nove idiomas e em todos eles lê prazos, recibos, entregas, códigos de uso único e eventos. O fim de semana segue a sua região."]), "same"),
  (("COM OU SEM APPLE INTELLIGENCE", [
     "Precisa de Você, seus motivos e detalhes importantes como valores, datas e números de pedido funcionam em qualquer iPhone e iPad.",
     "Com a Apple Intelligence, o Corres Pro também escreve resumos e respostas sugeridas, no próprio iPhone, e confere cada um com o e-mail antes de mostrar."]),
   ("COM OU SEM APPLE INTELLIGENCE", [
     "Precisa de Você, seus motivos e detalhes importantes como valores, datas e números de pedido funcionam em qualquer Mac.",
     "Com a Apple Intelligence, o Corres Pro também escreve resumos e respostas sugeridas, no próprio Mac, e confere cada um com o e-mail antes de mostrar."])),
  (("PRIVACIDADE", [
     "Seus e-mails vão do seu provedor direto para o seu iPhone. Nossos servidores nunca os recebem.",
     "Imagens remotas e pixels de rastreamento ficam bloqueados até você permitir, e descadastrar é um toque.",
     "Sem anúncios. Seus dados nunca são vendidos nem usados para treinar IA."]),
   ("PRIVACIDADE", [
     "Seus e-mails vão do seu provedor direto para o seu Mac. Nossos servidores nunca os recebem.",
     "Imagens remotas e pixels de rastreamento ficam bloqueados até você permitir, e descadastrar é um clique.",
     "Sem anúncios. Seus dados nunca são vendidos nem usados para treinar IA."])),
 ],
 pro=("GRÁTIS E PRO", "O E-mail é grátis: leia, escreva, busque e organize todas as contas. O Corres Pro adiciona Precisa de Você, Aguardando, respostas na busca, resumos e respostas sugeridas. O Pro começa com um teste gratuito e depois renova todo mês ou todo ano, a menos que você cancele pelo menos 24 horas antes do fim do período, {cancel}.",
      {"ios": "nos Ajustes do seu iPhone", "mac": "nos ajustes da sua Conta Apple"}),
 terms="Termos", privacy="Privacidade",
)

# Bangla. App Store Connect's locale code is bn-BD (Apple's "Managing
# metadata in your app by using locale shortcodes": Bengali, bn-BD).
# Terms follow the app's own App/bn.lproj/Localizable.strings.
L["bn-BD"] = dict(
 name="Corres",
 subtitle="যে মেইল জানে আপনার করণীয়",
 keywords="ইমেইল,ইনবক্স,উত্তর,ফলো-আপ,সারাংশ,ঘড়ি",
 promo=("Gmail, Outlook, iCloud আর আরও অনেক অ্যাকাউন্ট এক ইনবক্সে, iPhone, iPad, Mac আর Apple Watch-এ। Corres আগে দেখায় আপনার করণীয়, কারণসহ, আর মেইল রাখে আপনার ডিভাইসেই।",
        "Gmail, Outlook, iCloud আর আরও অনেক অ্যাকাউন্ট এক ইনবক্সে, Mac, iPhone আর iPad-এ। Corres আগে দেখায় যে ইমেইলগুলো আপনার করণীয়, কারণসহ, আর মেইল রাখে আপনার ডিভাইসেই।"),
 intro=("Corres খোলে আপনার করণীয় দিয়ে। Gmail, Outlook, iCloud আর প্রায় যেকোনো ইমেইল অ্যাকাউন্ট এক ইনবক্সে থাকে, পড়া ও সাজানো হয় আপনার iPhone আর iPad-এ। যে ইমেইলগুলো আপনার কাছে কিছু চায় সেগুলো আগে আসে, প্রতিটির সাথে তার কারণ। বাকি মেইল এক ট্যাপ দূরে, আপনি প্রস্তুত না হওয়া পর্যন্ত চুপচাপ থাকে।",
        "Corres খোলে আপনার করণীয় দিয়ে। Gmail, Outlook, iCloud আর প্রায় যেকোনো ইমেইল অ্যাকাউন্ট এক ইনবক্সে থাকে, পড়া ও সাজানো হয় আপনার Mac-এ। যে ইমেইলগুলো আপনার কাছে কিছু চায় সেগুলো আগে আসে, প্রতিটির সাথে তার কারণ। বাকি মেইল এক ক্লিক দূরে, আপনি প্রস্তুত না হওয়া পর্যন্ত চুপচাপ থাকে।"),
 sections=[
  (None, ("সত্যিকারের Mac অ্যাপ", [
     "Mail-এর কিবোর্ড শর্টকাট, যেকোনো মেইলবক্স বা কমান্ড খুলতে ⌘K, আর টেনে এনে সরানো।",
     "কথোপকথন আলাদা উইন্ডোতে, লেবেল আর ফোল্ডার সাইডবারে, আর আপনার মেইল Spotlight-এ।",
     "কোনো উইন্ডো খোলা না থাকলেও মেনু বার থেকে চলতে থাকে: নতুন মেইল, Dock ব্যাজ, উইজেট আর সার্চ হালনাগাদ থাকে।",
     "একবার কিনলেই iPhone, iPad আর Mac-এ Corres ব্যবহার করুন।"])),
  (("আপনার করণীয় আর অপেক্ষায় (Corres Pro)", [
     "আপনার করণীয়-তে থাকে সেই ইমেইলগুলো, যাতে আপনার জন্য কোনো প্রশ্ন, সিদ্ধান্ত বা শেষ সময় আছে, “শিগগির শেষ সময়” আর “সময় পেলে” এই দুই ভাগে।",
     "অপেক্ষায় দেখায় আপনার পাঠানো যে ইমেইলের উত্তর এখনো আসেনি, আর ফলো-আপের সময় হলে মনে করিয়ে দেয়।",
     "কাজ শেষ হলে সোয়াইপ করে সরিয়ে দিন। চেপে ধরে অন্য জায়গায় সরান, Corres শিখে নেয়।"]),
   ("আপনার করণীয় আর অপেক্ষায় (Corres Pro)", [
     "আপনার করণীয়-তে থাকে সেই ইমেইলগুলো, যাতে আপনার জন্য কোনো প্রশ্ন, সিদ্ধান্ত বা শেষ সময় আছে, “শিগগির শেষ সময়” আর “সময় পেলে” এই দুই ভাগে।",
     "অপেক্ষায় দেখায় আপনার পাঠানো যে ইমেইলের উত্তর এখনো আসেনি, আর ফলো-আপের সময় হলে মনে করিয়ে দেয়।",
     "কাজ শেষ হলে এক কী চেপে আর্কাইভ করুন। অন্য জায়গায় সরান, Corres শিখে নেয়।"])),
  (("আপনার সব অ্যাকাউন্ট", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365 আর iCloud Mail, সাথে Yahoo, AOL, Fastmail, Zoho বা অফিসের সার্ভার, আপনার ঠিকানা আর পাসওয়ার্ড দিয়ে।",
     "প্রধান, প্রচার, সামাজিক আর আপডেট: Corres মেইল সাজায় এবং আপনি যে ইমেইল সরান তা থেকে শেখে।",
     "প্রতিটি অ্যাকাউন্টের নিজের রং, নাম, স্বাক্ষর আর নোটিফিকেশন।",
     "নিয়ম আসা মেইল সাজায়, আর Gmail ও Outlook-এও চলতে পারে, তাই Corres বন্ধ থাকলেও কাজ করে।",
     "Outlook-এর নতুন মেইলের নোটিফিকেশন আসে কয়েক সেকেন্ডে, তাৎক্ষণিক নোটিফিকেশন চালু করলে iCloud-এরও।"]), "same-drop-last"),
  (("নতুন প্রেরক", [
     "নতুন কারও প্রথম ইমেইল কীভাবে আসবে বেছে নিন: সবাইকে আগে দেখুন, শুধু প্রতিষ্ঠান দেখুন, নতুন চিহ্ন দিয়ে দেখান বা সবাইকে আসতে দিন।",
     "পুরো একটি প্রতিষ্ঠানকে একবারে অনুমতি দিন বা ব্লক করুন, আর যেকোনো সময় ফিরিয়ে নিন।"]), "same"),
  (("যে সার্চ উত্তর দেয়", [
     "সব অ্যাকাউন্টে একসাথে খুঁজুন, আর্কাইভ করা মেইলসহ।",
     "Corres Pro-তে “আমার ফ্লাইট কবে?” এর মতো প্রশ্ন করুন, উত্তর পাবেন আপনার নিজের মেইল থেকে।",
     "হোম স্ক্রিনের সার্চ থেকেও যেকোনো কথোপকথন খুঁজে পান।"]),
   ("যে সার্চ উত্তর দেয়", [
     "সব অ্যাকাউন্টে একসাথে খুঁজুন, আর্কাইভ করা মেইলসহ।",
     "Corres Pro-তে “আমার ফ্লাইট কবে?” এর মতো প্রশ্ন করুন, উত্তর পাবেন আপনার নিজের মেইল থেকে।",
     "Spotlight থেকেও যেকোনো কথোপকথন খুঁজে পান।"])),
  (("আমন্ত্রণ", [
     "আপনার টাইম জোনে সময়, ভিডিও কল আর আপনি ফাঁকা আছেন কি না দেখুন, তারপর ইমেইল থেকেই গ্রহণ, হয়তো বা প্রত্যাখ্যান করুন।"]), "same"),
  (("লেখা", [
     "খসড়া, পরে পাঠান, পাঠানো ফিরিয়ে নিন, টেমপ্লেট, আর কেউ উত্তর না দিলে রিমাইন্ডার।",
     "একাধিক স্বাক্ষর, অন্য ঠিকানা থেকে পাঠানো, আর বোল্ড, তালিকা ও লিংক।",
     "Corres Pro-তে প্রস্তাবিত উত্তর আর নতুন করে লেখা হয় আপনার নিজের সম্ভাষণ, বিদায় সম্ভাষণ আর দৈর্ঘ্যে, আপনার পাঠানো ইমেইল থেকে শেখা। আপনি না পাঠানো পর্যন্ত কিছুই যায় না।",
     "Siri-কে বলুন Corres-এ ইমেইল লিখতে, পাঠাতে বা খুঁজে দিতে।",
     "যেকোনো অ্যাপের শেয়ার বোতাম থেকে ইমেইল লিখুন।"]),
   ("লেখা", [
     "খসড়া, পরে পাঠান, পাঠানো ফিরিয়ে নিন, টেমপ্লেট, আর কেউ উত্তর না দিলে রিমাইন্ডার।",
     "একাধিক স্বাক্ষর, অন্য ঠিকানা থেকে পাঠানো, আর বোল্ড, তালিকা ও লিংক।",
     "Corres Pro-তে প্রস্তাবিত উত্তর আর নতুন করে লেখা হয় আপনার নিজের সম্ভাষণ, বিদায় সম্ভাষণ আর দৈর্ঘ্যে, আপনার পাঠানো ইমেইল থেকে শেখা। আপনি না পাঠানো পর্যন্ত কিছুই যায় না।",
     "Siri-কে বলুন Corres-এ ইমেইল লিখতে, পাঠাতে বা খুঁজে দিতে।"])),
  (("অফলাইন আর সিঙ্ক", [
     "নেটওয়ার্ক না থাকলেও আর্কাইভ, মুছে ফেলা আর ফ্ল্যাগ করা যায়। আবার অনলাইনে এলে আপনার পরিবর্তনগুলো কার্যকর হয়।",
     "আপনি যা সাজান, স্নুজ করেন, পিন করেন, অনুমতি দেন আর ব্লক করেন, তা iCloud দিয়ে iPhone, iPad আর Mac-এ আপনার সাথে থাকে। আপনার ইমেইল কখনো যায় না।"]),
   ("অফলাইন আর সিঙ্ক", [
     "সংযোগ না থাকলেও আর্কাইভ, মুছে ফেলা আর ফ্ল্যাগ করা যায়। আবার অনলাইনে এলে আপনার পরিবর্তনগুলো কার্যকর হয়।",
     "আপনি যা সাজান, স্নুজ করেন, পিন করেন, অনুমতি দেন আর ব্লক করেন, তা iCloud দিয়ে iPhone, iPad আর Mac-এ আপনার সাথে থাকে। আপনার ইমেইল কখনো যায় না।"])),
  (("Apple Watch", [
     "Corres Pro-তে কবজিতে আর ওয়াচ ফেসে দেখুন আপনার করণীয় আর তার কারণ।",
     "ভয়েস, Scribble বা তৈরি উত্তর দিয়ে জবাব দিন, অথবা সম্পন্ন চিহ্নিত করুন। উত্তর যায় আপনার iPhone দিয়ে।"]), None),
  (("সারা বিশ্বে", [
     "Corres নয়টি ভাষায় চলে: বাংলা, ইংরেজি, জাপানি, সরলীকৃত চীনা, কোরিয়ান, জার্মান, ফরাসি, স্প্যানিশ আর পর্তুগিজ।",
     "শেষ সময়, রসিদ, ডেলিভারি, এককালীন কোড আর ইভেন্ট এই নয়টি ভাষাতেই পড়ে নেয়। সপ্তাহান্ত ধরা হয় আপনার অঞ্চল অনুযায়ী।"]), "same"),
  (("Apple Intelligence থাকুক বা না থাকুক", [
     "আপনার করণীয়, তার কারণ, আর টাকার অঙ্ক, তারিখ ও অর্ডার নম্বরের মতো মূল তথ্য সব iPhone আর iPad-এ কাজ করে।",
     "Apple Intelligence থাকলে Corres Pro iPhone-এই সারসংক্ষেপ আর প্রস্তাবিত উত্তরও লেখে, আর দেখানোর আগে ইমেইলের সাথে মিলিয়ে নেয়।"]),
   ("Apple Intelligence থাকুক বা না থাকুক", [
     "আপনার করণীয়, তার কারণ, আর টাকার অঙ্ক, তারিখ ও অর্ডার নম্বরের মতো মূল তথ্য সব Mac-এ কাজ করে।",
     "Apple Intelligence থাকলে Corres Pro Mac-এই সারসংক্ষেপ আর প্রস্তাবিত উত্তরও লেখে, আর দেখানোর আগে ইমেইলের সাথে মিলিয়ে নেয়।"])),
  (("গোপনীয়তা", [
     "আপনার ইমেইল আপনার প্রোভাইডার থেকে সরাসরি আপনার iPhone-এ আসে। আমাদের সার্ভার কখনো তা পায় না।",
     "দূরের ছবি আর ট্র্যাকিং পিক্সেল আপনি অনুমতি না দেওয়া পর্যন্ত বন্ধ থাকে, আর আনসাবস্ক্রাইব এক ট্যাপে।",
     "কোনো বিজ্ঞাপন বা ট্র্যাকিং নেই। আপনার ডেটা কখনো বিক্রি হয় না, AI প্রশিক্ষণেও ব্যবহার হয় না।"]),
   ("গোপনীয়তা", [
     "আপনার ইমেইল আপনার প্রোভাইডার থেকে সরাসরি আপনার Mac-এ আসে। আমাদের সার্ভার কখনো তা পায় না।",
     "দূরের ছবি আর ট্র্যাকিং পিক্সেল আপনি অনুমতি না দেওয়া পর্যন্ত বন্ধ থাকে, আর আনসাবস্ক্রাইব এক ক্লিকে।",
     "কোনো বিজ্ঞাপন বা ট্র্যাকিং নেই। আপনার ডেটা কখনো বিক্রি হয় না, AI প্রশিক্ষণেও ব্যবহার হয় না।"])),
 ],
 pro=("বিনামূল্যে আর Pro", "মেইল বিনামূল্যে: প্রতিটি অ্যাকাউন্টে পড়ুন, লিখুন, খুঁজুন আর সাজান। Corres Pro যোগ করে আপনার করণীয়, অপেক্ষায়, সার্চে উত্তর, সারসংক্ষেপ আর প্রস্তাবিত উত্তর। Pro শুরু হয় বিনামূল্যে ট্রায়াল দিয়ে, তারপর মাসিক বা বার্ষিকভাবে নিজে থেকে নবায়ন হয়, যদি না মেয়াদ শেষ হওয়ার অন্তত 24 ঘণ্টা আগে {cancel} বাতিল করেন।",
      {"ios": "আপনার iPhone-এর সেটিংসে", "mac": "আপনার Apple Account-এর সেটিংসে"}),
 terms="শর্তাবলি", privacy="গোপনীয়তা",
)

L["es-MX"] = L["es-ES"]
L["fr-CA"] = L["fr-FR"]

def description(d, plat):
    i = 0 if plat == "ios" else 1
    parts = [d["intro"][i]]
    for sec in d["sections"]:
        ios, rest = sec[0], sec[1]
        if rest == "same":
            title, bullets = ios
        elif rest == "same-drop-last":
            title, bullets = ios if plat == "ios" else (ios[0], ios[1][:-1])
        else:
            pick = ios if plat == "ios" else rest
            if pick is None: continue
            title, bullets = pick
        parts.append(title + "\n" + "\n".join("• " + b for b in bullets))
    t, text, cancel = d["pro"]
    parts.append(t + "\n" + text.replace("{cancel}", cancel[plat]))
    parts.append(f'{d["terms"]}: https://anwarcreativestudio.com/corres/terms/\n{d["privacy"]}: https://anwarcreativestudio.com/corres/privacy/')
    return "\n\n".join(parts)

out = {}
for loc, d in L.items():
    e = dict(name=d.get("name", "Corres"),
             subtitle=d["subtitle"], keywords=d["keywords"],
             ios=dict(description=description(d, "ios"), promotionalText=d["promo"][0]),
             mac=dict(description=description(d, "mac"), promotionalText=d["promo"][1]))
    assert len(e["name"]) <= 30, (loc, len(e["name"]))
    assert len(e["subtitle"]) <= 30, (loc, len(e["subtitle"]))
    assert len(e["keywords"]) <= 100, (loc, len(e["keywords"]))
    # Apple's documented keyword limit is 100 bytes (UTF-8). Latin-script
    # lists must fit; the Japanese, Chinese and Korean lists are longer in
    # bytes but were accepted by App Store Connect on 2026-10-20.
    if loc not in ("ja", "zh-Hans", "ko"):
        assert len(e["keywords"].encode()) <= 100, (loc, len(e["keywords"].encode()))
    assert ", " not in e["keywords"]
    for p in ("ios", "mac"):
        assert len(e[p]["description"]) <= 4000, (loc, p, len(e[p]["description"]))
        assert len(e[p]["promotionalText"]) <= 170, (loc, p, len(e[p]["promotionalText"]))
        assert "—" not in e[p]["description"]
    out[loc] = e
    print(loc, len(e["subtitle"]), len(e["keywords"]), len(e["keywords"].encode()), len(e["ios"]["description"]), len(e["mac"]["description"]), len(e["ios"]["promotionalText"]), len(e["mac"]["promotionalText"]))
json.dump(out, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
