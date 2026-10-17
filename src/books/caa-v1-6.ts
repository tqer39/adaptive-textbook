import { bookSchema } from "../schema";
import { legacyBook } from "./caa-v1";
export const version16Book = bookSchema.parse({
  bookId: "caa-first-rrset",
  version: "1.6.0",
  contentSchemaVersion: 4,
  title: "CAA は、どこまで効く？",
  blocks: [
    {
      id: "read",
      kind: "reading",
      title: "01 / 発行判断に使う CAA レコードはどれ？",
      visual: "issuance-sequence",
      outcomes: [
        "CAA で発行元を絞る目的と、発行成功や既存証明書の失効を保証しない限界を説明できる。",
        "設定が自分・子孫・親・兄弟のどこに効くかを、対象名からの探索で判断できる。",
        "最初に採用する CAA の集合を見つけ、その内容から指定した CA の許可・禁止を読み取れる。",
        "子の独自設定や更新先 CA の変更で見落としやすい点を挙げ、確認する箇所を説明できる。",
      ],
      markdown:
        "認証局（CA）は、証明書を発行する主体です。Let’s Encrypt はその一例で、DNS の提供者を指す名前ではありません。CAA は「この名前の証明書を、どの CA が発行してよいか」を DNS に示すレコードで、CA が発行前に確認します。\n\n**RRset は、同じ名前・種類・クラスに属する DNS レコードの集合です。**ここでは、ある名前の IN（インターネット用の DNS クラス）の CAA レコードをひとまとめにしたもの。issue と iodef が複数あっても、その名前の同じ集合に入ります。\n\nCA は申請する対象名から親名へ進み、**探索中に最初に見つかった CAA の集合を、発行判断に使います**。親と子の集合は合算しません。\n\nissue は許可する CA を指定します。iodef は違反の報告先を示し、発行を制限しません。報告が必ず送信・到達するという保証もありません。権威 DNS は担当する範囲のレコードを返し、リゾルバーは問い合わせに必要な答えを探す役割です。次の図では、間に入る再帰リゾルバーを省略して、問い合わせと発行判断を分けて見ます。",
    },
    ...legacyBook.blocks.slice(1, 3),
    {
      id: "explain",
      kind: "reading",
      title: "04 / どこで探索を止める？",
      visual: "lookup-flow",
      markdown:
        '親が issue ";" で禁止していても、子に iodef があれば、子で CAA の集合が見つかります。**探索は子で終わり、親の禁止は採用しません**。子の集合に issue がなければ、CAA による発行制限はありません。\n\n子でも禁止を維持したい場合は、子の同じ集合に issue ";" だけを置く方法があります。同じ集合に CA を許可する issue もあれば、その CA の許可は残ります。空の issue が他の許可を取り消すわけではありません。\n\n運用では、親だけでなく証明書の対象名から探索し、採用する集合を確認します。DNS の委任境界と探索の停止条件は同じではありません。下位チームが iodef を追加しただけでも採用する集合が変わるため、親だけの監査では見落とします。\n\n「名前を照会する」「使う集合を確定する」「この CA の許可を判断する」を分けて、次のフローを一つずつ追ってください。',
    },
    {
      id: "scope",
      kind: "reading",
      title: "05 / 子だけに禁止を置いたら",
      markdown:
        '親 example.com とその上位に CAA がなく、子 api.example.com だけに `CAA 0 issue ";"` を置きます。**禁止の範囲は、その子自身と、探索でその子の RRset に到達する子孫**です。上方向や兄弟へ禁止が伝わるわけではありません。\n\n子 api 自身はそこで停止して禁止。v1.api は CAA がなければ api へ進むので禁止。親 example.com は子を探さず、兄弟 www.example.com も api を通らないため、この禁止の対象になりません。今回は上位も CAA なしなので、この 2 名には CAA による制限がありません。\n\nspecial.api が独自の issue または iodef を持つと、そこで RRset が見つかり探索終了。api の禁止は採用しません。図で「CAA なし」「iodef だけ」「Let’s Encrypt を許可」を比較してください。\n\n運用では、組織の所有境界やゾーン委任だけから適用範囲を決めず、対象名からの探索で確認します。下位の独自 RRset を追加・変更すると禁止の範囲が変わるため、変更レビューで確認してください。',
    },
    {
      id: "boundary",
      kind: "scope-diagram",
      title: "06 / 5 つの名前を比較する",
    },
    {
      id: "scope-predict",
      kind: "question",
      title: "07 / 子孫の結果を予測",
      scenario: "child-descendant",
      prompt:
        '親と上位に CAA なし。api.example.com だけに issue ";"。v1.api.example.com に独自 CAA はありません。Let’s Encrypt にとって v1.api.example.com は CAA 上、許可されるでしょうか？',
    },
    {
      id: "sibling-predict",
      kind: "question",
      title: "08 / 兄弟の結果を予測",
      scenario: "child-sibling",
      prompt:
        "同じ設定で、www.example.com（api の兄弟）自身にも CAA はありません。Let’s Encrypt にとって www.example.com は CAA 上、許可されるでしょうか？",
    },
    {
      id: "override-predict",
      kind: "question",
      title: "09 / 独自 RRset の結果を予測",
      scenario: "child-independent",
      prompt:
        '親と上位に CAA なし。api.example.com は issue ";"。子孫 special.api.example.com に issue "letsencrypt.org" を置きました。Let’s Encrypt にとって special.api.example.com は CAA 上、許可されるでしょうか？',
    },
    {
      id: "applications",
      kind: "applications",
      title: "10 / CAA があると何が嬉しい？",
      cases: [
        {
          title: "想定する CA に絞る",
          scenario: "limited-other",
          prediction:
            "example.com の issue は letsencrypt.org だけ。別 CA（架空の other-ca.example）が発行しようとすると？",
          benefit:
            "標準に準拠する別 CA は CAA により発行を制限されます。使う予定の CA を絞り、想定外の CA からの発行リスクを減らせます。許可した CA による不正発行まで防げるものではありません。",
        },
        {
          title: "発行予定のない名前を禁止する",
          scenario: "child-self",
          prediction:
            '発行を予定していない検証用 api.example.com に issue ";" だけを置く。Let’s Encrypt が発行しようとすると？',
          benefit:
            "その名前の新規発行を CAA 上、禁止できます。子孫まで禁止したい場合は、途中や対象に独自 RRset がないことも確認します。親や兄弟の通常運用はこの設定では制限しません。",
        },
        {
          title: "更新時の CA 変更を見つける",
          scenario: "limited-other",
          prediction:
            "issue は letsencrypt.org のまま。更新先を別 CA（other-ca.example）へ変更したら？",
          benefit:
            "変更先 CA は CAA 上、禁止です。更新直前に気づくと失効後の障害につながり得ます。移行前に対象名の採用 RRset を確認し、意図した CA に方針を合わせることで、更新失敗を避ける判断に役立ちます。CAA を置けば自動で更新成功するわけではありません。",
        },
      ],
    },
    {
      id: "renewal-predict",
      kind: "question",
      title: "11 / CA を変えるときの予測",
      scenario: "limited-other",
      prompt:
        'example.com の採用 RRset は issue "letsencrypt.org" のみ。次回の更新に別 CA（架空の other-ca.example）を使うと、その CA は CAA 上、許可されるでしょうか？',
    },
    {
      id: "limits",
      kind: "reading",
      title: "12 / 全面禁止と CA 限定の違い",
      markdown:
        '**issue ";" のみなら許可する CA はゼロ。issue "letsencrypt.org" ならその CA を許可し、他の CA を制限します。**同じ RRset に両方あれば、Let’s Encrypt への許可は残ります。空の issue が他の許可を取り消すわけではありません。\n\nDNSSEC は DNS の答えの出所と改ざんの有無を検証する仕組みです。通信の暗号化や、発行してよい CA の指定はしません。CAA と役割が違います。\n\nCAA は標準に準拠する CA が発行前に確認する制御です。許可した CA の誤発行まで防ぐ万能な仕組みではありません。既存の証明書を失効させず、ブラウザの接続を直接拒否するものでもありません。\n\n図は各名前を単独で比較しています。実際の証明書が SAN（証明書に含める対象名の一覧）に複数の名前を含む場合、要求するすべての名前について CA の許可を確認する必要があります。1 名の許可から証明書全体の発行成功は判断できません。所有確認など他条件も必要です。\n\n今回の正常応答・非ワイルドカードの簡略 DNS 木では、図にない上位も CAA なしと仮定します。CNAME の追跡、issuewild、未知 critical、DNSSEC と障害、CP/CPS（認証局の証明書ポリシー・運用規程）の例外は未実装です。図の結果を実 DNS の診断に流用しないでください。',
    },
    {
      id: "takeaway",
      kind: "summary",
      title: "13 / 明日、説明できるように",
      markdown:
        "**対象から親へ、最初の RRset で止まる。親子は合算しない。上方向や兄弟には伝わらない。iodef は発行制限ではない。**\n\n説明の練習：①親の禁止が子の iodef で採用されなくなる理由 ②子だけの禁止が親・兄弟へ届かない理由 ③独自 RRset で探索が止まること、を自分の言葉で答えてみましょう。\n\n記事の下書き課題：子だけの禁止が届く範囲、独自 RRset の例外、CAA が助ける運用判断と限界を図と一緒にまとめる。公開や提出はありません。\n\n模擬運用課題：図で「全 CA 禁止」と「CA 限定」を比較し、対象ごとの採用 RRset と結果を説明してください。実際の DNS やクラウドは変更しません。",
    },
  ],
});
