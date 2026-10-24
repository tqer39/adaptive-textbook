import { effectiveTags } from "./article-tags";
import type { FeedArticle } from "./feed-parser";
export const normalizeSearch = (text: string) =>
  text.normalize("NFKC").toLowerCase();
export class ArticleSearch {
  private documents = new Map<
    string,
    { original: string[]; normalized: string }
  >();
  private generation = 0;
  ready = false;
  async prepare(
    articles: FeedArticle[],
    yieldWork = () => new Promise<void>((r) => setTimeout(r, 0)),
  ) {
    const generation = ++this.generation;
    this.ready = false;
    const next = new Map<string, { original: string[]; normalized: string }>();
    for (let i = 0; i < articles.length; i++) {
      if (i % 500 === 0) {
        await yieldWork();
        if (generation !== this.generation) return false;
      }
      const a = articles[i];
      const original = [
        effectiveTags(a).join(" "),
        a.title,
        a.body,
        a.content?.title ?? "",
        a.content?.text ?? "",
        a.translation?.sourceText === (a.content?.text || a.body)
          ? a.translation.text
          : "",
      ];
      const previous = this.documents.get(a.id);
      next.set(
        a.id,
        previous && previous.original.every((v, index) => v === original[index])
          ? previous
          : { original, normalized: normalizeSearch(original.join("\n")) },
      );
    }
    if (generation !== this.generation) return false;
    this.documents = next;
    this.ready = true;
    return true;
  }
  invalidate() {
    this.generation++;
    this.ready = false;
  }
  update(a: FeedArticle) {
    if (!this.ready) throw Error("検索の準備が終わっていません。");
    const original = [
      effectiveTags(a).join(" "),
      a.title,
      a.body,
      a.content?.title ?? "",
      a.content?.text ?? "",
      a.translation?.sourceText === (a.content?.text || a.body)
        ? a.translation.text
        : "",
    ];
    this.documents.set(a.id, {
      original,
      normalized: normalizeSearch(original.join("\n")),
    });
  }
  search(query: string): Set<string> {
    if (!this.ready) throw Error("検索の準備が終わっていません。");
    const terms = normalizeSearch(query).trim().split(/\s+/u).filter(Boolean);
    const found = new Set<string>();
    for (const [id, document] of this.documents)
      if (terms.every((term) => document.normalized.includes(term)))
        found.add(id);
    return found;
  }
}
