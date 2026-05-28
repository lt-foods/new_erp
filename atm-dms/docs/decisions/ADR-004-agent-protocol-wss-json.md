---
title: ADR-004 機端協定 wss + JSON（對齊 XFS4IoT）
module: AFMP / ADR
status: accepted
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [ADR, Protocol, wss, XFS4IoT, gRPC, SNMP]
---

# ADR-004：機端 agent 協定採 wss + JSON（控制/遙測）+ HTTPS REST（大量）

## 狀態
Accepted（draft-v1）

## 背景
機端需上傳心跳/狀態/現金/交易/EJ，並接收下令（軟體/內容/設定/白名單）。機台位於行內網段，受 NAT/防火牆限制；多廠牌異質。

## 決策
- **控制/遙測面**：agent 主動外連的 **wss（WebSocket Secure）+ JSON**，雙向。對齊 **XFS4IoT（CWA 17852）** 的 wss/JSON 模型。
- **大量傳輸面**：**HTTPS REST（分塊/可續傳）** 處理 EJ 上傳、韌體/內容下載。
- **SNMP**：作為 legacy/多廠牌週邊的攝取 adapter，於 Gateway 正規化。
- 皆 **mTLS**。

## 被否決選項
- **gRPC（機端邊界）**：行內防火牆/代理摩擦、瀏覽器/legacy 工具弱、串流經 proxy 易斷 → 否決；僅保留給未來內部服務間。
- 純 REST 輪詢：即時性差、下令困難。
- 私有二進位協定：省頻寬但失去除錯性/廠商中立/前向相容。

## 理由
- agent 主動外連 → 機台不需開 inbound port，最大化防火牆穿透。
- wss/JSON 可除錯、廠商中立、前向相容 XFS4IoT。
- 大量傳輸與即時控制分流，互不干擾。

## 取捨
- wss/JSON 線上負載略高於二進位 → 以壓縮 + 分流大量傳輸緩解。

## 影響
- 合約（`20`）、攝取/HA（`21`）、模擬器（`22`）、安全（`60`）。
