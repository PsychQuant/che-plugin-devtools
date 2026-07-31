---
name: cli-new-app
description: |
  建立 Swift CLI 專案骨架：Package.swift（含 ArgumentParser 依賴）、main entry point、Version.swift、.gitignore、README.md，並可選擇同時初始化 git 與建立 GitHub repo。
  Use when: 要從零寫一個命令列工具；「建新的 CLI 專案」「Swift CLI 骨架」「new CLI app」；想要一個能被 cli-deploy 直接發布的專案結構。
  防止的失敗：手刻 Package.swift 漏掉 ArgumentParser 依賴；沒建 Version.swift，導致日後 cli-deploy 找不到版本號可 bump、--version 也做不出來。
argument-hint: <project-name>
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, AskUserQuestion
---

# CLI New App — 建立 Swift CLI 專案

Scaffold 一個新的 Swift CLI 專案，包含完整的開發結構。

## 參數

- `$1` = 專案名稱（kebab-case，如 `my-tool`）

---

## Phase 0: 收集資訊

如果沒有提供專案名稱，用 AskUserQuestion 詢問：

1. **專案名稱**（kebab-case）
2. **Binary 名稱**（預設同專案名稱）
3. **描述**（一句話）
4. **GitHub repo**（預設 `PsychQuant/{project-name}`）

---

## Phase 1: 建立專案結構

```bash
mkdir -p {project-name}
cd {project-name}
```

### Step 1: Package.swift

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "{ProjectName}",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "{binary-name}", targets: ["{target-name}"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "{target-name}",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
```

### Step 2: Main entry point

`Sources/{target-name}/{ProjectName}.swift`:

```swift
import ArgumentParser

@main
struct {ProjectName}: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "{binary-name}",
        abstract: "{description}",
        subcommands: [Version.self]
    )
}
```

### Step 3: Version.swift

`Sources/{target-name}/Version.swift`:

```swift
import ArgumentParser

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print version"
    )

    static let current = "0.1.0"

    func run() {
        print("{binary-name} \(Version.current)")
    }
}
```

### Step 4: .gitignore

```
.build/
.release/
.swiftpm/
*.xcodeproj/
```

### Step 5: README.md

基本的 README，包含安裝指令和使用說明。

---

## Phase 2: 初始化 Git

```bash
git init
git add -A
git commit -m "init: {binary-name} — {description}"
```

### 建立 GitHub Repo（可選）

用 AskUserQuestion 詢問是否建立 GitHub repo：

```bash
gh repo create {owner}/{project-name} --public --source=. --push
```

---

## Phase 3: 驗證

```bash
swift build
.build/debug/{binary-name} version
```

---

## 完成報告

```
專案 {project-name} 已建立！

結構：
  {project-name}/
  ├── Package.swift
  ├── Sources/{target-name}/
  │   ├── {ProjectName}.swift
  │   └── Version.swift
  ├── .gitignore
  └── README.md

下一步：
1. 加入你的 subcommands
2. `swift build` 測試
3. （macOS 26 + 公開分發）裝簽章 pipeline：`/harness-devtools:mcp-sign-pipeline`
   - macOS 26 對 ad-hoc binary 收緊；若要對外分發給其他 macOS 26 使用者，必須走 Developer ID + hardened runtime + notarization
   - 純自用 / dev-only CLI 不需要（ad-hoc 仍能跑，只會 Gatekeeper warning）
   - 此 skill 在 mcp-tools plugin 內但對 Swift CLI 同樣適用
4. `/harness-devtools:cli-deploy` 發布
   - 若已裝 sign-pipeline，可跑 `make release-signed` 產出 signed binary
```
