import "./style.css";
import { CHAIN, TOKEN_DECIMALS } from "./config";
import { fileUrl, formatType, hashFile, manifest, type LogoFile } from "./logo";

const { token, files } = manifest;
const primary = files.find((f) => f.file === manifest.primary) ?? files[0];
const master = files.find((f) => f.role === "SVG master");
const tokenUrl = `${CHAIN.explorer}/token/${token.address}`;
const bytesFormat = new Intl.NumberFormat("en");

function escapeHtml(value: string | number): string {
  return String(value).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function sentenceCase(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1);
}

function fileMeta(f: LogoFile): string {
  return [
    escapeHtml(sentenceCase(f.role)),
    `${f.width}&nbsp;×&nbsp;${f.height} ${formatType(f.type)}`,
    `${bytesFormat.format(f.bytes)}&nbsp;bytes`,
  ].join(" · ");
}

function fileRow(f: LogoFile): string {
  const thumb = Math.min(f.width, 64);
  return `
    <li class="file" data-file="${escapeHtml(f.file)}">
      <img class="file__thumb" src="${fileUrl(f.file)}" width="${thumb}" height="${thumb}" alt="" />
      <div class="file__body">
        <h3 class="file__name">${escapeHtml(f.file)}</h3>
        <p class="file__meta">${fileMeta(f)}</p>
        <dl class="ids">
          <div><dt>CID</dt><dd><code>${escapeHtml(f.cid)}</code></dd></div>
          <div><dt>SHA-256</dt><dd><code>${escapeHtml(f.sha256)}</code></dd></div>
        </dl>
        <p class="file__status" data-status hidden></p>
      </div>
      <div class="file__actions">
        <a class="button" href="${fileUrl(f.file)}" download="${escapeHtml(f.file)}">Download ${escapeHtml(f.file)}</a>
        <a class="text-link" href="${escapeHtml(f.url)}" target="_blank" rel="noopener noreferrer">Open ${escapeHtml(f.file)} on IPFS</a>
      </div>
    </li>`;
}

function render(): string {
  return `
  <section class="container hero" aria-labelledby="hero-title">
    <div class="hero__text">
      <h1 id="hero-title">The ${escapeHtml(token.symbol)} token logo</h1>
      <p class="lede">The image for ${escapeHtml(token.name)} (${escapeHtml(token.symbol)}) on ${CHAIN.name}, byte for byte as served from IPFS.</p>
    </div>
    <figure class="hero__logo">
      <img src="${fileUrl(primary.file)}" width="${primary.width}" height="${primary.height}"
        alt="${escapeHtml(token.name)} (${escapeHtml(token.symbol)}) token logo" />
    </figure>
    <div class="hero__actions">
      <a class="button button--primary" href="${fileUrl(primary.file)}" download="${escapeHtml(primary.file)}">Download ${primary.width}&nbsp;px PNG</a>
      ${master ? `<a class="button" href="${fileUrl(master.file)}" download="${escapeHtml(master.file)}">Download SVG master</a>` : ""}
    </div>
    <div class="address">
      <p class="address__label" id="address-label">Token contract on ${CHAIN.name}</p>
      <div class="address__row">
        <code id="token-address" aria-labelledby="address-label">${escapeHtml(token.address)}</code>
        <button class="button" type="button" id="copy-address">Copy address</button>
      </div>
      <p class="address__status" role="status" id="copy-status"></p>
    </div>
  </section>

  <section class="container section" aria-labelledby="files-title">
    <h2 id="files-title">Logo files</h2>
    <p class="section__intro">Every file is the one its IPFS CID names, unchanged. Submit these same files when you add the token logo on RobinScan or Blockscout.</p>
    <ul class="file-list">${files.map(fileRow).join("")}</ul>
  </section>

  <section class="container section" aria-labelledby="check-title">
    <h2 id="check-title">Check the hashes</h2>
    <p class="section__intro">Hash each file this page serves and compare it with the SHA-256 listed above.</p>
    <div class="check">
      <button class="button" type="button" id="check-hashes">Check SHA-256 hashes</button>
      <p class="check__status" role="status" id="check-status"></p>
    </div>
    <p class="section__intro">From a copy of the repository, the same check is one command:</p>
    <pre class="command"><code>sha256sum assets/logo/*</code></pre>
  </section>

  <section class="container section" aria-labelledby="token-title">
    <h2 id="token-title">Token</h2>
    <dl class="facts">
      <div><dt>Name</dt><dd>${escapeHtml(token.name)}</dd></div>
      <div><dt>Symbol</dt><dd>${escapeHtml(token.symbol)}</dd></div>
      <div><dt>Decimals</dt><dd>${TOKEN_DECIMALS}</dd></div>
      <div><dt>Chain</dt><dd>${CHAIN.name}, chain ID ${token.chainId}</dd></div>
      <div><dt>Contract</dt><dd><code>${escapeHtml(token.address)}</code></dd></div>
    </dl>
    <p><a class="text-link" href="${tokenUrl}" target="_blank" rel="noopener noreferrer">View ${escapeHtml(token.symbol)} on RobinScan</a></p>
  </section>

  <footer class="container site-footer">
    <p>${escapeHtml(token.name)} (${escapeHtml(token.symbol)}) on ${CHAIN.name}. The logo files are also in the repository under <code>assets/logo/</code>.</p>
  </footer>`;
}

async function copyText(text: string, source: HTMLElement): Promise<boolean> {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // Fall through to the selection-based copy below.
  }
  const range = document.createRange();
  range.selectNodeContents(source);
  const selection = window.getSelection();
  selection?.removeAllRanges();
  selection?.addRange(range);
  let ok = false;
  try {
    ok = document.execCommand("copy");
  } catch {
    ok = false;
  }
  if (ok) selection?.removeAllRanges();
  return ok;
}

function setupCopy(): void {
  const button = document.querySelector<HTMLButtonElement>("#copy-address");
  const status = document.querySelector<HTMLElement>("#copy-status");
  const address = document.querySelector<HTMLElement>("#token-address");
  if (!button || !status || !address) return;
  button.addEventListener("click", async () => {
    const ok = await copyText(token.address, address);
    status.dataset.state = ok ? "ok" : "error";
    status.textContent = ok
      ? "Address copied."
      : "Unable to copy here. The address is selected; press Ctrl+C or Cmd+C.";
  });
}

function setupCheck(): void {
  const button = document.querySelector<HTMLButtonElement>("#check-hashes");
  const status = document.querySelector<HTMLElement>("#check-status");
  if (!button || !status) return;
  const label = button.textContent ?? "";

  button.addEventListener("click", async () => {
    if (!globalThis.crypto?.subtle) {
      status.dataset.state = "error";
      status.textContent =
        "This browser only hashes files on an HTTPS page. Open the site over HTTPS or run sha256sum instead.";
      return;
    }
    button.disabled = true;
    button.textContent = "Checking hashes…";
    status.dataset.state = "";
    status.textContent = `Checking ${files.length} files…`;

    let matched = 0;
    for (const f of files) {
      const row = document.querySelector<HTMLElement>(`.file[data-file="${CSS.escape(f.file)}"] [data-status]`);
      let text: string;
      let state: "ok" | "error";
      try {
        const actual = await hashFile(f.file);
        if (actual === f.sha256) {
          matched += 1;
          state = "ok";
          text = "SHA-256 matches.";
        } else {
          state = "error";
          text = `SHA-256 does not match. This page served ${actual}.`;
        }
      } catch (error) {
        state = "error";
        text = `Unable to load the file (${error instanceof Error ? error.message : "unknown error"}). Reload and try again.`;
      }
      if (row) {
        row.hidden = false;
        row.dataset.state = state;
        row.textContent = text;
      }
    }

    status.dataset.state = matched === files.length ? "ok" : "error";
    status.textContent =
      matched === files.length
        ? `All ${files.length} files match their SHA-256.`
        : `${matched} of ${files.length} files match. See the files marked above.`;
    button.disabled = false;
    button.textContent = label;
  });
}

const app = document.querySelector<HTMLDivElement>("#app");
if (app) {
  app.innerHTML = render();
  setupCopy();
  setupCheck();
}
