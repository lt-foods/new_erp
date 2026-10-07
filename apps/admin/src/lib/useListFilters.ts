"use client";

import { useEffect, useState } from "react";
import { useAuth } from "@/components/AuthProvider";
import {
  browserSessionStorage,
  listFiltersKey,
  readListFilters,
  serializeListFilters,
  writeListFilters,
  type ListFilterSpec,
} from "./listFilters";

// 後台列表「點進明細再回來，篩選條件還在」的 React 那一層；存法、驗證都在 ./listFilters.ts。
//
// 用法（每個條件照舊各自一個 useState，只是初始值改成上次存的）：
//   const saved = useSavedListFilters(SPEC);
//   const [tab, setTab] = useState(saved.tab);
//   …
//   useSaveListFilters(SPEC, { tab, … });
//
// 為什麼初始值要在 useState 裡同步讀，不能等 useEffect 再塞回去：
//   列表一打開就會用「目前的條件」查資料庫。等 effect 才塞回去 = 先用空條件查一次、
//   再用舊條件查一次（多打一次資料庫、畫面閃一下）。
//   受保護的頁面要等登入確認完才渲染（(protected)/layout.tsx），伺服器端預先產生的畫面裡沒有這些頁，
//   所以第一次渲染就讀 sessionStorage 不會有「伺服器跟瀏覽器畫面對不起來」的問題。

/** 列表頁第一次渲染時讀回上次的條件（每次進到列表頁只讀這一次） */
export function useSavedListFilters<T extends Record<string, unknown>>(spec: ListFilterSpec<T>): T {
  const { user } = useAuth();
  const [saved] = useState(() =>
    readListFilters(browserSessionStorage(), listFiltersKey(spec.page, user?.id), spec),
  );
  return saved;
}

/** 條件一改就存回 sessionStorage（內容沒變不重寫）；寫不進去就算了，不影響畫面 */
export function useSaveListFilters<T extends Record<string, unknown>>(spec: ListFilterSpec<T>, values: T): void {
  const { user } = useAuth();
  const key = listFiltersKey(spec.page, user?.id);
  const raw = serializeListFilters(values, spec);
  useEffect(() => {
    writeListFilters(browserSessionStorage(), key, raw);
  }, [key, raw]);
}
