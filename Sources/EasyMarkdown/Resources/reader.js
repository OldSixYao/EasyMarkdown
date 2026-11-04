/* All document content is untrusted. Sanitize before insertion; never interpolate it into JS. */
const content = document.getElementById('content');
const copyStatus = document.getElementById('copy-status');
const send = (type, payload) => window.webkit?.messageHandlers.reader?.postMessage({type, payload});
let lastPosition = null;
let restoring = false;
let imageResizeObserver;
let sourceBlocks = [];
let synchronizedY = null;
let renderGeneration = 0;
let previewTruncated = false;
let sourceScrollTimer;
let renderedBlocks = [];
let renderContext = '';
let readingBlocks = [];
let readingKeys = new Map();
let headingElements = [];
let lastActiveHeading;
const copyTargets = new WeakMap();
const pendingCopies = new Map();
let nextCopyRequest = 0;
let readerStrings = {copy:'复制代码', copied:'已复制', copyFailed:'复制失败', content:'文档内容',
  truncated:'大文件已使用纯文本预览，仅显示前 500,000 个字符。编辑模式可查看和编辑全文。', remoteImage:'远程图片未加载'};

function makeCopyButton(target) {
  const button = document.createElement('button');
  button.type = 'button';
  button.tabIndex = 0;
  button.className = 'code-copy-button';
  button.title = readerStrings.copy;
  button.setAttribute('aria-label', readerStrings.copy);
  const icon = document.createElement('span');
  icon.className = 'code-copy-icon';
  icon.setAttribute('aria-hidden', 'true');
  button.append(icon);
  copyTargets.set(button, {target, request:null, timer:null});
  return button;
}

window.completeCodeCopy = function(request, success) {
  const button = pendingCopies.get(request)?.deref();
  pendingCopies.delete(request);
  const state = button && copyTargets.get(button);
  if (!state || state.request !== request || !button.isConnected) return;
  clearTimeout(state.timer);
  button.dataset.copyState = success ? 'success' : 'failure';
  const feedback = success ? readerStrings.copied : readerStrings.copyFailed;
  button.dataset.feedback = feedback;
  button.title = feedback;
  button.setAttribute('aria-label', feedback);
  copyStatus.textContent = feedback;
  state.timer = setTimeout(() => {
    delete button.dataset.copyState;
    delete button.dataset.feedback;
    button.title = readerStrings.copy;
    button.setAttribute('aria-label', readerStrings.copy);
    state.request = null;
  }, 1500);
};

function updateActiveHeading() {
  let id = null;
  if (headingElements.length) {
    const maximum = Math.max(0, document.documentElement.scrollHeight - innerHeight);
    const index = maximum > 0 && scrollY >= maximum - 2 ? headingElements.length - 1 :
      lastAtOrBefore(headingElements, 72, element => element.getBoundingClientRect().top);
    id = headingElements[index].id;
  }
  if (id !== lastActiveHeading) {
    lastActiveHeading = id;
    send('activeHeading', id);
  }
}

function lastAtOrBefore(items, value, position) {
  let low = 0, high = items.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (position(items[middle]) <= value) low = middle + 1;
    else high = middle;
  }
  return Math.max(0, low - 1);
}

function updateReadingBlocks() {
  readingBlocks = [];
  readingKeys = new Map();
  for (const element of content.children) {
    const text = element.textContent.trim();
    if (!text) continue;
    const key = text.slice(0, 180);
    const matches = readingKeys.get(key) || [];
    const block = {element, key, duplicate:matches.length};
    matches.push(block); readingKeys.set(key, matches); readingBlocks.push(block);
  }
}

function sourcePosition() {
  const maximum = Math.max(0, document.documentElement.scrollHeight - innerHeight);
  const progress = maximum ? Math.min(1, Math.max(0, scrollY / maximum)) : 0;
  if (!sourceBlocks.length) return {offset:0, progress};
  const index = lastAtOrBefore(sourceBlocks, 0.5, block => block.element.getBoundingClientRect().top);
  const block = sourceBlocks[index];
  const top = block.element.getBoundingClientRect().top + scrollY;
  const bottom = sourceBlocks[index + 1]?.element.getBoundingClientRect().top + scrollY ||
    block.element.getBoundingClientRect().bottom + scrollY;
  const fraction = Math.max(0, Math.min(1, (scrollY - top) / Math.max(1, bottom - top)));
  return {offset:block.start + fraction * (block.end - block.start), progress};
}

window.synchronizeSourceScroll = function(position) {
  if (!sourceBlocks.length) return;
  // A newer synchronized move supersedes a render's pending position restoration.
  restoring = false;
  clearTimeout(sourceScrollTimer);
  sourceScrollTimer = null;
  const maximum = Math.max(0, document.documentElement.scrollHeight - innerHeight);
  let y;
  if (position.progress <= 0.0001) y = 0;
  else if (position.progress >= 0.9999) y = maximum;
  else {
    const index = lastAtOrBefore(sourceBlocks, position.offset, block => block.start);
    const block = sourceBlocks[index];
    const top = block.element.getBoundingClientRect().top + scrollY;
    const next = sourceBlocks[index + 1];
    const bottom = next ? next.element.getBoundingClientRect().top + scrollY :
      block.element.getBoundingClientRect().bottom + scrollY;
    const fraction = Math.max(0, Math.min(1, (position.offset - block.start) / Math.max(1, block.end - block.start)));
    y = top + fraction * (bottom - top);
  }
  synchronizedY = Math.min(maximum, Math.max(0, y));
  window.scrollTo(0, synchronizedY);
  synchronizedY = scrollY;
  lastPosition = capturePosition();
  updateActiveHeading();
};

function capturePosition() {
  let low = 0, high = readingBlocks.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (readingBlocks[middle].element.getBoundingClientRect().bottom <= 18) low = middle + 1;
    else high = middle;
  }
  const block = readingBlocks[low];
  return {key:block?.key || '', duplicate:block?.duplicate || 0, offset:block?.element.getBoundingClientRect().top || 0,
    ratio:scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)};
}

function restorePosition(position) {
  if (!position) return;
  const anchor = readingKeys.get(position.key)?.[position.duplicate || 0]?.element;
  const y = anchor ? anchor.getBoundingClientRect().top + scrollY - position.offset :
    position.ratio * Math.max(0, document.documentElement.scrollHeight - innerHeight);
  window.scrollTo(0, Math.max(0, y));
}

window.updateDocument = function(text, kind, baseURL, preferences, savedPosition) {
  readerStrings = {...readerStrings, ...preferences.strings};
  document.documentElement.lang = preferences.language || 'zh-Hans';
  content.setAttribute('aria-label', readerStrings.content);
  invalidateReaderSearch();
  const generation = ++renderGeneration;
  lastActiveHeading = undefined;
  const position = content.childElementCount ? capturePosition() : savedPosition;
  restoring = true;
  document.documentElement.style.setProperty('--size', preferences.fontSize + 'px');
  document.documentElement.style.setProperty('--width', preferences.width + 'px');
  document.documentElement.dataset.appearance = preferences.appearance;
  const limit = 500000;
  const truncated = text.length > limit;
  previewTruncated = truncated;
  const source = truncated ? text.slice(0, limit) : text;
  let nextContent;
  let pendingNodes = null;
  let changedElements = [];
  sourceBlocks = [];
  if (kind === 'markdown' && !truncated) {
    nextContent = document.createDocumentFragment();
    const tokens = marked.lexer(source, {gfm:true, breaks:false});
    // marked normalizes CRLF to LF. Translate its UTF-16 offsets back to the editor's original text.
    const removedCR = [];
    for (const match of source.matchAll(/\r\n/g)) removedCR.push(match.index - removedCR.length + 1);
    const originalOffset = offset => {
      let low = 0, high = removedCR.length;
      while (low < high) {
        const middle = (low + high) >>> 1;
        if (removedCR[middle] <= offset) low = middle + 1;
        else high = middle;
      }
      return offset + low;
    };
    const context = JSON.stringify([baseURL, preferences.remoteImages, source.length < 150000]);
    const previous = context === renderContext ? renderedBlocks : [];
    const next = [];
    let offset = 0;
    for (const token of tokens) {
      const start = originalOffset(offset);
      offset += token.raw.length;
      const single = [token];
      single.links = tokens.links;
      next.push({html:marked.parser(single, {gfm:true, breaks:false}), start, end:originalOffset(offset)});
    }
    let prefix = 0, suffix = 0;
    while (prefix < next.length && prefix < previous.length && next[prefix].html === previous[prefix].html) prefix++;
    while (suffix < next.length - prefix && suffix < previous.length - prefix &&
           next[next.length - suffix - 1].html === previous[previous.length - suffix - 1].html) suffix++;
    for (let i = 0; i < prefix; i++) next[i].nodes = previous[i].nodes;
    for (let i = 0; i < suffix; i++) next[next.length - i - 1].nodes = previous[previous.length - i - 1].nodes;

    if (prefix + suffix < next.length) {
      const inertDocument = document.implementation.createHTMLDocument('');
      const staging = inertDocument.createElement('div');
      const template = inertDocument.createElement('template');
      for (let i = prefix; i < next.length - suffix; i++) {
        // Only changed blocks are parsed into new DOM nodes. They stay inert
        // until the entire changed tree has passed the same security filter.
        template.innerHTML = next[i].html;
        const group = inertDocument.createElement('section');
        group.append(template.content);
        next[i].group = group;
        staging.append(group);
      }
      DOMPurify.sanitize(staging, {
        IN_PLACE:true, ALLOW_DATA_ATTR:false,
        FORBID_TAGS:['script','style','iframe','object','embed','form','textarea','button','svg','math','video','audio','link','meta','base'],
        FORBID_ATTR:['style','srcset','autofocus','contenteditable','name']
      });
      DOMPurify.removed = [];
      for (let i = prefix; i < next.length - suffix; i++) {
        // Read back the sanitized children, including safe children unwrapped
        // from disallowed HTML. Never reattach the original unfiltered nodes.
        next[i].nodes = [...next[i].group.childNodes];
        delete next[i].group;
        changedElements.push(...next[i].nodes.filter(node => node.nodeType === Node.ELEMENT_NODE));
      }
    }
    pendingNodes = next.flatMap(block => block.nodes);
    for (const block of next) {
      for (const element of block.nodes) {
        if (element.nodeType === Node.ELEMENT_NODE) sourceBlocks.push({element, start:block.start, end:block.end});
      }
    }
    renderedBlocks = next;
    renderContext = context;
    nextContent = null;
  } else {
    renderedBlocks = []; renderContext = '';
    nextContent = document.createDocumentFragment();
    const pre = document.createElement('pre');
    pre.className = 'plain';
    const code = document.createElement('code');
    code.textContent = source;
    if ((kind === 'json' || kind === 'xml') && source.length < 150000) code.className = 'language-' + kind;
    pre.append(code); nextContent.append(pre);
    sourceBlocks.push({element:pre, start:0, end:source.length});
    changedElements = [pre];
  }
  if (truncated) {
    const notice = document.createElement('div'); notice.className = 'notice';
    notice.textContent = readerStrings.truncated;
    nextContent.prepend(notice);
  }
  const changedMatching = selector => changedElements.flatMap(element =>
    [...(element.matches(selector) ? [element] : []), ...element.querySelectorAll(selector)]);
  const imageReplacements = new Map();
  changedMatching('img').forEach(img => {
    img.loading = 'lazy';
    img.decoding = 'async';
    const original = img.getAttribute('src') || '';
    try {
      const resolved = new URL(original, baseURL);
      if (resolved.protocol === 'file:') {
        img.src = 'document-resource://local' + resolved.pathname;
      } else if (['https:','http:'].includes(resolved.protocol)) {
        if (!preferences.remoteImages) {
          const placeholder = document.createElement('span'); placeholder.className = 'image-placeholder';
          placeholder.textContent = '[' + readerStrings.remoteImage + (img.alt ? ': ' + img.alt : '') + ']';
          img.replaceWith(placeholder);
          imageReplacements.set(img, placeholder);
        } else { img.referrerPolicy = 'no-referrer'; img.loading = 'lazy'; }
      } else if (!original.startsWith('data:image/')) { img.removeAttribute('src'); }
    } catch { img.removeAttribute('src'); }
  });
  if (imageReplacements.size && pendingNodes) {
    pendingNodes = pendingNodes.map(node => imageReplacements.get(node) || node);
    for (const block of renderedBlocks) block.nodes = block.nodes.map(node => imageReplacements.get(node) || node);
    for (const block of sourceBlocks) block.element = imageReplacements.get(block.element) || block.element;
  }
  if (nextContent) content.replaceChildren(nextContent);
  else if (pendingNodes) {
    // Resolve/disable image URLs before inserting any new node into the page.
    const retained = new Set(pendingNodes);
    for (const node of [...content.childNodes]) if (!retained.has(node)) node.remove();
    let cursor = content.firstChild;
    for (const node of pendingNodes) {
      if (node === cursor) cursor = cursor.nextSibling;
      else content.insertBefore(node, cursor);
    }
  }
  const ids = new Set();
  const headings = [...content.querySelectorAll('h1,h2,h3,h4,h5,h6')].map(el => {
    const title = el.textContent.trim();
    let slug = title.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu,'').replace(/\s+/g,'-') || 'section';
    const base = slug; let n = 1;
    while (ids.has(slug)) slug = base + '-' + n++;
    ids.add(slug); if (el.id !== slug) el.id = slug;
    return {id:slug, title, level:Number(el.tagName.slice(1))};
  });
  changedMatching('input').forEach(e => { e.disabled = true; });
  changedMatching('a').forEach(e => { e.removeAttribute('target'); e.removeAttribute('download'); });
  if (source.length < 150000) {
    changedMatching('pre code[class*=language-]').forEach(el => {
      try { hljs.highlightElement(el); } catch { /* Unsupported language remains plain text. */ }
    });
  }
  if (kind === 'markdown' && !truncated) {
    changedMatching('pre').forEach(pre => {
      // Keep the pre itself as the source/reading anchor. Only its body scrolls.
      const scroll = document.createElement('div');
      scroll.className = 'code-copy-scroll';
      while (pre.firstChild) scroll.append(pre.firstChild);
      pre.classList.add('code-copy-block');
      pre.append(scroll, makeCopyButton(scroll));
    });
    const replacements = new Map();
    changedMatching('code').filter(code => !code.closest('pre')).forEach(code => {
      const wrapper = document.createElement('span');
      wrapper.className = 'code-copy-inline';
      const topLevel = code.parentNode === content;
      code.replaceWith(wrapper);
      wrapper.append(code, makeCopyButton(code));
      if (topLevel) replacements.set(code, wrapper);
    });
    if (replacements.size) {
      for (const block of renderedBlocks) block.nodes = block.nodes.map(node => replacements.get(node) || node);
      for (const block of sourceBlocks) block.element = replacements.get(block.element) || block.element;
    }
  }
  updateReadingBlocks();
  send('headings', headings);
  headingElements = [...content.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(element => element.getClientRects().length);
  // Background WebKit pages may suspend animation frames; restore synchronously too.
  restorePosition(position);
  const finishRestoring = () => {
    if (generation !== renderGeneration || !restoring) return;
    restorePosition(position);
    synchronizedY = scrollY;
    restoring = false; lastPosition = capturePosition();
    updateActiveHeading();
  };
  requestAnimationFrame(() => {
    if (generation !== renderGeneration || !restoring) return;
    restorePosition(position);
    // WebKit can apply its own scroll compensation after this first layout.
    requestAnimationFrame(() => {
      if (generation !== renderGeneration || !restoring) return;
      restorePosition(position);
      requestAnimationFrame(() => {
        finishRestoring();
      });
    });
  });
  // A background window may suspend animation frames indefinitely.
  setTimeout(finishRestoring, 80);
  // Image loads above the viewport should not shift the current reading anchor.
  imageResizeObserver?.disconnect();
  imageResizeObserver = new ResizeObserver(() => {
    if (!restoring && lastPosition) restorePosition(lastPosition);
    if (!restoring) updateActiveHeading();
  });
  content.querySelectorAll('img').forEach(img => imageResizeObserver.observe(img));
};

let scrollTimer;
addEventListener('scroll', () => {
  if (restoring) return;
  updateActiveHeading();
  lastPosition = capturePosition();
  clearTimeout(scrollTimer);
  scrollTimer = setTimeout(() => send('position', lastPosition), 200);
  if (synchronizedY !== null && Math.abs(scrollY - synchronizedY) < 1) return;
  synchronizedY = null;
  if (sourceScrollTimer) return;
  sourceScrollTimer = setTimeout(() => {
    sourceScrollTimer = null;
    if (!restoring && (synchronizedY === null || Math.abs(scrollY - synchronizedY) >= 1)) {
      send('sourceScroll', sourcePosition());
    }
  }, 16);
}, {passive:true});
addEventListener('resize', () => { if (!restoring) updateActiveHeading(); }, {passive:true});

content.addEventListener('click', event => {
  const button = event.target.closest('button');
  const state = button && copyTargets.get(button);
  if (state) {
    event.preventDefault();
    event.stopPropagation();
    clearTimeout(state.timer);
    if (state.request !== null) pendingCopies.delete(state.request);
    const request = ++nextCopyRequest;
    state.request = request;
    pendingCopies.set(request, new WeakRef(button));
    send('copyCode', {request, text:state.target.textContent});
    return;
  }
  const link = event.target.closest('a');
  if (!link) return;
  event.preventDefault();
  const href = link.getAttribute('href') || '';
  if (href.startsWith('#')) {
    try { document.getElementById(decodeURIComponent(href.slice(1)))?.scrollIntoView(); } catch {}
  } else { send('link', href); }
});
send('ready', true);
