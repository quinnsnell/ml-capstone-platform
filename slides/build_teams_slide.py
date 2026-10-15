#!/usr/bin/env python3
"""Build a single 16:9 slide listing the 2026 capstone teams.

Styled to sit inside ProjectProposals2026: a small kicker over a large title,
sponsor name in colour above each project, and a quiet footer line. One card
per project, grouped two columns by four rows, with a sponsor-coloured rule
down the left edge so the eye can group Amby/Dryden/etc. without reading.

Teams come from project-teams-2026-FINAL-30.tsv so the slide cannot drift from
the file. Reads it rather than restating the names.

Output: slides/CapstoneTeams2026.pptx
"""
import csv
import os
import sys

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Emu, Inches, Pt

HERE = os.path.dirname(os.path.abspath(__file__))
TSV = os.path.join(os.path.dirname(HERE), 'project-teams-2026-FINAL-30.tsv')
OUT = os.path.join(HERE, 'CapstoneTeams2026.pptx')

NAVY = RGBColor(0x00, 0x2E, 0x5D)        # BYU navy
INK = RGBColor(0x1A, 0x1A, 0x1A)
BODY = RGBColor(0x3F, 0x46, 0x4D)
MUTED = RGBColor(0x8A, 0x92, 0x9B)
HAIR = RGBColor(0xDD, 0xE1, 0xE6)

# Sponsor -> (display label, accent colour)
SPONSOR = {
    'Student-sponsored': ('STUDENT-PROPOSED', RGBColor(0x1F, 0x7A, 0x5C)),
    'Amby':              ('AMBY',             RGBColor(0x0E, 0x74, 0x90)),
    'Dryden':            ('DRYDEN',           RGBColor(0x6D, 0x28, 0xD9)),
    'FamilySearch':      ('FAMILYSEARCH',     RGBColor(0xB4, 0x53, 0x09)),
    'Waystar':           ('WAYSTAR',          RGBColor(0x1D, 0x4E, 0xD8)),
    'BYU OIT':           ('BYU OIT',          RGBColor(0xBE, 0x12, 0x3C)),
    'Dr. Snell':         ('BYU COMPUTER SCIENCE', NAVY),
}


# Names students typed into the form, corrected against the roster. A slide
# shown to the class should not carry someone's own typo of their name.
NAME_FIX = {'Andre Agurire Roman': 'Andre Aguirre Roman'}


def load():
    rows = []
    with open(TSV, newline='') as f:
        for r in csv.reader(f, delimiter='\t'):
            if len(r) < 3 or r[0] in ('Project', '') or not r[1].strip():
                continue
            sponsor, _, title = r[0].partition(': ')
            label, colour = SPONSOR[sponsor]
            members = [NAME_FIX.get(m.strip(), m.strip())
                       for m in r[1].split(',') if m.strip()]
            rows.append((label, colour, title.strip(), members))
    return rows


def textbox(slide, x, y, w, h, anchor=MSO_ANCHOR.TOP):
    tb = slide.shapes.add_textbox(x, y, w, h)
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    return tf


def run(p, text, size, colour, bold=False, space_after=0, spacing=1.0,
        font='Arial'):
    # Arial, because this slide gets imported into Google Slides, where Arial
    # is the default. Calibri would silently substitute and reflow.
    p.space_after = Pt(space_after)
    p.line_spacing = spacing
    r = p.add_run()
    r.text = text
    r.font.size = Pt(size)
    r.font.bold = bold
    r.font.color.rgb = colour
    r.font.name = font
    return r


def build():
    teams = load()
    assert len(teams) == 8, f"expected 8 projects, got {len(teams)}"
    total = sum(len(m) for _, _, _, m in teams)

    prs = Presentation()
    prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)
    slide = prs.slides.add_slide(prs.slide_layouts[6])      # blank

    M = Inches(0.62)
    W = prs.slide_width - 2 * M

    # ---- header
    tf = textbox(slide, M, Inches(0.46), W, Inches(0.3))
    run(tf.paragraphs[0], 'CS 482  ·  ML CAPSTONE  ·  FALL 2026', 11.5, MUTED,
        bold=True)


    tf = textbox(slide, M, Inches(0.74), Inches(9.0), Inches(0.62))
    run(tf.paragraphs[0], 'Project Teams', 33, INK, bold=True)

    tf = textbox(slide, M + Inches(9.0), Inches(0.86), W - Inches(9.0),
                 Inches(0.4))
    p = tf.paragraphs[0]
    p.alignment = PP_ALIGN.RIGHT
    run(p, f'8 projects   ·   {total} students', 13, NAVY, bold=True)

    rule = slide.shapes.add_connector(1, M, Inches(1.44),
                                      M + W, Inches(1.44))
    rule.line.color.rgb = HAIR
    rule.line.width = Pt(1.0)

    # ---- cards, two columns x four rows
    gap_x, gap_y = Inches(0.34), Inches(0.14)
    cw = Emu(int((W - gap_x) / 2))
    gap_y = Inches(0.30)
    top = Inches(1.78)
    ch = Emu(int((Inches(6.70) - top - 3 * gap_y) / 4))

    for i, (sponsor, colour, title, members) in enumerate(teams):
        col, row = i % 2, i // 2
        x = M + col * (cw + gap_x)
        y = top + row * (ch + gap_y)

        bar = slide.shapes.add_shape(1, x, y, Pt(3.2), ch)   # rectangle
        bar.fill.solid()
        bar.fill.fore_color.rgb = colour
        bar.line.fill.background()
        bar.shadow.inherit = False

        tx = x + Inches(0.17)
        tw = cw - Inches(0.17)

        tf = textbox(slide, tx, y + Inches(0.02), tw, Inches(0.2))
        run(tf.paragraphs[0], sponsor, 9, colour, bold=True)

        tf = textbox(slide, tx, y + Inches(0.23), tw, Inches(0.3))
        run(tf.paragraphs[0], title, 14.5, INK, bold=True, spacing=0.95)

        tf = textbox(slide, tx, y + Inches(0.63), tw, ch - Inches(0.63))
        run(tf.paragraphs[0], '   ·   '.join(members), 10.5, BODY,
            spacing=1.12)

    # ---- footer
    tf = textbox(slide, M, Inches(6.92), W, Inches(0.3))
    p = tf.paragraphs[0]
    run(p, 'Matched from your preference survey  —  ', 10, MUTED)
    run(p, '15 of you got your first choice', 10, NAVY, bold=True)
    run(p, ', 7 your second, 5 your third.  Teams of three and four.', 10,
        MUTED)

    prs.save(OUT)
    print(f"wrote {OUT}")
    for sponsor, _, title, members in teams:
        print(f"  {sponsor:<22} {title[:42]:<44} {len(members)}")


if __name__ == '__main__':
    build()
