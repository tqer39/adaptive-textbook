export class ArticleSpeech {
  state: "idle" | "speaking" | "paused" = "idle";
  message = "";
  private epoch = 0;
  private utterance: SpeechSynthesisUtterance | null = null;
  constructor(private changed: () => void) {}
  get supported() {
    return (
      typeof speechSynthesis !== "undefined" &&
      typeof SpeechSynthesisUtterance !== "undefined"
    );
  }
  stop(notify = true) {
    this.epoch++;
    if (this.supported) speechSynthesis.cancel();
    this.utterance = null;
    this.state = "idle";
    this.message = "";
    if (notify) this.changed();
  }
  start(text: string, language: string, rate: number) {
    this.stop(false);
    if (!this.supported) {
      this.message = "このブラウザでは読み上げを利用できません。";
      this.changed();
      return;
    }
    if (!language) {
      this.message = "原文の言語を選択してから読み上げてください。";
      this.changed();
      return;
    }
    const voices = speechSynthesis
      .getVoices()
      .filter(
        (v) =>
          v.localService &&
          v.lang.toLowerCase().split("-")[0] === language.split("-")[0],
      );
    if (!voices.length) {
      this.message =
        "この言語の端末内音声が見つかりません。OSの音声設定で追加してから再試行してください。";
      this.changed();
      return;
    }
    const ticket = this.epoch;
    const chunks =
      text.match(/[^。！？.!?\n]{1,180}[。！？.!?\n]*|[。！？.!?\n]+/gu) ?? [];
    let index = 0;
    const next = () => {
      if (ticket !== this.epoch) return;
      if (index >= chunks.length) {
        this.state = "idle";
        this.utterance = null;
        this.message = "読み上げが終わりました。";
        this.changed();
        return;
      }
      const utterance = new SpeechSynthesisUtterance(chunks[index++]);
      this.utterance = utterance;
      utterance.voice = voices[0];
      utterance.lang = voices[0].lang;
      utterance.rate = rate;
      utterance.onend = next;
      utterance.onerror = () => {
        if (ticket !== this.epoch) return;
        this.stop(false);
        this.message =
          "読み上げに失敗しました。音声設定を確認して再試行してください。";
        this.changed();
      };
      // An end event queued before pause may arrive afterward. Keep the user's
      // pause while queuing subsequent chunks; only explicit start clears it.
      const paused = index > 1 && this.state === "paused";
      this.state = paused ? "paused" : "speaking";
      this.message = paused ? "一時停止中" : "読み上げ中";
      try {
        // cancel() removes queued speech but preserves the engine's paused flag.
        // Resume only on explicit start, after the old queue has been cancelled.
        if (index === 1 && speechSynthesis.paused) speechSynthesis.resume();
        speechSynthesis.speak(utterance);
      } catch {
        this.stop(false);
        this.message =
          "読み上げを開始できませんでした。音声設定を確認して再試行してください。";
      }
      this.changed();
    };
    next();
  }
  togglePause() {
    if (!this.supported || this.state === "idle") return;
    if (this.state === "paused") {
      speechSynthesis.resume();
      this.state = "speaking";
      this.message = "読み上げ中";
    } else {
      speechSynthesis.pause();
      this.state = "paused";
      this.message = "一時停止中";
    }
    this.changed();
  }
}
