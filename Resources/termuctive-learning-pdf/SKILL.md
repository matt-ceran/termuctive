---
name: termuctive-learning-pdf
description: Create a compact, professional educational PDF from recent coding or terminal work. Use when Termuctive submits /makepdf, when a user asks to turn session work into a learning document, or when an explanation needs plain-language teaching, technical evidence, and a conceptual visual.
---

# Termuctive Learning PDF

Create a trustworthy lesson about the recent work without changing, restarting, or publishing the project being explained.
Use the Compact Textbook layout so every lesson has a familiar reading order and visual language.

## Workflow

### 1. Set the learning boundary

Summarize the work completed since the most recent meaningful checkpoint in the active conversation.
Do not summarize every terminal line or claim that proposed work is complete.
Inspect relevant local files and verification output when the conversation does not contain enough evidence.
Keep completed, verified, proposed, uncertain, and untouched work distinct.

### 2. Plan the lesson

Read [references/document-schema.md](references/document-schema.md) before writing the input data.
Explain the main idea in plain language before introducing file names, commands, or implementation details.
Choose one visual relationship that materially helps the explanation.
Use a flow for sequences, layers for dependencies or hierarchy, and a comparison for alternatives.
Prefer three to five short visual items.

### 3. Create the structured input

Create a temporary JSON file under `tmp/pdfs/` in the active workspace.
Use only claims supported by the conversation, repository, or verification evidence.
Keep paragraphs short enough to scan while retaining the reasoning that makes the lesson useful.
Use absolute paths only where a path is itself important evidence.

### 4. Render the Compact Textbook PDF

Create the final artifact under `output/pdf/` in the active workspace unless the user requests another location.
Choose a unique, descriptive filename so an existing lesson is never silently overwritten.
Run the bundled renderer with absolute input and output paths:

```bash
python3 <skill-directory>/scripts/render_learning_pdf.py \
  --input <absolute-input-json> \
  --output <absolute-output-pdf>
```

The renderer embeds Times New Roman and uses a compact grayscale book layout.
If ReportLab is unavailable, create a task-local virtual environment under `tmp/pdfs/`, install only ReportLab there, and rerun the renderer with that Python executable.
Do not install or relaunch Termuctive as part of PDF creation.

### 5. Verify every page

Use `pdfinfo` to confirm the file is a valid Letter-sized PDF with the expected page count.
Use `pdffonts` to confirm Times New Roman is embedded.
Use `pdftotext` to confirm the title, takeaway, and evidence are extractable.
Render every page to PNG with `pdftoppm` under `tmp/pdfs/` and inspect every rendered page.
Check for clipped text, overlapping elements, tiny type, broken arrows, awkward page breaks, excess dead space, or missing sections.
Revise the JSON or renderer input and repeat verification until every page is clean.
Remove temporary page renders after verification while retaining the source JSON when it is useful provenance.

### 6. Hand the artifact to Termuctive

Confirm the final file still exists and is not empty.
End the response with exactly one canonical absolute path to the finished PDF on its own line.
Do not print another valid PDF path after that line.
This final path lets Termuctive remember the artifact so `/movepdfright` can display it beside the same terminal.

## Quality Rules

- Write for a curious learner who may not know the implementation vocabulary yet.
- Use a concrete analogy only when it clarifies the actual mechanism.
- Include implementation details after the mental model, not in place of it.
- Include evidence for important completion claims.
- State what remains unfinished and what must remain untouched.
- Use grayscale throughout, with no decorative color.
- Use only ASCII hyphens in generated prose.
- Do not commit, push, deploy, publish, or modify the work being explained unless the user separately requests it.
