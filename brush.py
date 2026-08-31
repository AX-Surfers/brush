#!/usr/bin/env python3
"""Brush — 화면 위 필기 오버레이 (Windows / Linux / macOS)

Brush.swift(macOS 네이티브)의 이식판. 도구·굵기·단축키·지우개 규칙 모두 동일하다.
실행: pythonw brush.py     검증: python brush.py --selftest
"""

import math
import os
import sys
import tempfile
from dataclasses import dataclass, field
from enum import IntEnum

from PySide6.QtCore import (QAbstractNativeEventFilter, QPoint, QPointF, QRect, QRectF,
                            QSettings, QSizeF, QTimer, Qt)
from PySide6.QtGui import (QAction, QColor, QCursor, QFont, QFontMetricsF, QIcon,
                           QKeySequence, QPainter, QPainterPath, QPen, QPixmap,
                           QPolygonF)
from PySide6.QtWidgets import (QApplication, QColorDialog, QDialog, QDialogButtonBox,
                               QDoubleSpinBox, QFormLayout, QFrame, QHBoxLayout, QLabel,
                               QLineEdit, QMenu, QMessageBox, QPushButton,
                               QKeySequenceEdit, QSpinBox, QSystemTrayIcon, QTabWidget,
                               QVBoxLayout, QWidget)


class Tool(IntEnum):
    PEN = 0
    ARROW = 1
    RECT = 2
    TEXT = 3
    ERASER = 4
    CLICK = 5
    LASER = 6
    ARROW_POINTER = 7
    MAGNIFIER_CIRCLE = 8
    MAGNIFIER_RECT = 9


DRAWING_TOOLS = {Tool.PEN, Tool.ARROW, Tool.RECT, Tool.TEXT, Tool.ERASER}
TRANSIENT_TOOLS = {
    Tool.LASER, Tool.ARROW_POINTER, Tool.MAGNIFIER_CIRCLE, Tool.MAGNIFIER_RECT,
}
MAGNIFIER_TOOLS = {Tool.MAGNIFIER_CIRCLE, Tool.MAGNIFIER_RECT}

ACTION_TO_TOOL = {
    "click": Tool.CLICK,
    "pen": Tool.PEN,
    "arrow": Tool.ARROW,
    "rect": Tool.RECT,
    "text": Tool.TEXT,
    "eraser": Tool.ERASER,
    "laser": Tool.LASER,
    "arrow_pointer": Tool.ARROW_POINTER,
    "magnifier_circle": Tool.MAGNIFIER_CIRCLE,
    "magnifier_rect": Tool.MAGNIFIER_RECT,
}

SHORTCUT_LABELS = {
    "toggle": "브러시 켜기 / 끄기",
    "click": "클릭 통과",
    "pen": "펜",
    "arrow": "화살표 그리기",
    "rect": "사각형 그리기",
    "text": "텍스트",
    "eraser": "지우개",
    "laser": "레이저 포인터",
    "arrow_pointer": "화살표 포인터",
    "magnifier_circle": "원형 확대",
    "magnifier_rect": "사각형 확대",
    "undo": "실행취소",
    "clear": "전체 취소 후 마우스 모드",
}

DEFAULT_SHORTCUTS = {
    "toggle": "Alt+Z",
    "click": "Alt+1",
    "pen": "Alt+2",
    "arrow": "Alt+3",
    "rect": "Alt+4",
    "text": "Alt+5",
    "eraser": "Alt+6",
    "laser": "Alt+7",
    "arrow_pointer": "Alt+8",
    "magnifier_circle": "Alt+9",
    "magnifier_rect": "Alt+0",
    "undo": "Ctrl+Alt+Z",
    "clear": "Escape",
}

SESSION_ACTIONS = set(DEFAULT_SHORTCUTS) - {"toggle"}


def clamp(value, low, high):
    return min(high, max(low, value))


def clamp_zoom(value):
    """확대 배율을 지원 범위와 0.25 단위에 맞춘다."""
    try:
        value = float(value)
    except (TypeError, ValueError):
        value = 2.0
    if not math.isfinite(value):
        value = 2.0
    return clamp(round(value * 4) / 4, 1.25, 8.0)


def safe_int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def canonical_shortcut(value):
    """QKeySequence의 플랫폼 독립 표기로 바꾸고 다중 스트로크를 거부한다."""
    sequence = QKeySequence(str(value or ""))
    text = sequence.toString(QKeySequence.PortableText)
    if not text or "," in text:
        return None
    return text


def validate_shortcuts(shortcuts):
    normalized = {}
    used = {}
    for action in DEFAULT_SHORTCUTS:
        text = canonical_shortcut(shortcuts.get(action))
        if text is None:
            return None, "%s 단축키가 비어 있거나 지원되지 않습니다." % SHORTCUT_LABELS[action]
        duplicate_key = text.casefold()
        if duplicate_key in used:
            return None, "%s와 %s 단축키가 같습니다." % (
                SHORTCUT_LABELS[used[duplicate_key]], SHORTCUT_LABELS[action])
        used[duplicate_key] = action
        normalized[action] = text
    return normalized, None


@dataclass
class Preferences:
    shortcuts: dict = field(default_factory=lambda: dict(DEFAULT_SHORTCUTS))
    laser_size: int = 14
    laser_color: str = "#ff3b30"
    arrow_pointer_size: int = 56
    arrow_pointer_color: str = "#ffcc00"
    magnification: float = 2.0

    def sanitized(self):
        shortcuts, error = validate_shortcuts(self.shortcuts)
        if error:
            shortcuts = dict(DEFAULT_SHORTCUTS)
        laser = QColor(str(self.laser_color or ""))
        arrow = QColor(str(self.arrow_pointer_color or ""))
        return Preferences(
            shortcuts=shortcuts,
            laser_size=int(clamp(safe_int(self.laser_size, 14), 4, 64)),
            laser_color=laser.name() if laser.isValid() else "#ff3b30",
            arrow_pointer_size=int(clamp(safe_int(self.arrow_pointer_size, 56), 20, 160)),
            arrow_pointer_color=arrow.name() if arrow.isValid() else "#ffcc00",
            magnification=clamp_zoom(self.magnification),
        )


class SettingsStore:
    """UI와 독립된 설정 저장소. 테스트에서는 INI QSettings를 주입할 수 있다."""

    def __init__(self, settings=None):
        self.settings = settings or QSettings("AX-Surfers", "Brush")

    def load(self):
        shortcuts = {
            action: str(self.settings.value("shortcuts/" + action, default))
            for action, default in DEFAULT_SHORTCUTS.items()
        }
        value = Preferences(
            shortcuts=shortcuts,
            laser_size=self.settings.value("pointer/laserSize", 14, int),
            laser_color=str(self.settings.value("pointer/laserColor", "#ff3b30")),
            arrow_pointer_size=self.settings.value("pointer/arrowSize", 56, int),
            arrow_pointer_color=str(self.settings.value("pointer/arrowColor", "#ffcc00")),
            magnification=self.settings.value("magnifier/lastZoom", 2.0, float),
        ).sanitized()
        return value

    def save(self, value):
        value = value.sanitized()
        for action, shortcut in value.shortcuts.items():
            self.settings.setValue("shortcuts/" + action, shortcut)
        self.settings.setValue("pointer/laserSize", value.laser_size)
        self.settings.setValue("pointer/laserColor", value.laser_color)
        self.settings.setValue("pointer/arrowSize", value.arrow_pointer_size)
        self.settings.setValue("pointer/arrowColor", value.arrow_pointer_color)
        self.settings.setValue("magnifier/lastZoom", value.magnification)
        self.settings.sync()

    def save_zoom(self, zoom):
        self.settings.setValue("magnifier/lastZoom", clamp_zoom(zoom))
        self.settings.sync()


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


def adjusted_zoom(zoom, wheel_delta):
    """휠 한 노치마다 0.25배 변경하며 범위를 벗어나지 않는다."""
    if abs(wheel_delta) < 120:
        return clamp_zoom(zoom)
    steps = int(wheel_delta / 120)
    return clamp_zoom(zoom + steps * 0.25)


def clamped_centered_rect(center, size, bounds):
    """center 주위 사각형을 만들되 한 디스플레이 경계 안으로 밀어 넣는다."""
    width = min(float(size.width()), float(bounds.width()))
    height = min(float(size.height()), float(bounds.height()))
    left = clamp(center.x() - width / 2, bounds.left(), bounds.right() - width)
    top = clamp(center.y() - height / 2, bounds.top(), bounds.bottom() - height)
    return QRectF(left, top, width, height)


MAGNIFIER_CLICK_THRESHOLD = 10.0
CIRCLE_LENS_MIN, CIRCLE_LENS_MAX = 96.0, 520.0
RECT_LENS_MIN = QSizeF(120.0, 90.0)
RECT_LENS_MAX = QSizeF(720.0, 480.0)


def magnifier_selection_rect(tool, start, end, bounds):
    """드래그를 display-local DIP 렌즈 사각형으로 변환한다."""
    bounds = QRectF(bounds)
    start, end = QPointF(start), QPointF(end)
    center = QPointF((start.x() + end.x()) / 2, (start.y() + end.y()) / 2)
    raw_width = max(1.0, abs(end.x() - start.x()))
    raw_height = max(1.0, abs(end.y() - start.y()))

    if tool == Tool.MAGNIFIER_CIRCLE:
        side = max(raw_width, raw_height, CIRCLE_LENS_MIN)
        side = min(side, CIRCLE_LENS_MAX, bounds.width(), bounds.height())
        return clamped_centered_rect(center, QSizeF(side, side), bounds)

    # 사각 렌즈는 드래그 종횡비를 유지하면서 최소 크기로 키우고 최대/화면 크기로 줄인다.
    grow = max(1.0, RECT_LENS_MIN.width() / raw_width, RECT_LENS_MIN.height() / raw_height)
    shrink_limit = min(RECT_LENS_MAX.width() / raw_width,
                       RECT_LENS_MAX.height() / raw_height,
                       bounds.width() / raw_width,
                       bounds.height() / raw_height)
    scale = min(grow, shrink_limit) if shrink_limit > 0 else 1.0
    # 극단적으로 가는 드래그는 화면에 맞춘 뒤 한 축이 0에 가까워질 수 있으므로
    # 그 경우에만 종횡비를 제한해 두 축 모두 실제로 쓸 수 있는 크기를 보장한다.
    width = clamp(raw_width * scale,
                  min(RECT_LENS_MIN.width(), bounds.width()),
                  min(RECT_LENS_MAX.width(), bounds.width()))
    height = clamp(raw_height * scale,
                   min(RECT_LENS_MIN.height(), bounds.height()),
                   min(RECT_LENS_MAX.height(), bounds.height()))
    size = QSizeF(width, height)
    return clamped_centered_rect(center, size, bounds)


def magnifier_source_rect(global_center, target_size, zoom, frame_geometry, pixel_size):
    """DIP 렌즈 크기를 캡처 픽셀 좌표로 바꿔 혼합 DPI에서도 같은 영역을 샘플링한다."""
    frame_geometry = QRectF(frame_geometry)
    source_dip_size = QSizeF(target_size.width() / zoom, target_size.height() / zoom)
    source_global = clamped_centered_rect(global_center, source_dip_size, frame_geometry)
    relative = source_global.translated(-frame_geometry.x(), -frame_geometry.y())
    scale_x = pixel_size.width() / max(1.0, frame_geometry.width())
    scale_y = pixel_size.height() / max(1.0, frame_geometry.height())
    return QRectF(relative.x() * scale_x, relative.y() * scale_y,
                  relative.width() * scale_x, relative.height() * scale_y)


@dataclass
class CaptureFrame:
    geometry: QRect
    pixmap: QPixmap


class ScreenCaptureService:
    """화면별 스냅샷을 보관한다. Brush 창 제외는 앱 컨트롤러가 적용한다."""

    def __init__(self):
        self.frames = []
        self.last_error = None

    def refresh(self):
        frames = []
        try:
            for screen in QApplication.screens():
                pixmap = screen.grabWindow(0)
                if not pixmap.isNull():
                    frames.append(CaptureFrame(QRect(screen.geometry()), pixmap))
        except Exception as exc:
            self.last_error = str(exc)
            self.frames = []
            return False
        self.frames = frames
        self.last_error = None if frames else "화면을 캡처할 수 없습니다."
        return bool(frames)

    def frame_at(self, global_point):
        point = global_point.toPoint() if isinstance(global_point, QPointF) else global_point
        for frame in self.frames:
            if frame.geometry.contains(point):
                return frame
        return self.frames[0] if self.frames else None


# MARK: - 캔버스 겸 오버레이 창

class Canvas(QWidget):
    history_limit = 100

    def __init__(self, preferences=None, capture_service=None):
        super().__init__(None,
                         Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setMouseTracking(True)

        self.shapes = []
        self.current = []
        self.undo_stack = []
        self.redo_stack = []
        self._erasing = False
        self._erase_snapshot_taken = False
        self.editor = None
        self._editor_width = 0  # 입력 시작 시점의 굵기 — 도중에 툴바를 만져도 안 흔들리게

        self.tool = Tool.PEN
        self.ink_color = QColor("#ff3b30")
        self.line_width = BRUSH_WIDTHS[1]
        self.preferences = (preferences or Preferences()).sanitized()
        self.capture_service = capture_service or ScreenCaptureService()
        self.transient_position = None
        self.magnifier_drag_origin = None
        self.magnifier_drag_current = None
        self.magnifier_drag_bounds = None
        self.magnifier_dragging = False
        self.magnifier_locked_rect = None
        self._wheel_remainder = 0
        self.on_zoom_changed = None
        self.on_local_action = None
        self.set_tool(Tool.PEN)

    def set_preferences(self, preferences):
        self.preferences = preferences.sanitized()
        self.update()

    def set_tool(self, tool):
        tool = Tool(tool)
        if tool != self.tool:
            self.reset_magnifier_interaction(follow=False)
        if self.tool == Tool.TEXT and tool != Tool.TEXT:
            self.commit_text()
        self.current = []
        self.tool = tool
        self._wheel_remainder = 0
        self.setAttribute(Qt.WA_TransparentForMouseEvents, tool == Tool.CLICK)
        self.unsetCursor()
        if tool in (Tool.LASER, Tool.ARROW_POINTER):
            self.setCursor(Qt.BlankCursor)
        elif tool == Tool.CLICK:
            self.setCursor(Qt.ArrowCursor)
        else:
            self.setCursor(Qt.CrossCursor)
        if tool in TRANSIENT_TOOLS:
            self.transient_position = QPointF(self.mapFromGlobal(QCursor.pos()))
        else:
            self.transient_position = None
        self.update()

    def reset_magnifier_interaction(self, follow=False):
        self.magnifier_drag_origin = None
        self.magnifier_drag_current = None
        self.magnifier_drag_bounds = None
        self.magnifier_dragging = False
        self.magnifier_locked_rect = None
        if self.tool in MAGNIFIER_TOOLS:
            self.transient_position = (
                QPointF(self.mapFromGlobal(QCursor.pos())) if follow else None)
        self.update()

    def _screen_bounds_for_local_point(self, p):
        global_point = QPoint(int(p.x() + self.geometry().x()),
                              int(p.y() + self.geometry().y()))
        screen = QApplication.screenAt(global_point)
        if screen is None:
            return QRectF(self.rect())
        return QRectF(screen.geometry()).translated(-self.geometry().x(), -self.geometry().y())

    def begin_magnifier_drag(self, p, bounds=None):
        if self.tool not in MAGNIFIER_TOOLS:
            return
        self.magnifier_drag_origin = QPointF(p)
        self.magnifier_drag_current = QPointF(p)
        self.magnifier_drag_bounds = QRectF(
            bounds if bounds is not None else self._screen_bounds_for_local_point(p))
        self.magnifier_dragging = False

    def move_magnifier_pointer(self, p):
        if self.tool not in MAGNIFIER_TOOLS:
            return
        p = QPointF(p)
        if self.magnifier_drag_origin is not None:
            self.magnifier_drag_current = p
            distance = math.hypot(p.x() - self.magnifier_drag_origin.x(),
                                  p.y() - self.magnifier_drag_origin.y())
            self.magnifier_dragging = distance >= MAGNIFIER_CLICK_THRESHOLD
        elif self.magnifier_locked_rect is None:
            self.transient_position = p
        self.update()

    def magnifier_preview_rect(self):
        if not self.magnifier_dragging or self.magnifier_drag_origin is None:
            return None
        return magnifier_selection_rect(
            self.tool, self.magnifier_drag_origin, self.magnifier_drag_current,
            self.magnifier_drag_bounds)

    def end_magnifier_drag(self, p):
        if self.tool not in MAGNIFIER_TOOLS or self.magnifier_drag_origin is None:
            return
        self.move_magnifier_pointer(p)
        if self.magnifier_dragging:
            self.magnifier_locked_rect = self.magnifier_preview_rect()
            self.transient_position = QPointF(self.magnifier_locked_rect.center())
        else:
            # 짧은 클릭은 잠금을 해제하고 현재 포인터 위치를 따라가게 한다.
            self.magnifier_locked_rect = None
            self.transient_position = QPointF(p)
        self.magnifier_drag_origin = None
        self.magnifier_drag_current = None
        self.magnifier_drag_bounds = None
        self.magnifier_dragging = False
        self.update()

    def restore_cursor(self):
        self.unsetCursor()
        self.setCursor(Qt.ArrowCursor)

    def _remember(self):
        self.undo_stack.append(list(self.shapes))
        if len(self.undo_stack) > self.history_limit:
            self.undo_stack.pop(0)
        self.redo_stack = []

    def undo(self):
        self.commit_text()
        if not self.undo_stack:
            return
        self.redo_stack.append(list(self.shapes))
        self.shapes = self.undo_stack.pop()
        self.current = []
        self.update()

    def redo(self):
        self.commit_text()
        if not self.redo_stack:
            return
        self.undo_stack.append(list(self.shapes))
        self.shapes = self.redo_stack.pop()
        self.current = []
        self.update()

    def reset_history(self):
        self.undo_stack = []
        self.redo_stack = []

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
        if len(self.current) > 1 and self.tool in (Tool.PEN, Tool.ARROW, Tool.RECT):
            self._remember()
            self.shapes.append(Shape(self.tool, self.current, QColor(self.ink_color), self.line_width))
        self.current = []
        self.update()

    def clear(self):
        self._drop_editor()
        if self.shapes:
            self._remember()
        self.shapes = []
        self.current = []
        self.update()

    def cancel_all(self):
        """현재 작업과 실행취소 이력을 모두 버린다."""
        self.reset_magnifier_interaction(follow=False)
        self.clear()
        self.reset_history()

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
            self._remember()
            self.shapes.append(Shape(Tool.TEXT, [origin], QColor(self.ink_color), self._editor_width, s))
        self.setFocus()  # ESC 전체 지우기가 다시 캔버스로 오도록
        self.update()

    # MARK: 지우개 — 픽셀이 아니라 도형 단위로 지운다 (도형 목록만 들고 있는 구조라 그게 자연스럽다)
    @property
    def eraser_radius(self):
        return max(14, self.line_width * 1.5)

    def erase(self, p):
        before = list(self.shapes)
        remaining = [s for s in self.shapes if not self._hits(s, QPointF(p))]
        if len(remaining) != len(before):
            if not self._erase_snapshot_taken:
                self.undo_stack.append(before)
                if len(self.undo_stack) > self.history_limit:
                    self.undo_stack.pop(0)
                self.redo_stack = []
                self._erase_snapshot_taken = True
            self.shapes = remaining
            self.update()
        if not self._erasing:
            self._erase_snapshot_taken = False

    def begin_erase_stroke(self):
        self._erasing = True
        self._erase_snapshot_taken = False

    def end_erase_stroke(self):
        self._erasing = False
        self._erase_snapshot_taken = False

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
        if self.tool in MAGNIFIER_TOOLS:
            self.begin_magnifier_drag(p)
        elif self.tool == Tool.TEXT:
            self.begin_text(p)
        elif self.tool == Tool.ERASER:
            self.begin_erase_stroke()
            self.erase(p)
        elif self.tool in (Tool.PEN, Tool.ARROW, Tool.RECT):
            self.begin(p)

    def mouseMoveEvent(self, e):
        p = e.position()
        if self.tool in MAGNIFIER_TOOLS:
            self.move_magnifier_pointer(p)
            return
        if self.tool in TRANSIENT_TOOLS:
            self.transient_position = QPointF(p)
            self.update()
            return
        if self.tool == Tool.TEXT:
            return
        if self.tool == Tool.ERASER:
            self.erase(p)
        elif self.current:
            self.extend(p)

    def mouseReleaseEvent(self, e):
        if self.tool in MAGNIFIER_TOOLS:
            self.end_magnifier_drag(e.position())
        elif self.tool == Tool.ERASER:
            self.end_erase_stroke()
        elif self.tool in (Tool.PEN, Tool.ARROW, Tool.RECT):
            self.end()

    def wheelEvent(self, e):
        if self.tool not in MAGNIFIER_TOOLS:
            super().wheelEvent(e)
            return
        self._wheel_remainder += e.angleDelta().y()
        steps = int(self._wheel_remainder / 120)
        if steps == 0:
            e.accept()
            return
        self._wheel_remainder -= steps * 120
        updated = clamp_zoom(self.preferences.magnification + steps * 0.25)
        if updated != self.preferences.magnification:
            self.preferences.magnification = updated
            if self.on_zoom_changed:
                self.on_zoom_changed(updated)
            self.update()
        e.accept()

    def keyPressEvent(self, e):
        modifiers = e.modifiers()
        if e.key() == Qt.Key_Escape:
            if self.on_local_action:
                self.on_local_action("clear")
            else:
                self.cancel_all()
        elif e.key() == Qt.Key_Z and modifiers & Qt.ControlModifier:
            self.redo() if modifiers & Qt.ShiftModifier else self.undo()
        elif modifiers == Qt.NoModifier:
            action = {
                Qt.Key_P: "pen", Qt.Key_A: "arrow", Qt.Key_R: "rect",
                Qt.Key_T: "text", Qt.Key_E: "eraser", Qt.Key_C: "click",
                Qt.Key_L: "laser", Qt.Key_M: "magnifier_circle",
            }.get(e.key())
            if action and self.on_local_action:
                self.on_local_action(action)
        else:
            super().keyPressEvent(e)

    def leaveEvent(self, e):
        if self.tool in TRANSIENT_TOOLS:
            self.transient_position = None
            self.update()
        super().leaveEvent(e)

    def hideEvent(self, e):
        self.restore_cursor()
        self.transient_position = None
        super().hideEvent(e)

    # MARK: 그리기
    # ponytail: 점 하나 찍힐 때마다 전체 다시 그림. 선이 수백 개로 늘어 버벅이면 캐시 레이어로.
    def paintEvent(self, _):
        g = QPainter(self)
        g.setRenderHint(QPainter.Antialiasing)
        # 완전 투명이면 윈도우가 클릭을 밑 앱으로 통과시킨다 → 눈에 안 보이는 최소 알파 필요
        g.fillRect(self.rect(), QColor(0, 0, 0, 1))
        live = ([Shape(self.tool, self.current, self.ink_color, self.line_width)]
                if len(self.current) > 1 and self.tool in DRAWING_TOOLS else [])
        for s in self.shapes + live:
            self._draw_shape(g, s)
        if self.tool in MAGNIFIER_TOOLS:
            preview = self.magnifier_preview_rect()
            if preview is not None:
                self._draw_magnifier(g, preview.center(), preview)
                self._draw_magnifier_selection(g, preview)
            elif self.magnifier_locked_rect is not None:
                self._draw_magnifier(
                    g, self.magnifier_locked_rect.center(), self.magnifier_locked_rect)
            elif self.transient_position is not None:
                self._draw_magnifier(g, self.transient_position)
        elif self.transient_position is not None:
            if self.tool == Tool.LASER:
                self._draw_laser(g, self.transient_position)
            elif self.tool == Tool.ARROW_POINTER:
                self._draw_arrow_pointer(g, self.transient_position)

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

    def _draw_laser(self, g, p):
        size = self.preferences.laser_size
        color = QColor(self.preferences.laser_color)
        glow = QColor(color)
        glow.setAlpha(75)
        g.setPen(Qt.NoPen)
        g.setBrush(glow)
        g.drawEllipse(QRectF(p.x() - size, p.y() - size, size * 2, size * 2))
        g.setBrush(color)
        g.drawEllipse(QRectF(p.x() - size / 2, p.y() - size / 2, size, size))
        g.setPen(QPen(QColor(255, 255, 255, 210), max(1.0, size / 10)))
        g.setBrush(Qt.NoBrush)
        g.drawEllipse(QRectF(p.x() - size / 2, p.y() - size / 2, size, size))

    def _draw_arrow_pointer(self, g, p):
        size = float(self.preferences.arrow_pointer_size)
        color = QColor(self.preferences.arrow_pointer_color)
        points = [
            (0.00, 0.00), (0.10, 0.78), (0.29, 0.58), (0.51, 1.00),
            (0.70, 0.90), (0.48, 0.50), (0.76, 0.48),
        ]
        polygon = QPolygonF([QPointF(p.x() + x * size, p.y() + y * size) for x, y in points])
        luminance = color.red() * 0.299 + color.green() * 0.587 + color.blue() * 0.114
        outline = QColor("#ffffff" if luminance < 135 else "#151515")
        g.setPen(QPen(outline, max(2.0, size / 18), Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin))
        g.setBrush(color)
        g.drawPolygon(polygon)

    def _draw_magnifier_selection(self, g, target):
        path = QPainterPath()
        if self.tool == Tool.MAGNIFIER_CIRCLE:
            path.addEllipse(target)
        else:
            path.addRoundedRect(target, 14, 14)
        fill = QColor(10, 132, 255, 45)
        g.setBrush(fill)
        g.setPen(QPen(QColor(255, 255, 255, 235), 3, Qt.DashLine))
        g.drawPath(path)

    def _draw_magnifier(self, g, p, locked_target=None):
        global_point = QPointF(p.x() + self.geometry().x(), p.y() + self.geometry().y())
        frame = self.capture_service.frame_at(global_point)
        if frame is None or frame.pixmap.isNull():
            g.setPen(QColor("#ffffff"))
            g.setBrush(QColor(20, 20, 20, 220))
            notice = QRectF(p.x() - 100, p.y() - 24, 200, 48)
            g.drawRoundedRect(notice, 12, 12)
            g.drawText(notice, Qt.AlignCenter, "화면 캡처를 사용할 수 없습니다")
            return

        if locked_target is not None:
            target = QRectF(locked_target)
        else:
            if self.tool == Tool.MAGNIFIER_CIRCLE:
                target_size = QSizeF(220, 220)
            else:
                target_size = QSizeF(280, 180)
            screen_bounds = QRectF(frame.geometry).translated(
                -self.geometry().x(), -self.geometry().y())
            target = clamped_centered_rect(p, target_size, screen_bounds)

        zoom = self.preferences.magnification
        source = magnifier_source_rect(
            global_point, target.size(), zoom, frame.geometry, frame.pixmap.size())

        path = QPainterPath()
        if self.tool == Tool.MAGNIFIER_CIRCLE:
            path.addEllipse(target)
        else:
            path.addRoundedRect(target, 14, 14)
        g.save()
        g.setClipPath(path)
        g.drawPixmap(target, frame.pixmap, source)
        g.restore()
        g.setPen(QPen(QColor(255, 255, 255, 235), 4))
        g.setBrush(Qt.NoBrush)
        g.drawPath(path)

        label = QRectF(target.right() - 66, target.bottom() - 30, 58, 22)
        g.setPen(Qt.NoPen)
        g.setBrush(QColor(20, 20, 20, 205))
        g.drawRoundedRect(label, 7, 7)
        g.setPen(QColor("#ffffff"))
        zoom_text = ("%.2f" % zoom).rstrip("0").rstrip(".") + "×"
        g.drawText(label, Qt.AlignCenter, zoom_text)


# MARK: - 도구 모음

BUTTON = 28

TOOL_BUTTONS = [
    (Tool.CLICK, "⌁", "클릭 통과 · C / Alt+1"),
    (Tool.PEN, "✏", "펜 · P / Alt+2"),
    (Tool.ARROW, "↗", "화살표 그리기 · A / Alt+3"),
    (Tool.RECT, "□", "사각형 · R / Alt+4"),
    (Tool.TEXT, "T", "텍스트 · T / Alt+5"),
    (Tool.ERASER, "⌫", "지우개 · E / Alt+6"),
    (Tool.LASER, "●", "레이저 포인터 · L / Alt+7"),
    (Tool.ARROW_POINTER, "➤", "화살표 포인터 · Alt+8"),
    (Tool.MAGNIFIER_CIRCLE, "◉", "원형 확대 · M / Alt+9 · 휠로 배율 변경"),
    (Tool.MAGNIFIER_RECT, "▣", "사각형 확대 · Alt+0 · 휠로 배율 변경"),
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
        self.on_tool_changed = None
        self.on_undo = None
        self.on_settings = None

        self.tool_buttons = {}
        self.size_buttons = []
        box = QVBoxLayout(self)
        box.setContentsMargins(8, 10, 8, 10)
        box.setSpacing(3)

        self.tool_column = QVBoxLayout()
        self.tool_column.setContentsMargins(0, 0, 0, 0)
        self.tool_column.setSpacing(2)
        for tool, glyph, tip in TOOL_BUTTONS:
            b = self._button(glyph, tip)
            b.clicked.connect(lambda _=False, t=tool: self._pick_tool(t))
            self.tool_buttons[tool] = b
            self.tool_column.addWidget(b)
        box.addLayout(self.tool_column)
        self.tool_buttons[Tool.PEN].setChecked(True)

        box.addWidget(self._separator())

        self.undo_button = self._button("↶", "실행취소 · Ctrl+Alt+Z", checkable=False)
        self.undo_button.clicked.connect(
            lambda: self.on_undo() if self.on_undo else self.canvas.undo())
        box.addWidget(self.undo_button)

        settings = self._button("⚙", "환경설정", checkable=False)
        settings.clicked.connect(lambda: self.on_settings() if self.on_settings else None)
        box.addWidget(settings)

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

    def _button(self, glyph, tip, checkable=True):
        b = QPushButton(glyph)
        b.setCheckable(checkable)
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
        self.canvas.set_tool(tool)
        for t, b in self.tool_buttons.items():
            b.setChecked(t == tool)
        if self.on_tool_changed:
            self.on_tool_changed(tool)

    def select_tool(self, tool):
        self._pick_tool(tool)

    def refresh_shortcut_tips(self, shortcuts):
        for action, tool in ACTION_TO_TOOL.items():
            suffix = " · 휠로 배율 변경" if tool in MAGNIFIER_TOOLS else ""
            self.tool_buttons[tool].setToolTip(
                "%s · %s%s" % (SHORTCUT_LABELS[action], shortcuts[action], suffix))
        self.undo_button.setToolTip("실행취소 · %s" % shortcuts["undo"])

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
        minimum_y = screen_rect.top() + 8
        maximum_y = max(minimum_y, screen_rect.bottom() - self.height() - 8)
        y = clamp(screen_rect.center().y() - self.height() // 2, minimum_y, maximum_y)
        self.move(screen_rect.left() + 24, int(y))


class SettingsDialog(QDialog):
    def __init__(self, value, apply_callback, live_callback=None, parent=None):
        super().__init__(parent)
        self.setWindowFlags(self.windowFlags() | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setWindowTitle("Brush 환경설정")
        self.setMinimumWidth(460)
        self.apply_callback = apply_callback
        self.live_callback = live_callback
        self._committed_shortcuts = dict(value.shortcuts)
        self._applying = False
        self.shortcut_edits = {}
        self._laser_color = value.laser_color
        self._arrow_color = value.arrow_pointer_color

        root = QVBoxLayout(self)
        tabs = QTabWidget()
        root.addWidget(tabs)

        shortcut_tab = QWidget()
        shortcut_form = QFormLayout(shortcut_tab)
        for action, label in SHORTCUT_LABELS.items():
            edit = QKeySequenceEdit(QKeySequence(value.shortcuts[action]))
            if hasattr(edit, "setMaximumSequenceLength"):
                edit.setMaximumSequenceLength(1)
            edit.editingFinished.connect(self._apply)
            self.shortcut_edits[action] = edit
            shortcut_form.addRow(label, edit)
        local_note = QLabel(
            "캔버스에 포커스가 있으면 P/A/R/T/E/C, Esc, Ctrl+Z 별칭도 계속 사용할 수 있습니다.")
        local_note.setWordWrap(True)
        shortcut_form.addRow(local_note)
        tabs.addTab(shortcut_tab, "전역 단축키")

        pointer_tab = QWidget()
        pointer_form = QFormLayout(pointer_tab)
        self.laser_size = QSpinBox()
        self.laser_size.setRange(4, 64)
        self.laser_size.setSuffix(" px")
        self.laser_size.setValue(value.laser_size)
        self.laser_color = self._color_button(self._laser_color, "laser")
        self.arrow_size = QSpinBox()
        self.arrow_size.setRange(20, 160)
        self.arrow_size.setSuffix(" px")
        self.arrow_size.setValue(value.arrow_pointer_size)
        self.arrow_color = self._color_button(self._arrow_color, "arrow")
        pointer_form.addRow("레이저 점 크기", self.laser_size)
        pointer_form.addRow("레이저 색상", self.laser_color)
        pointer_form.addRow("화살표 크기", self.arrow_size)
        pointer_form.addRow("화살표 색상", self.arrow_color)
        hint = QLabel("색상과 크기는 적용 즉시 현재 포인터에 반영됩니다.")
        hint.setWordWrap(True)
        pointer_form.addRow(hint)
        tabs.addTab(pointer_tab, "포인터")

        magnifier_tab = QWidget()
        magnifier_form = QFormLayout(magnifier_tab)
        self.zoom = QDoubleSpinBox()
        self.zoom.setRange(1.25, 8.0)
        self.zoom.setSingleStep(0.25)
        self.zoom.setDecimals(2)
        self.zoom.setSuffix("×")
        self.zoom.setValue(value.magnification)
        magnifier_form.addRow("기본 확대 배율", self.zoom)
        magnifier_form.addRow(QLabel("확대 모드에서 휠로 바꾼 마지막 배율이 자동 저장됩니다."))
        tabs.addTab(magnifier_tab, "확대")

        controls = QHBoxLayout()
        defaults = QPushButton("기본값 복원")
        defaults.clicked.connect(self._restore_defaults)
        controls.addWidget(defaults)
        controls.addStretch()
        buttons = QDialogButtonBox(QDialogButtonBox.Close)
        buttons.rejected.connect(self.reject)
        controls.addWidget(buttons)
        root.addLayout(controls)

        self.laser_size.valueChanged.connect(self._live_visual)
        self.arrow_size.valueChanged.connect(self._live_visual)
        self.zoom.valueChanged.connect(self._live_visual)

    def _color_button(self, color, which):
        button = QPushButton(color.upper())
        button.clicked.connect(lambda: self._choose_color(which, button))
        self._style_color(button, color)
        return button

    @staticmethod
    def _style_color(button, color):
        c = QColor(color)
        lightness = c.lightness()
        foreground = "#ffffff" if lightness < 135 else "#151515"
        button.setStyleSheet("background: %s; color: %s; padding: 6px;" % (c.name(), foreground))
        button.setText(c.name().upper())

    def _choose_color(self, which, button):
        current = self._laser_color if which == "laser" else self._arrow_color
        color = QColorDialog.getColor(QColor(current), self, "포인터 색상")
        if not color.isValid():
            return
        if which == "laser":
            self._laser_color = color.name()
        else:
            self._arrow_color = color.name()
        self._style_color(button, color.name())
        self._live_visual()

    def _restore_defaults(self):
        defaults = Preferences()
        for action, shortcut in defaults.shortcuts.items():
            self.shortcut_edits[action].setKeySequence(QKeySequence(shortcut))
        self.laser_size.setValue(defaults.laser_size)
        self._laser_color = defaults.laser_color
        self._style_color(self.laser_color, self._laser_color)
        self.arrow_size.setValue(defaults.arrow_pointer_size)
        self._arrow_color = defaults.arrow_pointer_color
        self._style_color(self.arrow_color, self._arrow_color)
        self.zoom.setValue(defaults.magnification)
        self._apply()

    def _value(self):
        return Preferences(
            shortcuts={
                action: edit.keySequence().toString(QKeySequence.PortableText)
                for action, edit in self.shortcut_edits.items()
            },
            laser_size=self.laser_size.value(),
            laser_color=self._laser_color,
            arrow_pointer_size=self.arrow_size.value(),
            arrow_pointer_color=self._arrow_color,
            magnification=self.zoom.value(),
        )

    def _try_apply(self, notify=True):
        """현재 편집 내용을 적용하고 (성공 여부, 실패 사유)를 돌려준다."""
        if self._applying:
            return False, None
        self._applying = True
        try:
            value = self._value()
            ok, error = self.apply_callback(value)
        finally:
            self._applying = False
        if ok:
            self._committed_shortcuts = dict(value.shortcuts)
        elif notify:
            QMessageBox.warning(self, "단축키를 적용할 수 없음", error)
        return ok, error

    def _apply(self):
        return self._try_apply()[0]

    def _revert_shortcut_edits(self):
        """적용되지 않은 단축키 편집을 마지막으로 성공한 값으로 되돌린다."""
        for action, edit in self.shortcut_edits.items():
            edit.setKeySequence(QKeySequence(self._committed_shortcuts[action]))

    def _live_visual(self, _=None):
        if self.live_callback is None or self._applying:
            return
        self.live_callback(Preferences(
            shortcuts=dict(self._committed_shortcuts),
            laser_size=self.laser_size.value(),
            laser_color=self._laser_color,
            arrow_pointer_size=self.arrow_size.value(),
            arrow_pointer_color=self._arrow_color,
            magnification=self.zoom.value(),
        ))

    def reject(self):
        # 모든 변경은 즉시 적용되므로 닫을 때도 마지막 편집 내용을 검증한다. 다만 적용에
        # 실패했다고 창을 붙잡아 두면 빠져나갈 길이 없으므로, 적용되지 않은 편집만 버리고
        # 마지막으로 정상 적용된 단축키로 되돌린 뒤 닫는다. 실패 사유는 편집을 마칠 때
        # 이미 경고로 알렸으므로 닫는 길목에서 다시 막지 않는다.
        ok, _ = self._try_apply(notify=False)
        if not ok:
            self._revert_shortcut_edits()
            self._try_apply(notify=False)
        super().reject()


# MARK: - 전역 단축키 — Windows RegisterHotKey를 한 곳에서 등록/해제한다

MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN = 0x0001, 0x0002, 0x0004, 0x0008
MOD_NOREPEAT, WM_HOTKEY = 0x4000, 0x0312

SPECIAL_VIRTUAL_KEYS = {
    "Esc": 0x1B, "Escape": 0x1B, "Tab": 0x09, "Backspace": 0x08,
    "Return": 0x0D, "Enter": 0x0D, "Space": 0x20, "Insert": 0x2D,
    "Delete": 0x2E, "Home": 0x24, "End": 0x23, "Left": 0x25,
    "Up": 0x26, "Right": 0x27, "Down": 0x28, "PgUp": 0x21,
    "PageUp": 0x21, "PgDown": 0x22, "PageDown": 0x22,
}


def shortcut_to_native(shortcut):
    """PortableText 단축키를 RegisterHotKey modifier/VK 쌍으로 변환한다."""
    text = canonical_shortcut(shortcut)
    if text is None:
        return None
    parts = text.split("+")
    if not parts:
        return None
    key_name = parts[-1]
    modifiers = MOD_NOREPEAT
    for modifier in parts[:-1]:
        if modifier == "Alt":
            modifiers |= MOD_ALT
        elif modifier == "Ctrl":
            modifiers |= MOD_CONTROL
        elif modifier == "Shift":
            modifiers |= MOD_SHIFT
        elif modifier in ("Meta", "Win"):
            modifiers |= MOD_WIN
        else:
            return None

    upper = key_name.upper()
    if len(upper) == 1 and ("A" <= upper <= "Z" or "0" <= upper <= "9"):
        key = ord(upper)
    elif upper.startswith("F") and upper[1:].isdigit() and 1 <= int(upper[1:]) <= 24:
        key = 0x70 + int(upper[1:]) - 1
    else:
        key = SPECIAL_VIRTUAL_KEYS.get(key_name)
    return (modifiers, key) if key is not None else None


class WindowsHotKeyManager(QAbstractNativeEventFilter):
    """여러 전역 단축키를 원자적으로 교체하고 실패하면 직전 구성을 복원한다."""

    first_id = 0xB100

    def __init__(self, callback, register_fn=None, unregister_fn=None, platform=None):
        super().__init__()
        self.callback = callback
        self.platform = sys.platform if platform is None else platform
        self._register_fn = register_fn
        self._unregister_fn = unregister_fn
        self._active_by_id = {}
        self.active_actions = set()
        self.shortcuts = dict(DEFAULT_SHORTCUTS)
        if self.platform == "win32" and self._register_fn is None:
            import ctypes
            self._register_fn = ctypes.windll.user32.RegisterHotKey
            self._unregister_fn = ctypes.windll.user32.UnregisterHotKey

    @property
    def enabled(self):
        return self._register_fn is not None and self._unregister_fn is not None

    def _id_for(self, action):
        return self.first_id + list(DEFAULT_SHORTCUTS).index(action)

    def _unregister_all(self):
        if self.enabled:
            for hotkey_id in list(self._active_by_id):
                self._unregister_fn(None, hotkey_id)
        self._active_by_id = {}
        self.active_actions = set()

    def _register_actions(self, shortcuts, actions):
        for action in DEFAULT_SHORTCUTS:
            if action not in actions:
                continue
            native = shortcut_to_native(shortcuts[action])
            if native is None:
                return False, action
            hotkey_id = self._id_for(action)
            modifiers, key = native
            if not self._register_fn(None, hotkey_id, modifiers, key):
                return False, action
            self._active_by_id[hotkey_id] = action
        self.active_actions = set(actions)
        return True, None

    def configure(self, shortcuts, active_actions, probe_all=False):
        normalized, error = validate_shortcuts(shortcuts)
        if error:
            return False, error
        for action, shortcut in normalized.items():
            if shortcut_to_native(shortcut) is None:
                return False, "%s 단축키는 Windows에서 지원되지 않습니다." % SHORTCUT_LABELS[action]
        if not self.enabled:
            self.shortcuts = normalized
            self.active_actions = set(active_actions)
            return True, None

        previous_shortcuts = dict(self.shortcuts)
        previous_actions = set(self.active_actions)
        self._unregister_all()
        probe_actions = set(DEFAULT_SHORTCUTS) if probe_all else set(active_actions)
        ok, failed_action = self._register_actions(normalized, probe_actions)
        if ok and probe_actions != set(active_actions):
            self._unregister_all()
            ok, failed_action = self._register_actions(normalized, set(active_actions))
        if not ok:
            self._unregister_all()
            self._register_actions(previous_shortcuts, previous_actions)
            self.shortcuts = previous_shortcuts
            return False, "%s 단축키를 다른 앱이 사용 중입니다. 기존 설정을 유지합니다." % (
                SHORTCUT_LABELS[failed_action])
        self.shortcuts = normalized
        return True, None

    def activate(self, actions):
        return self.configure(self.shortcuts, set(actions), probe_all=False)

    def nativeEventFilter(self, kind, message):
        if self.platform == "win32" and (kind == b"windows_generic_MSG" or
                                          str(kind) == "windows_generic_MSG"):
            import ctypes.wintypes
            msg = ctypes.wintypes.MSG.from_address(int(message))
            if msg.message == WM_HOTKEY:
                if self._handle_hotkey_id(int(msg.wParam)):
                    return True, 0
        return False, 0

    def _handle_hotkey_id(self, hotkey_id):
        action = self._active_by_id.get(int(hotkey_id))
        if action is None:
            return False
        self.callback(action)
        return True

    def close(self):
        self._unregister_all()


# MARK: - 앱

class BrushApp:
    def __init__(self, app):
        self.app = app
        self.store = SettingsStore()
        self.preferences = self.store.load()
        self.capture_service = ScreenCaptureService()
        self.canvas = Canvas(self.preferences, self.capture_service)
        self.toolbar = Toolbar(self.canvas)
        self.is_on = False
        self.capture_exclusion_supported = False
        self._shutting_down = False

        self.canvas.on_zoom_changed = self._zoom_changed
        self.canvas.on_local_action = self.dispatch_action
        self.toolbar.on_tool_changed = self._tool_changed
        self.toolbar.on_undo = self.canvas.undo
        self.toolbar.on_settings = self.open_settings
        self.toolbar.refresh_shortcut_tips(self.preferences.shortcuts)

        self.hotkeys = WindowsHotKeyManager(self.dispatch_action)
        if sys.platform == "win32":
            app.installNativeEventFilter(self.hotkeys)
        hotkey_ok, hotkey_error = self.hotkeys.configure(
            self.preferences.shortcuts, {"toggle"}, probe_all=False)

        self.tray = QSystemTrayIcon(self._tray_icon("✏️"))
        menu = QMenu()
        self.toggle_menu_action = self._add(menu, "", self.toggle)
        self.undo_menu_action = self._add(menu, "", self.canvas.undo)
        self.clear_menu_action = self._add(menu, "", self.cancel_to_mouse_mode)
        self._update_menu_titles()
        self._add(menu, "환경설정…", self.open_settings)
        menu.addSeparator()
        self._add(menu, "종료", app.quit)
        self.tray.setContextMenu(menu)
        self.tray.activated.connect(
            lambda r: self.toggle() if r == QSystemTrayIcon.Trigger else None)
        self.tray.show()

        if not hotkey_ok:
            self.tray.setIcon(self._tray_icon("⚠️"))
            self.tray.setToolTip(hotkey_error + " 트레이 아이콘으로 켜고 끄세요.")
        elif sys.platform == "win32":
            self.tray.setToolTip("Brush — %s" % self.preferences.shortcuts["toggle"])
        else:
            self.tray.setToolTip("Brush — 트레이 아이콘 클릭으로 켜고 끄기")

        self.capture_timer = QTimer()
        self.capture_timer.setInterval(250)
        self.capture_timer.timeout.connect(self._capture_tick)
        app.aboutToQuit.connect(self.shutdown)

    def _add(self, menu, title, slot):
        a = QAction(title, menu)
        a.triggered.connect(slot)
        menu.addAction(a)
        return a

    def _update_menu_titles(self):
        shortcuts = self.preferences.shortcuts
        self.toggle_menu_action.setText("브러시 켜기 / 끄기  (%s)" % shortcuts["toggle"])
        self.undo_menu_action.setText("실행취소  (%s)" % shortcuts["undo"])
        self.clear_menu_action.setText("전체 취소 후 마우스 모드  (%s)" % shortcuts["clear"])

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

    def _desktop_geometry(self):
        screens = QApplication.screens()
        if not screens:
            return QRect(0, 0, 1, 1)
        result = QRect(screens[0].geometry())
        for screen in screens[1:]:
            result = result.united(screen.geometry())
        return result

    def dispatch_action(self, action):
        if action == "toggle":
            self.toggle()
            return
        if not self.is_on:
            return
        if action in ACTION_TO_TOOL:
            self.toolbar.select_tool(ACTION_TO_TOOL[action])
        elif action == "undo":
            self.canvas.undo()
        elif action == "clear":
            self.cancel_to_mouse_mode()

    def cancel_to_mouse_mode(self):
        self.canvas.cancel_all()
        self.toolbar.select_tool(Tool.CLICK)

    def toggle(self):
        self.turn_off() if self.is_on else self.turn_on()

    def turn_on(self):
        toolbar_rect = self._screen_under_mouse().availableGeometry()
        self.canvas.setGeometry(self._desktop_geometry())
        self.canvas.show()
        self.canvas.raise_()
        self.toolbar.reposition(toolbar_rect)
        self.toolbar.show()
        self.toolbar.raise_()
        self.is_on = True
        self.canvas.set_tool(self.canvas.tool)
        if self.canvas.tool != Tool.CLICK:
            self.canvas.activateWindow()
            self.canvas.setFocus()
        self.capture_exclusion_supported = self._exclude_brush_windows_from_capture()
        if self.canvas.tool in MAGNIFIER_TOOLS:
            self._prepare_magnifier_capture()
        ok, error = self.hotkeys.activate({"toggle"} | SESSION_ACTIONS)
        if not ok:
            self.tray.setToolTip(error)
        self.tray.setIcon(self._tray_icon("🖍️"))

    def turn_off(self):
        if not self.is_on:
            return
        self.capture_timer.stop()
        self.canvas.restore_cursor()
        self.canvas.cancel_all()
        self.canvas.hide()
        self.toolbar.hide()
        self.is_on = False
        self.hotkeys.activate({"toggle"})
        self.tray.setIcon(self._tray_icon("✏️"))

    def _tool_changed(self, tool):
        if tool in MAGNIFIER_TOOLS:
            self._prepare_magnifier_capture()
        else:
            self.capture_timer.stop()

    def _exclude_brush_windows_from_capture(self):
        if sys.platform != "win32":
            return False
        try:
            if sys.getwindowsversion().build < 19041:
                return False
        except (AttributeError, OSError):
            return False
        import ctypes
        import ctypes.wintypes
        user32 = ctypes.windll.user32
        user32.SetWindowDisplayAffinity.argtypes = [ctypes.wintypes.HWND, ctypes.wintypes.DWORD]
        user32.SetWindowDisplayAffinity.restype = ctypes.wintypes.BOOL
        excluded = True
        for widget in (self.canvas, self.toolbar):
            hwnd = int(widget.winId())
            # Windows 10 2004+에서는 0x11이 창을 캡처 결과에서 완전히 제외한다.
            ok = bool(user32.SetWindowDisplayAffinity(hwnd, 0x11))
            if not ok:
                # WDA_MONITOR(0x01)는 전체 화면 캔버스를 검게 만들므로 사용하지 않는다.
                user32.SetWindowDisplayAffinity(hwnd, 0x00)
            excluded = excluded and ok
        return excluded

    def _prepare_magnifier_capture(self):
        if not self.is_on:
            return
        if self.capture_exclusion_supported:
            if self.capture_service.refresh():
                self.capture_timer.start()
            else:
                self.canvas.reset_magnifier_interaction(follow=True)
            self.canvas.update()
            return

        # 제외 API를 쓸 수 없는 환경에서는 한 번 숨기고 정적인 배경을 잡아 재귀 캡처를 피한다.
        tool = self.canvas.tool
        self.canvas.hide()
        self.toolbar.hide()
        self.app.processEvents()
        captured = self.capture_service.refresh()
        self.canvas.show()
        self.canvas.raise_()
        self.canvas.set_tool(tool)
        if not captured:
            self.canvas.reset_magnifier_interaction(follow=True)
        self.toolbar.show()
        self.toolbar.raise_()

    def _capture_tick(self):
        if self.is_on and self.canvas.tool in MAGNIFIER_TOOLS and self.capture_exclusion_supported:
            if self.capture_service.refresh():
                self.canvas.update()
            else:
                self.canvas.reset_magnifier_interaction(follow=True)

    def _zoom_changed(self, zoom):
        self.preferences.magnification = clamp_zoom(zoom)
        self.store.save_zoom(self.preferences.magnification)

    def apply_preferences(self, value):
        shortcuts, error = validate_shortcuts(value.shortcuts)
        if error:
            return False, error
        active = {"toggle"} | SESSION_ACTIONS if self.is_on else {"toggle"}
        ok, error = self.hotkeys.configure(shortcuts, active, probe_all=True)
        if not ok:
            return False, error
        value.shortcuts = shortcuts
        self.preferences = value.sanitized()
        self.store.save(self.preferences)
        self.canvas.set_preferences(self.preferences)
        self.toolbar.refresh_shortcut_tips(self.preferences.shortcuts)
        self._update_menu_titles()
        self.tray.setToolTip("Brush — %s" % self.preferences.shortcuts["toggle"])
        return True, None

    def apply_visual_preferences(self, value):
        value.shortcuts = dict(self.preferences.shortcuts)
        self.preferences = value.sanitized()
        self.store.save(self.preferences)
        self.canvas.set_preferences(self.preferences)

    def open_settings(self):
        self.capture_timer.stop()
        dialog = SettingsDialog(
            self.preferences, self.apply_preferences, self.apply_visual_preferences)
        dialog.exec()
        if self.is_on and self.canvas.tool in MAGNIFIER_TOOLS:
            self._prepare_magnifier_capture()

    def shutdown(self):
        if self._shutting_down:
            return
        self._shutting_down = True
        self.capture_timer.stop()
        self.canvas.reset_magnifier_interaction(follow=False)
        self.canvas.restore_cursor()
        self.hotkeys.close()


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

    v.reset_history()
    before_undo = len(v.shapes)
    v.begin(QPointF(10, 190)); v.extend(QPointF(190, 10)); v.end()
    check(len(v.shapes) == before_undo + 1, "새 도형이 실행취소 이력과 함께 추가됨")
    v.undo()
    check(len(v.shapes) == before_undo, "실행취소가 마지막 도형만 복원")
    v.redo()
    check(len(v.shapes) == before_undo + 1, "다시 실행이 마지막 도형을 복원")

    v.cancel_all()
    check(not v.shapes and not v.undo_stack and not v.redo_stack,
          "ESC 전체 취소가 그림과 실행취소 이력을 함께 비움")

    v.set_tool(Tool.LASER)
    persistent_count = len(v.shapes)
    v.transient_position = QPointF(80, 80)
    v.grab()
    check(len(v.shapes) == persistent_count and not v.current,
          "레이저 포인터가 도형/실행취소 목록에 들어가지 않음")
    check(v.cursor().shape() == Qt.BlankCursor, "레이저 포인터가 시스템 커서를 임시로 숨김")
    v.set_tool(Tool.ARROW_POINTER)
    v.transient_position = QPointF(50, 50)
    v.grab()
    check(len(v.shapes) == persistent_count, "화살표 포인터가 영구 도형을 만들지 않음")
    v.restore_cursor()
    check(v.cursor().shape() == Qt.ArrowCursor, "포인터 종료 시 시스템 커서 복원")

    check(adjusted_zoom(2.0, 120) == 2.25 and adjusted_zoom(2.0, -120) == 1.75,
          "확대 휠이 한 단계마다 0.25배 변경")
    check(adjusted_zoom(2.0, 60) == 2.0, "고해상도 휠의 부분 델타를 즉시 한 단계로 오인하지 않음")
    check(adjusted_zoom(8.0, 120) == 8.0 and adjusted_zoom(1.25, -120) == 1.25,
          "확대 배율이 1.25~8배로 제한됨")
    check(clamp_zoom(float("nan")) == 2.0 and clamp_zoom(float("inf")) == 2.0,
          "손상된 확대 배율 설정을 안전한 기본값으로 복구")

    class WheelEventStub:
        def __init__(self, delta):
            self.delta = delta

        def angleDelta(self):
            return QPoint(0, self.delta)

        def accept(self):
            pass

    v.set_tool(Tool.MAGNIFIER_CIRCLE)
    v.preferences.magnification = 2.0
    v.wheelEvent(WheelEventStub(60))
    check(v.preferences.magnification == 2.0, "부분 휠 델타 첫 입력을 누적")
    v.wheelEvent(WheelEventStub(60))
    check(v.preferences.magnification == 2.25, "누적 휠 델타가 한 노치가 되면 배율 변경")
    edge_rect = clamped_centered_rect(QPointF(2, 2), QRectF(0, 0, 100, 80).size(),
                                      QRectF(0, 0, 300, 200))
    check(edge_rect.left() == 0 and edge_rect.top() == 0,
          "확대 렌즈가 디스플레이 왼쪽/위 경계를 벗어나지 않음")

    selection_bounds = QRectF(0, 0, 400, 300)
    circle_selection = magnifier_selection_rect(
        Tool.MAGNIFIER_CIRCLE, QPointF(370, 270), QPointF(520, 410), selection_bounds)
    check(abs(circle_selection.width() - circle_selection.height()) < 0.001 and
          selection_bounds.contains(circle_selection),
          "원형 선택이 정사각형을 유지하며 화면 경계 안으로 보정됨")
    small_circle = magnifier_selection_rect(
        Tool.MAGNIFIER_CIRCLE, QPointF(50, 50), QPointF(53, 54), selection_bounds)
    check(small_circle.width() >= CIRCLE_LENS_MIN,
          "원형 고정 렌즈에 유용한 최소 크기를 적용")
    rectangle_selection = magnifier_selection_rect(
        Tool.MAGNIFIER_RECT, QPointF(20, 20), QPointF(220, 120), selection_bounds)
    check(abs(rectangle_selection.width() / rectangle_selection.height() - 2.0) < 0.001,
          "사각형 선택이 사용자가 드래그한 종횡비를 유지")
    huge_rectangle = magnifier_selection_rect(
        Tool.MAGNIFIER_RECT, QPointF(-500, -250), QPointF(900, 450), selection_bounds)
    check(selection_bounds.contains(huge_rectangle) and
          huge_rectangle.width() <= selection_bounds.width() and
          huge_rectangle.height() <= selection_bounds.height(),
          "사각형 고정 렌즈의 최대 크기와 화면 경계를 제한")
    vertical_rectangle = magnifier_selection_rect(
        Tool.MAGNIFIER_RECT, QPointF(200, -500), QPointF(201, 900), selection_bounds)
    horizontal_rectangle = magnifier_selection_rect(
        Tool.MAGNIFIER_RECT, QPointF(-500, 150), QPointF(900, 151), selection_bounds)
    check(vertical_rectangle.width() >= RECT_LENS_MIN.width() and
          vertical_rectangle.height() >= RECT_LENS_MIN.height() and
          selection_bounds.contains(vertical_rectangle),
          "극단적으로 세로로 긴 선택도 최소 폭/높이와 화면 경계를 보장")
    check(horizontal_rectangle.width() >= RECT_LENS_MIN.width() and
          horizontal_rectangle.height() >= RECT_LENS_MIN.height() and
          selection_bounds.contains(horizontal_rectangle),
          "극단적으로 가로로 긴 선택도 최소 폭/높이와 화면 경계를 보장")
    mixed_dpi_source = magnifier_source_rect(
        QPointF(200, 150), QSizeF(200, 100), 2.0,
        QRectF(0, 0, 400, 300), QSizeF(800, 600))
    check(abs(mixed_dpi_source.width() - 200) < 0.001 and
          abs(mixed_dpi_source.height() - 100) < 0.001,
          "고정 렌즈 크기와 배율을 혼합 DPI 캡처 픽셀 좌표로 변환")

    history_before_magnifier = (len(v.shapes), len(v.undo_stack), len(v.redo_stack))
    v.set_tool(Tool.MAGNIFIER_CIRCLE)
    v.move_magnifier_pointer(QPointF(80, 80))
    check(v.transient_position == QPointF(80, 80) and v.magnifier_locked_rect is None,
          "드래그하지 않은 확대 렌즈가 포인터를 따라감")
    v.begin_magnifier_drag(QPointF(80, 80), selection_bounds)
    v.end_magnifier_drag(QPointF(84, 84))
    check(v.magnifier_locked_rect is None and v.transient_position == QPointF(84, 84),
          "임계값보다 짧은 클릭이 따라가기 모드로 복귀")
    v.begin_magnifier_drag(QPointF(60, 60), selection_bounds)
    v.move_magnifier_pointer(QPointF(260, 160))
    preview_rect = v.magnifier_preview_rect()
    check(preview_rect is not None and v.magnifier_dragging,
          "드래그 중 원형/사각형 렌즈 선택을 미리보기")

    class MagnifierPreviewSpy(Canvas):
        def __init__(self):
            super().__init__()
            self.preview_calls = []

        def _draw_magnifier(self, _, p, locked_target=None):
            self.preview_calls.append(("content", QPointF(p), QRectF(locked_target)))

        def _draw_magnifier_selection(self, _, target):
            self.preview_calls.append(("border", QRectF(target)))

    preview_spy = MagnifierPreviewSpy()
    preview_spy.resize(400, 300)
    preview_spy.set_tool(Tool.MAGNIFIER_RECT)
    preview_spy.begin_magnifier_drag(QPointF(40, 40), selection_bounds)
    preview_spy.move_magnifier_pointer(QPointF(240, 140))
    preview_spy.grab()
    check([call[0] for call in preview_spy.preview_calls] == ["content", "border"],
          "드래그 미리보기가 실제 확대 내용과 점선 선택 테두리를 함께 그림")
    preview_spy.close()

    v.end_magnifier_drag(QPointF(260, 160))
    locked_rect = QRectF(v.magnifier_locked_rect)
    check(locked_rect == preview_rect, "마우스를 놓으면 미리보기와 같은 위치/크기로 렌즈 고정")
    v.move_magnifier_pointer(QPointF(350, 250))
    check(v.magnifier_locked_rect == locked_rect,
          "고정 렌즈는 일반 포인터 이동으로 위치가 바뀌지 않음")
    zoom_before_lock_wheel = v.preferences.magnification
    v.wheelEvent(WheelEventStub(120))
    check(v.preferences.magnification == clamp_zoom(zoom_before_lock_wheel + 0.25) and
          v.magnifier_locked_rect == locked_rect,
          "고정 렌즈에서도 휠 배율을 변경하고 위치/크기는 유지")
    check((len(v.shapes), len(v.undo_stack), len(v.redo_stack)) == history_before_magnifier,
          "확대 선택/고정 상태가 도형 및 실행취소 이력과 완전히 분리됨")
    v.begin_magnifier_drag(QPointF(300, 200), selection_bounds)
    v.end_magnifier_drag(QPointF(302, 202))
    check(v.magnifier_locked_rect is None,
          "고정 후 짧은 클릭으로 잠금을 해제")
    v.begin_magnifier_drag(QPointF(40, 40), selection_bounds)
    v.end_magnifier_drag(QPointF(240, 140))
    v.set_tool(Tool.MAGNIFIER_RECT)
    check(v.magnifier_locked_rect is None and v.magnifier_drag_origin is None,
          "확대 도구 변경 시 고정/드래그 상태를 정리")

    class EscapeEventStub:
        def key(self):
            return Qt.Key_Escape

        def modifiers(self):
            return Qt.NoModifier

    v.begin_magnifier_drag(QPointF(40, 40), selection_bounds)
    v.end_magnifier_drag(QPointF(240, 140))
    v.keyPressEvent(EscapeEventStub())
    check(v.magnifier_locked_rect is None and v.magnifier_drag_origin is None,
          "ESC 전체 취소 시 고정 확대 상태를 정리")

    normalized, shortcut_error = validate_shortcuts(DEFAULT_SHORTCUTS)
    expected_tool_shortcuts = {
        "click": "Alt+1", "pen": "Alt+2", "arrow": "Alt+3",
        "rect": "Alt+4", "text": "Alt+5", "eraser": "Alt+6",
        "laser": "Alt+7", "arrow_pointer": "Alt+8",
        "magnifier_circle": "Alt+9", "magnifier_rect": "Alt+0",
    }
    check(shortcut_error is None and
          all(normalized[action] == shortcut
              for action, shortcut in expected_tool_shortcuts.items()),
          "클릭 Alt+1부터 확대 Alt+0까지 제품 기본 단축키 순서가 유효함")
    duplicates = dict(DEFAULT_SHORTCUTS)
    duplicates["laser"] = duplicates["toggle"]
    check(validate_shortcuts(duplicates)[1] is not None, "중복 단축키를 거부")
    check(shortcut_to_native("Ctrl+Alt+Z") == (MOD_NOREPEAT | MOD_CONTROL | MOD_ALT, ord("Z")),
          "Windows 단축키를 modifier/VK로 변환")

    registered = {}
    blocked = [None]

    def register_mock(_, hotkey_id, modifiers, key):
        if blocked[0] == (modifiers, key) or (modifiers, key) in registered.values():
            return 0
        registered[hotkey_id] = (modifiers, key)
        return 1

    def unregister_mock(_, hotkey_id):
        registered.pop(hotkey_id, None)
        return 1

    manager = WindowsHotKeyManager(lambda _: None, register_mock, unregister_mock, platform="win32")
    ok, _ = manager.configure(DEFAULT_SHORTCUTS, {"toggle"})
    check(ok and set(manager._active_by_id.values()) == {"toggle"},
          "꺼진 상태에는 토글 전역 단축키만 등록")
    dispatched = []
    manager.callback = dispatched.append
    check(not manager._handle_hotkey_id(123) and not dispatched,
          "알 수 없는 WM_HOTKEY ID를 무시함")
    check(manager._handle_hotkey_id(manager._id_for("toggle")) and dispatched == ["toggle"],
          "WM_HOTKEY ID에 대응하는 동작만 실행")
    candidate = dict(DEFAULT_SHORTCUTS)
    candidate["laser"] = "Ctrl+F12"
    blocked[0] = shortcut_to_native(candidate["laser"])
    ok, _ = manager.configure(candidate, {"toggle"}, probe_all=True)
    default_normalized, _ = validate_shortcuts(DEFAULT_SHORTCUTS)
    check(not ok and manager.shortcuts == default_normalized and
          set(manager._active_by_id.values()) == {"toggle"},
          "후보 등록 실패 시 직전 단축키를 원자적으로 복원")
    manager.close()
    check(not registered, "종료 시 등록한 전역 단축키를 모두 해제")

    with tempfile.TemporaryDirectory() as temp_dir:
        settings_path = os.path.join(temp_dir, "brush-test.ini")
        qsettings = QSettings(settings_path, QSettings.IniFormat)
        store = SettingsStore(qsettings)
        saved = Preferences(dict(DEFAULT_SHORTCUTS), 31, "#123456", 88, "#abcdef", 3.75)
        store.save(saved)
        loaded = SettingsStore(QSettings(settings_path, QSettings.IniFormat)).load()
        check(loaded == saved.sanitized(), "포인터 설정과 마지막 확대 배율이 재시작 후 복원")
        store.save_zoom(99)
        loaded = SettingsStore(QSettings(settings_path, QSettings.IniFormat)).load()
        check(loaded.magnification == 8.0, "저장되는 확대 배율도 허용 범위로 제한")
        legacy_shortcuts = dict(DEFAULT_SHORTCUTS)
        legacy_shortcuts.update({
            "pen": "Alt+1", "arrow": "Alt+2", "rect": "Alt+3",
            "text": "Alt+4", "eraser": "Alt+5", "click": "Alt+6",
        })
        for action, shortcut in legacy_shortcuts.items():
            qsettings.setValue("shortcuts/" + action, shortcut)
        qsettings.sync()
        loaded = SettingsStore(QSettings(settings_path, QSettings.IniFormat)).load()
        legacy_normalized, _ = validate_shortcuts(legacy_shortcuts)
        check(loaded.shortcuts == legacy_normalized,
              "기존 사용자가 저장한 구 단축키 값은 제품 기본값 변경과 무관하게 보존")

    erase_canvas = Canvas()
    erase_canvas.resize(200, 200)
    erase_canvas.begin(QPointF(10, 10)); erase_canvas.extend(QPointF(190, 190)); erase_canvas.end()
    erase_canvas.begin(QPointF(10, 190)); erase_canvas.extend(QPointF(190, 10)); erase_canvas.end()
    erase_canvas.reset_history()
    erase_canvas.set_tool(Tool.ERASER)
    erase_canvas.begin_erase_stroke()
    erase_canvas.erase(QPointF(50, 50))
    erase_canvas.erase(QPointF(50, 150))
    erase_canvas.end_erase_stroke()
    check(not erase_canvas.shapes, "한 번의 지우개 드래그로 닿은 여러 도형을 제거")
    erase_canvas.undo()
    check(len(erase_canvas.shapes) == 2, "지우개 한 스트로크를 한 번에 실행취소")

    toolbar_smoke = Toolbar(erase_canvas)
    toolbar_smoke.adjustSize()
    expected_toolbar_tools = [
        Tool.CLICK, Tool.PEN, Tool.ARROW, Tool.RECT, Tool.TEXT, Tool.ERASER,
        Tool.LASER, Tool.ARROW_POINTER, Tool.MAGNIFIER_CIRCLE, Tool.MAGNIFIER_RECT,
    ]
    actual_toolbar_buttons = [
        toolbar_smoke.tool_column.itemAt(index).widget()
        for index in range(toolbar_smoke.tool_column.count())
    ]
    expected_toolbar_buttons = [toolbar_smoke.tool_buttons[tool] for tool in expected_toolbar_tools]
    check(actual_toolbar_buttons == expected_toolbar_buttons and
          [tool for tool, _, _ in TOOL_BUTTONS] == expected_toolbar_tools,
          "클릭 도구부터 사각 확대까지 10개 도구가 단일 세로 1열로 배치됨")
    check(toolbar_smoke.height() <= 600,
          "보조 버튼을 포함한 전체 세로 툴바가 600px급 화면 높이에 들어감")
    toolbar_smoke.refresh_shortcut_tips(DEFAULT_SHORTCUTS)
    check("Alt+1" in toolbar_smoke.tool_buttons[Tool.CLICK].toolTip() and
          "Alt+2" in toolbar_smoke.tool_buttons[Tool.PEN].toolTip(),
          "툴팁에 새 클릭/펜 기본 단축키가 표시됨")
    toolbar_smoke.reposition(QRect(0, 0, 800, 600))
    check(toolbar_smoke.y() >= 8 and
          toolbar_smoke.y() + toolbar_smoke.height() <= 592,
          "600px 화면에서도 툴바 위치 보정 범위가 뒤집히지 않음")
    usable_area = QRect(0, 40, 800, 570)
    toolbar_smoke.reposition(usable_area)
    check(toolbar_smoke.y() >= usable_area.top() + 8 and
          toolbar_smoke.y() + toolbar_smoke.height() <= usable_area.bottom() - 8,
          "큰 작업표시줄이 있는 작은 화면에서도 툴바가 사용 가능 영역 안에 머묾")
    toolbar_smoke.close()
    live_values = []
    settings_smoke = SettingsDialog(
        Preferences(), lambda _: (True, None), live_values.append)
    check(settings_smoke._value().sanitized() == Preferences().sanitized(),
          "환경설정 창이 모든 기본값으로 정상 구성됨")
    check(list(settings_smoke.shortcut_edits)[1:7] ==
          ["click", "pen", "arrow", "rect", "text", "eraser"],
          "환경설정 단축키 목록이 클릭 Alt+1부터 그리기 Alt+6 순서로 표시됨")
    settings_smoke.laser_size.setValue(22)
    check(live_values and live_values[-1].laser_size == 22,
          "포인터/확대 설정 변경이 적용 버튼 없이 즉시 반영됨")
    check(settings_smoke.windowFlags() & Qt.WindowStaysOnTopHint,
          "전체 화면 오버레이 위에 환경설정 창이 표시됨")
    settings_smoke.close()

    # 적용할 수 없는 단축키가 남아 있어도 환경설정 창에 갇히면 안 된다.
    def strict_apply(value):
        _, error = validate_shortcuts(value.shortcuts)
        return error is None, error

    stuck = SettingsDialog(Preferences(), strict_apply)
    stuck.show()
    stuck.shortcut_edits["pen"].setKeySequence(QKeySequence(DEFAULT_SHORTCUTS["click"]))
    applied, reason = stuck._try_apply(notify=False)
    check(not applied and reason, "중복 단축키는 적용을 거부하고 사유를 돌려줌")
    stuck.reject()
    check(not stuck.isVisible(),
          "적용할 수 없는 단축키가 남아 있어도 환경설정 창을 닫을 수 있음")
    check(stuck._value().shortcuts["pen"] == DEFAULT_SHORTCUTS["pen"],
          "닫을 때 적용되지 않은 단축키 편집은 마지막 정상 값으로 되돌아감")
    stuck.close()

    # OS가 단축키 등록을 거부하는 경우(다른 앱이 선점)에도 같은 탈출구가 있어야 한다.
    refused = SettingsDialog(Preferences(), lambda _: (False, "다른 앱이 사용 중입니다."))
    refused.show()
    refused.shortcut_edits["laser"].setKeySequence(QKeySequence("Ctrl+Alt+L"))
    refused.reject()
    check(not refused.isVisible() and
          refused._value().shortcuts["laser"] == DEFAULT_SHORTCUTS["laser"],
          "등록이 거부된 단축키도 직전 값으로 되돌리고 창을 닫음")
    refused.close()

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
