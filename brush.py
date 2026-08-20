#!/usr/bin/env python3
"""Brush — 화면 위 필기 오버레이 (Windows / Linux / macOS)

Brush.swift(macOS 네이티브)의 이식판. 도구·굵기·단축키·지우개 규칙 모두 동일하다.
실행: pythonw brush.py     검증: python brush.py --selftest
"""

import math
import os
import sys
from dataclasses import dataclass
from enum import IntEnum

from PySide6.QtCore import QAbstractNativeEventFilter, QPointF, QRectF, Qt
from PySide6.QtGui import (QAction, QColor, QCursor, QFont, QFontMetricsF, QIcon,
                           QPainter, QPainterPath, QPen, QPixmap, QPolygonF)
from PySide6.QtWidgets import (QApplication, QColorDialog, QFrame, QLineEdit, QMenu,
                               QPushButton, QSystemTrayIcon, QVBoxLayout, QWidget)


class Tool(IntEnum):
    PEN = 0
    ARROW = 1
    RECT = 2
    TEXT = 3
    ERASER = 4


@dataclass
class Shape:
    tool: Tool
    points: list
    color: QColor
    width: float
    text: str = None


# 툴바에 그대로 한 줄씩 놓이는 굵기 — 강의 화면에서 보이라고 전체적으로 굵게 잡았다
BRUSH_WIDTHS = [4, 8, 14, 22]

# 텍스트 크기도 굵기에 묶는다 (별도 컨트롤을 만들 이유가 없음) — 기본 8 → 36pt
def font_size(width):
    return int(12 + width * 3)


def text_font(width):
    f = QFont()
    f.setPixelSize(font_size(width))
    f.setBold(True)
    return f


def distance_to_segment(p, a, b):
    dx, dy = b.x() - a.x(), b.y() - a.y()
    len2 = dx * dx + dy * dy
    if len2 <= 0:
        return math.hypot(p.x() - a.x(), p.y() - a.y())
    t = min(1.0, max(0.0, ((p.x() - a.x()) * dx + (p.y() - a.y()) * dy) / len2))
    return math.hypot(p.x() - (a.x() + t * dx), p.y() - (a.y() + t * dy))


# MARK: - 캔버스 겸 오버레이 창

class Canvas(QWidget):
    def __init__(self):
        super().__init__(None,
                         Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setCursor(Qt.CrossCursor)

        self.shapes = []
        self.current = []
        self.editor = None
        self._editor_width = 0  # 입력 시작 시점의 굵기 — 도중에 툴바를 만져도 안 흔들리게

        self.tool = Tool.PEN
        self.ink_color = QColor("#ff3b30")
        self.line_width = BRUSH_WIDTHS[1]

    # 마우스 핸들러가 부르는 것과 같은 진입점 — 셀프테스트도 여기를 쓴다
    def begin(self, p):
        self.current = [QPointF(p)]
        self.update()

    def extend(self, p):
        if self.tool == Tool.PEN:
            self.current.append(QPointF(p))
        elif self.tool in (Tool.ARROW, Tool.RECT):
            self.current = [self.current[0], QPointF(p)]  # 시작점 고정, 끝점만 갱신
        self.update()

    def end(self):
        if len(self.current) > 1:
            self.shapes.append(Shape(self.tool, self.current, QColor(self.ink_color), self.line_width))
        self.current = []
        self.update()

    def clear(self):
        self._drop_editor()
        self.shapes = []
        self.current = []
        self.update()

    def _drop_editor(self):
        e, self.editor = self.editor, None  # 콜백이 다시 들어와도 재진입하지 않게 먼저 비운다
        if e is not None:
            e.hide()  # deleteLater는 이벤트 루프가 돌 때까지 미뤄져서 그 사이 한 번 더 그려진다
            e.deleteLater()
        return e

    # MARK: 텍스트 — 클릭한 자리에 입력 필드를 띄우고, 엔터/포커스 이탈 시 도형으로 확정
    def begin_text(self, p):
        self.commit_text()
        self._editor_width = self.line_width
        size = font_size(self.line_width)
        e = QLineEdit(self)
        e.setFont(text_font(self.line_width))
        e.setStyleSheet(
            "background: transparent; border: none; color: %s;" % self.ink_color.name())
        e.setPlaceholderText("입력 후 Enter")
        e.setGeometry(int(p.x()), int(p.y()), 320, int(size * 1.5))
        e.returnPressed.connect(self.commit_text)
        e.editingFinished.connect(self.commit_text)
        e.show()
        e.setFocus()
        self.editor = e

    def commit_text(self):
        e = self._drop_editor()
        if e is None:
            return
        s = e.text()
        origin = QPointF(e.x(), e.y())
        if s:
            self.shapes.append(Shape(Tool.TEXT, [origin], QColor(self.ink_color), self._editor_width, s))
        self.setFocus()  # ESC 전체 지우기가 다시 캔버스로 오도록
        self.update()

    # MARK: 지우개 — 픽셀이 아니라 도형 단위로 지운다 (도형 목록만 들고 있는 구조라 그게 자연스럽다)
    @property
    def eraser_radius(self):
        return max(14, self.line_width * 1.5)

    def erase(self, p):
        before = len(self.shapes)
        self.shapes = [s for s in self.shapes if not self._hits(s, QPointF(p))]
        if len(self.shapes) != before:
            self.update()

    def _hits(self, s, p):
        tol = self.eraser_radius + s.width / 2
        if not s.points:
            return False
        first, last = s.points[0], s.points[-1]
        if s.tool in (Tool.PEN, Tool.ARROW):
            return any(distance_to_segment(p, a, b) <= tol
                       for a, b in zip(s.points, s.points[1:]))
        if s.tool == Tool.RECT:
            # 테두리만 그려지므로 안쪽을 훑어도 안 지워지게 네 변으로 따진다
            x0, x1 = min(first.x(), last.x()), max(first.x(), last.x())
            y0, y1 = min(first.y(), last.y()), max(first.y(), last.y())
            corners = [QPointF(x0, y0), QPointF(x1, y0), QPointF(x1, y1), QPointF(x0, y1)]
            return any(distance_to_segment(p, corners[i], corners[(i + 1) % 4]) <= tol
                       for i in range(4))
        if s.tool == Tool.TEXT:
            fm = QFontMetricsF(text_font(s.width))
            r = QRectF(first, fm.size(0, s.text or "")).adjusted(-tol, -tol, tol, tol)
            return r.contains(p)
        return False

    # MARK: 입력
    def mousePressEvent(self, e):
        p = e.position()
        if self.tool == Tool.TEXT:
            self.begin_text(p)
        elif self.tool == Tool.ERASER:
            self.erase(p)
        else:
            self.begin(p)

    def mouseMoveEvent(self, e):
        p = e.position()
        if self.tool == Tool.TEXT:
            return
        if self.tool == Tool.ERASER:
            self.erase(p)
        elif self.current:
            self.extend(p)

    def mouseReleaseEvent(self, e):
        if self.tool not in (Tool.TEXT, Tool.ERASER):
            self.end()

    def keyPressEvent(self, e):
        if e.key() == Qt.Key_Escape:
            self.clear()
        else:
            super().keyPressEvent(e)

    # MARK: 그리기
    # ponytail: 점 하나 찍힐 때마다 전체 다시 그림. 선이 수백 개로 늘어 버벅이면 캐시 레이어로.
    def paintEvent(self, _):
        g = QPainter(self)
        g.setRenderHint(QPainter.Antialiasing)
        # 완전 투명이면 윈도우가 클릭을 밑 앱으로 통과시킨다 → 눈에 안 보이는 최소 알파 필요
        g.fillRect(self.rect(), QColor(0, 0, 0, 1))
        live = ([Shape(self.tool, self.current, self.ink_color, self.line_width)]
                if len(self.current) > 1 else [])
        for s in self.shapes + live:
            self._draw_shape(g, s)

    def _draw_shape(self, g, s):
        if not s.points:
            return
        first, last = s.points[0], s.points[-1]
        pen = QPen(s.color, s.width, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
        g.setPen(pen)
        g.setBrush(Qt.NoBrush)
        if s.tool == Tool.PEN:
            path = QPainterPath(first)
            for p in s.points[1:]:
                path.lineTo(p)
            g.drawPath(path)
        elif s.tool == Tool.RECT:
            g.drawRect(QRectF(first, last).normalized())
        elif s.tool == Tool.ARROW:
            self._draw_arrow(g, first, last, s.width, s.color)
        elif s.tool == Tool.TEXT:
            g.setFont(text_font(s.width))
            fm = QFontMetricsF(g.font())
            g.drawText(QRectF(first, fm.size(0, s.text or "")),
                       Qt.AlignLeft | Qt.AlignTop, s.text or "")

    def _draw_arrow(self, g, a, b, width, color):
        g.drawLine(a, b)
        angle = math.atan2(b.y() - a.y(), b.x() - a.x())
        head_len = max(14, width * 3.5)
        head_angle = math.pi / 7
        p1 = QPointF(b.x() - head_len * math.cos(angle - head_angle),
                     b.y() - head_len * math.sin(angle - head_angle))
        p2 = QPointF(b.x() - head_len * math.cos(angle + head_angle),
                     b.y() - head_len * math.sin(angle + head_angle))
        g.setPen(Qt.NoPen)
        g.setBrush(color)
        g.drawPolygon(QPolygonF([b, p1, p2]))


# MARK: - 도구 모음 (펜/화살표/사각형/텍스트/지우개 + 색상 + 굵기)

BUTTON = 36

TOOL_BUTTONS = [
    (Tool.PEN, "✏", "펜"),
    (Tool.ARROW, "↗", "화살표"),
    (Tool.RECT, "□", "사각형"),
    (Tool.TEXT, "T", "텍스트"),
    (Tool.ERASER, "⌫", "지우개 (닿는 것만 지움 · 전체는 ESC)"),
]

# 색상 대화상자의 "사용자 지정" 칸으로 들어감 — 툴바에는 스와치 무더기 대신 색상 버튼 하나만 둔다
PRESET_COLORS = ["#ff3b30", "#000000", "#0a84ff", "#d9ff00", "#ff00cc", "#38ff14"]

FLAT_STYLE = """
QPushButton { border: none; border-radius: 9px; background: rgba(255,255,255,0.06);
              color: rgba(255,255,255,0.8); font-size: 18px; }
QPushButton:checked { background: #0a84ff; color: white; }
"""


class Toolbar(QWidget):
    def __init__(self, canvas):
        super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
                         | Qt.Tool | Qt.WindowDoesNotAcceptFocus)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setAttribute(Qt.WA_ShowWithoutActivating)  # 눌러도 캔버스의 키 포커스(ESC)를 뺏지 않게
        self.canvas = canvas
        self._drag = None

        self.tool_buttons = {}
        self.size_buttons = []
        box = QVBoxLayout(self)
        box.setContentsMargins(10, 16, 10, 16)
        box.setSpacing(10)

        for tool, glyph, tip in TOOL_BUTTONS:
            b = self._button(glyph, tip)
            b.clicked.connect(lambda _=False, t=tool: self._pick_tool(t))
            self.tool_buttons[tool] = b
            box.addWidget(b)
        self.tool_buttons[Tool.PEN].setChecked(True)

        box.addWidget(self._separator())

        self.color_button = QPushButton()
        self.color_button.setFixedSize(BUTTON, BUTTON)
        self.color_button.setToolTip("색상 선택 (형광펜 팔레트 포함)")
        self.color_button.clicked.connect(self._pick_color)
        self._paint_color_button()
        box.addWidget(self.color_button)

        box.addWidget(self._separator())

        for i, w in enumerate(BRUSH_WIDTHS):
            b = self._button("", "굵기 %d" % w)
            b.setIcon(self._dot_icon(min(w + 4, 22)))
            b.setChecked(w == canvas.line_width)
            b.clicked.connect(lambda _=False, i=i: self._pick_size(i))
            self.size_buttons.append(b)
            box.addWidget(b)

        for i, c in enumerate(PRESET_COLORS):
            QColorDialog.setCustomColor(i, QColor(c))

    def _button(self, glyph, tip):
        b = QPushButton(glyph)
        b.setCheckable(True)
        b.setFixedSize(BUTTON, BUTTON)
        b.setToolTip(tip)
        b.setFocusPolicy(Qt.NoFocus)
        b.setStyleSheet(FLAT_STYLE)
        return b

    def _separator(self):
        line = QFrame()
        line.setFrameShape(QFrame.HLine)
        line.setStyleSheet("color: rgba(255,255,255,0.2);")
        return line

    def _dot_icon(self, d):
        pm = QPixmap(24, 24)
        pm.fill(Qt.transparent)
        g = QPainter(pm)
        g.setRenderHint(QPainter.Antialiasing)
        g.setPen(Qt.NoPen)
        g.setBrush(QColor(255, 255, 255, 220))
        g.drawEllipse(QRectF((24 - d) / 2, (24 - d) / 2, d, d))
        g.end()
        return QIcon(pm)

    def _paint_color_button(self):
        c = self.canvas.ink_color.name()
        self.color_button.setStyleSheet(
            "border: 1px solid rgba(255,255,255,0.5); border-radius: 9px; background: %s;" % c)

    def _pick_tool(self, tool):
        self.canvas.commit_text()  # 입력 중이던 텍스트를 도구 바꾸며 잃지 않게
        self.canvas.tool = tool
        for t, b in self.tool_buttons.items():
            b.setChecked(t == tool)

    def _pick_size(self, i):
        self.canvas.line_width = BRUSH_WIDTHS[i]
        for j, b in enumerate(self.size_buttons):
            b.setChecked(j == i)

    def _pick_color(self):
        c = QColorDialog.getColor(self.canvas.ink_color, self, "색상")
        if c.isValid():
            self.canvas.ink_color = c
            self._paint_color_button()

    # 배경을 잡고 끌면 툴바가 따라온다
    def mousePressEvent(self, e):
        self._drag = e.globalPosition().toPoint() - self.pos()

    def mouseMoveEvent(self, e):
        if self._drag is not None:
            self.move(e.globalPosition().toPoint() - self._drag)

    def mouseReleaseEvent(self, e):
        self._drag = None

    def paintEvent(self, _):
        g = QPainter(self)
        g.setRenderHint(QPainter.Antialiasing)
        g.setPen(Qt.NoPen)
        g.setBrush(QColor(28, 28, 30, 235))
        g.drawRoundedRect(QRectF(self.rect()), 14, 14)

    def reposition(self, screen_rect):
        self.adjustSize()
        self.move(screen_rect.left() + 24,
                  screen_rect.center().y() - self.height() // 2)


# MARK: - 전역 단축키 (⌥Z / Alt+Z) — Windows는 RegisterHotKey, 그 외는 트레이 메뉴로

MOD_ALT, MOD_NOREPEAT, VK_Z, WM_HOTKEY = 0x0001, 0x4000, 0x5A, 0x0312


class WindowsHotKey(QAbstractNativeEventFilter):
    def __init__(self, callback):
        super().__init__()
        self.callback = callback
        import ctypes
        self.ok = bool(ctypes.windll.user32.RegisterHotKey(None, 1, MOD_ALT | MOD_NOREPEAT, VK_Z))

    def nativeEventFilter(self, kind, message):
        if kind == b"windows_generic_MSG":
            import ctypes.wintypes
            msg = ctypes.wintypes.MSG.from_address(int(message))
            if msg.message == WM_HOTKEY:
                self.callback()
        return False, 0


# MARK: - 앱

class BrushApp:
    def __init__(self, app):
        self.app = app
        self.canvas = Canvas()
        self.toolbar = Toolbar(self.canvas)
        self.is_on = False
        self.hotkey = None

        self.tray = QSystemTrayIcon(self._tray_icon("✏️"))
        menu = QMenu()
        self._add(menu, "브러시 켜기 / 끄기  (Alt+Z)", self.toggle)
        self._add(menu, "전체 지우기  (ESC)", self.canvas.clear)
        menu.addSeparator()
        self._add(menu, "종료", app.quit)
        self.tray.setContextMenu(menu)
        self.tray.activated.connect(
            lambda r: self.toggle() if r == QSystemTrayIcon.Trigger else None)
        self.tray.show()

        if sys.platform == "win32":
            self.hotkey = WindowsHotKey(self.toggle)
            app.installNativeEventFilter(self.hotkey)
            if not self.hotkey.ok:
                self.tray.setIcon(self._tray_icon("⚠️"))
                self.tray.setToolTip("Alt+Z를 다른 앱이 쓰는 중 — 트레이 아이콘으로 켜고 끄세요")
        else:
            self.tray.setToolTip("Brush — 트레이 아이콘 클릭으로 켜고 끄기")

    def _add(self, menu, title, slot):
        a = QAction(title, menu)
        a.triggered.connect(slot)
        menu.addAction(a)

    def _tray_icon(self, glyph):
        pm = QPixmap(32, 32)
        pm.fill(Qt.transparent)
        g = QPainter(pm)
        f = QFont()
        f.setPixelSize(26)
        g.setFont(f)
        g.drawText(pm.rect(), Qt.AlignCenter, glyph)
        g.end()
        return QIcon(pm)

    def _screen_under_mouse(self):
        return QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()

    def toggle(self):
        self.turn_off() if self.is_on else self.turn_on()

    def turn_on(self):
        rect = self._screen_under_mouse().geometry()
        self.canvas.setGeometry(rect)
        self.canvas.show()
        self.canvas.raise_()
        self.canvas.activateWindow()
        self.canvas.setFocus()
        self.toolbar.reposition(rect)
        self.toolbar.show()
        self.toolbar.raise_()
        self.is_on = True
        self.tray.setIcon(self._tray_icon("🖍️"))

    def turn_off(self):
        self.canvas.clear()
        self.canvas.hide()
        self.toolbar.hide()
        self.is_on = False
        self.tray.setIcon(self._tray_icon("✏️"))


# MARK: - 셀프테스트 (--selftest)

def run_selftest():
    app = QApplication(sys.argv)
    v = Canvas()
    v.resize(200, 200)
    failures = 0

    def check(cond, msg):
        nonlocal failures
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures += 1

    def ink_pixels():
        img = v.grab().toImage()
        n = 0
        for x in range(0, img.width(), 2):
            for y in range(0, img.height(), 2):
                c = img.pixelColor(x, y)
                if c.alpha() > 76 and c.red() > 127 and c.green() < 127:
                    n += 1
        return n

    check(ink_pixels() == 0, "빈 캔버스에는 잉크 없음")

    v.begin(QPointF(20, 20))
    v.extend(QPointF(100, 100))
    v.extend(QPointF(180, 180))
    check(ink_pixels() > 20, "드래그 중인 선이 즉시 보임")

    v.end()
    check(len(v.shapes) == 1 and len(v.shapes[0].points) == 3, "마우스를 떼면 도형 1개 확정")
    check(ink_pixels() > 20, "확정된 도형이 계속 보임")

    v.begin(QPointF(5, 5)); v.end()
    check(len(v.shapes) == 1, "점 하나짜리(=단순 클릭)는 도형으로 안 남음")

    v.clear()
    check(not v.shapes and ink_pixels() == 0, "clear() 후 캔버스 비워짐")

    v.tool = Tool.RECT
    v.begin(QPointF(20, 20)); v.extend(QPointF(20, 20)); v.extend(QPointF(150, 150)); v.end()
    check(len(v.shapes) == 1 and v.shapes[0].tool == Tool.RECT, "사각형 도구로 도형 1개 확정")
    check(ink_pixels() > 5, "사각형 테두리가 보임")
    v.clear()

    v.tool = Tool.ARROW
    v.begin(QPointF(20, 100)); v.extend(QPointF(180, 100)); v.end()
    check(len(v.shapes) == 1 and v.shapes[0].tool == Tool.ARROW, "화살표 도구로 도형 1개 확정")
    check(ink_pixels() > 20, "화살표가 보임")
    v.clear()

    v.tool = Tool.PEN
    v.line_width = 8
    v.begin(QPointF(20, 20)); v.extend(QPointF(180, 180)); v.end()
    v.begin(QPointF(20, 180)); v.extend(QPointF(60, 180)); v.end()
    v.tool = Tool.ERASER
    v.erase(QPointF(190, 20))
    check(len(v.shapes) == 2, "빈 곳을 지워도 도형은 그대로")
    v.erase(QPointF(100, 100))
    check(len(v.shapes) == 1, "선 위를 지우면 그 도형만 사라짐")
    v.erase(QPointF(40, 180))
    check(not v.shapes and ink_pixels() == 0, "남은 도형도 지워짐")

    v.tool = Tool.TEXT
    v.line_width = 14
    v.begin_text(QPointF(10, 90))
    v.editor.setText("가나다ABC")
    v.commit_text()
    check(len(v.shapes) == 1 and v.shapes[0].text == "가나다ABC", "텍스트 입력이 도형 1개로 확정됨")
    check(ink_pixels() > 20, "확정된 텍스트가 보임")

    v.begin_text(QPointF(10, 40))
    v.commit_text()
    check(len(v.shapes) == 1, "빈 텍스트는 도형으로 안 남음")

    v.tool = Tool.ERASER
    v.erase(QPointF(30, 100))
    check(not v.shapes, "텍스트도 지우개로 지워짐")

    v.tool = Tool.TEXT
    v.begin_text(QPointF(10, 90))
    v.clear()
    check(v.editor is None and ink_pixels() == 0, "clear()가 입력 중인 텍스트 필드도 걷어냄")

    v.tool = Tool.PEN
    v.ink_color = QColor("#0a84ff")
    v.line_width = 10
    v.begin(QPointF(10, 10)); v.extend(QPointF(190, 190)); v.end()
    check(v.shapes[0].color == QColor("#0a84ff") and v.shapes[0].width == 10,
          "색상/굵기 변경이 새 도형에 반영됨")

    print("\n셀프테스트 통과" if failures == 0 else "\n실패 %d건" % failures)
    return 0 if failures == 0 else 1


def main():
    if "--selftest" in sys.argv:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        sys.exit(run_selftest())

    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)  # 창을 다 닫아도 트레이로 살아 있는다
    brush = BrushApp(app)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
