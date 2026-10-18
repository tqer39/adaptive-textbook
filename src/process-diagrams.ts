import { evaluate, lookupStages, scenarios, type Scenario } from "./caa";
import { button, el } from "./ui";
export function issuanceSequence() {
  const figure = el("figure", undefined, "process-figure");
  figure.append(
    el("figcaption", "発行前の CAA 確認：誰が、誰に問い合わせる？"),
  );
  const participants = el("div", undefined, "sequence-participants");
  for (const name of ["申請者", "認証局（CA）", "権威 DNS"])
    participants.append(el("strong", name));
  figure.append(participants);
  const body = el("div", undefined, "sequence-body");
  body.setAttribute("aria-label", "やり取りは上から下の順に進む");
  for (const percent of ["16.667%", "50%", "83.333%"]) {
    const line = el("span", undefined, "lifeline");
    line.style.left = percent;
    line.setAttribute("aria-hidden", "true");
    body.append(line);
  }
  const list = el("ol", undefined, "sequence-events");
  const events = [
    {
      from: 0,
      to: 1,
      title: "申請者 → 認証局",
      text: "対象名 api.example.com を含む証明書を申請する。",
    },
    {
      from: 1,
      to: 2,
      title: "認証局 → 権威 DNS",
      text: "対象名の CAA を照会する。空の応答なら、親名も照会する。",
    },
    {
      from: 2,
      to: 1,
      title: "権威 DNS → 認証局",
      text: "照会した名前の CAA レコードの集合、または空の応答を返す。",
    },
    {
      from: 1,
      to: 1,
      title: "認証局の内部処理",
      text: "最初に見つかった集合を採用し、その CA が CAA 上、許可されるかを判断する。",
    },
  ];
  events.forEach((event, i) => {
    const item = el("li");
    const track = el("div", undefined, "sequence-arrow-track");
    track.setAttribute("aria-hidden", "true");
    const arrow = el(
      "span",
      event.from === event.to ? "↺" : undefined,
      "sequence-arrow",
    );
    if (event.from === event.to) arrow.classList.add("self-arrow");
    arrow.style.left = `${16.667 + Math.min(event.from, event.to) * 33.333}%`;
    arrow.style.width = event.from === event.to ? "26px" : "33.333%";
    if (event.from > event.to) arrow.classList.add("arrow-left");
    track.append(arrow);
    const message = el("div", undefined, "sequence-message");
    message.append(
      el("strong", `${i + 1}. ${event.title}`),
      el("p", event.text),
    );
    item.append(track, message);
    list.append(item);
  });
  body.append(list);
  figure.append(
    body,
    el(
      "p",
      "上から下が時間の順です。権威 DNS はレコードを返し、発行を許可するかは認証局が判断します。",
      "muted",
    ),
    el(
      "p",
      "やり取りを簡略化し、再帰リゾルバー・キャッシュ・各親名への反復照会・DNS 障害を省略しています。所有確認との厳密な実行順序は示していません。標準に準拠する CA の通常の確認を説明し、CP/CPS（認証局の証明書ポリシー・運用規程）の例外は扱いません。",
      "muted",
    ),
    el(
      "p",
      "ここでの許可は発行完了ではありません。所有確認や CA 独自の要件なども必要です。既存証明書の失効やブラウザの接続判断も、この確認の役割ではありません。",
      "muted",
    ),
  );
  return figure;
}
export function lookupFlow() {
  const root = el("div");
  const figure = el("figure", undefined, "process-figure");
  figure.append(el("figcaption", "採用する CAA レコードを探すフロー"));
  const flow = el("ol", undefined, "flowchart");
  function node(title: string, text: string) {
    const item = el("li", undefined, "flow-node");
    item.append(el("strong", title), el("p", text));
    return item;
  }
  flow.append(
    node("1 / 対象名から始める", "対象名を照会候補にする。"),
    node("2 / 候補名の CAA を照会する", "CAA レコードの集合（RRset）はある？"),
  );
  const branch = el("li", undefined, "flow-branches");
  const no = el("div", undefined, "flow-branch");
  no.append(
    el("strong", "ない → 親名へ"),
    el(
      "p",
      "親名を次の候補にして 2 へ戻る。root の手前まで見つからなければ「採用なし」で 3 へ。",
    ),
  );
  const yes = el("div", undefined, "flow-branch");
  yes.append(
    el("strong", "ある → 探索を止める"),
    el("p", "その集合を採用する。親の集合を足さず、3 へ。"),
  );
  branch.append(no, yes);
  flow.append(
    branch,
    node(
      "3 / 採用する集合を確定する",
      "ここからは、採用した集合だけで判断する。",
    ),
    node(
      "4 / この CA の許可を確認する",
      "issue にこの CA の許可があるか。今回の範囲では、issue がなければ CAA の制限なし。",
    ),
  );
  figure.append(flow);
  const overview = el("details", undefined, "flow-overview");
  overview.append(el("summary", "探索フロー全体を見る"), figure);
  const label = el("label", "フローを追う子の設定");
  const select = el("select");
  select.id = "flow-scenario";
  label.htmlFor = select.id;
  for (const s of scenarios) {
    const o = el("option", s.label);
    o.value = s.id;
    select.append(o);
  }
  select.value = "report";
  let step = 0;
  const output = el("div", undefined, "flow-run");
  output.setAttribute("aria-live", "polite");
  const controls = el("div", undefined, "flow-controls");
  const previous = button("一つ前のステップ", () => {
    if (step > 0) {
      step--;
      draw();
    }
  });
  const next = button("次のステップを見る", () => {
    if (step < lookupStages(select.value as Scenario).length - 1) {
      step++;
      draw();
    }
  });
  const reset = button("最初から追う", () => {
    step = 0;
    draw();
  });
  controls.append(previous, next, reset);
  function draw() {
    const stages = lookupStages(select.value as Scenario);
    output.replaceChildren(
      el("p", `ステップ ${step + 1} / ${stages.length}`, "eyebrow"),
    );
    const list = el("ol", undefined, "flow-stages");
    for (const stage of [stages[step]]) {
      const item = el("li");
      item.dataset.kind = stage.kind;
      item.setAttribute("aria-current", "step");
      list.start = step + 1;
      item.append(el("strong", stage.title), el("p", stage.detail));
      list.append(item);
    }
    output.append(list);
    previous.disabled = step === 0;
    next.disabled = step === stages.length - 1;
    if (step === stages.length - 1)
      output.append(
        el(
          "p",
          `判定の根拠: ${evaluate(select.value as Scenario).reason}`,
          "muted",
        ),
      );
  }
  select.addEventListener("change", () => {
    step = 0;
    draw();
  });
  root.append(
    label,
    select,
    controls,
    output,
    overview,
    el(
      "p",
      '親 example.com は issue ";" のまま。正常応答・非ワイルドカード・flags 0（特別なフラグなし）の固定例です。CNAME の追跡、未知 critical、issuewild、CA パラメータは省略しています。発行成功を判定するものではありません。',
      "muted",
    ),
  );
  draw();
  return root;
}
