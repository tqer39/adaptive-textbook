import { bookSchema } from "../schema";
export const legacyBook = bookSchema.parse({
  bookId: "caa-first-rrset",
  version: "1.0.0",
  title: "親の禁止は、子にも届く？",
  blocks: [
    {
      id: "read",
      kind: "reading",
      title: "01 / 最初の RRset が決める",
      markdown:
        'CAA は、認証局（CA）がそのドメインの証明書を発行してよいかを確認する DNS レコードです。発行前の制約であり、既存の証明書の有効性を判断する仕組みではありません。\n\nRRset は、同じ名前・クラス・種類に属するレコードの集合です。CA は対象名から親へ進み、**最初に見つけた CAA RRset** を採用します。親と子の CAA は合算しません。\n\n親 example.com に `CAA 0 issue ";"` があると、許可する CA がなく発行は禁止です。子 api.example.com に CAA がなければ、親の RRset が採用されます。\n\nでは、子に `CAA 0 iodef "mailto:security@example.com"` だけを置くと？ iodef は違反の報告先を示します。発行制限を指定する issue ではありません。',
      advanced:
        "運用の視点：DNS の委任境界と CAA の探索停止条件は同じものではありません。下位チームが iodef を追加しただけでも Relevant RRset が変わります。親だけの監査では見落とすため、対象名での探索と採用 RRset を確認します。",
    },
    { id: "explore", kind: "diagram", title: "02 / DNS の親子を操作する" },
    {
      id: "predict",
      kind: "question",
      title: "03 / 結果を予測する",
      scenario: "report",
      prompt:
        '親は issue ";"。子は iodef だけ。Let’s Encrypt は api.example.com に対して、CAA ポリシー上、許可されるでしょうか？',
    },
    {
      id: "explain",
      kind: "reading",
      title: "04 / 親の禁止が届かない理由",
      markdown:
        '子の iodef も CAA レコードです。したがって子で RRset が見つかり、探索はそこで終わります。採用する子の RRset に issue がないので、**CAA による発行制限はありません**。親の禁止を引き継ぐために探索を続けることはありません。\n\n禁止を維持したいなら、子の同じ RRset に `CAA 0 issue ";"` を置く方法があります。ただし同じ RRset に CA を許可する issue もあれば、その CA は許可されます。「禁止が常に優先する」とは考えないでください。\n\nCAA ポリシー上の許可は、証明書発行成功ではありません。ドメイン所有確認・DNS 応答・CA の審査などは別に必要です。',
    },
    {
      id: "takeaway",
      kind: "summary",
      title: "05 / 明日、説明できるように",
      markdown:
        "**対象から親へ、最初の RRset で止まる。親子は合算しない。iodef は発行制限ではない。**\n\n説明の練習：同僚に「親で禁止しているのに、なぜ子は許可される？」と聞かれたら、探索停止 → 採用 RRset → issue の有無、の順で答えてみましょう。\n\n記事の下書き課題：①親子のレコード ②探索の手順 ③許可と発行成功の違い、を自分の言葉で書く。公開や提出はありません。\n\n模擬運用課題：図で子を「発行禁止」に変え、どの RRset が採用されるか再確認してください。実際の DNS やクラウドは変更しません。",
    },
  ],
});
