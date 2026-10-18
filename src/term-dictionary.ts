export const termIds = [
  "ca",
  "rrset",
  "iodef",
  "lets-encrypt",
  "dnssec",
  "resolver",
  "authoritative-dns",
] as const;
export type TermId = (typeof termIds)[number];
type Explanation = {
  label: string;
  definition: string;
  example: string;
  detail?: string;
  source: { title: string; url: string };
  relatedSource?: { title: string; url: string };
};
const caaSource = {
  title: "RFC 8659 §2–4",
  url: "https://www.rfc-editor.org/rfc/rfc8659.html",
};
const dnsSource = {
  title: "RFC 9499 §6",
  url: "https://www.rfc-editor.org/rfc/rfc9499.html#section-6",
};
const definitions: Record<TermId, Explanation> = {
  ca: {
    source: caaSource,
    label: "認証局",
    definition: "証明書を発行する主体（CA）です。",
    example:
      "Let’s Encrypt は認証局の一つです。CAA の許可に加え、所有確認なども必要です。",
  },
  rrset: {
    source: caaSource,
    label: "RRset",
    definition: "同じ名前・種類・クラスに属する DNS レコードの集合です。",
    example:
      "api.example.com の IN CAA に issue と iodef があれば、両方が同じ集合に入ります。親 example.com の集合とは別です。",
  },
  iodef: {
    source: caaSource,
    label: "iodef",
    definition:
      "CAA 違反の報告先を指定する属性です。発行を制限する属性ではありません。",
    example:
      'CAA 0 iodef "mailto:security@example.com" は報告先を示します。通知の送信・到達を保証しません。',
  },
  "lets-encrypt": {
    label: "Let’s Encrypt",
    definition: "Web サイトの HTTPS 用証明書を無料で自動発行する認証局です。",
    example:
      'CAA 0 issue "letsencrypt.org" は、Let’s Encrypt に CAA ポリシー上の発行を許可します。',
    detail:
      "認証局の具体例です。DNS のレコードを公開するサービスとは役割が違います。CAA 上の許可だけで発行が成功するわけではなく、対象名の所有確認なども必要です。",
    source: {
      title: "Let’s Encrypt について",
      url: "https://letsencrypt.org/about/",
    },
    relatedSource: {
      title: "CAA の指定方法",
      url: "https://letsencrypt.org/docs/caa/",
    },
  },
  dnssec: {
    label: "DNSSEC",
    definition:
      "電子署名を使い、DNS の答えの出所と改ざんの有無を検証できるようにする仕組みです。",
    example:
      "署名された CAA の答えを検証できても、どの CA を許可するかは CAA の内容を別に判断します。",
    detail:
      "通信を暗号化したり、証明書を発行できる認証局を指定したりする機能ではありません。検証には正しくつながる署名と、それを検証する側の設定が必要です。この図では署名の検証や失敗時の処理を再現していません。",
    source: {
      title: "RFC 4033 §3–4",
      url: "https://www.rfc-editor.org/rfc/rfc4033.html#section-3",
    },
  },
  resolver: {
    label: "リゾルバー",
    definition: "DNS の問い合わせに対して、必要な答えを探すソフトウェアです。",
    example:
      "CA が再帰リゾルバーへ CAA を問い合わせ、そのリゾルバーが権威 DNS から答えを得て CA に返す構成があります。",
    detail:
      "この図で省略した再帰リゾルバーは、依頼者に代わって他の DNS サーバーへ問い合わせます。以前の答えを一定時間保存して使うこともあります。担当範囲の正式なレコードを提供する権威 DNS とは役割が違い、CAA による発行許可を判断する主体は CA です。",
    source: dnsSource,
  },
  "authoritative-dns": {
    label: "権威 DNS",
    definition:
      "担当する DNS の範囲について、設定された正式なレコードを答えるサーバーです。",
    example:
      "example.com を担当する権威 DNS が、api.example.com の CAA レコードを返します。CA はその内容から許可を判断します。",
    detail:
      "他のサーバーへ答えを探しに行くリゾルバーとは役割が違います。権威 DNS は、担当外の子の範囲を別のサーバーへ案内することもあります。図の名前の親子関係と、サーバーが担当する範囲の境界は同じとは限りません。",
    source: dnsSource,
  },
};
export function termExplanation(term: TermId, blockId: string) {
  const scope = [
    "scope",
    "boundary",
    "scope-predict",
    "sibling-predict",
    "override-predict",
  ].includes(blockId);
  const additionalContext: Partial<Record<TermId, string>> = {
    "lets-encrypt":
      "この教材では発行元の CA の例です。画面の許可は CAA ポリシー上の判断で、証明書の発行完了を示しません。",
    dnssec:
      "このセクションでは CAA の探索と許可を扱います。DNSSEC の署名検証は図の範囲外です。CAA は誤発行をすべて防ぐ仕組みではなく、既存の証明書も失効させません。",
    resolver:
      "発行前の図は再帰リゾルバーを省略しています。実際には問い合わせを仲介する構成があり、画面から実 DNS へは問い合わせません。",
    "authoritative-dns":
      "発行前の図ではレコードを返す役です。発行許可を判断するのは CA であり、権威 DNS が証明書を発行するのではありません。",
  };
  let context =
    additionalContext[term] ??
    (term === "ca"
      ? "この教材では、指定した対象名をこの CA が発行してよいかを CAA 上で判断します。許可と発行成功は別です。"
      : term === "rrset"
        ? scope
          ? "この場面では、対象名から親へ探索し、最初に見つかった集合を採用します。独自の集合があれば、その上の禁止を足しません。"
          : "この場面では、子の集合が見つかればそこで探索を止めます。親と子の集合は合算しません。"
        : scope
          ? "この場面では、子孫の独自 RRset が iodef だけでも、その集合で探索が止まります。上の名前の禁止は採用しません。"
          : "この場面では、子に iodef だけを置くと子で探索が止まります。その集合に issue がないため、CAA による制限はありません。");
  if (term === "rrset" && blockId === "limits")
    context =
      "この場面では、同じ集合に空の issue と CA を許可する issue がある場合を比べます。空の issue が他の許可を取り消すわけではありません。";
  if (term === "rrset" && blockId === "renewal-predict")
    context =
      "この場面では、採用した集合の issue に指定された CA と、更新先の CA を比較します。集合に存在するだけで全 CA を許可するわけではありません。";
  return { ...definitions[term], context };
}
