# Brush — 화면 위 필기 오버레이

강의 중 화면에 바로 선을 그어 시선을 잡아두는 도구.

- **macOS** — `Brush.swift` 네이티브 앱. macOS 13 이상, 애플 실리콘 / 인텔 모두 지원. 권한 설정 불필요.
- **Windows** — `brush.py` (Python + Qt). 펜 · 화살표 · 사각형 · 텍스트 · 지우개와 색상 ·
  굵기가 같습니다. 실행취소 · 클릭 도구 · 글자 단축키는 아직 macOS 판에만 있습니다.
  Linux · macOS 에서도 그대로 돕니다.

## 설치 (macOS)

### 방법 1 — 내려받기

[릴리스](https://github.com/AX-Surfers/brush/releases/latest)에서 `Brush.zip` 을 받아
압축을 풀고 `Brush.app` 을 `/응용 프로그램` 으로 옮깁니다.

인터넷에서 받은 앱이라 **첫 실행 때 한 번** macOS가 막습니다. Apple에 등록비를 내고
서명한 앱이 아니라서 그렇습니다 (열어보면 소스가 전부 이 저장소에 있습니다):

1. `Brush.app` 을 더블클릭 → 경고가 뜨면 닫기
2. 시스템 설정 → 개인정보 보호 및 보안 → 아래로 스크롤 → **"확인 없이 열기"**
3. 다시 더블클릭 → **열기**

터미널이 편하면 이 한 줄로 대신할 수 있습니다.

```sh
xattr -dr com.apple.quarantine /Applications/Brush.app
```

### 방법 2 — 직접 빌드 (경고 없음)

Xcode Command Line Tools (`xcode-select --install`) 만 있으면 됩니다.

```sh
git clone https://github.com/AX-Surfers/brush.git && cd brush && ./build.sh && open Brush.app
```

메뉴바에 ✏️ 가 생기면 실행 중입니다. 로그인 시 자동 실행하려면
시스템 설정 → 일반 → 로그인 항목에 `Brush.app` 추가.

## 설치 (Windows)

[Python 3.10 이상](https://www.python.org/downloads/windows/)이 필요합니다 (설치할 때
"Add python.exe to PATH" 체크). PowerShell 에서:

```
py -m pip install PySide6
py brush.py
```

콘솔 창 없이 띄우려면 `pythonw brush.py`, 로그인 시 자동 실행하려면 그 명령을 담은
바로가기를 `Win+R` → `shell:startup` 폴더에 넣습니다.

배포용 단일 실행 파일(`dist\Brush.exe`, Python 설치 없이 실행)이 필요하면:

```
py -m pip install pyinstaller
py -m PyInstaller --noconsole --onefile --name Brush brush.py
```

작업 표시줄 알림 영역에 ✏️ 가 생기면 실행 중입니다 (아이콘 클릭으로도 켜고 끄기).

## 조작

| 키 | 동작 |
|---|---|
| `⌥Z` (Windows `Alt+Z`) | 브러시 켜기 / 끄기 (어느 앱에서든) |
| 드래그 | 선택한 도구로 그리기 |
| `⌘Z` / `⇧⌘Z` | 실행취소 / 다시 실행 |
| `P` `A` `R` `T` `E` `C` | 펜 · 화살표 · 사각형 · 텍스트 · 지우개 · 클릭 |
| `⌥1`~`⌥6` | 같은 도구 전환 (클릭 모드 등 포커스를 잃었을 때도 동작) |
| `⌥⌘Z` | 실행취소 (클릭 모드용) |
| `ESC` | 전체 지우기 (브러시는 켜진 채 유지) |

글자 단축키(`P`/`A`/...)와 `⌘Z`는 브러시 창에 포커스가 있을 때 동작합니다. 클릭 모드로
넘어가면 키보드가 밑 앱 차지가 되므로 `⌥1`~`⌥6`, `⌥⌘Z` 를 쓰면 됩니다. 이 전역 단축키들은
브러시가 켜져 있는 동안에만 등록되어 평소 다른 앱의 `⌥1` 입력을 막지 않습니다.

Windows 판은 `Alt+Z` 와 `ESC` 두 개뿐입니다. 실행취소 · 클릭 도구 · 글자 단축키는 아직
옮기지 않았고, 도구는 툴바 버튼으로 고릅니다.

브러시를 켜면 화면 왼쪽에 작은 툴바가 함께 뜹니다. 위에서부터 펜 / 화살표 / 사각형 /
텍스트 / 지우개 / 클릭 도구 버튼, 실행취소 버튼, 색상 버튼, 굵기 버튼 4개(4 · 8 · 14 · 22)
순서이며 드래그로 옮길 수 있습니다. 굵기는 원하는 버튼을 바로 누르면 되고, 선택된 것이 강조 표시됩니다.

지우개는 픽셀이 아니라 **도형 단위**로 지웁니다 — 지나간 자리에 닿는 선·도형·텍스트가
통째로 사라집니다. 지우는 범위는 굵기 버튼을 따릅니다. 전부 지우려면 `ESC`.

텍스트 도구로는 화면을 클릭한 자리에 바로 입력하고 `Enter` 로 확정합니다. 글자 크기도
굵기 버튼을 따라갑니다(기본 36pt, 최대 78pt).

실행취소는 획·도형·텍스트 하나 단위이고, `ESC` 전체 지우기도 되돌릴 수 있습니다. 지우개는
드래그 한 번이 실행취소 한 번입니다. 브러시를 끄면 그림과 함께 이력도 비워집니다.

**클릭 도구**를 고르면 그린 것은 화면에 남겨둔 채 마우스가 오버레이를 통과해 밑 앱을 그대로
쓸 수 있습니다. 다시 그리려면 `⌥1`(펜) 등으로 돌아오면 됩니다. 브러시를 완전히 끌 때는
`⌥Z`이고, 끌 때 그림은 지워집니다.
메뉴바(Windows 는 알림 영역) ✏️ 아이콘에서도 켜기/끄기·지우기·종료를 할 수 있습니다.

단축키를 바꾸려면 macOS 는 `Brush.swift` 의 `hotKeyCode` / `hotKeyModifiers` 두 줄을 고치고
`./build.sh`, Windows 는 `brush.py` 의 `MOD_ALT` / `VK_Z` 두 줄을 고칩니다.
다른 앱이 이미 그 키를 쓰고 있으면 아이콘이 ⚠️ 로 바뀌어 알려줍니다.

Windows 외의 플랫폼에서 `brush.py` 를 돌리면 전역 단축키는 잡히지 않고 트레이 아이콘으로만
켜고 끕니다 (macOS 는 네이티브 앱을 쓰면 됩니다).

## 구조

- `Brush.swift` — macOS 전부. 오버레이 창 + 캔버스 + 전역 단축키 + 셀프테스트
- `build.sh` — 두 아키텍처로 컴파일해 하나로 합치고 `Brush.app` 번들 생성 + 셀프테스트.
  `./build.sh --zip` 이면 배포용 `Brush.zip` 까지
- `brush.py` — Windows 판 전부. 같은 구조를 PySide6 로 옮긴 이식판 (도형 목록 · 지우개
  판정 · 굵기/텍스트 크기 규칙이 Swift 쪽과 동일). 실행취소 · 클릭 도구는 아직 미이식

셀프테스트는 두 판 모두 같은 항목을 검사합니다.

```sh
./Brush.app/Contents/MacOS/Brush --selftest   # macOS
py brush.py --selftest                        # Windows
```
