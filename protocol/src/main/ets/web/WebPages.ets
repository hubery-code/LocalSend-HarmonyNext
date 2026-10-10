/**
 * The browser-facing assets: the file list page, the page a stopped share serves instead, and the
 * strings the page shows.
 *
 * The pages are deliberately plain HTML with ES5-era JavaScript so that any browser on the LAN works
 * — an old TV box, a corporate Safari, a HarmonyOS webview. Every visible word comes from `/i18n.json`
 * in the language the browser asked for, so one page serves both locales.
 *
 * Two constraints keep the source compilable inside a template literal: no backslash escapes and no
 * backticks anywhere in the markup or script.
 */

/** A file list a browser can pick from. */
export const DOWNLOAD_PAGE: string = `<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LocalSend</title>
<style>
body { margin: 0; padding: 24px 16px 56px; background: #f2f3f5; color: #1c1d1f;
       font-family: system-ui, "HarmonyOS Sans SC", "PingFang SC", sans-serif; }
main { max-width: 620px; margin: 0 auto; }
h1 { font-size: 20px; margin: 0 0 2px; }
.muted { color: #6b7076; font-size: 13px; margin: 0; }
#status { min-height: 20px; margin: 18px 0; font-size: 14px; color: #6b7076; }
#status.bad { color: #c62828; }
.file { display: flex; align-items: center; margin-bottom: 9px; padding: 13px 15px; background: #fff; border-radius: 12px; }
.name { flex: 1; margin-right: 10px; font-size: 14px; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.size { margin-right: 12px; font-size: 12px; color: #6b7076; white-space: nowrap; }
.get { padding: 7px 14px; font-size: 13px; color: #fff; background: #00796b; border-radius: 999px; text-decoration: none; }
.get:active { background: #00695c; }
@media (prefers-color-scheme: dark) {
body { background: #16171a; color: #e9eaec; }
.file { background: #232529; }
.muted, #status, .size { color: #9a9ea3; }
}
</style>
</head>
<body>
<main>
<h1>LocalSend</h1>
<p class="muted" id="device"></p>
<p id="status">LocalSend</p>
<div id="list"></div>
<noscript><p>需要浏览器启用 JavaScript / JavaScript is required to download these files.</p></noscript>
</main>
<script>
(function () {
  var API = '/api/localsend/v2';
  var status = document.getElementById('status');
  var device = document.getElementById('device');
  var list = document.getElementById('list');
  var text = {};

  function param(name) {
    var parts = location.search.slice(1).split('&');
    for (var i = 0; i < parts.length; i++) {
      var pair = parts[i].split('=');
      if (pair[0] === name) {
        return decodeURIComponent(pair.slice(1).join('=') || '');
      }
    }
    return '';
  }

  function remember(sessionId) {
    try { sessionStorage.setItem('localsendSession', sessionId); } catch (e) {}
  }

  function recalled() {
    try { return sessionStorage.getItem('localsendSession') || ''; } catch (e) { return ''; }
  }

  function ask(method, url, done) {
    var xhr = new XMLHttpRequest();
    xhr.open(method, url, true);
    xhr.onreadystatechange = function () {
      if (xhr.readyState === 4) { done(xhr); }
    };
    xhr.send(null);
  }

  function bad(message) {
    status.className = 'bad';
    status.textContent = message;
  }

  function sizeOf(bytes) {
    if (bytes < 1024) { return bytes + ' B'; }
    if (bytes < 1048576) { return (bytes / 1024).toFixed(1) + ' KB'; }
    if (bytes < 1073741824) { return (bytes / 1048576).toFixed(1) + ' MB'; }
    return (bytes / 1073741824).toFixed(2) + ' GB';
  }

  function esc(value) {
    var out = '';
    for (var i = 0; i < value.length; i++) {
      var c = value.charAt(i);
      if (c === '&') { out += '&amp;'; }
      else if (c === '<') { out += '&lt;'; }
      else if (c === '>') { out += '&gt;'; }
      else if (c === '"') { out += '&quot;'; }
      else { out += c; }
    }
    return out;
  }

  function show(data) {
    remember(data.sessionId);
    device.textContent = (text.sharedBy || 'Shared by') + ' ' + data.info.alias;
    var ids = Object.keys(data.files);
    status.className = '';
    status.textContent = (text.files || 'Files') + ' (' + ids.length + ')';
    var html = '';
    for (var i = 0; i < ids.length; i++) {
      var file = data.files[ids[i]];
      var href = API + '/download?sessionId=' + encodeURIComponent(data.sessionId)
        + '&fileId=' + encodeURIComponent(ids[i]);
      html += '<div class="file"><span class="name">' + esc(file.fileName) + '</span>'
        + '<span class="size">' + sizeOf(file.size) + '</span>'
        + '<a class="get" href="' + href + '">' + esc(text.download || 'Download') + '</a></div>';
    }
    list.innerHTML = html;
  }

  function request(pin, first) {
    status.className = '';
    status.textContent = text.waiting || 'Waiting for the phone to confirm';
    var qs = [];
    var id = recalled();
    if (id) { qs.push('sessionId=' + encodeURIComponent(id)); }
    if (pin) { qs.push('pin=' + encodeURIComponent(pin)); }
    var url = API + '/prepare-download' + (qs.length ? '?' + qs.join('&') : '');
    ask('POST', url, function (xhr) {
      if (xhr.status === 401) {
        var label = text.pin || 'PIN';
        var typed = window.prompt(first ? label : label + ' / ' + (text.badPin || 'Wrong PIN'));
        if (!typed) { bad(text.badPin || 'Wrong PIN'); return; }
        request(typed, false);
        return;
      }
      if (xhr.status === 403) { bad(text.rejected || 'Rejected on the phone'); return; }
      if (xhr.status === 409) { bad(text.busy || 'The phone is busy with another request'); return; }
      if (xhr.status === 429) { bad(text.tooMany || 'Too many wrong PIN attempts'); return; }
      if (xhr.status !== 200) { bad((text.failed || 'Request failed, status') + ' ' + xhr.status); return; }
      show(JSON.parse(xhr.responseText));
    });
  }

  ask('GET', '/i18n.json', function (xhr) {
    if (xhr.status === 200) {
      text = JSON.parse(xhr.responseText);
    }
    request(param('pin'), true);
  });
})();
</script>
</body>
</html>`;

/** Served with 403 while nothing is shared, so a stale bookmark explains itself. */
export const SHARING_OFF_PAGE: string = `<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LocalSend</title>
<style>
body { margin: 0; padding: 20vh 16px 0; text-align: center; background: #f2f3f5; color: #5f6469;
       font-family: system-ui, "HarmonyOS Sans SC", "PingFang SC", sans-serif; }
h1 { margin: 0 0 10px; font-size: 18px; color: #1c1d1f; }
p { margin: 0 0 4px; font-size: 14px; }
@media (prefers-color-scheme: dark) {
body { background: #16171a; color: #9a9ea3; }
h1 { color: #e9eaec; }
}
</style>
</head>
<body>
<h1>LocalSend</h1>
<p>这台设备当前没有开启网页传</p>
<p>This device is not sharing files right now.</p>
</body>
</html>`;

const ENGLISH: Map<string, string> = buildEnglish();
const CHINESE: Map<string, string> = buildChinese();

function buildEnglish(): Map<string, string> {
  const table: Map<string, string> = new Map<string, string>();
  table.set('sharedBy', 'Shared by');
  table.set('waiting', 'Waiting for the phone to confirm');
  table.set('pin', 'Enter the PIN');
  table.set('badPin', 'Wrong PIN');
  table.set('tooMany', 'Too many wrong PIN attempts');
  table.set('rejected', 'Rejected on the phone');
  table.set('busy', 'The phone is busy with another request');
  table.set('failed', 'Request failed, status');
  table.set('files', 'Files');
  table.set('download', 'Download');
  return table;
}

function buildChinese(): Map<string, string> {
  const table: Map<string, string> = new Map<string, string>();
  table.set('sharedBy', '分享自');
  table.set('waiting', '等待手机确认');
  table.set('pin', '请输入 PIN');
  table.set('badPin', 'PIN 不正确');
  table.set('tooMany', 'PIN 尝试次数过多');
  table.set('rejected', '手机上拒绝了这次下载');
  table.set('busy', '手机上正有另一个请求待处理');
  table.set('failed', '请求失败，状态码');
  table.set('files', '可下载的文件');
  table.set('download', '下载');
  return table;
}

/**
 * The translations for one request, chosen from its `Accept-Language`.
 *
 * The browser is the reader here, not the phone, so a German browser gets German words even though
 * the app itself is Chinese. Chinese is the fallback: it is what the phone's own user reads.
 */
export function webText(acceptLanguage: string): Map<string, string> {
  const raw: string = acceptLanguage.toLowerCase();
  if (raw.indexOf('zh') >= 0) {
    return CHINESE;
  }
  return ENGLISH;
}
