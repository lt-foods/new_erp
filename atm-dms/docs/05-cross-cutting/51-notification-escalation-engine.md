---
title: 告警通知與升級引擎
module: AFMP / CrossCutting
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Notification, Alerting, Escalation, RuleEngine]
---

# 告警通知與升級引擎（Notification & Escalation）

對標 DMS 多通道告警，**現代化通道 + 規則引擎 + 分層升級**，**傳真退役**。

## 1. 規則引擎（Rule Engine）

條件來源：整合事件 + 時序指標。

| 條件型別 | 例 |
|---|---|
| 門檻（threshold）| 現金低於 X、拒鈔匣 > Y% |
| 缺席（absence）| 心跳缺失 N 次 → Offline |
| 速率（rate）| 單位時間故障數激增、退鈔率飆高 |
| ML 異常（v2）| 交易/現金樣態異常 |
| 狀態轉移 | incident SLA 逾時風險 |

- 規則 → 嚴重度映射：`Info / Warning / Critical / Emergency`。
- **去重 + 抑制視窗**（避免風暴）；**維護視窗靜音**（Maintenance 機台不擾人）。

## 2. 通道（Channels）— 現代化

| 通道 | 用途 |
|---|---|
| App push（FCM/APNs）| 行動外勤、值班 |
| 站內通知 | Web 即時 |
| IM（LINE / Teams / Slack webhook）| 團隊群組 |
| Email（SMTP）| 正式記錄 |
| SMS | 緊急 |
| 語音電話 | Emergency 級 |
| ~~傳真~~ | **退役**（僅銀行堅持時保留 legacy adapter）|

## 3. 升級策略（Escalation Policy）

- 分層：工程師 → 主管 → 廠商 → 經理。
- **時間驅動**：未在 T1 內 ack → 升一層 + 換通道；未在 T2 內處理 → 再升級。
- **on-call 排班**：依班表決定當前接收人。
- **ack 追蹤**：誰、何時確認；未確認持續升級。
- 與 SLA 計時器連動（incident `sla_response_due`/`sla_resolve_due`）。

## 4. 資料模型

| 表 | 說明 |
|---|---|
| `notification_rule` | 條件 + 嚴重度 + 抑制視窗 + 目標 |
| `notification_channel` | 通道設定（端點/憑證）|
| `escalation_policy` | 分層 + 時限 + on-call |
| `notification_log` | 送達稽核（誰/通道/時間/狀態/ack）|

## 5. 流程

```
事件/指標 → 規則匹配 → 去重/抑制檢查 → 嚴重度
   → 依升級策略選第一層接收人 + 通道 → 送出（記 log）
   → 等待 ack/解決；逾時 → 升級下一層/換通道
```

## 6. 與模組關係

- 訂閱整合事件：`DeviceWentOffline`、`CashBelowThreshold`、`FaultRaised`、`IncidentSlaBreachImminent`、`ReconExceptionFound`、`WhitelistViolation`。
- 告警可自動衍生 incident（M4）並反向更新通知狀態。
- 金管會應通報事件 → 觸發異常通報工作流（見 `61`），通知 Compliance。

## 7. 對標檢核（vs DMS）

| DMS | AFMP |
|---|---|
| 語音/email/SMS/傳真 | ✅ push/IM/email/SMS/語音；傳真退役 |
| 通知人員/廠商 | ✅ + 分層升級 + on-call + ack 追蹤 |
| — | ✅ 規則引擎 + 去重/抑制/維護靜音 |
