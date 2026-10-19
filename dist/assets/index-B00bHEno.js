(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))o(s);new MutationObserver(s=>{for(const n of s)if(n.type==="childList")for(const d of n.addedNodes)d.tagName==="LINK"&&d.rel==="modulepreload"&&o(d)}).observe(document,{childList:!0,subtree:!0});function r(s){const n={};return s.integrity&&(n.integrity=s.integrity),s.referrerPolicy&&(n.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?n.credentials="include":s.crossOrigin==="anonymous"?n.credentials="omit":n.credentials="same-origin",n}function o(s){if(s.ep)return;s.ep=!0;const n=r(s);fetch(s.href,n)}})();const b={name:"Robinhood Chain"},v=18,$={chainId:4663,address:"0x4f1b7a5aaf3768f7500e9ab5cbbf3762834e8b57",name:"Item",symbol:"ITEM"},k="item-256.png",w=[{file:"item-256.png",role:"token image",type:"image/png",width:256,height:256,bytes:8740,cid:"bafkreifenq2t55lzpff6ffoxct6klzoy6ur3rbscdpjdrkp3e42kumxpby",sha256:"a46c353ef579794be295d714fca5e5d8f523b886421bd238a9fb2734aa32ef0e",url:"https://gateway.pinata.cloud/ipfs/bafkreifenq2t55lzpff6ffoxct6klzoy6ur3rbscdpjdrkp3e42kumxpby"},{file:"item.svg",role:"SVG master",type:"image/svg+xml",width:1024,height:1024,bytes:987,cid:"bafkreicqjagwzaq63lpsnlb2gq4nl7wtplqz5772jomqgvpsbva3ohws2e",sha256:"50480d6c821edadf26ac3a3438d5fed37ae19efffa4b990355f20d41b71ed2d1",url:"https://gateway.pinata.cloud/ipfs/bafkreicqjagwzaq63lpsnlb2gq4nl7wtplqz5772jomqgvpsbva3ohws2e"},{file:"item-32.svg",role:"32 px SVG",type:"image/svg+xml",width:32,height:32,bytes:983,cid:"bafkreihtkwltlruqamom7sgy43jxdchkydqflruzzghbkbe37g3c33vbt4",sha256:"f3559735c690031ccfc8d8e6d37188eac0e055c699c98e15049bf9b62deea19f",url:"https://gateway.pinata.cloud/ipfs/bafkreihtkwltlruqamom7sgy43jxdchkydqflruzzghbkbe37g3c33vbt4"},{file:"item-64.svg",role:"64 px SVG",type:"image/svg+xml",width:64,height:64,bytes:983,cid:"bafkreiejgix7cndhixbbbs5r6olnnjr3qvjpyhgvddafxbda7mpcpni6e4",sha256:"89322ff1346745c210cbb1f396d6a63b8552fc1cd518c05b8460fb1e27b51e27",url:"https://gateway.pinata.cloud/ipfs/bafkreiejgix7cndhixbbbs5r6olnnjr3qvjpyhgvddafxbda7mpcpni6e4"}],S={token:$,primary:k,files:w},y=S;function f(e){return`./logo/${e}`}function x(e){return e==="image/png"?"PNG":e==="image/svg+xml"?"SVG":e}function _(e){return Array.from(new Uint8Array(e),t=>t.toString(16).padStart(2,"0")).join("")}async function C(e){const t=await fetch(f(e),{cache:"no-store"});if(!t.ok)throw new Error(`HTTP ${t.status}`);const r=await t.arrayBuffer();return _(await crypto.subtle.digest("SHA-256",r))}const{token:i,files:c}=y,l=c.find(e=>e.file===y.primary)??c[0],m=c.find(e=>e.role==="SVG master"),q=new Intl.NumberFormat("en");function a(e){return String(e).replace(/[&<>"']/g,t=>`&#${t.charCodeAt(0)};`)}function T(e){return e.charAt(0).toUpperCase()+e.slice(1)}function A(e){return[a(T(e.role)),`${e.width}&nbsp;×&nbsp;${e.height} ${x(e.type)}`,`${q.format(e.bytes)}&nbsp;bytes`].join(" · ")}function j(e){const t=Math.min(e.width,64);return`
    <li class="file" data-file="${a(e.file)}">
      <img class="file__thumb" src="${f(e.file)}" width="${t}" height="${t}" alt="" />
      <div class="file__body">
        <h3 class="file__name">${a(e.file)}</h3>
        <p class="file__meta">${A(e)}</p>
        <dl class="ids">
          <div><dt>CID</dt><dd><code>${a(e.cid)}</code></dd></div>
          <div><dt>SHA-256</dt><dd><code>${a(e.sha256)}</code></dd></div>
        </dl>
        <p class="file__status" data-status hidden></p>
      </div>
      <div class="file__actions">
        <a class="button" href="${f(e.file)}" download="${a(e.file)}">Download ${a(e.file)}</a>
        <a class="text-link" href="${a(e.url)}" target="_blank" rel="noopener noreferrer">Open ${a(e.file)} on IPFS</a>
      </div>
    </li>`}function H(){return`
  <section class="container hero" aria-labelledby="hero-title">
    <div class="hero__text">
      <h1 id="hero-title">The ${a(i.symbol)} token logo</h1>
      <p class="lede">The image for ${a(i.name)} (${a(i.symbol)}) on ${b.name}, byte for byte as served from IPFS.</p>
    </div>
    <figure class="hero__logo">
      <img src="${f(l.file)}" width="${l.width}" height="${l.height}"
        alt="${a(i.name)} (${a(i.symbol)}) token logo" />
    </figure>
    <div class="hero__actions">
      <a class="button button--primary" href="${f(l.file)}" download="${a(l.file)}">Download ${l.width}&nbsp;px PNG</a>
      ${m?`<a class="button" href="${f(m.file)}" download="${a(m.file)}">Download SVG master</a>`:""}
    </div>
    <div class="address">
      <p class="address__label" id="address-label">Token contract on ${b.name}</p>
      <div class="address__row">
        <code id="token-address" aria-labelledby="address-label">${a(i.address)}</code>
        <button class="button" type="button" id="copy-address">Copy address</button>
      </div>
      <p class="address__status" role="status" id="copy-status"></p>
    </div>
  </section>

  <section class="container section" aria-labelledby="files-title">
    <h2 id="files-title">Logo files</h2>
    <p class="section__intro">Every file is the one its IPFS CID names, unchanged. Submit these same files when you add the token logo on RobinScan or Blockscout.</p>
    <ul class="file-list">${c.map(j).join("")}</ul>
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
      <div><dt>Name</dt><dd>${a(i.name)}</dd></div>
      <div><dt>Symbol</dt><dd>${a(i.symbol)}</dd></div>
      <div><dt>Decimals</dt><dd>${v}</dd></div>
      <div><dt>Chain</dt><dd>${b.name}, chain ID ${i.chainId}</dd></div>
    </dl>
  </section>

  <footer class="container site-footer">
    <p>${a(i.name)} (${a(i.symbol)}) on ${b.name}. The logo files are also in the repository under <code>assets/logo/</code>.</p>
  </footer>`}async function I(e,t){try{if(navigator.clipboard&&window.isSecureContext)return await navigator.clipboard.writeText(e),!0}catch{}const r=document.createRange();r.selectNodeContents(t);const o=window.getSelection();o==null||o.removeAllRanges(),o==null||o.addRange(r);let s=!1;try{s=document.execCommand("copy")}catch{s=!1}return s&&(o==null||o.removeAllRanges()),s}function z(){const e=document.querySelector("#copy-address"),t=document.querySelector("#copy-status"),r=document.querySelector("#token-address");!e||!t||!r||e.addEventListener("click",async()=>{const o=await I(i.address,r);t.dataset.state=o?"ok":"error",t.textContent=o?"Address copied.":"Unable to copy here. The address is selected; press Ctrl+C or Cmd+C."})}function P(){const e=document.querySelector("#check-hashes"),t=document.querySelector("#check-status");if(!e||!t)return;const r=e.textContent??"";e.addEventListener("click",async()=>{var s;if(!((s=globalThis.crypto)!=null&&s.subtle)){t.dataset.state="error",t.textContent="This browser only hashes files on an HTTPS page. Open the site over HTTPS or run sha256sum instead.";return}e.disabled=!0,e.textContent="Checking hashes…",t.dataset.state="",t.textContent=`Checking ${c.length} files…`;let o=0;for(const n of c){const d=document.querySelector(`.file[data-file="${CSS.escape(n.file)}"] [data-status]`);let u,p;try{const h=await C(n.file);h===n.sha256?(o+=1,p="ok",u="SHA-256 matches."):(p="error",u=`SHA-256 does not match. This page served ${h}.`)}catch(h){p="error",u=`Unable to load the file (${h instanceof Error?h.message:"unknown error"}). Reload and try again.`}d&&(d.hidden=!1,d.dataset.state=p,d.textContent=u)}t.dataset.state=o===c.length?"ok":"error",t.textContent=o===c.length?`All ${c.length} files match their SHA-256.`:`${o} of ${c.length} files match. See the files marked above.`,e.disabled=!1,e.textContent=r})}const g=document.querySelector("#app");g&&(g.innerHTML=H(),z(),P());
