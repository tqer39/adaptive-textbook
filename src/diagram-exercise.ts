import { diagram } from "./diagram";
import { button, el } from "./ui";
import { feedbackMessage, policyFeedback } from "./feedback";
import {
  comparePrediction,
  scenarioSnapshot,
  type Prediction,
} from "./diagram-learning";
import { formatRecord, scenarios, type Scenario } from "./caa";
import type { History } from "./history";
export type LearningStore = { history: History; save: () => void };
type State = {
  mode: "choice" | "predict" | "saved" | "free";
  attemptId?: string;
  scenario: Scenario;
  reason: string;
  selected: "allow" | "deny" | null;
  difference: string;
  changed: string;
  helpful: string;
  understanding: "clearer" | "unchanged" | "unsure" | null;
};
const sessions = new Map<string, State>();
export function diagramExercise(
  identity: { bookId: string; version: string; blockId: string },
  store: LearningStore,
) {
  const { history } = store;
  const matching = () =>
    history.diagramPredictions.filter(
      (p) =>
        p.bookId === identity.bookId &&
        p.version === identity.version &&
        p.blockId === identity.blockId,
    );
  const key = `${identity.bookId}:${identity.version}:${identity.blockId}`;
  const previous = matching().at(-1);
  let state = sessions.get(key);
  if (!state) {
    state = {
      mode: previous ? "saved" : "choice",
      attemptId: previous?.attemptId,
      scenario: "report",
      reason: "",
      selected: null,
      difference: "",
      changed: "",
      helpful: "",
      understanding: null,
    };
    sessions.set(key, state);
  }
  const s = state;
  const root = el("div", undefined, "diagram-exercise");
  const stamp = () => ({
    ...identity,
    userId: history.userId,
    time: new Date().toISOString(),
  });
  function input(label: string, value: string, change: (text: string) => void) {
    const wrapper = el("label", label);
    const text = el("textarea");
    text.rows = 2;
    text.maxLength = 1000;
    text.value = value;
    text.addEventListener("input", () => change(text.value));
    wrapper.append(text);
    return wrapper;
  }
  function newPrediction() {
    s.mode = "predict";
    s.attemptId = undefined;
    s.reason = "";
    s.selected = null;
    s.difference = "";
    s.changed = "";
    s.helpful = "";
    s.understanding = null;
    draw();
    root.querySelector<HTMLSelectElement>("select")?.focus();
  }
  function savePrediction(skip: boolean) {
    if (s.mode !== "predict") return;
    const prediction: Prediction = {
      ...stamp(),
      attemptId: crypto.randomUUID(),
      snapshot: scenarioSnapshot(s.scenario),
      prediction: skip ? null : s.selected,
      reason: s.reason,
    };
    history.diagramPredictions.push(prediction);
    s.attemptId = prediction.attemptId;
    s.mode = "saved";
    store.save();
    draw();
    root.querySelector<HTMLButtonElement>("[data-reveal]")?.focus();
  }
  function draw() {
    root.replaceChildren();
    root.append(
      el("h3", "図を動かす前に予想する"),
      el(
        "p",
        "親は発行禁止。子の設定を選び、Let’s Encrypt が api.example.com を CAA 上で発行できるか予想します。理由・ふりかえりは任意です。AI は使いません。",
      ),
    );
    if (s.mode === "choice") {
      root.append(
        button("予想して図を見る", newPrediction),
        button("予想をスキップして自由探索", () => {
          s.mode = "free";
          draw();
        }),
      );
      return;
    }
    if (s.mode === "free") {
      root.append(
        el("p", "自由探索：予想や正誤として記録しません。"),
        button("予想して図を見る", newPrediction),
        diagram(s.scenario, (scenario) => {
          s.scenario = scenario;
        }),
      );
      return;
    }
    if (s.mode === "predict") {
      const label = el("label", "予想する子の設定");
      const select = el("select");
      for (const scenario of scenarios) {
        const option = el("option", scenario.label);
        option.value = scenario.id;
        select.append(option);
      }
      select.value = s.scenario;
      label.append(select);
      const config = el("div", undefined, "records");
      function showConfig() {
        config.replaceChildren(
          el("p", "対象：api.example.com / CA：letsencrypt.org"),
          el("code", '親 example.com: CAA 0 issue ";"'),
        );
        const records = scenarioSnapshot(s.scenario).tree["api.example.com"];
        config.append(el("p", "子 api.example.com の設定"));
        for (const r of records) config.append(el("code", formatRecord(r)));
        if (!records.length) config.append(el("p", "CAA なし"));
      }
      select.addEventListener("change", () => {
        s.scenario = select.value as Scenario;
        s.selected = null;
        draw();
        root.querySelector("select")?.focus();
      });
      showConfig();
      const group = el("fieldset");
      group.append(el("legend", "予想（CAA ポリシー上）"));
      const save = button("予想を保存", () => savePrediction(false));
      save.disabled = s.selected === null;
      for (const [value, text] of [
        ["allow", "許可されると予想"],
        ["deny", "禁止されると予想"],
      ] as const) {
        const choice = button(text, () => {
          s.selected = value;
          group
            .querySelectorAll("button")
            .forEach((b) =>
              b.setAttribute("aria-pressed", String(b === choice)),
            );
          save.disabled = false;
        });
        choice.setAttribute("aria-pressed", String(s.selected === value));
        group.append(choice);
      }
      root.append(
        label,
        config,
        group,
        input("予想の理由（任意・1000文字まで）", s.reason, (v) => {
          s.reason = v;
        }),
        el(
          "p",
          "保存後に結果を開けます。入力途中の未保存文は再読み込みで戻りません。",
          "muted",
        ),
        save,
        button("予想せず結果へ（未回答として保存）", () =>
          savePrediction(true),
        ),
      );
      return;
    }
    const prediction = matching().find((p) => p.attemptId === s.attemptId);
    if (!prediction) {
      s.mode = "choice";
      draw();
      return;
    }
    const reveal = history.diagramReveals.find(
      (r) => r.attemptId === prediction.attemptId,
    );
    const comparison = comparePrediction(prediction);
    const snapshot = prediction.snapshot;
    root.append(
      el(
        "p",
        `保存した予想：${snapshot.target} / ${snapshot.issuer} / ${scenarios.find((x) => x.id === snapshot.scenario)!.label}`,
      ),
      el(
        "p",
        `あなたの予想：${prediction.prediction === null ? "未回答（評価なし）" : prediction.prediction === "allow" ? "許可" : "禁止"}`,
      ),
      el("p", `理由：${prediction.reason || "記入なし"}`),
      el("p", `記録時刻：${prediction.time}`, "muted"),
    );
    if (!reveal) {
      root.append(
        feedbackMessage(
          "neutral",
          "予想を記録しました",
          "結果はまだ表示していません。保存エラーが表示されている場合はこのタブ内だけの記録です。",
        ),
      );
      const show = button("結果と図を見る", () => {
        if (
          history.diagramReveals.some(
            (r) => r.attemptId === prediction.attemptId,
          )
        )
          return;
        history.diagramReveals.push({
          ...stamp(),
          revealId: crypto.randomUUID(),
          attemptId: prediction.attemptId,
          allowed: comparison.result.allowed,
          correct: comparison.correct,
        });
        store.save();
        draw();
        root.querySelector<HTMLElement>(".prediction-comparison")?.focus();
      });
      show.dataset.reveal = "true";
      root.append(show);
    } else {
      const fixed = el("div", undefined, "prediction-comparison");
      fixed.tabIndex = -1;
      fixed.append(
        el("h3", "保存した設定と予想の比較"),
        feedbackMessage(
          comparison.correct === null
            ? "neutral"
            : comparison.correct
              ? "success"
              : "error",
          comparison.correct === null
            ? "未回答：正誤の評価なし"
            : comparison.correct
              ? "予想は一致しました"
              : "予想と結果が違いました",
          "この比較は保存した設定だけが対象です。理解度を自動で判定しません。",
        ),
        policyFeedback(comparison.result.allowed, comparison.result.reason),
      );
      root.append(fixed);
      const exploration = el("div");
      const note = el("div");
      exploration.append(
        el(
          "p",
          "ここからは自由探索。設定を変えても、上の比較と保存した予想は変わりません。",
        ),
        note,
        diagram(snapshot.scenario, (scenario) => {
          note.replaceChildren();
          if (scenario !== snapshot.scenario)
            note.append(
              feedbackMessage(
                "warning",
                "保存した予想と異なる設定を探索中",
                "上の比較は元の設定に固定しています。この結果を元の予想の正誤として扱いません。",
              ),
            );
        }),
      );
      root.append(exploration);
      const reflections = history.diagramReflections.filter(
        (r) => r.attemptId === prediction.attemptId,
      );
      if (reflections.length) {
        const saved = el("details");
        saved.append(
          el("summary", `保存したふりかえり（${reflections.length}件）`),
        );
        for (const r of reflections)
          saved.append(
            el(
              "p",
              `${r.time}\n違い：${r.difference || "未記入"}\n変化：${r.changed || "未記入"}\n助かった説明：${r.helpful || "未記入"}\n理解の自己申告：${r.understanding === "clearer" ? "前より説明できそう" : r.understanding === "unchanged" ? "変わらない" : r.understanding === "unsure" ? "まだ迷う" : "未回答"}`,
            ),
          );
        root.append(saved);
      }
      root.append(
        el("h3", "短くふりかえる（任意）"),
        input("予想と何が違った？（任意）", s.difference, (v) => {
          s.difference = v;
        }),
      );
      const more = el("details");
      more.append(
        el("summary", "理解の変化・助かった説明も記録する（任意）"),
        input("理解がどう変わった？（任意）", s.changed, (v) => {
          s.changed = v;
        }),
        input("どの説明が助かった？（任意）", s.helpful, (v) => {
          s.helpful = v;
        }),
      );
      const self = el("label", "理解の自己申告（任意・正誤とは別）");
      const options = el("select");
      for (const [value, text] of [
        ["", "未回答"],
        ["clearer", "前より説明できそう"],
        ["unchanged", "変わらない"],
        ["unsure", "まだ迷う"],
      ]) {
        const o = el("option", text);
        o.value = value;
        options.append(o);
      }
      options.value = s.understanding ?? "";
      options.addEventListener("change", () => {
        s.understanding = (options.value as State["understanding"]) || null;
      });
      self.append(options);
      more.append(self);
      root.append(more);
      const reflect = button("ふりかえりを追加保存", () => {
        if (
          !s.difference.trim() &&
          !s.changed.trim() &&
          !s.helpful.trim() &&
          !s.understanding
        )
          return;
        history.diagramReflections.push({
          ...stamp(),
          reflectionId: crypto.randomUUID(),
          attemptId: prediction.attemptId,
          difference: s.difference,
          changed: s.changed,
          helpful: s.helpful,
          understanding: s.understanding,
        });
        s.difference = "";
        s.changed = "";
        s.helpful = "";
        s.understanding = null;
        store.save();
        draw();
        root.querySelector<HTMLElement>("details > summary")?.focus();
      });
      root.append(
        reflect,
        el(
          "p",
          "追加保存は過去の文を上書きしません。未記入のままでも先へ進めます。",
          "muted",
        ),
      );
    }
    root.append(
      button("新しい予想で再挑戦", newPrediction),
      button("比較を閉じて自由探索", () => {
        s.mode = "free";
        draw();
      }),
    );
    if (matching().length > 1) {
      const archive = el("label", "過去の予想を確認");
      const select = el("select");
      for (const p of matching()) {
        const o = el(
          "option",
          `${p.time} / ${scenarios.find((x) => x.id === p.snapshot.scenario)!.label}`,
        );
        o.value = p.attemptId;
        select.append(o);
      }
      select.value = prediction.attemptId;
      select.addEventListener("change", () => {
        s.attemptId = select.value;
        s.difference = "";
        s.changed = "";
        s.helpful = "";
        s.understanding = null;
        draw();
      });
      archive.append(select);
      root.append(archive);
    }
  }
  draw();
  return root;
}
