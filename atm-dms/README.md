# AFMP — ATM 機隊監控管理平台（獨立系統）

> **AFMP**（ATM Fleet Monitoring & Management Platform，暫名「智監」）
> 為金融機構打造的 ATM/AVM 機隊監控管理平台，技術棧 **.NET**。
> 對標並升級 MDS 三商電腦 **DMS 自動化設備監控管理系統**。

這是一個**全新、獨立**的系統，與本 repo 內既有的食品 ERP 完全無關，故獨立放在根目錄 `atm-dms/`。
此資料夾自成一個系統根，未來可直接整包搬遷到專屬 repo，無需改動內部結構。

## 目前狀態：規格與架構藍圖（docs-only）

本階段交付**完整系統設計與架構藍圖**（規格文件），尚未進入程式實作。

## 目錄佈局

```
atm-dms/
  README.md          ← 你正在看的這份
  docs/              ← 架構藍圖（完整規格）★ 目前內容
    00-overview/     願景、利害關係人、術語
    01-architecture/ C4、.NET 解決方案結構、部署拓撲、技術選型
    02-integration/  ★ agent↔平台合約、攝取/HA、設備模擬器、對帳介接
    03-data-model/   各模組資料模型 + 狀態機
    04-modules/      四大模組功能規格 + 派送/內容/白名單
    05-cross-cutting/認證授權、告警引擎、現金預測、報表
    06-nfr-compliance/安全/PCI、金管會合規、HA/DR/觀測/效能
    07-delivery/     roadmap、風險/假設/開放問題
    decisions/       ADR-001 ~ ADR-006
  (未來) src/        .NET solution（AFMP.sln）
  (未來) simulator/  設備模擬器
  (未來) deploy/     Helm / Terraform / Ansible / compose
```

## 從哪裡開始讀

1. `docs/00-overview/00-vision-and-goals.md`
2. `docs/01-architecture/10-c4-context-and-containers.md`
3. `docs/02-integration/20-device-agent-contract-v1.md`（承載一切的合約）
4. `docs/03-data-model/35-state-machines.md`

完整文件地圖見 `docs/README.md`。

## 搬遷到獨立 repo 的方式（未來）

```bash
# 於本 repo 根目錄
git subtree split --prefix=atm-dms -b afmp-export
# 在新 repo
git pull <this-repo> afmp-export
```
或直接複製 `atm-dms/` 內容到新 repo 初始化。所有相對連結均限定在本資料夾內，搬遷後不會斷鏈。
