#!/usr/bin/env python3
"""Render a Termuctive Compact Textbook learning PDF from structured JSON."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import tempfile
from html import escape
from pathlib import Path
from typing import Any

try:
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_RIGHT
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    from reportlab.platypus import (
        BaseDocTemplate,
        Flowable,
        Frame,
        HRFlowable,
        KeepTogether,
        PageTemplate,
        Paragraph,
        Spacer,
        Table,
        TableStyle,
    )
except ImportError as error:
    raise SystemExit(
        "ReportLab is required. Install it in a task-local environment with "
        "`python3 -m pip install reportlab`."
    ) from error


PAGE_WIDTH, PAGE_HEIGHT = letter
LEFT_MARGIN = 42
RIGHT_MARGIN = 42
TOP_MARGIN = 58
BOTTOM_MARGIN = 42
CONTENT_WIDTH = PAGE_WIDTH - LEFT_MARGIN - RIGHT_MARGIN

INK = colors.HexColor("#151515")
MIDDLE = colors.HexColor("#666666")
LINE = colors.HexColor("#B7B7B7")
PANEL = colors.HexColor("#F1F1F1")
PAPER = colors.HexColor("#F8F8F8")
WHITE = colors.white

FONT_PATHS = {
    "TermuctiveTimes": "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
    "TermuctiveTimes-Bold": "/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf",
    "TermuctiveTimes-Italic": "/System/Library/Fonts/Supplemental/Times New Roman Italic.ttf",
    "TermuctiveTimes-BoldItalic": (
        "/System/Library/Fonts/Supplemental/Times New Roman Bold Italic.ttf"
    ),
}


def register_fonts() -> None:
    missing = [path for path in FONT_PATHS.values() if not Path(path).is_file()]
    if missing:
        joined = ", ".join(missing)
        raise SystemExit(f"Times New Roman font files were not found: {joined}")

    for name, path in FONT_PATHS.items():
        pdfmetrics.registerFont(TTFont(name, path))
    pdfmetrics.registerFontFamily(
        "TermuctiveTimes",
        normal="TermuctiveTimes",
        bold="TermuctiveTimes-Bold",
        italic="TermuctiveTimes-Italic",
        boldItalic="TermuctiveTimes-BoldItalic",
    )


def build_styles() -> dict[str, ParagraphStyle]:
    return {
        "title": ParagraphStyle(
            "Title",
            fontName="TermuctiveTimes-Bold",
            fontSize=22,
            leading=24,
            textColor=INK,
            spaceAfter=4,
        ),
        "subtitle": ParagraphStyle(
            "Subtitle",
            fontName="TermuctiveTimes-Italic",
            fontSize=10,
            leading=13,
            textColor=MIDDLE,
            spaceAfter=8,
        ),
        "meta": ParagraphStyle(
            "Meta",
            fontName="TermuctiveTimes",
            fontSize=7.4,
            leading=9.2,
            textColor=MIDDLE,
        ),
        "section": ParagraphStyle(
            "Section",
            fontName="TermuctiveTimes-Bold",
            fontSize=8,
            leading=9.5,
            tracking=1.25,
            textColor=MIDDLE,
            spaceBefore=7,
            spaceAfter=7,
            keepWithNext=1,
        ),
        "heading": ParagraphStyle(
            "Heading",
            fontName="TermuctiveTimes-Bold",
            fontSize=13,
            leading=15,
            textColor=INK,
            spaceAfter=5,
        ),
        "body": ParagraphStyle(
            "Body",
            fontName="TermuctiveTimes",
            fontSize=9.2,
            leading=12.2,
            textColor=INK,
            spaceAfter=6,
        ),
        "body_small": ParagraphStyle(
            "BodySmall",
            fontName="TermuctiveTimes",
            fontSize=8.2,
            leading=10.4,
            textColor=INK,
        ),
        "detail": ParagraphStyle(
            "Detail",
            fontName="TermuctiveTimes",
            fontSize=7.6,
            leading=9.4,
            textColor=MIDDLE,
        ),
        "card_title": ParagraphStyle(
            "CardTitle",
            fontName="TermuctiveTimes-Bold",
            fontSize=8.7,
            leading=10.2,
            textColor=INK,
        ),
        "diagram_title": ParagraphStyle(
            "DiagramTitle",
            fontName="TermuctiveTimes-Bold",
            fontSize=8.2,
            leading=9.4,
            textColor=INK,
            alignment=TA_CENTER,
        ),
        "diagram_detail": ParagraphStyle(
            "DiagramDetail",
            fontName="TermuctiveTimes-Italic",
            fontSize=7.1,
            leading=8.2,
            textColor=MIDDLE,
            alignment=TA_CENTER,
        ),
        "table_header": ParagraphStyle(
            "TableHeader",
            fontName="TermuctiveTimes-Bold",
            fontSize=7,
            leading=8,
            textColor=WHITE,
        ),
        "table_body": ParagraphStyle(
            "TableBody",
            fontName="TermuctiveTimes",
            fontSize=7.8,
            leading=9.6,
            textColor=INK,
        ),
        "status": ParagraphStyle(
            "Status",
            fontName="TermuctiveTimes-Bold",
            fontSize=6.4,
            leading=7.5,
            textColor=MIDDLE,
            alignment=TA_RIGHT,
        ),
        "number": ParagraphStyle(
            "Number",
            fontName="TermuctiveTimes-Bold",
            fontSize=8,
            leading=9,
            textColor=WHITE,
            alignment=TA_CENTER,
        ),
        "takeaway": ParagraphStyle(
            "Takeaway",
            fontName="TermuctiveTimes-Italic",
            fontSize=9.3,
            leading=12,
            textColor=INK,
        ),
    }


def clean_text(value: Any, default: str = "") -> str:
    if value is None:
        return default
    return str(value).strip()


def markup(value: Any) -> str:
    return escape(clean_text(value)).replace("\n", "<br/>")


def paragraph(value: Any, style: ParagraphStyle) -> Paragraph:
    return Paragraph(markup(value), style)


def labeled_paragraph(
    label: Any,
    detail: Any,
    styles: dict[str, ParagraphStyle],
) -> Paragraph:
    content = f"<b>{markup(label)}</b><br/>{markup(detail)}"
    return Paragraph(content, styles["body_small"])


def require_text(document: dict[str, Any], key: str) -> str:
    value = clean_text(document.get(key))
    if not value:
        raise ValueError(f"`{key}` must be a non-empty string")
    return value


def require_list(document: dict[str, Any], key: str) -> list[Any]:
    value = document.get(key)
    if not isinstance(value, list) or not value:
        raise ValueError(f"`{key}` must be a non-empty array")
    return value


def validate_document(document: Any) -> dict[str, Any]:
    if not isinstance(document, dict):
        raise ValueError("the input must be a JSON object")

    for key in ("title", "subtitle", "project", "learning_boundary", "takeaway"):
        require_text(document, key)

    explanation = document.get("simple_explanation")
    if not isinstance(explanation, dict):
        raise ValueError("`simple_explanation` must be an object")
    require_list(explanation, "paragraphs")

    visual = document.get("visual")
    if not isinstance(visual, dict):
        raise ValueError("`visual` must be an object")
    require_text(visual, "heading")
    require_text(visual, "caption")
    kind = require_text(visual, "kind").lower()
    if kind not in {"flow", "layers", "comparison"}:
        raise ValueError("`visual.kind` must be `flow`, `layers`, or `comparison`")
    items = require_list(visual, "items")
    if len(items) < 2:
        raise ValueError("`visual.items` must contain at least two items")
    for index, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"visual item {index} must be an object")
        for key in ("title", "detail"):
            if not clean_text(item.get(key)):
                raise ValueError(f"visual item {index} must have a non-empty `{key}`")

    work = require_list(document, "work")
    for index, item in enumerate(work, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"work item {index} must be an object")
        for key in ("title", "detail", "status"):
            if not clean_text(item.get(key)):
                raise ValueError(f"work item {index} must have a non-empty `{key}`")

    evidence = require_list(document, "evidence")
    for index, item in enumerate(evidence, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"evidence item {index} must be an object")
        for key in ("claim", "proof", "status"):
            if not clean_text(item.get(key)):
                raise ValueError(f"evidence item {index} must have a non-empty `{key}`")

    return document


class ConceptDiagram(Flowable):
    def __init__(
        self,
        kind: str,
        items: list[dict[str, Any]],
        caption: str,
        styles: dict[str, ParagraphStyle],
    ) -> None:
        super().__init__()
        self.kind = kind
        self.items = items
        self.caption = caption
        self.styles = styles
        self.width = 0.0
        self.height = 0.0
        self._layout: dict[str, Any] = {}

    def wrap(self, avail_width: float, avail_height: float) -> tuple[float, float]:
        del avail_height
        self.width = avail_width
        if self.kind == "layers":
            self._measure_layers(avail_width)
        else:
            self._measure_cards(avail_width)
        return self.width, self.height

    def _measure_cards(self, width: float) -> None:
        item_count = len(self.items)
        columns = min(item_count, 5 if self.kind == "flow" else 3)
        rows = math.ceil(item_count / columns)
        horizontal_gap = 18 if self.kind == "flow" else 10
        vertical_gap = 18
        inner_width = width - 28
        card_width = (inner_width - horizontal_gap * (columns - 1)) / columns
        card_heights: list[float] = []
        for item in self.items:
            title = paragraph(item.get("title"), self.styles["diagram_title"])
            detail = paragraph(item.get("detail"), self.styles["diagram_detail"])
            _, title_height = title.wrap(card_width - 14, 1000)
            _, detail_height = detail.wrap(card_width - 14, 1000)
            card_heights.append(max(62, 27 + title_height + detail_height))
        row_heights = []
        for row in range(rows):
            start = row * columns
            row_heights.append(max(card_heights[start : start + columns]))
        caption_height = 0.0
        if self.caption:
            caption = paragraph(self.caption, self.styles["detail"])
            _, caption_height = caption.wrap(inner_width, 1000)
        self.height = 26 + caption_height + sum(row_heights) + vertical_gap * (rows - 1) + 16
        self._layout = {
            "columns": columns,
            "rows": rows,
            "horizontal_gap": horizontal_gap,
            "vertical_gap": vertical_gap,
            "card_width": card_width,
            "card_heights": card_heights,
            "row_heights": row_heights,
            "caption_height": caption_height,
        }

    def _measure_layers(self, width: float) -> None:
        inner_width = width - 28
        row_heights = []
        for item in self.items:
            content = labeled_paragraph(
                item.get("title"), item.get("detail"), self.styles
            )
            _, content_height = content.wrap(inner_width - 42, 1000)
            row_heights.append(max(37, content_height + 14))
        caption_height = 0.0
        if self.caption:
            caption = paragraph(self.caption, self.styles["detail"])
            _, caption_height = caption.wrap(inner_width, 1000)
        self.height = 26 + caption_height + sum(row_heights) + 8 * (len(row_heights) - 1) + 16
        self._layout = {
            "row_heights": row_heights,
            "caption_height": caption_height,
        }

    def draw(self) -> None:
        canvas = self.canv
        canvas.saveState()
        canvas.setFillColor(PAPER)
        canvas.setStrokeColor(LINE)
        canvas.roundRect(0, 0, self.width, self.height, 5, stroke=1, fill=1)
        if self.kind == "layers":
            self._draw_layers(canvas)
        else:
            self._draw_cards(canvas)
        canvas.restoreState()

    def _draw_caption(self, canvas: Any, inner_width: float) -> float:
        caption_height = self._layout["caption_height"]
        if not self.caption:
            return self.height - 14
        caption = paragraph(self.caption, self.styles["detail"])
        caption.wrap(inner_width, caption_height)
        y = self.height - 14 - caption_height
        caption.drawOn(canvas, 14, y)
        return y - 10

    def _draw_cards(self, canvas: Any) -> None:
        layout = self._layout
        inner_width = self.width - 28
        top = self._draw_caption(canvas, inner_width)
        columns = layout["columns"]
        card_width = layout["card_width"]
        horizontal_gap = layout["horizontal_gap"]
        vertical_gap = layout["vertical_gap"]
        index = 0
        y_top = top
        for row, row_height in enumerate(layout["row_heights"]):
            y = y_top - row_height
            remaining = len(self.items) - index
            count = min(columns, remaining)
            used_width = count * card_width + (count - 1) * horizontal_gap
            row_start = 14 + (inner_width - used_width) / 2
            for column in range(count):
                item = self.items[index]
                x = row_start + column * (card_width + horizontal_gap)
                canvas.setFillColor(WHITE)
                canvas.setStrokeColor(INK)
                canvas.roundRect(x, y, card_width, row_height, 4, stroke=1, fill=1)
                canvas.setFillColor(INK)
                canvas.circle(x + 12, y + row_height - 12, 7, stroke=0, fill=1)
                canvas.setFillColor(WHITE)
                canvas.setFont("TermuctiveTimes-Bold", 6.8)
                canvas.drawCentredString(x + 12, y + row_height - 14.3, str(index + 1))

                title = paragraph(item.get("title"), self.styles["diagram_title"])
                detail = paragraph(item.get("detail"), self.styles["diagram_detail"])
                _, title_height = title.wrap(card_width - 14, row_height)
                _, detail_height = detail.wrap(card_width - 14, row_height)
                content_height = title_height + 4 + detail_height
                content_y = y + max(7, (row_height - content_height) / 2 - 2)
                detail.drawOn(canvas, x + 7, content_y)
                title.drawOn(canvas, x + 7, content_y + detail_height + 4)

                if self.kind == "flow" and column < count - 1:
                    start_x = x + card_width + 3
                    end_x = x + card_width + horizontal_gap - 3
                    arrow_y = y + row_height / 2
                    canvas.setStrokeColor(INK)
                    canvas.setFillColor(INK)
                    canvas.setLineWidth(1)
                    canvas.line(start_x, arrow_y, end_x, arrow_y)
                    path = canvas.beginPath()
                    path.moveTo(end_x, arrow_y)
                    path.lineTo(end_x - 4, arrow_y + 3)
                    path.lineTo(end_x - 4, arrow_y - 3)
                    path.close()
                    canvas.drawPath(path, stroke=0, fill=1)
                index += 1
            y_top = y - vertical_gap

    def _draw_layers(self, canvas: Any) -> None:
        inner_width = self.width - 28
        top = self._draw_caption(canvas, inner_width)
        y_top = top
        for index, (item, row_height) in enumerate(
            zip(self.items, self._layout["row_heights"])
        ):
            y = y_top - row_height
            inset = min(index * 12, 42)
            width = inner_width - inset * 2
            x = 14 + inset
            canvas.setFillColor(WHITE)
            canvas.setStrokeColor(INK)
            canvas.roundRect(x, y, width, row_height, 4, stroke=1, fill=1)
            canvas.setFillColor(INK)
            canvas.circle(x + 15, y + row_height / 2, 8, stroke=0, fill=1)
            canvas.setFillColor(WHITE)
            canvas.setFont("TermuctiveTimes-Bold", 7)
            canvas.drawCentredString(x + 15, y + row_height / 2 - 2.4, str(index + 1))
            content = labeled_paragraph(
                item.get("title"), item.get("detail"), self.styles
            )
            _, content_height = content.wrap(width - 42, row_height - 10)
            content.drawOn(canvas, x + 32, y + (row_height - content_height) / 2)
            if index < len(self.items) - 1:
                next_inset = min((index + 1) * 12, 42)
                arrow_x = 14 + next_inset + (inner_width - next_inset * 2) / 2
                canvas.setStrokeColor(INK)
                canvas.line(arrow_x, y - 1, arrow_x, y - 7)
            y_top = y - 8


class LearningDocTemplate(BaseDocTemplate):
    def __init__(self, filename: str, document: dict[str, Any]) -> None:
        super().__init__(
            filename,
            pagesize=letter,
            leftMargin=LEFT_MARGIN,
            rightMargin=RIGHT_MARGIN,
            topMargin=TOP_MARGIN,
            bottomMargin=BOTTOM_MARGIN,
            title=clean_text(document.get("title")),
            author="Termuctive Learning PDF",
            subject=clean_text(document.get("learning_boundary")),
            initialFontName="TermuctiveTimes",
            initialFontSize=9.2,
            initialLeading=12.2,
        )
        self.learning_title = clean_text(document.get("title"))
        frame = Frame(
            LEFT_MARGIN,
            BOTTOM_MARGIN,
            CONTENT_WIDTH,
            PAGE_HEIGHT - TOP_MARGIN - BOTTOM_MARGIN,
            leftPadding=0,
            rightPadding=0,
            topPadding=0,
            bottomPadding=0,
        )
        self.addPageTemplates(PageTemplate(id="lesson", frames=[frame], onPage=self._page))

    def _page(self, canvas: Any, doc: Any) -> None:
        canvas.saveState()
        canvas.setTitle(self.learning_title)
        canvas.setAuthor("Termuctive Learning PDF")
        canvas.setSubject("Compact Textbook learning brief")
        canvas.setFillColor(MIDDLE)
        canvas.setFont("TermuctiveTimes-Bold", 6.8)
        canvas.drawString(
            LEFT_MARGIN,
            PAGE_HEIGHT - 30,
            "TERMUCTIVE LEARNING SERIES / COMPACT TEXTBOOK",
        )
        canvas.setFont("TermuctiveTimes", 6.8)
        canvas.drawRightString(
            PAGE_WIDTH - RIGHT_MARGIN,
            PAGE_HEIGHT - 30,
            f"PAGE {doc.page:02d}",
        )
        canvas.setStrokeColor(LINE)
        canvas.setLineWidth(0.45)
        canvas.line(LEFT_MARGIN, 29, PAGE_WIDTH - RIGHT_MARGIN, 29)
        canvas.setFont("TermuctiveTimes", 6.6)
        footer_title = self.learning_title
        if len(footer_title) > 74:
            footer_title = footer_title[:71].rstrip() + "..."
        canvas.drawString(LEFT_MARGIN, 18, footer_title)
        canvas.drawRightString(
            PAGE_WIDTH - RIGHT_MARGIN,
            18,
            f"Learning brief | {doc.page}",
        )
        canvas.restoreState()


def section_label(text: Any, styles: dict[str, ParagraphStyle]) -> Paragraph:
    return Paragraph(markup(text).upper(), styles["section"])


def metadata_table(
    document: dict[str, Any], styles: dict[str, ParagraphStyle]
) -> Table:
    values = [
        ("PROJECT", document.get("project")),
        ("DATE", document.get("date") or "Not specified"),
        ("LEARNING BOUNDARY", document.get("learning_boundary")),
    ]
    cells = [
        Paragraph(
            f"<b>{markup(label)}</b><br/>{markup(value)}",
            styles["meta"],
        )
        for label, value in values
    ]
    table = Table([cells], colWidths=[CONTENT_WIDTH * 0.19, CONTENT_WIDTH * 0.19, CONTENT_WIDTH * 0.62])
    table.setStyle(
        TableStyle(
            [
                ("FONTNAME", (0, 0), (-1, -1), "TermuctiveTimes"),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 9),
                ("TOPPADDING", (0, 0), (-1, -1), 0),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
            ]
        )
    )
    return table


def overview_table(
    overview: list[dict[str, Any]], styles: dict[str, ParagraphStyle]
) -> Table:
    rows: list[list[Any]] = [
        [Paragraph("AT A GLANCE", styles["section"]), Spacer(1, 1)]
    ]
    for item in overview:
        rows.append(
            [
                labeled_paragraph(item.get("label"), item.get("detail"), styles),
                paragraph(clean_text(item.get("status"), "NOTED").upper(), styles["status"]),
            ]
        )
    table = Table(rows, colWidths=[CONTENT_WIDTH * 0.25, CONTENT_WIDTH * 0.14])
    commands = [
        ("FONTNAME", (0, 0), (-1, -1), "TermuctiveTimes"),
        ("SPAN", (0, 0), (1, 0)),
        ("BACKGROUND", (0, 0), (-1, -1), PANEL),
        ("BOX", (0, 0), (-1, -1), 0.6, LINE),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
    ]
    for row in range(2, len(rows)):
        commands.append(("LINEABOVE", (0, row), (-1, row), 0.35, LINE))
    table.setStyle(TableStyle(commands))
    return table


def explanation_block(
    document: dict[str, Any], styles: dict[str, ParagraphStyle]
) -> Table:
    explanation = document["simple_explanation"]
    left: list[Flowable] = [paragraph("The idea in simple terms", styles["heading"])]
    analogy = clean_text(explanation.get("analogy"))
    if analogy:
        left.append(
            Table(
                [[paragraph(analogy, styles["takeaway"])]],
                colWidths=[CONTENT_WIDTH * 0.55 - 18],
                style=TableStyle(
                    [
                        ("FONTNAME", (0, 0), (-1, -1), "TermuctiveTimes"),
                        ("BACKGROUND", (0, 0), (-1, -1), PAPER),
                        ("LINEBEFORE", (0, 0), (0, -1), 1.5, INK),
                        ("LEFTPADDING", (0, 0), (-1, -1), 9),
                        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
                        ("TOPPADDING", (0, 0), (-1, -1), 7),
                        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
                    ]
                ),
            )
        )
        left.append(Spacer(1, 6))
    for text in explanation["paragraphs"]:
        left.append(paragraph(text, styles["body"]))

    overview = document.get("overview")
    right: Flowable
    if isinstance(overview, list) and overview:
        right = overview_table(overview, styles)
    else:
        right = Table(
            [[paragraph(document.get("learning_boundary"), styles["takeaway"])]],
            colWidths=[CONTENT_WIDTH * 0.39],
            style=TableStyle(
                [
                    ("FONTNAME", (0, 0), (-1, -1), "TermuctiveTimes"),
                    ("BACKGROUND", (0, 0), (-1, -1), PANEL),
                    ("BOX", (0, 0), (-1, -1), 0.6, LINE),
                    ("LEFTPADDING", (0, 0), (-1, -1), 10),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 10),
                    ("TOPPADDING", (0, 0), (-1, -1), 10),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 10),
                ]
            ),
        )

    table = Table(
        [[left, right]],
        colWidths=[CONTENT_WIDTH * 0.58, CONTENT_WIDTH * 0.42],
    )
    table.setStyle(
        TableStyle(
            [
                ("FONTNAME", (0, 0), (-1, -1), "TermuctiveTimes"),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (0, 0), 0),
                ("RIGHTPADDING", (0, 0), (0, 0), 13),
                ("LEFTPADDING", (1, 0), (1, 0), 0),
                ("RIGHTPADDING", (1, 0), (1, 0), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 0),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
            ]
        )
    )
    return table


def numbered_work(
    items: list[dict[str, Any]], styles: dict[str, ParagraphStyle]
) -> list[Flowable]:
    flowables: list[Flowable] = []
    for index, item in enumerate(items, start=1):
        status = clean_text(item.get("status"), "NOTED").upper()
        content = Paragraph(
            f"<b>{markup(item.get('title'))}</b>"
            f" <font color='#666666' size='6.4'>{markup(status)}</font><br/>"
            f"{markup(item.get('detail'))}",
            styles["body_small"],
        )
        table = Table(
            [[paragraph(index, styles["number"]), content]],
            colWidths=[23, CONTENT_WIDTH - 23],
        )
        table.setStyle(
            TableStyle(
                [
                    ("FONTNAME", (0, 0), (-1, -1), "TermuctiveTimes"),
                    ("BACKGROUND", (0, 0), (0, 0), INK),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (0, 0), 2),
                    ("RIGHTPADDING", (0, 0), (0, 0), 2),
                    ("TOPPADDING", (0, 0), (0, 0), 7),
                    ("BOTTOMPADDING", (0, 0), (0, 0), 5),
                    ("LEFTPADDING", (1, 0), (1, 0), 8),
                    ("RIGHTPADDING", (1, 0), (1, 0), 2),
                    ("TOPPADDING", (1, 0), (1, 0), 3),
                    ("BOTTOMPADDING", (1, 0), (1, 0), 5),
                ]
            )
        )
        flowables.append(KeepTogether([table, Spacer(1, 4)]))
    return flowables


def evidence_table(
    items: list[dict[str, Any]], styles: dict[str, ParagraphStyle]
) -> Table:
    rows: list[list[Flowable]] = [
        [
            paragraph("CLAIM", styles["table_header"]),
            paragraph("EVIDENCE", styles["table_header"]),
            paragraph("STATUS", styles["table_header"]),
        ]
    ]
    for item in items:
        rows.append(
            [
                paragraph(item.get("claim"), styles["table_body"]),
                paragraph(item.get("proof"), styles["table_body"]),
                paragraph(clean_text(item.get("status"), "NOTED").upper(), styles["status"]),
            ]
        )
    table = Table(
        rows,
        colWidths=[CONTENT_WIDTH * 0.27, CONTENT_WIDTH * 0.56, CONTENT_WIDTH * 0.17],
        repeatRows=1,
    )
    table.setStyle(
        TableStyle(
            [
                ("FONTNAME", (0, 0), (-1, -1), "TermuctiveTimes"),
                ("BACKGROUND", (0, 0), (-1, 0), INK),
                ("GRID", (0, 0), (-1, -1), 0.35, LINE),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("ROWBACKGROUNDS", (0, 1), (-1, -1), [WHITE, PAPER]),
                ("LEFTPADDING", (0, 0), (-1, -1), 6),
                ("RIGHTPADDING", (0, 0), (-1, -1), 6),
                ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ]
        )
    )
    return table


def paired_reference_table(
    documentation: list[dict[str, Any]],
    glossary: list[dict[str, Any]],
    styles: dict[str, ParagraphStyle],
) -> Table:
    rows: list[list[Flowable]] = [
        [
            section_label("Documentation", styles),
            section_label("Reusable vocabulary", styles),
        ]
    ]
    for index in range(max(len(documentation), len(glossary))):
        left: Flowable = Spacer(1, 1)
        right: Flowable = Spacer(1, 1)
        if index < len(documentation):
            item = documentation[index]
            left = labeled_paragraph(item.get("label"), item.get("detail"), styles)
        if index < len(glossary):
            item = glossary[index]
            right = labeled_paragraph(item.get("term"), item.get("definition"), styles)
        rows.append([left, right])
    table = Table(
        rows,
        colWidths=[CONTENT_WIDTH / 2, CONTENT_WIDTH / 2],
        repeatRows=1,
    )
    table.setStyle(
        TableStyle(
            [
                ("FONTNAME", (0, 0), (-1, -1), "TermuctiveTimes"),
                ("BACKGROUND", (0, 0), (-1, -1), PANEL),
                ("BOX", (0, 0), (-1, -1), 0.6, LINE),
                ("LINEBEFORE", (1, 0), (1, 0), 0.6, LINE),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 11),
                ("RIGHTPADDING", (0, 0), (-1, -1), 11),
                ("TOPPADDING", (0, 0), (-1, 0), 1),
                ("BOTTOMPADDING", (0, 0), (-1, 0), 1),
                ("TOPPADDING", (0, 1), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 1), (-1, -1), 6),
            ]
        )
    )
    return table


def boundaries_table(
    boundaries: list[Any],
    next_steps: list[Any],
    styles: dict[str, ParagraphStyle],
) -> Table:
    rows: list[list[Flowable]] = [
        [
            section_label("Keep the boundary clear", styles),
            section_label("Continue from here", styles),
        ]
    ]
    for index in range(max(len(boundaries), len(next_steps))):
        left: Flowable = Spacer(1, 1)
        right: Flowable = Spacer(1, 1)
        if index < len(boundaries):
            left = Paragraph(f"&#8226;&nbsp; {markup(boundaries[index])}", styles["body_small"])
        if index < len(next_steps):
            right = Paragraph(f"&#8226;&nbsp; {markup(next_steps[index])}", styles["body_small"])
        rows.append([left, right])
    table = Table(
        rows,
        colWidths=[CONTENT_WIDTH / 2, CONTENT_WIDTH / 2],
        repeatRows=1,
    )
    table.setStyle(
        TableStyle(
            [
                ("FONTNAME", (0, 0), (-1, -1), "TermuctiveTimes"),
                ("BOX", (0, 0), (-1, -1), 0.7, INK),
                ("LINEBEFORE", (1, 0), (1, 0), 0.45, LINE),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 11),
                ("RIGHTPADDING", (0, 0), (-1, -1), 11),
                ("TOPPADDING", (0, 0), (-1, 0), 1),
                ("BOTTOMPADDING", (0, 0), (-1, 0), 1),
                ("TOPPADDING", (0, 1), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 1), (-1, -1), 3),
            ]
        )
    )
    return table


def build_story(
    document: dict[str, Any], styles: dict[str, ParagraphStyle]
) -> list[Flowable]:
    visual = document["visual"]
    story: list[Flowable] = [
        paragraph(document["title"], styles["title"]),
        paragraph(document["subtitle"], styles["subtitle"]),
        metadata_table(document, styles),
        Spacer(1, 8),
        HRFlowable(width="100%", thickness=1.1, color=INK, spaceBefore=2, spaceAfter=7),
        section_label(visual.get("heading"), styles),
        ConceptDiagram(
            clean_text(visual.get("kind")).lower(),
            visual["items"],
            clean_text(visual.get("caption")),
            styles,
        ),
        Spacer(1, 10),
        explanation_block(document, styles),
        section_label("What the session accomplished", styles),
    ]
    story.extend(numbered_work(document["work"], styles))
    story.extend(
        [
            section_label("Evidence and confidence", styles),
            evidence_table(document["evidence"], styles),
        ]
    )

    documentation = document.get("documentation") or []
    glossary = document.get("glossary") or []
    if documentation or glossary:
        story.extend(
            [
                Spacer(1, 7),
                paired_reference_table(documentation, glossary, styles),
            ]
        )

    boundaries = document.get("boundaries") or []
    next_steps = document.get("next_steps") or []
    if boundaries or next_steps:
        story.extend(
            [
                Spacer(1, 7),
                boundaries_table(boundaries, next_steps, styles),
            ]
        )

    takeaway = Table(
        [
            [
                paragraph("ONE-SENTENCE TAKEAWAY", styles["card_title"]),
                paragraph(document["takeaway"], styles["takeaway"]),
            ]
        ],
        colWidths=[CONTENT_WIDTH * 0.24, CONTENT_WIDTH * 0.76],
    )
    takeaway.setStyle(
        TableStyle(
            [
                ("FONTNAME", (0, 0), (-1, -1), "TermuctiveTimes"),
                ("BACKGROUND", (0, 0), (-1, -1), PAPER),
                ("BOX", (0, 0), (-1, -1), 0.75, INK),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("LEFTPADDING", (0, 0), (-1, -1), 10),
                ("RIGHTPADDING", (0, 0), (-1, -1), 10),
                ("TOPPADDING", (0, 0), (-1, -1), 10),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 10),
            ]
        )
    )
    story.extend([Spacer(1, 8), takeaway])
    return story


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render a Termuctive Compact Textbook learning PDF."
    )
    parser.add_argument("--input", required=True, type=Path, help="Input JSON path")
    parser.add_argument("--output", required=True, type=Path, help="Output PDF path")
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Replace an existing output file intentionally",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    input_path = args.input.expanduser().resolve()
    output_path = args.output.expanduser().resolve()
    if input_path.suffix.lower() != ".json":
        raise SystemExit("The input path must end in .json")
    if output_path.suffix.lower() != ".pdf":
        raise SystemExit("The output path must end in .pdf")
    if not input_path.is_file():
        raise SystemExit(f"Input JSON was not found: {input_path}")
    if output_path.exists() and not args.overwrite:
        raise SystemExit("The output already exists. Choose a unique name or pass --overwrite.")

    try:
        with input_path.open("r", encoding="utf-8") as handle:
            document = validate_document(json.load(handle))
    except (json.JSONDecodeError, OSError, ValueError) as error:
        raise SystemExit(f"Invalid learning document: {error}") from error

    register_fonts()
    styles = build_styles()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output_path.stem}-",
        suffix=".pdf",
        dir=output_path.parent,
    )
    os.close(descriptor)
    temporary_path = Path(temporary_name)
    try:
        template = LearningDocTemplate(str(temporary_path), document)
        template.build(build_story(document, styles))
        if temporary_path.stat().st_size == 0:
            raise RuntimeError("the renderer produced an empty file")
        os.replace(temporary_path, output_path)
    except Exception as error:
        temporary_path.unlink(missing_ok=True)
        raise SystemExit(f"Could not render the learning PDF: {error}") from error

    print("Created and embedded the Compact Textbook learning document.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
