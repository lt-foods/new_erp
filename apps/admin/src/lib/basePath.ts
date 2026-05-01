// Next.js's <Link> auto-prefixes basePath, but raw <a href> and window.open
// don't. Use this for those cases (especially print pages opened via
// window.open and external-style <a target="_blank"> links).
export const BASE_PATH = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

export function withBasePath(path: string): string {
  if (!path) return path;
  if (/^https?:\/\//i.test(path) || path.startsWith("mailto:") || path.startsWith("tel:")) {
    return path;
  }
  if (!path.startsWith("/")) return path;
  return BASE_PATH + path;
}
