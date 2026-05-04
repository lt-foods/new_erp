"use client";

import { useEffect, useMemo, useRef } from "react";
import { useAuth } from "@/components/AuthProvider";

/**
 * 回傳當前使用者「分店帳號」鎖到的 store id;HQ / 沒設 stores 回 null。
 * 拿來判斷是否要強制鎖門市篩選 / 隱藏下拉。
 */
export function useUserBranchStoreId(
  stores: ReadonlyArray<{ id: number | string; name: string }>,
): number | null {
  const { user } = useAuth();
  return useMemo(() => {
    const userStores = user?.app_metadata?.stores as unknown;
    if (!Array.isArray(userStores) || userStores.length === 0) return null;
    if (userStores.includes("總倉")) return null;
    const match = stores.find((s) => userStores.includes(s.name));
    return match ? Number(match.id) : null;
  }, [stores, user]);
}

/**
 * 分店帳號登入時,把任何「分店篩選下拉」預設選中該分店。
 *
 * - 使用者 app_metadata.stores 為陣列且非空 → 比對 stores[i].name 找出第一個 match
 *   設成 storeId state (如果現在還是空的)
 * - HQ 帳號 (沒 stores 或包含「總倉」) → 不動
 * - 一旦套過就不再 reapply,使用者手動切回「全部」也尊重
 *
 * 用法:
 *   useDefaultStoreFromUser(stores, storeId, setStoreId);
 */
export function useDefaultStoreFromUser(
  stores: ReadonlyArray<{ id: number | string; name: string }>,
  currentStoreId: string,
  setStoreId: (v: string) => void,
) {
  const { user } = useAuth();
  const appliedRef = useRef(false);

  useEffect(() => {
    if (appliedRef.current) return;
    if (currentStoreId) {
      // URL 或使用者已預先設過 → 不覆蓋
      appliedRef.current = true;
      return;
    }
    if (stores.length === 0) return;
    const userStores = user?.app_metadata?.stores as unknown;
    if (!Array.isArray(userStores) || userStores.length === 0) return;
    if (userStores.includes("總倉")) return;
    const match = stores.find((s) => userStores.includes(s.name));
    if (match) {
      setStoreId(String(match.id));
      appliedRef.current = true;
    }
  }, [stores, user, currentStoreId, setStoreId]);
}
