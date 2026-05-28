---
title: ADR-005 前端採 React
module: AFMP / ADR
status: accepted
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [ADR, Frontend, React, Blazor]
---

# ADR-005：前端採 React（非 Blazor）

## 狀態
Accepted（draft-v1）

## 背景
前端核心是**互動地圖、即時儀表板、複雜工作台**（事件 Kanban、對帳並排、現金量表/趨勢）。

## 決策
採 **React + TypeScript** + 地圖庫（MapLibre/Leaflet）+ 圖表庫。行動外勤採 **React Native**（共用技能）。

## 被否決選項
- **Blazor Server**：與 .NET 整合緊密，但互動地圖/圖表生態較弱、每連線伺服器成本高（機隊規模下不利）、離線/行動弱。
- Blazor WASM：啟動體積/生態仍不及 React。

## 理由
- 互動地圖/即時 UI 的生態與元件最成熟。
- 人才供給大；團隊既有 TS/React 經驗。
- 與 SignalR（即時推送）整合良好。

## 取捨
- 前後端分離需維護 API 合約（以 OpenAPI/型別產生緩解）。

## 影響
- 容器視圖（`10`）、即時推送（SignalR）、技術選型（`13`）。
