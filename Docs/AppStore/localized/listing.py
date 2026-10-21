import json, sys

# Each language: subtitle, keywords, promo (ios/mac), and description parts.
# Lists of (ios, mac) pairs; None means the line is left out on that platform.
L = {}

L["ja"] = dict(
 subtitle="要対応がひと目でわかるメール",
 keywords="受信トレイ,メール,電子メール,優先,ニュースレター,要約,返信,フォローアップ,整理,集中,プライバシー,オフライン,迷惑メール",
 promo=("Gmail、Outlook、iCloudなどを1つの受信ボックスに。Corresはあなたへの用件から開き、その理由を示し、メールをiPhoneに保ちます。",
        "Gmail、Outlook、iCloudなどを1つの受信ボックスに。Corresはあなたへの用件から開き、その理由を示し、メールをMacに保ちます。"),
 intro=("Corresは「要対応」から開きます。Gmail、Outlook、iCloud、そのほかほとんどのメールアカウントを1つの受信ボックスにまとめ、iPhone上で読み、振り分けます。あなたに何かを求めるメールが先頭に並び、それぞれに理由が添えられます。ほかのメールはスワイプひとつ先で、準備ができるまで静かに待っています。",
        "Corresは「要対応」から開きます。Gmail、Outlook、iCloud、そのほかほとんどのメールアカウントを1つの受信ボックスにまとめ、Mac上で読み、振り分けます。あなたに何かを求めるメールが先頭に並び、それぞれに理由が添えられます。ほかのメールはクリックひとつ先で、準備ができるまで静かに待っています。"),
 sections=[
  (None, ("本物のMacアプリ", [
     "ネイティブで速く、キーボード中心。メールのショートカット、⌘Kでどこへでも移動・何でも実行、ドラッグで整理。",
     "会話を別ウインドウで、ラベルとフォルダをサイドバーに、メールはSpotlightで検索。",
     "1回の購入でiPhone、iPad、MacのCorresが使えます。"])),
  (("要対応と返信待ち", [
     "「要対応」には、あなたへの質問、判断、期限があるメールが「まもなく期限」と「時間のあるときに」に分かれて入ります。",
     "「返信待ち」には、返信がまだのメールが並び、フォローアップの時期をお知らせします。",
     "済んだらスワイプで片付け。違っていたら長押しで移動すれば、Corresが学びます。"]),
   ("要対応と返信待ち", [
     "「要対応」には、あなたへの質問、判断、期限があるメールが「まもなく期限」と「時間のあるときに」に分かれて入ります。",
     "「返信待ち」には、返信がまだのメールが並び、フォローアップの時期をお知らせします。",
     "済んだらキーひとつでアーカイブ。違っていたら移動すれば、Corresが学びます。"])),
  (("すべてのアカウント", [
     "Gmail、Google Workspace、Outlook.com、Microsoft 365、iCloudメールに加え、Yahoo、AOL、Fastmail、Zoho、職場のサーバもアドレスとパスワードだけで。",
     "メイン、プロモーション、ソーシャル、更新をCorresが振り分け、あなたが移したメールから学びます。",
     "アカウントごとに色、名前、署名、通知を設定できます。",
     "OutlookとiCloudの新着メールは数秒で通知されます。"]), "same-drop-last"),
  (("新しい差出人", [
     "初めての人からのメールは、許可かブロックをするまで待機します。",
     "会社ごとまとめて許可やブロックができ、気が変わったら取り消せます。"]), "same"),
  (("答えてくれる検索", [
     "すべてのアカウントをまとめて検索。アーカイブ済みのメールも含み、from:、has:attachment、is:unreadなどで絞り込めます。",
     "「フライトはいつ？」のように質問すると、あなた自身のメールから答えが返ってきます。",
     "ホーム画面の検索からも会話を探せます。"]),
   ("答えてくれる検索", [
     "すべてのアカウントをまとめて検索。アーカイブ済みのメールも含み、from:、has:attachment、is:unreadなどで絞り込めます。",
     "「フライトはいつ？」のように質問すると、あなた自身のメールから答えが返ってきます。",
     "Spotlightからも会話を探せます。"])),
  (("招待", [
     "あなたのタイムゾーンでの時刻、場所、参加するビデオ通話、その時間が空いているかがわかります。",
     "メールから承諾、未定、辞退を選び、タップひとつでカレンダーに追加できます。"]),
   ("招待", [
     "あなたのタイムゾーンでの時刻、場所、参加するビデオ通話、その時間が空いているかがわかります。",
     "メールから承諾、未定、辞退を選び、クリックひとつでカレンダーに追加できます。"])),
  (("作成", [
     "下書き、あとで送信、送信の取り消し、返信がないときのリマインダー。",
     "複数の署名、別の送信アドレス、太字、リスト、リンク。",
     "返信の候補と書き直し。あなたが送るまで何も送信されません。",
     "どのアプリからでも共有ボタンでメールを書けます。"]), "same-drop-last"),
  (("どこでも", [
     "電波がなくてもアーカイブ、削除、フラグ付けができます。変更はオンラインに戻ったときに反映されます。",
     "振り分け、スヌーズ、ピン、許可、ブロックはiCloudでほかのデバイスにも反映されます。メール自体は送られません。"]),
   ("どこでも", [
     "接続がなくてもアーカイブ、削除、フラグ付けができます。変更はオンラインに戻ったときに反映されます。",
     "振り分け、スヌーズ、ピン、許可、ブロックはiCloudでiPhone、iPad、Macの間で共有されます。メール自体は送られません。"])),
  (("どのiPhoneでもスマート", [
     "「要対応」とその理由、金額、日付、注文番号などの重要な情報は、どのiPhoneでも使えます。",
     "Apple Intelligenceがあれば、Corresは要約と返信の候補もiPhone上で作成し、表示する前にメールと照らし合わせて確認します。"]),
   ("どのMacでもスマート", [
     "「要対応」とその理由、金額、日付、注文番号などの重要な情報は、どのMacでも使えます。",
     "Apple Intelligenceがあれば、Corresは要約と返信の候補もMac上で作成し、表示する前にメールと照らし合わせて確認します。"])),
  (("プライバシー", [
     "メールはプロバイダからiPhoneへ直接届きます。私たちのサーバに届くことはありません。",
     "リモート画像とトラッキングピクセルは許可するまでブロックされ、配信停止はワンタップです。",
     "広告はありません。データが販売されたり、AIの学習に使われたりすることはありません。"]),
   ("プライバシー", [
     "メールはプロバイダからMacへ直接届きます。私たちのサーバに届くことはありません。",
     "リモート画像とトラッキングピクセルは許可するまでブロックされ、配信停止はワンクリックです。",
     "広告はありません。データが販売されたり、AIの学習に使われたりすることはありません。"])),
 ],
 pro=("無料とPro", "メールは無料です。すべてのアカウントで閲覧、作成、検索、整理ができます。Corres Proでは「要対応」「返信待ち」、検索での回答、要約、返信の候補が使えます。Proは無料トライアルから始まり、その後は月額または年額で自動更新されます。期間終了の24時間前までに{cancel}でキャンセルしない限り更新されます。買い切りは1回限りの購入です。",
      {"ios": "iPhoneの設定", "mac": "Apple Accountの設定"}),
 terms="利用規約", privacy="プライバシー",
)

L["zh-Hans"] = dict(
 subtitle="知道什么需要你处理的邮件",
 keywords="邮件,电子邮件,收件箱,优先,邮件管理,摘要,回复,跟进,筛选,专注,隐私,离线,订阅,邮箱",
 promo=("Gmail、Outlook、iCloud 等邮箱汇集在一个收件箱。Corres 先显示需要你处理的邮件并说明原因，你的邮件只保留在 iPhone 上。",
        "Gmail、Outlook、iCloud 等邮箱汇集在一个收件箱。Corres 先显示需要你处理的邮件并说明原因，你的邮件只保留在 Mac 上。"),
 intro=("Corres 打开时先显示需要你处理的邮件。Gmail、Outlook、iCloud 以及几乎所有其他邮件账户都在一个收件箱里，在你的 iPhone 上阅读和分类。向你提出请求的邮件排在最前，每封都附上原因。其余邮件就在轻扫之外，安静地等你准备好。",
        "Corres 打开时先显示需要你处理的邮件。Gmail、Outlook、iCloud 以及几乎所有其他邮件账户都在一个收件箱里，在你的 Mac 上阅读和分类。向你提出请求的邮件排在最前，每封都附上原因。其余邮件就在一次点按之外，安静地等你准备好。"),
 sections=[
  (None, ("真正的 Mac App", [
     "原生、快速、键盘优先：沿用“邮件”的快捷键，⌘K 可前往任意位置或执行任意操作，拖移即可归档。",
     "对话可在独立窗口中打开，标签和文件夹在边栏中，邮件可在“聚焦”中找到。",
     "一次购买，即可在 iPhone、iPad 和 Mac 上使用 Corres。"])),
  (("需要你与等待中", [
     "“需要你”收纳带有问题、决定或截止日期的邮件，分为“即将到期”和“有空再看”。",
     "“等待中”列出你发出但尚未收到回复的邮件，并在该跟进时提醒你。",
     "处理完了？轻扫即可。分错了？按住移动，Corres 会学习。"]),
   ("需要你与等待中", [
     "“需要你”收纳带有问题、决定或截止日期的邮件，分为“即将到期”和“有空再看”。",
     "“等待中”列出你发出但尚未收到回复的邮件，并在该跟进时提醒你。",
     "处理完了？一个按键即可归档。分错了？移动它，Corres 会学习。"])),
  (("你的所有账户", [
     "Gmail、Google Workspace、Outlook.com、Microsoft 365 和 iCloud 邮件，以及 Yahoo、AOL、Fastmail、Zoho 或工作服务器，只需地址和密码。",
     "Corres 将邮件分为主要、促销、社交和动态，并从你移动的邮件中学习。",
     "每个账户都有自己的颜色、名称、签名和通知设置。",
     "Outlook 和 iCloud 的新邮件几秒内就会通知你。"]), "same-drop-last"),
  (("新发件人", [
     "陌生人的第一封邮件会等待，直到你允许或屏蔽。",
     "可一次允许或屏蔽整家公司，改变主意也能撤销。"]), "same"),
  (("会回答问题的搜索", [
     "一次搜索所有账户，包括已归档的邮件，支持 from:、has:attachment 和 is:unread 等筛选。",
     "问一句“我的航班是什么时候？”，就能从你自己的邮件中得到答案。",
     "也能在主屏幕的搜索中找到任意对话。"]),
   ("会回答问题的搜索", [
     "一次搜索所有账户，包括已归档的邮件，支持 from:、has:attachment 和 is:unread 等筛选。",
     "问一句“我的航班是什么时候？”，就能从你自己的邮件中得到答案。",
     "也能在“聚焦”中找到任意对话。"])),
  (("邀请", [
     "查看你所在时区的时间、地点、要加入的视频通话，以及你是否有空。",
     "直接在邮件中接受、待定或拒绝，轻点一下即可添加到日历。"]),
   ("邀请", [
     "查看你所在时区的时间、地点、要加入的视频通话，以及你是否有空。",
     "直接在邮件中接受、待定或拒绝，点按一下即可添加到日历。"])),
  (("写邮件", [
     "草稿、稍后发送、撤销发送，以及无人回复时的提醒。",
     "多个签名、其他发件地址，以及粗体、列表和链接。",
     "建议回复和改写。在你发送之前，什么都不会发出。",
     "在任何 App 中都能通过共享按钮写邮件。"]), "same-drop-last"),
  (("随时随地", [
     "没有信号也能归档、删除和加旗标。恢复联网后，更改会自动完成。",
     "你的分类、稍后提醒、置顶、允许和屏蔽会通过 iCloud 同步到你的其他设备。你的邮件不会。"]),
   ("随时随地", [
     "没有网络也能归档、删除和加旗标。恢复联网后，更改会自动完成。",
     "你的分类、稍后提醒、置顶、允许和屏蔽会通过 iCloud 在 iPhone、iPad 和 Mac 之间同步。你的邮件不会。"])),
  (("每台 iPhone 都智能", [
     "“需要你”、其原因，以及金额、日期和订单号等关键信息，在每台 iPhone 上都能使用。",
     "有了 Apple 智能，Corres 还会在 iPhone 本机上生成摘要和建议回复，并在显示前对照邮件核实。"]),
   ("每台 Mac 都智能", [
     "“需要你”、其原因，以及金额、日期和订单号等关键信息，在每台 Mac 上都能使用。",
     "有了 Apple 智能，Corres 还会在 Mac 本机上生成摘要和建议回复，并在显示前对照邮件核实。"])),
  (("隐私", [
     "你的邮件从服务商直接传到你的 iPhone。我们的服务器从不接收。",
     "远程图片和追踪像素在你允许前一律拦截，退订只需轻点一下。",
     "没有广告。你的数据绝不会被出售或用于训练 AI。"]),
   ("隐私", [
     "你的邮件从服务商直接传到你的 Mac。我们的服务器从不接收。",
     "远程图片和追踪像素在你允许前一律拦截，退订只需点按一下。",
     "没有广告。你的数据绝不会被出售或用于训练 AI。"])),
 ],
 pro=("免费与 Pro", "“邮件”免费：可阅读、撰写、搜索和整理所有账户。Corres Pro 新增“需要你”、“等待中”、搜索中的回答、摘要和建议回复。Pro 从免费试用开始，之后按月或按年自动续订，除非你在当期结束前至少 24 小时在{cancel}中取消。终身版为一次性购买。",
      {"ios": "iPhone 的“设置”", "mac": "Apple 账户设置"}),
 terms="条款", privacy="隐私",
)

L["de-DE"] = dict(
 subtitle="Mail, die mitdenkt",
 keywords="posteingang,email,mail,priorität,newsletter,zusammenfassung,antworten,nachfassen,fokus,privat",
 promo=("Gmail, Outlook, iCloud und mehr in einem Eingang. Corres öffnet mit den E-Mails, die dich brauchen, sagt warum und hält deine E-Mails auf deinem iPhone.",
        "Gmail, Outlook, iCloud und mehr in einem Eingang. Corres öffnet mit den E-Mails, die dich brauchen, sagt warum und hält deine E-Mails auf deinem Mac."),
 intro=("Corres öffnet mit dem, was dich braucht. Gmail, Outlook, iCloud und fast jeder andere E-Mail-Account landen in einem Eingang, gelesen und sortiert auf deinem iPhone. Die E-Mails, die etwas von dir wollen, stehen oben, jeweils mit dem Grund. Der Rest wartet ein Streichen entfernt, ruhig, bis du so weit bist.",
        "Corres öffnet mit dem, was dich braucht. Gmail, Outlook, iCloud und fast jeder andere E-Mail-Account landen in einem Eingang, gelesen und sortiert auf deinem Mac. Die E-Mails, die etwas von dir wollen, stehen oben, jeweils mit dem Grund. Der Rest wartet einen Klick entfernt, ruhig, bis du so weit bist."),
 sections=[
  (None, ("EINE ECHTE MAC-APP", [
     "Nativ, schnell und für die Tastatur gemacht: die Kurzbefehle von Mail, ⌘K, um überall hinzugehen oder alles zu tun, und Ziehen zum Ablegen.",
     "Konversationen in eigenen Fenstern, Labels und Ordner in der Seitenleiste und deine E-Mails in Spotlight.",
     "Ein Kauf gilt für Corres auf iPhone, iPad und Mac."])),
  (("BRAUCHT DICH UND WARTET", [
     "„Braucht dich“ sammelt E-Mails mit einer Frage, einer Entscheidung oder einer Frist für dich, aufgeteilt in „Bald fällig“ und „Wenn du Zeit hast“.",
     "„Wartet“ zeigt E-Mails, die du gesendet hast und auf die noch keine Antwort kam, und erinnert dich ans Nachfassen.",
     "Erledigt? Weg damit per Streichen. Falsch einsortiert? Lange drücken zum Bewegen, und Corres lernt dazu."]),
   ("BRAUCHT DICH UND WARTET", [
     "„Braucht dich“ sammelt E-Mails mit einer Frage, einer Entscheidung oder einer Frist für dich, aufgeteilt in „Bald fällig“ und „Wenn du Zeit hast“.",
     "„Wartet“ zeigt E-Mails, die du gesendet hast und auf die noch keine Antwort kam, und erinnert dich ans Nachfassen.",
     "Erledigt? Mit einer Taste archivieren. Falsch einsortiert? Bewegen, und Corres lernt dazu."])),
  (("ALLE DEINE ACCOUNTS", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365 und iCloud Mail, dazu Yahoo, AOL, Fastmail, Zoho oder ein Server bei der Arbeit, nur mit Adresse und Passwort.",
     "Allgemein, Werbung, Soziale Netzwerke und Updates, sortiert von Corres, das aus den E-Mails lernt, die du bewegst.",
     "Jeder Account hat eigene Farbe, eigenen Namen, eigene Signaturen und Mitteilungen.",
     "Neue E-Mails von Outlook und iCloud melden sich innerhalb von Sekunden."]), "same-drop-last"),
  (("NEUE ABSENDER", [
     "Erste E-Mails von jemand Neuem warten, bis du erlaubst oder blockierst.",
     "Erlaube oder blockiere eine ganze Firma auf einmal und mach es rückgängig, wenn du es dir anders überlegst."]), "same"),
  (("SUCHE, DIE ANTWORTET", [
     "Durchsuche alle Accounts auf einmal, archivierte E-Mails eingeschlossen, mit Filtern wie from:, has:attachment und is:unread.",
     "Stell eine Frage wie „Wann geht mein Flug?“ und bekomm die Antwort aus deinen eigenen E-Mails.",
     "Finde jede Konversation auch über die Suche auf dem Home-Bildschirm."]),
   ("SUCHE, DIE ANTWORTET", [
     "Durchsuche alle Accounts auf einmal, archivierte E-Mails eingeschlossen, mit Filtern wie from:, has:attachment und is:unread.",
     "Stell eine Frage wie „Wann geht mein Flug?“ und bekomm die Antwort aus deinen eigenen E-Mails.",
     "Finde jede Konversation auch über Spotlight."])),
  (("EINLADUNGEN", [
     "Sieh die Uhrzeit in deiner Zeitzone, den Ort, den Videoanruf zum Beitreten und ob du frei bist.",
     "Zusagen, Vielleicht oder Absagen direkt in der E-Mail und mit einem Tipp in den Kalender."]),
   ("EINLADUNGEN", [
     "Sieh die Uhrzeit in deiner Zeitzone, den Ort, den Videoanruf zum Beitreten und ob du frei bist.",
     "Zusagen, Vielleicht oder Absagen direkt in der E-Mail und mit einem Klick in den Kalender."])),
  (("SCHREIBEN", [
     "Entwürfe, Später senden, Senden widerrufen und eine Erinnerung, wenn niemand antwortet.",
     "Mehrere Signaturen, weitere Absenderadressen sowie Fett, Listen und Links.",
     "Antwortvorschläge und Umformulierungen. Nichts wird gesendet, bevor du es sendest.",
     "Schreib eine E-Mail aus jeder App über die Teilen-Taste."]), "same-drop-last"),
  (("ÜBERALL", [
     "Archivieren, löschen und markieren ohne Netz. Deine Änderungen gehen durch, sobald du wieder online bist.",
     "Was du sortierst, erinnern lässt, anheftest, erlaubst und blockierst, folgt dir über iCloud auf deine anderen Geräte. Deine E-Mails nie."]),
   ("ÜBERALL", [
     "Archivieren, löschen und markieren ohne Verbindung. Deine Änderungen gehen durch, sobald du wieder online bist.",
     "Was du sortierst, erinnern lässt, anheftest, erlaubst und blockierst, folgt dir über iCloud zwischen iPhone, iPad und Mac. Deine E-Mails nie."])),
  (("SMART AUF JEDEM IPHONE", [
     "„Braucht dich“, die Gründe dafür und wichtige Details wie Beträge, Termine und Bestellnummern funktionieren auf jedem iPhone.",
     "Mit Apple Intelligence schreibt Corres außerdem Zusammenfassungen und Antwortvorschläge, direkt auf dem iPhone, und prüft jede davon an der E-Mail, bevor du sie siehst."]),
   ("SMART AUF JEDEM MAC", [
     "„Braucht dich“, die Gründe dafür und wichtige Details wie Beträge, Termine und Bestellnummern funktionieren auf jedem Mac.",
     "Mit Apple Intelligence schreibt Corres außerdem Zusammenfassungen und Antwortvorschläge, direkt auf dem Mac, und prüft jede davon an der E-Mail, bevor du sie siehst."])),
  (("DATENSCHUTZ", [
     "Deine E-Mails kommen von deinem Anbieter direkt auf dein iPhone. Unsere Server erhalten sie nie.",
     "Externe Bilder und Tracking-Pixel bleiben blockiert, bis du sie erlaubst, und Abmelden ist ein Tipp.",
     "Keine Werbung. Deine Daten werden nie verkauft oder zum Trainieren von KI verwendet."]),
   ("DATENSCHUTZ", [
     "Deine E-Mails kommen von deinem Anbieter direkt auf deinen Mac. Unsere Server erhalten sie nie.",
     "Externe Bilder und Tracking-Pixel bleiben blockiert, bis du sie erlaubst, und Abmelden ist ein Klick.",
     "Keine Werbung. Deine Daten werden nie verkauft oder zum Trainieren von KI verwendet."])),
 ],
 pro=("KOSTENLOS UND PRO", "„E-Mail“ ist kostenlos: lesen, schreiben, suchen und ordnen in jedem Account. Corres Pro bietet „Braucht dich“, „Wartet“, Antworten in der Suche, Zusammenfassungen und Antwortvorschläge. Pro beginnt mit einem kostenlosen Test und verlängert sich dann monatlich oder jährlich, sofern du nicht mindestens 24 Stunden vor Ende des Zeitraums in {cancel} kündigst. „Dauerhaft“ ist ein einmaliger Kauf.",
      {"ios": "den Einstellungen deines iPhone", "mac": "den Einstellungen deines Apple Accounts"}),
 terms="Nutzungsbedingungen", privacy="Datenschutz",
)

L["ko"] = dict(
 subtitle="꼭 필요한 메일을 먼저",
 keywords="이메일,메일,받은편지함,우선순위,뉴스레터,요약,답장,후속조치,정리,집중,개인정보,오프라인,스팸",
 promo=("Gmail, Outlook, iCloud 등을 하나의 받은 편지함에서. Corres는 나에게 필요한 메일부터 이유와 함께 보여주고, 메일은 iPhone에만 둡니다.",
        "Gmail, Outlook, iCloud 등을 하나의 받은 편지함에서. Corres는 나에게 필요한 메일부터 이유와 함께 보여주고, 메일은 Mac에만 둡니다."),
 intro=("Corres는 나에게 필요한 것부터 엽니다. Gmail, Outlook, iCloud를 비롯한 거의 모든 이메일 계정을 하나의 받은 편지함에 모아 iPhone에서 읽고 분류합니다. 나에게 무언가를 요청하는 메일이 이유와 함께 맨 위에 오고, 나머지 메일은 한 번 쓸어넘기면 닿는 곳에서 조용히 기다립니다.",
        "Corres는 나에게 필요한 것부터 엽니다. Gmail, Outlook, iCloud를 비롯한 거의 모든 이메일 계정을 하나의 받은 편지함에 모아 Mac에서 읽고 분류합니다. 나에게 무언가를 요청하는 메일이 이유와 함께 맨 위에 오고, 나머지 메일은 한 번 클릭하면 닿는 곳에서 조용히 기다립니다."),
 sections=[
  (None, ("진짜 Mac 앱", [
     "네이티브로 빠르고 키보드 중심: Mail의 단축키, 어디든 가거나 무엇이든 하는 ⌘K, 드래그로 정리.",
     "대화를 별도 윈도우로, 레이블과 폴더는 사이드바에, 메일은 Spotlight에서.",
     "한 번 구입으로 iPhone, iPad, Mac의 Corres를 모두 사용합니다."])),
  (("나에게 필요와 대기 중", [
     "'나에게 필요'에는 질문, 결정, 마감이 있는 메일이 '곧 마감'과 '여유 있을 때'로 나뉘어 담깁니다.",
     "'대기 중'에는 보냈지만 아직 답장이 없는 메일이 모이고, 후속 조치할 때를 알려줍니다.",
     "끝났나요? 쓸어넘겨 정리하세요. 잘못 분류되었나요? 길게 눌러 옮기면 Corres가 배웁니다."]),
   ("나에게 필요와 대기 중", [
     "'나에게 필요'에는 질문, 결정, 마감이 있는 메일이 '곧 마감'과 '여유 있을 때'로 나뉘어 담깁니다.",
     "'대기 중'에는 보냈지만 아직 답장이 없는 메일이 모이고, 후속 조치할 때를 알려줍니다.",
     "끝났나요? 키 하나로 보관하세요. 잘못 분류되었나요? 옮기면 Corres가 배웁니다."])),
  (("모든 계정", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365, iCloud 메일은 물론 Yahoo, AOL, Fastmail, Zoho, 회사 서버도 주소와 암호만으로.",
     "기본, 프로모션, 소셜, 업데이트로 Corres가 분류하고, 내가 옮긴 메일에서 배웁니다.",
     "계정마다 색상, 이름, 서명, 알림을 따로 설정합니다.",
     "Outlook과 iCloud의 새로운 메일은 몇 초 안에 알림이 옵니다."]), "same-drop-last"),
  (("새 보낸 사람", [
     "처음 보는 사람의 첫 이메일은 허용하거나 차단할 때까지 기다립니다.",
     "회사 전체를 한 번에 허용하거나 차단하고, 마음이 바뀌면 되돌릴 수 있습니다."]), "same"),
  (("답을 주는 검색", [
     "보관된 메일을 포함해 모든 계정을 한 번에 검색하고, from:, has:attachment, is:unread 같은 필터를 사용하세요.",
     "'내 항공편이 언제지?'처럼 물으면 내 메일에서 답을 찾아줍니다.",
     "홈 화면의 검색에서도 대화를 찾을 수 있습니다."]),
   ("답을 주는 검색", [
     "보관된 메일을 포함해 모든 계정을 한 번에 검색하고, from:, has:attachment, is:unread 같은 필터를 사용하세요.",
     "'내 항공편이 언제지?'처럼 물으면 내 메일에서 답을 찾아줍니다.",
     "Spotlight에서도 대화를 찾을 수 있습니다."])),
  (("초대", [
     "내 시간대 기준 시간, 장소, 참여할 화상 통화, 그 시간에 비어 있는지 확인하세요.",
     "메일에서 바로 수락, 미정, 거절하고, 한 번 탭으로 캘린더에 추가합니다."]),
   ("초대", [
     "내 시간대 기준 시간, 장소, 참여할 화상 통화, 그 시간에 비어 있는지 확인하세요.",
     "메일에서 바로 수락, 미정, 거절하고, 한 번 클릭으로 캘린더에 추가합니다."])),
  (("작성", [
     "임시 저장, 나중에 보내기, 보내기 취소, 답장이 없을 때 알림.",
     "여러 서명, 다른 보내는 주소, 굵게, 목록, 링크.",
     "추천 답장과 다시 쓰기. 직접 보내기 전에는 아무것도 전송되지 않습니다.",
     "어느 앱에서든 공유 버튼으로 이메일을 쓸 수 있습니다."]), "same-drop-last"),
  (("어디서나", [
     "신호가 없어도 보관, 삭제, 깃발 표시가 됩니다. 다시 온라인이 되면 변경 사항이 반영됩니다.",
     "분류, 다시 알림, 고정, 허용, 차단은 iCloud로 다른 기기에도 이어집니다. 메일 자체는 이동하지 않습니다."]),
   ("어디서나", [
     "연결이 없어도 보관, 삭제, 깃발 표시가 됩니다. 다시 온라인이 되면 변경 사항이 반영됩니다.",
     "분류, 다시 알림, 고정, 허용, 차단은 iCloud로 iPhone, iPad, Mac 사이에 이어집니다. 메일 자체는 이동하지 않습니다."])),
  (("모든 iPhone에서 스마트하게", [
     "'나에게 필요', 그 이유, 금액, 날짜, 주문 번호 같은 주요 정보는 모든 iPhone에서 작동합니다.",
     "Apple Intelligence가 있으면 Corres가 iPhone에서 직접 요약과 추천 답장도 작성하고, 보여주기 전에 메일과 대조해 확인합니다."]),
   ("모든 Mac에서 스마트하게", [
     "'나에게 필요', 그 이유, 금액, 날짜, 주문 번호 같은 주요 정보는 모든 Mac에서 작동합니다.",
     "Apple Intelligence가 있으면 Corres가 Mac에서 직접 요약과 추천 답장도 작성하고, 보여주기 전에 메일과 대조해 확인합니다."])),
  (("개인정보 보호", [
     "메일은 제공업체에서 iPhone으로 바로 전달됩니다. 저희 서버는 메일을 받지 않습니다.",
     "원격 이미지와 추적 픽셀은 허용할 때까지 차단되고, 수신 거부는 한 번 탭이면 됩니다.",
     "광고가 없습니다. 데이터를 판매하거나 AI 학습에 사용하지 않습니다."]),
   ("개인정보 보호", [
     "메일은 제공업체에서 Mac으로 바로 전달됩니다. 저희 서버는 메일을 받지 않습니다.",
     "원격 이미지와 추적 픽셀은 허용할 때까지 차단되고, 수신 거부는 한 번 클릭이면 됩니다.",
     "광고가 없습니다. 데이터를 판매하거나 AI 학습에 사용하지 않습니다."])),
 ],
 pro=("무료와 Pro", "메일은 무료입니다. 모든 계정에서 읽고, 쓰고, 검색하고, 정리하세요. Corres Pro는 '나에게 필요', '대기 중', 검색의 답변, 요약, 추천 답장을 추가합니다. Pro는 무료 체험으로 시작해 이후 월간 또는 연간으로 자동 갱신되며, 기간 종료 최소 24시간 전에 {cancel}에서 취소하지 않으면 갱신됩니다. 평생 이용권은 1회 구입입니다.",
      {"ios": "iPhone 설정", "mac": "Apple 계정 설정"}),
 terms="이용 약관", privacy="개인정보 처리방침",
)

L["fr-FR"] = dict(
 subtitle="Le mail qui sait ce qui compte",
 keywords="boîte de réception,email,mail,priorité,newsletter,résumé,répondre,relance,tri,concentration,privé",
 promo=("Gmail, Outlook, iCloud et plus dans une seule boîte. Corres s’ouvre sur les e-mails qui vous attendent, dit pourquoi, et garde vos e-mails sur votre iPhone.",
        "Gmail, Outlook, iCloud et plus dans une seule boîte. Corres s’ouvre sur les e-mails qui vous attendent, dit pourquoi, et garde vos e-mails sur votre Mac."),
 intro=("Corres s’ouvre sur ce qui vous attend. Gmail, Outlook, iCloud et presque tous les autres comptes de messagerie réunis dans une seule boîte, lus et triés sur votre iPhone. Les e-mails qui vous demandent quelque chose passent en premier, chacun avec sa raison. Le reste attend à un balayage, au calme, jusqu’à ce que vous soyez prêt.",
        "Corres s’ouvre sur ce qui vous attend. Gmail, Outlook, iCloud et presque tous les autres comptes de messagerie réunis dans une seule boîte, lus et triés sur votre Mac. Les e-mails qui vous demandent quelque chose passent en premier, chacun avec sa raison. Le reste attend à un clic, au calme, jusqu’à ce que vous soyez prêt."),
 sections=[
  (None, ("UNE VRAIE APP MAC", [
     "Native, rapide et pensée pour le clavier : les raccourcis de Mail, ⌘K pour aller partout ou tout faire, et le glisser pour classer.",
     "Les conversations dans leur propre fenêtre, libellés et dossiers dans la barre latérale, et vos e-mails dans Spotlight.",
     "Un seul achat pour Corres sur iPhone, iPad et Mac."])),
  (("POUR VOUS ET EN ATTENTE", [
     "Pour vous rassemble les e-mails avec une question, une décision ou une échéance pour vous, répartis entre Bientôt dus et Quand vous pouvez.",
     "En attente liste les e-mails envoyés restés sans réponse, et vous prévient quand il est temps de relancer.",
     "Fini avec l’un d’eux ? Balayez-le. Mal classé ? Maintenez-le appuyé pour le déplacer, et Corres apprend."]),
   ("POUR VOUS ET EN ATTENTE", [
     "Pour vous rassemble les e-mails avec une question, une décision ou une échéance pour vous, répartis entre Bientôt dus et Quand vous pouvez.",
     "En attente liste les e-mails envoyés restés sans réponse, et vous prévient quand il est temps de relancer.",
     "Fini avec l’un d’eux ? Archivez-le d’une touche. Mal classé ? Déplacez-le, et Corres apprend."])),
  (("TOUS VOS COMPTES", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365 et iCloud Mail, plus Yahoo, AOL, Fastmail, Zoho ou un serveur professionnel avec simplement votre adresse et votre mot de passe.",
     "Principale, Promotions, Réseaux sociaux et Mises à jour, triés par Corres qui apprend des e-mails que vous déplacez.",
     "Chaque compte a sa couleur, son nom, ses signatures et ses notifications.",
     "Les nouveaux e-mails Outlook et iCloud vous notifient en quelques secondes."]), "same-drop-last"),
  (("NOUVEAUX EXPÉDITEURS", [
     "Les premiers e-mails d’une nouvelle personne attendent que vous l’autorisiez ou la bloquiez.",
     "Autorisez ou bloquez toute une entreprise d’un coup, et annulez si vous changez d’avis."]), "same"),
  (("UNE RECHERCHE QUI RÉPOND", [
     "Cherchez dans tous vos comptes à la fois, e-mails archivés compris, avec des filtres comme from:, has:attachment et is:unread.",
     "Posez une question comme « quand est mon vol ? » et obtenez la réponse à partir de vos propres e-mails.",
     "Retrouvez aussi n’importe quelle conversation depuis la recherche de l’écran d’accueil."]),
   ("UNE RECHERCHE QUI RÉPOND", [
     "Cherchez dans tous vos comptes à la fois, e-mails archivés compris, avec des filtres comme from:, has:attachment et is:unread.",
     "Posez une question comme « quand est mon vol ? » et obtenez la réponse à partir de vos propres e-mails.",
     "Retrouvez aussi n’importe quelle conversation depuis Spotlight."])),
  (("INVITATIONS", [
     "Voyez l’heure dans votre fuseau horaire, le lieu, l’appel vidéo à rejoindre, et si vous êtes libre.",
     "Acceptez, répondez Peut-être ou refusez depuis l’e-mail, et ajoutez-la au calendrier d’un toucher."]),
   ("INVITATIONS", [
     "Voyez l’heure dans votre fuseau horaire, le lieu, l’appel vidéo à rejoindre, et si vous êtes libre.",
     "Acceptez, répondez Peut-être ou refusez depuis l’e-mail, et ajoutez-la au calendrier d’un clic."])),
  (("RÉDACTION", [
     "Brouillons, Envoyer plus tard, Annuler l’envoi, et un rappel si personne ne répond.",
     "Plusieurs signatures, d’autres adresses d’envoi, et gras, listes et liens.",
     "Réponses suggérées et reformulations. Rien n’est envoyé tant que vous ne l’envoyez pas.",
     "Écrivez un e-mail depuis le bouton Partager de n’importe quelle app."]), "same-drop-last"),
  (("PARTOUT", [
     "Archivez, supprimez et signalez sans réseau. Vos changements sont appliqués dès votre retour en ligne.",
     "Ce que vous triez, rappelez plus tard, épinglez, autorisez et bloquez vous suit sur vos autres appareils via iCloud. Vos e-mails, jamais."]),
   ("PARTOUT", [
     "Archivez, supprimez et signalez sans connexion. Vos changements sont appliqués dès votre retour en ligne.",
     "Ce que vous triez, rappelez plus tard, épinglez, autorisez et bloquez vous suit entre iPhone, iPad et Mac via iCloud. Vos e-mails, jamais."])),
  (("INTELLIGENT SUR TOUS LES IPHONE", [
     "Pour vous, ses raisons, et les détails clés comme les montants, les dates et les numéros de commande fonctionnent sur tous les iPhone.",
     "Avec Apple Intelligence, Corres rédige aussi des résumés et des réponses suggérées, sur l’iPhone lui-même, et vérifie chacun d’eux par rapport à l’e-mail avant de vous le montrer."]),
   ("INTELLIGENT SUR TOUS LES MAC", [
     "Pour vous, ses raisons, et les détails clés comme les montants, les dates et les numéros de commande fonctionnent sur tous les Mac.",
     "Avec Apple Intelligence, Corres rédige aussi des résumés et des réponses suggérées, sur le Mac lui-même, et vérifie chacun d’eux par rapport à l’e-mail avant de vous le montrer."])),
  (("CONFIDENTIALITÉ", [
     "Vos e-mails vont de votre fournisseur directement sur votre iPhone. Nos serveurs ne les reçoivent jamais.",
     "Les images distantes et les pixels de suivi sont bloqués jusqu’à ce que vous les autorisiez, et le désabonnement se fait d’un toucher.",
     "Aucune publicité. Vos données ne sont jamais vendues ni utilisées pour entraîner une IA."]),
   ("CONFIDENTIALITÉ", [
     "Vos e-mails vont de votre fournisseur directement sur votre Mac. Nos serveurs ne les reçoivent jamais.",
     "Les images distantes et les pixels de suivi sont bloqués jusqu’à ce que vous les autorisiez, et le désabonnement se fait d’un clic.",
     "Aucune publicité. Vos données ne sont jamais vendues ni utilisées pour entraîner une IA."])),
 ],
 pro=("GRATUIT ET PRO", "Messagerie est gratuite : lire, écrire, rechercher et organiser tous vos comptes. Corres Pro ajoute Pour vous, En attente, les réponses dans la recherche, les résumés et les réponses suggérées. Pro commence par un essai gratuit, puis se renouvelle chaque mois ou chaque année, sauf résiliation au moins 24 heures avant la fin de la période, dans {cancel}. La formule À vie est un achat unique.",
      {"ios": "les Réglages de votre iPhone", "mac": "les réglages de votre compte Apple"}),
 terms="Conditions", privacy="Confidentialité",
)

L["es-ES"] = dict(
 subtitle="El correo que sabe qué importa",
 keywords="bandeja de entrada,correo,email,prioridad,boletín,resumen,responder,seguimiento,enfoque,privado",
 promo=("Gmail, Outlook, iCloud y más en una sola bandeja. Corres se abre en los correos que te necesitan, te dice por qué y mantiene tu correo en tu iPhone.",
        "Gmail, Outlook, iCloud y más en una sola bandeja. Corres se abre en los correos que te necesitan, te dice por qué y mantiene tu correo en tu Mac."),
 intro=("Corres se abre en lo que te necesita. Gmail, Outlook, iCloud y casi cualquier otra cuenta de correo en una sola bandeja, leída y clasificada en tu iPhone. Los correos que te piden algo van primero, cada uno con su motivo. El resto de tu correo espera a un deslizamiento, en calma hasta que estés listo.",
        "Corres se abre en lo que te necesita. Gmail, Outlook, iCloud y casi cualquier otra cuenta de correo en una sola bandeja, leída y clasificada en tu Mac. Los correos que te piden algo van primero, cada uno con su motivo. El resto de tu correo espera a un clic, en calma hasta que estés listo."),
 sections=[
  (None, ("UNA APP DE MAC DE VERDAD", [
     "Nativa, rápida y pensada para el teclado: los atajos de Mail, ⌘K para ir a cualquier sitio o hacer cualquier cosa, y arrastrar para archivar.",
     "Conversaciones en su propia ventana, etiquetas y carpetas en la barra lateral, y tu correo en Spotlight.",
     "Una sola compra sirve para Corres en iPhone, iPad y Mac."])),
  (("TE NECESITA Y EN ESPERA", [
     "Te necesita reúne los correos con una pregunta, una decisión o una fecha límite para ti, en Vence pronto y Cuando puedas.",
     "En espera muestra los correos que enviaste sin respuesta, y te avisa cuando toca hacer seguimiento.",
     "¿Ya está? Deslízalo. ¿Se equivocó? Mantenlo pulsado para moverlo, y Corres aprende."]),
   ("TE NECESITA Y EN ESPERA", [
     "Te necesita reúne los correos con una pregunta, una decisión o una fecha límite para ti, en Vence pronto y Cuando puedas.",
     "En espera muestra los correos que enviaste sin respuesta, y te avisa cuando toca hacer seguimiento.",
     "¿Ya está? Archívalo con una tecla. ¿Se equivocó? Muévelo, y Corres aprende."])),
  (("TODAS TUS CUENTAS", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365 e iCloud Mail, además de Yahoo, AOL, Fastmail, Zoho o un servidor del trabajo con solo tu dirección y contraseña.",
     "Principal, Promociones, Social y Novedades, clasificados por Corres, que aprende de los correos que mueves.",
     "Cada cuenta tiene su color, nombre, firmas y avisos.",
     "El correo nuevo de Outlook e iCloud te avisa en segundos."]), "same-drop-last"),
  (("REMITENTES NUEVOS", [
     "Los primeros correos de alguien nuevo esperan hasta que lo permitas o lo bloquees.",
     "Permite o bloquea una empresa entera de una vez, y deshazlo si cambias de idea."]), "same"),
  (("UNA BÚSQUEDA QUE RESPONDE", [
     "Busca en todas las cuentas a la vez, correo archivado incluido, con filtros como from:, has:attachment e is:unread.",
     "Haz una pregunta como «¿cuándo es mi vuelo?» y obtén la respuesta de tu propio correo.",
     "Encuentra cualquier conversación también desde la búsqueda de la pantalla de inicio."]),
   ("UNA BÚSQUEDA QUE RESPONDE", [
     "Busca en todas las cuentas a la vez, correo archivado incluido, con filtros como from:, has:attachment e is:unread.",
     "Haz una pregunta como «¿cuándo es mi vuelo?» y obtén la respuesta de tu propio correo.",
     "Encuentra cualquier conversación también desde Spotlight."])),
  (("INVITACIONES", [
     "Ve la hora en tu zona horaria, el lugar, la videollamada a la que unirte y si estás libre.",
     "Acepta, responde Quizás o rechaza desde el correo, y añádela al calendario con un toque."]),
   ("INVITACIONES", [
     "Ve la hora en tu zona horaria, el lugar, la videollamada a la que unirte y si estás libre.",
     "Acepta, responde Quizás o rechaza desde el correo, y añádela al calendario con un clic."])),
  (("ESCRIBIR", [
     "Borradores, Enviar más tarde, Deshacer envío y un recordatorio si nadie responde.",
     "Varias firmas, otras direcciones de envío, y negrita, listas y enlaces.",
     "Respuestas sugeridas y reescrituras. No se envía nada hasta que tú lo envías.",
     "Escribe un correo desde el botón Compartir de cualquier app."]), "same-drop-last"),
  (("EN CUALQUIER LUGAR", [
     "Archiva, elimina y marca sin cobertura. Tus cambios se aplican cuando vuelves a estar en línea.",
     "Lo que clasificas, pospones, fijas, permites y bloqueas te sigue a tus otros dispositivos con iCloud. Tu correo nunca."]),
   ("EN CUALQUIER LUGAR", [
     "Archiva, elimina y marca sin conexión. Tus cambios se aplican cuando vuelves a estar en línea.",
     "Lo que clasificas, pospones, fijas, permites y bloqueas te sigue entre iPhone, iPad y Mac con iCloud. Tu correo nunca."])),
  (("INTELIGENTE EN CUALQUIER IPHONE", [
     "Te necesita, sus motivos y datos clave como importes, fechas y números de pedido funcionan en cualquier iPhone.",
     "Con Apple Intelligence, Corres también escribe resúmenes y respuestas sugeridas, en el propio iPhone, y comprueba cada uno con el correo antes de mostrártelo."]),
   ("INTELIGENTE EN CUALQUIER MAC", [
     "Te necesita, sus motivos y datos clave como importes, fechas y números de pedido funcionan en cualquier Mac.",
     "Con Apple Intelligence, Corres también escribe resúmenes y respuestas sugeridas, en el propio Mac, y comprueba cada uno con el correo antes de mostrártelo."])),
  (("PRIVACIDAD", [
     "Tu correo va de tu proveedor directo a tu iPhone. Nuestros servidores nunca lo reciben.",
     "Las imágenes remotas y los píxeles de rastreo se bloquean hasta que los permites, y darse de baja es un toque.",
     "Sin anuncios. Tus datos nunca se venden ni se usan para entrenar IA."]),
   ("PRIVACIDAD", [
     "Tu correo va de tu proveedor directo a tu Mac. Nuestros servidores nunca lo reciben.",
     "Las imágenes remotas y los píxeles de rastreo se bloquean hasta que los permites, y darse de baja es un clic.",
     "Sin anuncios. Tus datos nunca se venden ni se usan para entrenar IA."])),
 ],
 pro=("GRATIS Y PRO", "Correo es gratis: lee, escribe, busca y organiza todas tus cuentas. Corres Pro añade Te necesita, En espera, respuestas en la búsqueda, resúmenes y respuestas sugeridas. Pro empieza con una prueba gratuita y después se renueva cada mes o cada año, salvo que canceles al menos 24 horas antes del final del periodo en {cancel}. Vitalicio es una compra única.",
      {"ios": "los Ajustes de tu iPhone", "mac": "los ajustes de tu cuenta de Apple"}),
 terms="Condiciones", privacy="Privacidad",
)

L["pt-BR"] = dict(
 subtitle="E-mail que sabe o que importa",
 keywords="caixa de entrada,email,correio,prioridade,newsletter,resumo,responder,acompanhar,foco,privado",
 promo=("Gmail, Outlook, iCloud e mais em uma só caixa. O Corres abre nos e-mails que precisam de você, diz por quê e mantém seus e-mails no seu iPhone.",
        "Gmail, Outlook, iCloud e mais em uma só caixa. O Corres abre nos e-mails que precisam de você, diz por quê e mantém seus e-mails no seu Mac."),
 intro=("O Corres abre no que precisa de você. Gmail, Outlook, iCloud e quase qualquer outra conta de e-mail em uma só caixa de entrada, lidos e classificados no seu iPhone. Os e-mails que pedem algo a você vêm primeiro, cada um com o motivo. O resto espera a um deslize, em silêncio até você estar pronto.",
        "O Corres abre no que precisa de você. Gmail, Outlook, iCloud e quase qualquer outra conta de e-mail em uma só caixa de entrada, lidos e classificados no seu Mac. Os e-mails que pedem algo a você vêm primeiro, cada um com o motivo. O resto espera a um clique, em silêncio até você estar pronto."),
 sections=[
  (None, ("UM APP DE MAC DE VERDADE", [
     "Nativo, rápido e feito para o teclado: os atalhos do Mail, ⌘K para ir a qualquer lugar ou fazer qualquer coisa, e arrastar para arquivar.",
     "Conversas em janelas próprias, etiquetas e pastas na barra lateral, e seus e-mails no Spotlight.",
     "Uma única compra vale para o Corres no iPhone, iPad e Mac."])),
  (("PRECISA DE VOCÊ E AGUARDANDO", [
     "Precisa de Você reúne os e-mails com uma pergunta, uma decisão ou um prazo para você, em Vence em breve e Quando puder.",
     "Aguardando lista os e-mails que você enviou e ainda não tiveram resposta, e avisa quando é hora de acompanhar.",
     "Terminou? Deslize. Classificou errado? Mantenha pressionado para mover, e o Corres aprende."]),
   ("PRECISA DE VOCÊ E AGUARDANDO", [
     "Precisa de Você reúne os e-mails com uma pergunta, uma decisão ou um prazo para você, em Vence em breve e Quando puder.",
     "Aguardando lista os e-mails que você enviou e ainda não tiveram resposta, e avisa quando é hora de acompanhar.",
     "Terminou? Arquive com uma tecla. Classificou errado? Mova, e o Corres aprende."])),
  (("TODAS AS SUAS CONTAS", [
     "Gmail, Google Workspace, Outlook.com, Microsoft 365 e E-mail do iCloud, além de Yahoo, AOL, Fastmail, Zoho ou um servidor do trabalho só com seu endereço e senha.",
     "Principal, Promoções, Social e Atualizações, classificados pelo Corres, que aprende com os e-mails que você move.",
     "Cada conta tem sua cor, nome, assinaturas e notificações.",
     "E-mails novos do Outlook e do iCloud notificam você em segundos."]), "same-drop-last"),
  (("NOVOS REMETENTES", [
     "Os primeiros e-mails de alguém novo esperam até você permitir ou bloquear.",
     "Permita ou bloqueie uma empresa inteira de uma vez, e desfaça se mudar de ideia."]), "same"),
  (("UMA BUSCA QUE RESPONDE", [
     "Busque em todas as contas de uma vez, incluindo e-mails arquivados, com filtros como from:, has:attachment e is:unread.",
     "Faça uma pergunta como “quando é meu voo?” e receba a resposta dos seus próprios e-mails.",
     "Encontre qualquer conversa também pela Busca na Tela de Início."]),
   ("UMA BUSCA QUE RESPONDE", [
     "Busque em todas as contas de uma vez, incluindo e-mails arquivados, com filtros como from:, has:attachment e is:unread.",
     "Faça uma pergunta como “quando é meu voo?” e receba a resposta dos seus próprios e-mails.",
     "Encontre qualquer conversa também pelo Spotlight."])),
  (("CONVITES", [
     "Veja o horário no seu fuso, o local, a chamada de vídeo para entrar e se você está livre.",
     "Aceite, responda Talvez ou recuse pelo e-mail, e adicione ao calendário com um toque."]),
   ("CONVITES", [
     "Veja o horário no seu fuso, o local, a chamada de vídeo para entrar e se você está livre.",
     "Aceite, responda Talvez ou recuse pelo e-mail, e adicione ao calendário com um clique."])),
  (("ESCRITA", [
     "Rascunhos, Enviar depois, Desfazer envio e um lembrete se ninguém responder.",
     "Várias assinaturas, outros endereços de envio, e negrito, listas e links.",
     "Respostas sugeridas e reescritas. Nada é enviado até você enviar.",
     "Escreva um e-mail pelo botão Compartilhar de qualquer app."]), "same-drop-last"),
  (("EM QUALQUER LUGAR", [
     "Arquive, apague e sinalize sem sinal. Suas alterações são aplicadas quando você volta a ficar online.",
     "O que você classifica, adia, fixa, permite e bloqueia acompanha você nos seus outros dispositivos pelo iCloud. Seus e-mails, nunca."]),
   ("EM QUALQUER LUGAR", [
     "Arquive, apague e sinalize sem conexão. Suas alterações são aplicadas quando você volta a ficar online.",
     "O que você classifica, adia, fixa, permite e bloqueia acompanha você entre iPhone, iPad e Mac pelo iCloud. Seus e-mails, nunca."])),
  (("INTELIGENTE EM QUALQUER IPHONE", [
     "Precisa de Você, seus motivos e detalhes importantes como valores, datas e números de pedido funcionam em qualquer iPhone.",
     "Com a Apple Intelligence, o Corres também escreve resumos e respostas sugeridas, no próprio iPhone, e confere cada um com o e-mail antes de mostrar."]),
   ("INTELIGENTE EM QUALQUER MAC", [
     "Precisa de Você, seus motivos e detalhes importantes como valores, datas e números de pedido funcionam em qualquer Mac.",
     "Com a Apple Intelligence, o Corres também escreve resumos e respostas sugeridas, no próprio Mac, e confere cada um com o e-mail antes de mostrar."])),
  (("PRIVACIDADE", [
     "Seus e-mails vão do seu provedor direto para o seu iPhone. Nossos servidores nunca os recebem.",
     "Imagens remotas e pixels de rastreamento ficam bloqueados até você permitir, e descadastrar é um toque.",
     "Sem anúncios. Seus dados nunca são vendidos nem usados para treinar IA."]),
   ("PRIVACIDADE", [
     "Seus e-mails vão do seu provedor direto para o seu Mac. Nossos servidores nunca os recebem.",
     "Imagens remotas e pixels de rastreamento ficam bloqueados até você permitir, e descadastrar é um clique.",
     "Sem anúncios. Seus dados nunca são vendidos nem usados para treinar IA."])),
 ],
 pro=("GRÁTIS E PRO", "O E-mail é grátis: leia, escreva, busque e organize todas as contas. O Corres Pro adiciona Precisa de Você, Aguardando, respostas na busca, resumos e respostas sugeridas. O Pro começa com um teste gratuito e depois renova todo mês ou todo ano, a menos que você cancele pelo menos 24 horas antes do fim do período, {cancel}. O Vitalício é uma compra única.",
      {"ios": "nos Ajustes do seu iPhone", "mac": "nos ajustes da sua Conta Apple"}),
 terms="Termos", privacy="Privacidade",
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
    e = dict(subtitle=d["subtitle"], keywords=d["keywords"],
             ios=dict(description=description(d, "ios"), promotionalText=d["promo"][0]),
             mac=dict(description=description(d, "mac"), promotionalText=d["promo"][1]))
    assert len(e["subtitle"]) <= 30, (loc, len(e["subtitle"]))
    assert len(e["keywords"]) <= 100, (loc, len(e["keywords"]))
    assert ", " not in e["keywords"]
    for p in ("ios", "mac"):
        assert len(e[p]["description"]) <= 4000
        assert len(e[p]["promotionalText"]) <= 170, (loc, p, len(e[p]["promotionalText"]))
        assert "—" not in e[p]["description"]
    out[loc] = e
    print(loc, len(e["subtitle"]), len(e["keywords"]), len(e["ios"]["description"]), len(e["mac"]["description"]), len(e["ios"]["promotionalText"]))
json.dump(out, open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
