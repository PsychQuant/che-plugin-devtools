---
name: mcp-new-app
description: |
  互動式建立新 MCP Server 專案骨架，支援 Swift / Python / TypeScript：收集專案資訊、建立目錄結構、設定 git 與 MCPB 打包配置。
  與鄰近 skill 的分工：建好之後用 mcp-deploy 編譯發布到 GitHub Release、用 mcp-publish 上架到官方 MCP Registry。需要 Developer ID 簽章的走 mcp-sign-pipeline。
argument-hint: [project-name]
allowed-tools: Write, Read, Bash(mkdir:*), Bash(git:*), Bash(chmod:*), Bash(swift:*), Bash(npm:*), Bash(python:*), Glob, AskUserQuestion
disable-model-invocation: true
---

# MCP New App - 建立新 MCP 專案

互動式建立完整的 MCP Server 專案結構。

**部署專案請用 `/devtools:mcp-deploy`**

## 參數

- `$1` = 專案名稱（可選，如 `che-notes-mcp`）

---

## Step 0: Bootstrap Stage Task List（強制）

**動任何事之前**先用 `TaskCreate` 建 todo list：

```
TaskCreate(name="collect_info", description="Phase 0: 確認專案名稱 + 收集資訊 + 確認位置")
TaskCreate(name="create_structure", description="Phase 1: 建立專案結構（Package.swift + Sources + Tests + mcpb）")
TaskCreate(name="setup_git_and_mcpb", description="Phase 2: Git init + .gitignore + .gitattributes + mcpb/manifest + PRIVACY + README + CHANGELOG + LICENSE")
TaskCreate(name="report", description="Phase 3: 完成報告")
```

完成每一步立即 `TaskUpdate → completed`。**靜默完成 = 違規**。

---

## Phase 0: 收集專案資訊

### Step 1: 確認專案名稱

如果沒有提供 `$1`，使用 AskUserQuestion 詢問：

**專案名稱規則**：
- 格式：`{prefix}-{name}-mcp`（如 `che-notes-mcp`）
- 小寫字母、數字、連字號
- 建議以 `mcp` 結尾

### Step 2: 收集專案資訊

使用 AskUserQuestion 詢問以下資訊：

1. **顯示名稱**（如 `Notes Manager`）
2. **簡短描述**（一句話說明功能）
3. **選擇語言**：
   - Swift（推薦，適合 macOS 原生整合）
   - Python（適合快速開發、跨平台）
   - TypeScript（適合 Node.js 生態系）

### Step 3: 確認專案位置

預設位置：`/Users/che/Library/CloudStorage/Dropbox/che_workspace/projects/mcp/{project-name}`

---

## Phase 1: 建立專案結構

根據選擇的語言，建立對應的專案結構。

### 通用目錄結構

```bash
mkdir -p {project-path}
mkdir -p {project-path}/mcpb/server
mkdir -p {project-path}/docs
```

### 語言 A: Swift 專案

#### A1: 建立目錄結構

```bash
mkdir -p {project-path}/Sources/{ProjectName}
mkdir -p {project-path}/Sources/{ProjectName}Core
mkdir -p {project-path}/Tests/{ProjectName}Tests
```

#### A2: Package.swift

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "{ProjectName}",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "{ProjectName}Core", targets: ["{ProjectName}Core"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.2")
    ],
    targets: [
        .target(
            name: "{ProjectName}Core",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            path: "Sources/{ProjectName}Core"
        ),
        .executableTarget(
            name: "{ProjectName}",
            dependencies: ["{ProjectName}Core"],
            path: "Sources/{ProjectName}"
        ),
        .testTarget(
            name: "{ProjectName}Tests",
            dependencies: ["{ProjectName}Core"],
            path: "Tests/{ProjectName}Tests"
        )
    ]
)
```

#### A3: main.swift

```swift
// Sources/{ProjectName}/main.swift
import Foundation
import {ProjectName}Core

do {
    let server = try await {ProjectName}Server()
    try await server.run()
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
```

#### A4: Server.swift

```swift
// Sources/{ProjectName}Core/Server.swift
import Foundation
import MCP

public class {ProjectName}Server {
    private let server: Server
    private let transport: StdioTransport
    private let tools: [Tool]

    public init() async throws {
        tools = Self.defineTools()

        server = Server(
            name: "{project-name}",
            version: "0.1.0",
            capabilities: .init(tools: .init())
        )

        transport = StdioTransport()
        await registerHandlers()
    }

    public func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool Definitions

    private static func defineTools() -> [Tool] {
        [
            Tool(
                name: "hello_world",
                description: "A simple hello world tool",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name to greet")
                        ])
                    ]),
                    "required": .array([])
                ])
            )
        ]
    }

    // MARK: - Handler Registration

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await self.handleToolCall(params)
        }
    }

    private func handleToolCall(_ params: CallTool.Request) async throws -> CallTool.Result {
        switch params.name {
        case "hello_world":
            let name = (params.arguments?["name"] as? String) ?? "World"
            return CallTool.Result(
                content: [.text("Hello, \(name)!")],
                isError: false
            )
        default:
            return CallTool.Result(
                content: [.text("Unknown tool: \(params.name)")],
                isError: true
            )
        }
    }
}
```

---

### 語言 B: Python 專案

#### B1: 建立目錄結構

```bash
mkdir -p {project-path}/src/{project_name}
```

#### B2: pyproject.toml

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "{project-name}"
version = "0.1.0"
description = "{description}"
requires-python = ">=3.10"
dependencies = [
    "mcp>=1.0.0",
]

[project.scripts]
{project-name} = "{project_name}:main"
```

#### B3: __init__.py

```python
# src/{project_name}/__init__.py
from .server import main

__all__ = ["main"]
```

#### B4: __main__.py

```python
# src/{project_name}/__main__.py
from .server import main

if __name__ == "__main__":
    main()
```

#### B5: server.py

```python
# src/{project_name}/server.py
import asyncio
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

app = Server("{project-name}")

@app.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="hello_world",
            description="A simple hello world tool",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name to greet"
                    }
                },
                "required": []
            }
        )
    ]

@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name == "hello_world":
        greeting_name = arguments.get("name", "World")
        return [TextContent(type="text", text="Hello, " + greeting_name + "!")]
    raise ValueError("Unknown tool: " + name)

def main():
    async def run():
        async with stdio_server() as (read_stream, write_stream):
            await app.run(read_stream, write_stream, app.create_initialization_options())
    asyncio.run(run())

if __name__ == "__main__":
    main()
```

---

### 語言 C: TypeScript 專案

#### C1: 建立目錄結構

```bash
mkdir -p {project-path}/src
```

#### C2: package.json

```json
{
  "name": "{project-name}",
  "version": "0.1.0",
  "description": "{description}",
  "type": "module",
  "main": "dist/index.js",
  "scripts": {
    "build": "tsc",
    "start": "node dist/index.js"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.0.0"
  },
  "devDependencies": {
    "typescript": "^5.0.0",
    "@types/node": "^20.0.0"
  }
}
```

#### C3: tsconfig.json

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "node",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*"]
}
```

#### C4: index.ts

```typescript
// src/index.ts
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const server = new Server(
  { name: "{project-name}", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "hello_world",
      description: "A simple hello world tool",
      inputSchema: {
        type: "object",
        properties: {
          name: { type: "string", description: "Name to greet" }
        },
        required: []
      }
    }
  ]
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name === "hello_world") {
    const name = (request.params.arguments as any)?.name || "World";
    return { content: [{ type: "text", text: "Hello, " + name + "!" }] };
  }
  throw new Error("Unknown tool: " + request.params.name);
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
```

---

## Phase 2: 設定 Git 和 MCPB

### Step 1: 初始化 Git

```bash
cd {project-path}
git init
```

### Step 2: .gitignore

根據語言建立對應的 .gitignore：

**Swift**:
```
.build/
.swiftpm/
Package.resolved
*.xcodeproj
*.xcworkspace
DerivedData/
```

**Python**:
```
__pycache__/
*.py[cod]
.venv/
venv/
dist/
*.egg-info/
```

**TypeScript**:
```
node_modules/
dist/
*.js.map
```

### Step 3: .gitattributes（LFS 設定）

```
*.mcpb filter=lfs diff=lfs merge=lfs -text
mcpb/server/* filter=lfs diff=lfs merge=lfs -text
*.png filter=lfs diff=lfs merge=lfs -text binary
```

```bash
git lfs install
git add .gitattributes
```

### Step 4: mcpb/manifest.json

**重要**：MCPB 0.3 規範對欄位格式有嚴格要求，錯誤會導致 Claude Desktop 顯示 "Invalid manifest"。

```json
{
  "manifest_version": "0.3",
  "name": "{project-name}",
  "version": "0.1.0",
  "description": "{description}",
  "author": {
    "name": "Che Cheng"
  },
  "license": "MIT",
  "homepage": "https://github.com/kiki830621/{project-name}",
  "repository": {
    "type": "git",
    "url": "https://github.com/kiki830621/{project-name}"
  },
  "server": {
    "type": "binary",
    "entry_point": "server/{BinaryName}",
    "mcp_config": {
      "command": "$DIRNAME/server/{BinaryName}",
      "args": [],
      "env": {}
    }
  },
  "keywords": []
}
```

**不要使用的欄位**（會被拒絕）：
- ~~`id`~~ - 使用 `name` 即可
- ~~`platforms`~~ - 不支援
- ~~`capabilities`~~ - 不支援
- ~~`display_name`~~ - 不支援
- ~~`tools`~~ - 不支援（工具從 Server 動態取得）

### Step 5: mcpb/PRIVACY.md

```markdown
# Privacy Policy

## Data Collection

This MCP server:
- Runs entirely locally on your Mac
- Does not collect or transmit any personal data
- Does not connect to external servers
- Only accesses local system resources as required for functionality

## Data Storage

No data is stored by this extension beyond what is necessary for its operation.

## Third-Party Services

This extension does not use any third-party services.

## Contact

For questions about this privacy policy, please open an issue at:
https://github.com/kiki830621/{project-name}/issues
```

### Step 6: README.md

```markdown
# {project-name}

{description}

## Installation

### Claude Code CLI

```bash
mkdir -p ~/bin
# Download binary from releases
chmod +x ~/bin/{BinaryName}
claude mcp add --scope user --transport stdio {project-name} -- ~/bin/{BinaryName}
```

## Tools

| Tool | Description |
|------|-------------|
| `hello_world` | A simple hello world tool |

## License

MIT
```

### Step 7: CHANGELOG.md

```markdown
# Changelog

## [0.1.0] - {date}

### Added
- Initial release
- `hello_world` tool
```

### Step 8: LICENSE

```
MIT License

Copyright (c) {year} Che Cheng

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Phase 3: 完成報告

### 顯示建立的檔案清單

```markdown
# MCP 專案建立完成

## 專案資訊
- 名稱: {project-name}
- 語言: Swift / Python / TypeScript
- 位置: {project-path}

## 建立的檔案

### 核心檔案
- [ ] Package.swift / pyproject.toml / package.json
- [ ] Server 程式碼

### Git 設定
- [ ] .gitignore
- [ ] .gitattributes (LFS)

### MCPB 套件（用於 Claude Desktop Extension Marketplace）
- [ ] mcpb/manifest.json    - 套件 metadata
- [ ] mcpb/PRIVACY.md       - 隱私政策
- [ ] mcpb/server/          - Binary 存放目錄
- [ ] mcpb/{project}.mcpb   - 打包後的套件檔（部署時產生）

### 文件
- [ ] README.md
- [ ] CHANGELOG.md
- [ ] LICENSE

## 下一步

1. **編輯 Server 程式碼**，加入你的功能
2. **測試編譯**：
   - Swift: `swift build`
   - Python: `pip install -e .`
   - TypeScript: `npm install && npm run build`
3. **若 MCP 會用到 macOS 隱私 API**（EventKit / AppleEvents / Photos / Mic / Camera / Full Disk Access）→ **裝簽章 pipeline**：使用 `/devtools:mcp-sign-pipeline`
   - macOS 26 的 TCC 不再對 ad-hoc 簽章的 binary 開放 permission dialog；若要 outside-MAS distribution 必須走 Developer ID + hardened runtime + notarization
   - 此 skill 會自動把 `scripts/sign-and-notarize.sh` + `Makefile release-signed` + `Sources/<Target>/Entitlements.plist` + README + CHANGELOG 補進你新建的 MCP
   - 純檔案 I/O / HTTP / 字串處理 MCP 不需要（簽章只影響 Gatekeeper warning，不影響功能）
4. **部署**：使用 `/devtools:mcp-deploy`
   - 會自動編譯、打包 .mcpb、發布到 GitHub Release
   - 若已裝 sign-pipeline，可用 `make release-signed` 跑 signed release（macOS 26 必要）
```

---

## 快速參考

### 命名轉換

| 輸入 | 專案名 | Binary 名 | 類別名 |
|------|--------|-----------|--------|
| `che-notes-mcp` | `che-notes-mcp` | `CheNotesMCP` | `CheNotesMCPServer` |
| `my-tool-mcp` | `my-tool-mcp` | `MyToolMCP` | `MyToolMCPServer` |

### 語言選擇建議

| 情境 | 推薦語言 |
|------|----------|
| macOS 原生整合（AppleScript, EventKit） | Swift |
| 快速原型開發 | Python |
| Node.js 生態系整合 | TypeScript |
| 跨平台需求 | Python / TypeScript |
