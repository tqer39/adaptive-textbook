# Documentation rules

[English](documentation.md) | [日本語](documentation.ja.md)

## Language and filenames

English is the default language for public documentation. Use `README.md` and
`docs/topic.md` for English, with `README.ja.md` and `docs/topic.ja.md` alongside them.
This applies to the root, Apple, and harness READMEs and all Markdown pages under `docs/`.
It does not imply that the app UI or lesson content has an English translation.

Place a language switch immediately after each page's H1, using relative filenames:

```markdown
[English](topic.md) | [日本語](topic.ja.md)
```

Keep ordinary links within the same language. A Japanese page links to `topic.ja.md`;
an English page links to `topic.md`. Keep external URLs, source paths, and API identifiers intact.

`AGENTS.md` is a tool-discovered instruction filename, so keep that exact name and
one short English version. Do not create `AGENTS.ja.md`, duplicate the rules into
`CLAUDE.md`, or put a translation of every document into the agent's startup context.
Likewise, `.agents/skills/*/SKILL.md` is a tool-discovered English entrypoint; do not create `SKILL.ja.md` copies.
Keep human-facing skill usage guidance in the paired [native development guide](../native-harness.md).
Machine-readable evidence and generated local artifacts do not need translated copies.

## Update only what the task affects

1. Identify documentation affected by the actual behavior or contract change.
   Use filenames, diffs, and targeted `rg` searches before opening files.
2. Read the relevant English sections. Read their Japanese counterparts only where
   needed to update the corresponding sections or preserve terminology.
3. Edit those English sections, then apply the equivalent changes to the Japanese
   sections in the same change. A request written in Japanese still needs an English update.
4. Leave unrelated paragraphs, formatting, and historical entries alone. Do not
   retranslate whole pages, traverse every document, or regenerate a document tree for a small code change.
5. If no documented behavior, setup step, or contract changes, leave the documentation unchanged.

English is the reference version for resolving translation drift; code and verified
evidence determine technical truth. Do not preserve a claim merely because it appears
in English. Resolve contradictions against the implementation or report the uncertainty.
For a new public page, add both language versions. Treat a full language migration as
a separate task rather than repeating it during ordinary implementation work.

## Content and evidence

- Keep both versions equivalent in scope, prerequisites, behavior, limitations, and safety boundaries.
  Do not replace one version with a summary or silently leave new instructions untranslated.
- Preserve executable examples, flags, environment variables, JSON keys, paths,
  URLs, model IDs, versions, dates, costs, and measured values. Japanese fixture data
  or literal UI labels may remain Japanese inside examples; explain them in the surrounding English prose.
- Keep one detailed explanation per topic and link to it. Do not copy large examples
  or detailed policies into the README, `AGENTS.md`, and multiple topic pages.
- Break lines at sentence or paragraph boundaries. Avoid reflowing unrelated prose
  to meet a column limit; `MD013` is disabled so links, tables, and both languages can retain their structure.
- Distinguish implemented behavior, completed verification, and proposals. State the
  date and conditions of performance or live-model evidence; a successful build is not runtime UI verification.
- Historical investigation and development logs describe their recorded dates.
  Do not present old prices, versions, or audit findings as a fresh investigation.
  Check current primary sources when the task changes a version-dependent claim.
- Keep secrets, real API keys, private paths, and raw credentials out of public documentation.

## Verification

Use `npm run docs:check` for a quick check of language pairs, language switches, and local
Markdown links. It reads documentation metadata and requires no model calls or network access.
After Markdown edits, run `mise run lint`; it includes that check and Markdown linting.
Both language versions and nested rule pages must be included in lint coverage.
Skill entrypoints are linted too; `docs:check` verifies their links to canonical rules, guides, sources, and scripts.

Review the changed sections for meaning and preserved commands. Automated checks cannot
prove translation accuracy. For documentation-only changes, do not rerun app builds,
live agent loops, or 100,000-article benchmarks unless a changed executable example needs verification.
