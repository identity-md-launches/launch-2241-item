import logo from "../../assets/logo/logo.json";

export interface LogoFile {
  file: string;
  role: string;
  type: string;
  width: number;
  height: number;
  bytes: number;
  cid: string;
  sha256: string;
  url: string;
}

export interface LogoManifest {
  token: { chainId: number; address: string; name: string; symbol: string };
  primary: string;
  files: LogoFile[];
}

export const manifest: LogoManifest = logo;

/** Relative URL of a logo file inside the export (dist/logo/<file>). */
export function fileUrl(file: string): string {
  return `./logo/${file}`;
}

export function formatType(type: string): string {
  return type === "image/png" ? "PNG" : type === "image/svg+xml" ? "SVG" : type;
}

export function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** SHA-256 of the bytes the page serves for a file, as lowercase hex. */
export async function hashFile(file: string): Promise<string> {
  const response = await fetch(fileUrl(file), { cache: "no-store" });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const bytes = await response.arrayBuffer();
  return toHex(await crypto.subtle.digest("SHA-256", bytes));
}
