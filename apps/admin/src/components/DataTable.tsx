"use client";

import type { MouseEventHandler, ReactNode } from "react";

type Align = "left" | "center" | "right";

function alignCls(align: Align | undefined) {
  if (align === "right") return "text-right";
  if (align === "center") return "text-center";
  return "text-left";
}

export function Table({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <div className="overflow-x-auto rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
      <table className={`min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800 ${className}`}>
        {children}
      </table>
    </div>
  );
}

export function THead({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <thead className="bg-zinc-50 dark:bg-zinc-900">
      <tr className={className}>{children}</tr>
    </thead>
  );
}

export function TBody({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <tbody className={`divide-y divide-zinc-200 dark:divide-zinc-800 ${className}`}>
      {children}
    </tbody>
  );
}

export function Tr({
  children,
  className = "",
  onClick,
}: {
  children: ReactNode;
  className?: string;
  onClick?: () => void;
}) {
  return (
    <tr
      onClick={onClick}
      className={`hover:bg-zinc-50 dark:hover:bg-zinc-900 ${onClick ? "cursor-pointer" : ""} ${className}`}
    >
      {children}
    </tr>
  );
}

export function Th({
  children,
  className = "",
  align,
  onClick,
  scope = "col",
}: {
  children?: ReactNode;
  className?: string;
  align?: Align;
  onClick?: () => void;
  scope?: "col" | "row";
}) {
  return (
    <th
      scope={scope}
      onClick={onClick}
      className={`px-4 py-2 ${alignCls(align)} text-xs font-medium uppercase tracking-wide text-zinc-500 ${onClick ? "cursor-pointer select-none hover:text-zinc-900 dark:hover:text-zinc-100" : ""} ${className}`}
    >
      {children}
    </th>
  );
}

export function Td({
  children,
  className = "",
  colSpan,
  align,
  onClick,
  title,
}: {
  children?: ReactNode;
  className?: string;
  colSpan?: number;
  align?: Align;
  onClick?: MouseEventHandler<HTMLTableCellElement>;
  title?: string;
}) {
  return (
    <td
      colSpan={colSpan}
      title={title}
      onClick={onClick}
      className={`px-4 py-3 ${alignCls(align)} ${className}`}
    >
      {children}
    </td>
  );
}

export function EmptyRow({
  colSpan,
  children,
}: {
  colSpan: number;
  children?: ReactNode;
}) {
  return (
    <tr>
      <td colSpan={colSpan} className="p-6 text-center text-sm text-zinc-500">
        {children ?? "目前沒有資料"}
      </td>
    </tr>
  );
}

export function LoadingRow({
  colSpan,
  children,
}: {
  colSpan: number;
  children?: ReactNode;
}) {
  return (
    <tr>
      <td colSpan={colSpan} className="p-3 text-center text-sm text-zinc-500">
        {children ?? "載入中…"}
      </td>
    </tr>
  );
}
