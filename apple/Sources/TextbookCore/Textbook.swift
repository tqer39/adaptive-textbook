import Foundation

public struct LearningOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let explanation: String
}

public struct LearningQuestion: Identifiable, Sendable, Equatable {
    public let id: String
    public let prompt: String
    public let options: [LearningOption]
    public let correctOptionID: String

    public func option(_ id: String) -> LearningOption? { options.first { $0.id == id } }
}

public struct LearningSection: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let objective: String
    public let paragraphs: [String]
    public let question: LearningQuestion
}

public struct Textbook: Sendable, Equatable {
    public let id: String
    public let version: Int
    public let title: String
    public let sections: [LearningSection]

    public init(id: String, version: Int, title: String, sections: [LearningSection]) {
        self.id = id
        self.version = version
        self.title = title
        self.sections = sections
    }

    public func question(_ id: String) -> LearningQuestion? {
        sections.map(\.question).first { $0.id == id }
    }

    public func answer(
        questionID: String, optionID: String, id: UUID = UUID(), at date: Date = Date()
    ) throws -> AnswerAttempt {
        guard let question = question(questionID), question.option(optionID) != nil else {
            throw HistoryError.invalidAnswer
        }
        return AnswerAttempt(
            id: id, textbookID: self.id, textbookVersion: version,
            questionID: questionID, optionID: optionID,
            isCorrect: question.correctOptionID == optionID, answeredAt: date
        )
    }

    public static let introductory = Textbook(
        id: "models-and-agents", version: 1, title: "モデルとエージェント",
        sections: [
            LearningSection(
                id: "model", title: "1. モデルの入力と出力",
                objective: "モデルに依頼する内容と、外部で実際に行われた操作を区別できる。",
                paragraphs: [
                    "ここでは、文章を入力すると文章を出力する言語モデルを考えます。入力は質問や指示、参考資料などです。出力は入力をもとに作られた文章です。",
                    "例えば『この記事を日本語で説明して』という入力に、モデルが日本語の説明を返します。説明の正しさは原文と照合して確かめます。",
                    "文章を出力しただけでは、ファイルの保存やWebサイトの更新が完了したことにはなりません。『保存しました』という文章と、保存処理の成功は別に確認します。",
                ],
                question: LearningQuestion(
                    id: "model-action", prompt: "外部ツールに接続されていないモデルが『ファイルを保存しました』と返しました。この返答だけから、何が確認できますか？",
                    options: [
                        LearningOption(id: "text", text: "保存したと述べる文章が出力された。", explanation: "そのとおりです。確認できるのは文章の出力です。実際の保存は、保存処理の結果やファイルで確かめます。"),
                        LearningOption(id: "saved", text: "端末へのファイル保存が成功した。", explanation: "保存成功は確認できません。今回は外部ツールに接続されていないため、文章の主張だけを保存の証拠にできません。"),
                    ], correctOptionID: "text"
                )
            ),
            LearningSection(
                id: "tool", title: "2. ツールで外部に働きかける",
                objective: "モデルの判断と、ツールの実行結果を分けて説明できる。",
                paragraphs: [
                    "ツールは、検索、ファイル保存、計算などの具体的な操作を実行する機能です。モデルがツールの呼び出しを提案し、周囲のソフトウェアが権限や入力を確かめて実行する構成があります。",
                    "記事を取得する例では、モデルがURLを選び、取得ツールがそのURLにアクセスします。ツールは本文や、取得に失敗した理由を返します。",
                    "URLを選べたことと、本文を取得できたことは別です。取得に失敗したら、本文がある前提で説明を作らず、失敗を記録して次の行動を決めます。",
                ],
                question: LearningQuestion(
                    id: "tool-result", prompt: "モデルが記事のURLを選びましたが、取得ツールは『アクセスできません』を返しました。次の判断として適切なのはどれですか？",
                    options: [
                        LearningOption(id: "guess", text: "記事本文を取得したことにして説明を作る。", explanation: "URLを選んだだけでは本文を取得していません。未取得の内容を、確認済みの根拠として扱うことはできません。"),
                        LearningOption(id: "failure", text: "本文は未取得と記録し、別の根拠の取得や保留を検討する。", explanation: "そのとおりです。ツールの失敗を状態に反映することで、未確認の情報を確認済みと取り違えるのを防げます。"),
                    ], correctOptionID: "failure"
                )
            ),
            LearningSection(
                id: "agent", title: "3. 結果を見て次の行動を選ぶ",
                objective: "行動の反復と、その終了条件が必要な理由を説明できる。",
                paragraphs: [
                    "この教材では、目的に向けてモデルが状況を判断し、ツールの実行結果を見ながら次の行動を選ぶ仕組みをエージェントと呼びます。エージェントという語の使い方はサービスによって異なります。",
                    "例えば『公式資料を探す→本文を取得する→不足を確認する→必要なら追加で探す』という反復です。モデルの判断、ツール、状態の保存、結果の検証をソフトウェアが結び付けます。",
                    "反復には終了条件が必要です。合格条件を満たしたら完了し、時間や回数の上限に達したら保留します。上限を増やすだけでは、情報の正しさは保証できません。",
                ],
                question: LearningQuestion(
                    id: "agent-stop", prompt: "根拠を探すエージェントに『検索は最大3回。根拠が見つからなければ保留』と設定しました。3回検索しても根拠がありません。どう処理しますか？",
                    options: [
                        LearningOption(id: "continue", text: "上限を無視し、根拠が見つかるまで検索する。", explanation: "設定した上限に従っていません。終了条件を守り、未確認の内容を残した状態で保留します。"),
                        LearningOption(id: "hold", text: "根拠が見つからなかったことを記録し、保留する。", explanation: "そのとおりです。完了と保留を区別すれば、次に再開するときにも未解決の点が分かります。"),
                    ], correctOptionID: "hold"
                )
            ),
        ]
    )
}

public struct AnswerAttempt: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let textbookID: String
    public let textbookVersion: Int
    public let questionID: String
    public let optionID: String
    public let isCorrect: Bool
    public let answeredAt: Date
}
