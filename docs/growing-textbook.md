# Growing a textbook through questions

[English](growing-textbook.md) | [日本語](growing-textbook.ja.md)

This is a design exploration only. Conversational AI, term popovers, a question queue, and automatic generation are not implemented.
For v1.1.0, a person received the request, rechecked official documentation, and improved the material manually.
Reading the existing textbook, working with its diagrams, and answering prediction questions remain the main learning activities.
Conversation is positioned as a supporting path for discovering gaps and improving the material.

## From a section's “point of interest” to a new edition

1. Associate a question with the section being studied. Save its original text and the reading position.
2. Use a supporting conversation to identify unclear concepts, missing comparisons, and practical purposes.
3. Check official sources, sections, and verification dates, separating the explanation's evidence from unverified points.
4. Propose explanations, diagrams, comparisons, and questions to add, their insertion points, and changes to the estimated duration.
5. Let the user review the diff and additional cost. Do not rewrite the current material before that review.
6. Apply the changes to a new edition, incorporating additions into the contents, time allocation, and learning path.
7. After studying, optionally reflect on what helped and associate that reflection with the original question.

Do not automatically append conversational answers verbatim to the material.
Check contradictions, duplication, length, sources, and the semantics of diagrams and questions; retain the old edition.
A section's stable block ID is separate from its order or displayed number.
Do not overwrite old-edition questions, answers, or timestamps with the new edition's correct answers.
Show what changed and suggest any additional study needed.
Use a separate proposal ID for an unreviewed draft; do not treat it as a published textbook version.

## Required data

- Question: question ID, user ID, book ID, version, block ID, original text, timestamp
- Context: reading position, relevant sentence/diagram, a short selected range for reference
- Gap: classification such as concept, purpose, counterexample, comparison, or practical application
- Proposal: proposal ID, evidence URL/section/verification date, additional block IDs, diff, estimated time
- Decision: user review, target version, applicable learning path, rejection reason (optional)
- Reflection: original question ID, target block/version, helpful points, remaining questions

Keep the original text instead of replacing it with only a summary, so the user's intent remains traceable.
Treat the original text, conversation history, textbook, and learning history as separate data.
Avoid sending unnecessary personal information to the generation API. Deletion and retention periods are also future design work.

## How this relates to the current manual improvements

The original questions were as follows.

> “If the parent is not prohibited and the restriction is applied only to the child, where does the prohibition begin?”

The missing comparison was how far to search for an RRset for each requested name.
Text, a comparison diagram for five names, and three prediction questions were added to v1.1.0's
`scope`, `boundary`, `scope-predict`, `sibling-predict`, and `override-predict`.

> “How does this help?”

The gap concerned the reason for using it and operational decisions. `applications` gained examples of
limiting CAs, prohibiting issuance for validation names that do not need certificates, and changing CAs at renewal.
`renewal-predict` gained a prediction question about migration, and `limits` gained limitations and cautions about multiple SAN names.
The explanation exercise in `takeaway` also incorporates the new perspective.

> A feature that grows the textbook through later questions and conversation about those “points of interest” may be needed.

This was recorded as the supporting path in this design. No actual conversational UI was added.
The user's own reflection on what helped has not yet been collected.
It has not been represented as though the user said the added diagrams or questions helped.

The changes incorporated RFC 8659 §1, §3–4, and §5.3 and official CAA documentation,
rechecked on 2026-10-10.
The old textbook source remains in `src/books/caa-v1.ts`.
The storage format remains schemaVersion 1; answers from old and new editions are retained by appending.
The textbook schema is version 2, adding new block kinds while still accepting the existing format.
An old edition's resume position is not automatically applied to the new edition.

## Word-level “points of interest”

> I also want to think about what happens when a word catches my attention.
> In this case, examples are `certificate authority`, `iodef`, and `RRset`.

The design lets a reader open a short explanation for “certificate authority,” “iodef,” or “RRset” without interrupting reading.
A static dictionary and clickable-term UI have not yet been implemented.
Distinguish a proposal to start with static, source-verified explanations from future conversational exploration.

The initial view is limited to three things: a short definition, its meaning in this sentence, and a concrete example.
The reader can choose to explore “start with the basics,” “what is it for,” or “how it differs from similar terms.”
“Read later” adds it to a queue so reading can continue.
Only when the gap concerns the whole section does the flow move on to the textbook supplement proposal above.

Manage term IDs as units of meaning, rather than using the literal term string as the ID.
Associate each occurrence with book ID/version, block ID, short context, and the selected range.
If an abbreviation has different meanings in different contexts, do not replace every explanation uniformly.
Save explanation versions, evidence, and verification dates in the dictionary and associate them with textbook versions.
Clicking a term does not mark it as understood.
Keep comprehension checks, the user's self-assessment, and explanation practice distinct as evidence of understanding.

### Current term examples and their evidence

- Certificate authority (CA): an entity that issues certificates. In this sentence, the issuer that checks CAA restrictions.
  Let’s Encrypt is a concrete example. Distinguish CAA authorization from other conditions such as domain-control validation.
- RRset: a set of DNS records with the same owner name / type / class.
  In this sentence, all IN CAA records for api.example.com.
  Use an example with issue and iodef in the same RRset to distinguish a set from a single record.
- iodef: in CAA, a property specifying where to report issuance requests or issuance that violate the policy.
  `mailto:security@example.com` is an example destination. It does not guarantee that a notification is sent or delivered.
  Explain how it differs from issue, which controls permission or prohibition of issuance.

The definitions are based on RFC 8659 §2.2 and §4.4 and were checked on 2026-10-10.
See the [official RFC](https://www.rfc-editor.org/rfc/rfc8659.html).
A term explanation alone must not make definitive claims about notification behavior or operational expectations.

### Presentation and interactions that preserve reading

The proposal uses the first occurrence or the reader's selection as an entry point, rather than continually highlighting every technical term.
A small popover on desktop and a short bottom sheet on mobile are candidates.
Prioritize a density that does not obscure too much text and keeps the original sentence available for reference.

Use a keyboard-accessible button as the entry point and establish its ARIA relationship with the explanation.
Opening moves focus to the explanation; closing or Escape returns focus and the reading position to the original word.
Do not mix non-modal and modal behavior. For a modal, design the focus trap and restrictions on background interaction.
Browser Back should close the explanation and return to reading, without unintentionally leaving the book.
Preserve the book/block return position even during a long exploration.
Do not rely on hover alone, color alone, or tap targets that are too small.
Review keyboard, focus, Back, reduced motion, and mobile interactions before implementation.

## Controlling a JPY 500 monthly budget, including AI

Use saved explanations for known terms or repeated displays in the same context, without calling AI.
Time selection, diagram interactions, normal reading, and question grading also need no AI.
Estimate cost only when generating a new follow-up question, deeper explanation, or textbook diff.

Limit regeneration to the target block and necessary prerequisites instead of regenerating the whole chapter each time.
Design for reuse of existing explanations, shared source retrieval, and suppression of duplicate requests.
Manage per-user monthly, request-count, and token limits, as well as a budget including network/storage costs.
If the budget would be exceeded, continue with existing explanations, queue the question, or defer the proposal.
Do not call paid APIs without permission or make static material unavailable.
Recheck models and prices when introducing them; achieving JPY 500 requires measurement.
No APIs, OAuth, or cloud resources were connected for the current manual improvements.
