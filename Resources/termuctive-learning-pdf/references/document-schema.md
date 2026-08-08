# Compact Textbook Input Schema

The renderer accepts one UTF-8 JSON object.
The fields below define the reusable lesson structure used by Termuctive.

## Required fields

- `title` is the lesson title.
- `subtitle` is a one-sentence description of what the reader will understand.
- `project` names the project or subject.
- `learning_boundary` identifies the span of recent work being explained.
- `simple_explanation` contains an optional `analogy` and a non-empty `paragraphs` array.
- `visual` contains `heading`, `kind`, `caption`, and at least two `items`.
- `work` is a non-empty array of objects with `title`, `detail`, and `status`.
- `evidence` is a non-empty array of objects with `claim`, `proof`, and `status`.
- `takeaway` is the final one-sentence lesson.

## Optional fields

- `date` is a display date such as `August 8, 2026`.
- `overview` is an array of short status objects with `label`, `detail`, and `status`.
- `documentation` is an array of implementation facts with `label` and `detail`.
- `glossary` is an array of terms with `term` and `definition`.
- `boundaries` lists things intentionally left untouched or still uncertain.
- `next_steps` lists useful follow-up actions without implying they are complete.

## Visual kinds

- `flow` shows a left-to-right sequence.
- `layers` shows a top-to-bottom dependency or hierarchy.
- `comparison` places alternatives or concepts side by side.

Each item in `visual.items` has a short `title` and `detail`.
Use three to five items when possible.

## Status language

Use short, explicit status labels such as `VERIFIED`, `COMPLETE`, `PROPOSED`, `UNKNOWN`, or `UNTOUCHED`.
Do not use `VERIFIED` unless direct evidence supports it.

## Example

```json
{
  "title": "How a learning PDF moves through Termuctive",
  "subtitle": "A compact lesson about turning recent session work into a verified artifact.",
  "project": "Termuctive",
  "date": "August 8, 2026",
  "learning_boundary": "Template selection and the local command handoff",
  "simple_explanation": {
    "analogy": "The terminal is the workshop, and the PDF is the notebook written after the lesson.",
    "paragraphs": [
      "The workshop keeps running while the notebook records what changed and why it works.",
      "A single final file path lets Termuctive find the finished notebook without searching the whole machine."
    ]
  },
  "visual": {
    "heading": "The mental model",
    "kind": "flow",
    "caption": "A lesson moves from request to verified artifact without replacing the live terminal.",
    "items": [
      {"title": "Request", "detail": "Type /makepdf"},
      {"title": "Explain", "detail": "Use recent context"},
      {"title": "Render", "detail": "Build and inspect"},
      {"title": "Discover", "detail": "Print one path"}
    ]
  },
  "overview": [
    {"label": "Live session", "detail": "Remains running", "status": "UNTOUCHED"},
    {"label": "Learning artifact", "detail": "Rendered and inspected", "status": "VERIFIED"}
  ],
  "work": [
    {"title": "Select the layout", "detail": "Use the Compact Textbook template for every lesson.", "status": "COMPLETE"}
  ],
  "evidence": [
    {"claim": "The output is readable", "proof": "Every rendered page was visually inspected.", "status": "VERIFIED"}
  ],
  "documentation": [
    {"label": "Command", "detail": "/makepdf creates the lesson request."}
  ],
  "glossary": [
    {"term": "Canonical path", "definition": "One unambiguous absolute path to the finished file."}
  ],
  "boundaries": ["Do not relaunch the installed application."],
  "next_steps": ["Use /movepdfright after the final path appears."],
  "takeaway": "The new command creates the lesson, and the existing move command decides where it appears."
}
```
