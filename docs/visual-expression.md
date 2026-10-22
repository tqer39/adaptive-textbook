# Diagram presentation and drill-down proposals

[English](visual-expression.md) | [日本語](visual-expression.ja.md)

This document considers additional designs. The current implementation covers terminology, status colors, learning outcomes, and predictions and reflections around diagrams.
It does not include adding Three.js, Mermaid, or React Flow, or implementing the full four-level drill-down.
The choice is not limited to custom SVG: it should depend on interactions that support understanding, accessibility, and the load on smartphones.

## CAA drill-down

Move closer to the same configuration through the overall sequence, DNS lookup, the contents of the selected RRset, and the reason for the decision.

1. Overall pre-issuance diagram: selecting the CAA check opens the lookup for the requested name.
2. Lookup: follow candidate names in order and stop at the first one where a set is found.
3. RRset: inspect each record in the selected set, including issue / iodef and their roles.
4. Reason: explain which issue authorizes this CA, or why the absence of issue leaves issuance unrestricted.

Always provide breadcrumbs and a way to return to the original diagram. Preserve the requested name, CA, saved prediction ID, and snapshot at every level.
Restore the previous selection, scroll position, and focus when returning. The diagram must not add a parent's prohibition after the lookup has stopped.
If free exploration changes the comparison conditions, show the new conditions explicitly without modifying those of the original prediction.
Use HTML buttons for selection, with navigation also available through Enter/Space and Back/Escape.
With reduced motion, stop animations and provide the same information through text and flat diagrams.

## Candidate tools and suitable uses

| Candidate | Suitable use | What to check when choosing |
| --- | --- | --- |
| Mermaid | Overall sequences / static lookup overviews | Labels at phone widths, explanatory navigation after rendering, safe syntax restrictions |
| Native SVG/CSS + HTML | Highlighting the selected location among a few nodes; the current simulated diagrams | Put keyboard interactions in HTML and avoid shrinking text |
| React Flow | Lookup screens with many node selections, expansions, and collapses | Cost of adding React to the current setup, screen-reader support, Japanese interaction instructions |
| Three.js | Other subjects where spatial presentation helps understanding | GPU/battery load, text, keyboard use, a non-3D alternative |

CAA lookup centers on the name hierarchy and stopping conditions. At this stage, no learning benefit from a 3D presentation has been demonstrated.
Keep Three.js as a candidate and compare prototypes on a subject where it may help before adopting it.
This suitability assessment is a design judgment, not a conclusion from measured performance or user testing.
The official React Flow documentation describes keyboard, focus, and ARIA features, but adoption alone does not guarantee conformance.
Mermaid input should also remain separate from arbitrary JS/MDX; links, click handlers, and HTML should not be allowed without limits.

Official starting points checked on 2026-10-11:

- [Mermaid](https://mermaid.js.org/intro/): text-defined diagrams and sequence / flowchart diagrams
- [React Flow accessibility](https://reactflow.dev/learn/advanced-use/accessibility)
  Keyboard, focus, and ARIA features and settings
- [Three.js manual](https://threejs.org/manual/)
  Official documentation for any further 3D exploration. 3D performance and interaction suitability have not been verified in this work.
