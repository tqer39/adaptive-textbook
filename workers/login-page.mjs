import { encode } from "./crypto.mjs";
export function loginPage(configured, request) {
  const nonce = encode(crypto.getRandomValues(new Uint8Array(18)));
  const body = `<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>積み木テキスト | 本人限定Dev</title>
 <style nonce="${nonce}">*{box-sizing:border-box}body{margin:0;padding:24px;font-family:system-ui,-apple-system,sans-serif;color:#20373c;background:#f8f7f2;line-height:1.8}main{max-width:540px;margin:8vh auto;padding:28px;border:1px solid #d8ded8;border-radius:14px;background:#fffefb}h1{margin:0;font-size:1.8rem}button{font:inherit;color:#20373c;background:#fff;border:1px solid #7d9596;border-radius:8px;padding:12px 16px;cursor:pointer}button:disabled{cursor:default;background:#eef0f4;color:#52666a}button:focus-visible{outline:3px solid #1d4ed8;outline-offset:3px}.tag{font-size:.85rem;color:#52666a}.notice{padding:14px;border-left:3px solid #47746c;background:#e9eee7}a{color:#1d5d55}</style></head><body><main>
 <p class="tag">本人限定Dev · 固定CAA教材の試作</p><h1>積み木テキスト</h1><p>読む・図を操作する・予測して答える、小さな教科書。</p>
 <p id="status" role="status" class="notice">${configured ? "本人のGoogleアカウントでログインしてください。" : "Googleログインの設定準備中です。現在は教材・履歴・BYOKへアクセスできません。"}</p>
 <button id="login" ${configured ? "" : "disabled"}>Googleでログイン</button>
 <p>本人確認に使う情報はIDとメールのみです。生成機能は未実装、実APIキー入力・AI送信は無効です。</p>
 <p class="tag">実Google接続は設定と検証が完了した後に利用できます。読書履歴のクラウド同期は未実装です。</p></main>
 <script nonce="${nonce}">const button=document.querySelector('#login'),status=document.querySelector('#status');
 if(new URL(location.href).searchParams.has('auth')){status.textContent='ログインを完了できませんでした。設定状況を確認してください。';history.replaceState(null,'','/');}
 button.addEventListener('click',async()=>{button.disabled=true;status.textContent='ログイン開始を確認しています。';try{
 const s=await fetch('/api/auth/status',{credentials:'same-origin',cache:'no-store',redirect:'error'});if(!s.ok)throw Error();const session=await s.json();if(!session.available||typeof session.csrfToken!=='string')throw Error();
 const r=await fetch('/api/auth/start',{method:'POST',credentials:'same-origin',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json','X-CSRF-Token':session.csrfToken},body:'{}'});if(!r.ok)throw Error();const data=await r.json(),url=new URL(data.authorizationUrl);if(url.origin!=='https://accounts.google.com'||url.pathname!=='/o/oauth2/v2/auth')throw Error();location.assign(url.href);
 }catch{status.textContent='Googleログインは設定準備中、または接続を確認できません。教材・履歴・BYOKへのアクセスは停止しています。';button.disabled=${configured ? "false" : "true"};}});</script></body></html>`;
  return new Response(request.method === "HEAD" ? null : body, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'`,
    },
  });
}
