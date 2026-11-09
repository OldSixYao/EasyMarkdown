/* All document content is untrusted. Sanitize before insertion; never interpolate it into JS. */
const content = document.getElementById('content');
const copyStatus = document.getElementById('copy-status');
const send = (type, payload) => window.webkit?.messageHandlers.reader?.postMessage({type, payload});
const readerImages = new ReaderImages(send);
window.completeReaderImage = (request, result) => readerImages.complete(request, result);
window.retryReaderImages = () => readerImages.schedule(true);
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
let parseContext = '';
let lastDocument = null;
let lastStyleKey = '';
let lastHeadingsPayload = '';
let readingBlocks = [];
let readingKeys = new Map();
let headingElements = [];
let lastActiveHeading;
const copyTargets = new WeakMap();
const readingTextCache = new WeakMap();
const headingTitleCache = new WeakMap();
const pendingCopies = new Map();
let nextCopyRequest = 0;
let readerStrings = {copy:'复制代码', copied:'已复制', copyFailed:'复制失败', content:'文档内容',
  truncated:'大文件已使用纯文本预览，仅显示前 500,000 个字符。编辑模式可查看和编辑全文。', remoteImage:'远程图片未加载',
  imageLoading:'正在加载图片…', imageBudget:'图片暂缓加载，滚动后重试或查看原图。',
  imageUnavailable:'图片无法预览，可查看原图。', openImage:'查看原图'};

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
    let key = readingTextCache.get(element);
    if (key === undefined) {
      key = readerText(element).trim().slice(0, 180);
      readingTextCache.set(element, key);
    }
    if (!key) continue;
    const matches = readingKeys.get(key) || [];
    const block = {element, key, duplicate:matches.length};
    matches.push(block); readingKeys.set(key, matches); readingBlocks.push(block);
  }
}

function readerText(element) {
  if (!element.querySelector('button,.image-status')) return element.textContent;
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, {
    acceptNode: node => node.parentElement?.closest('button,.image-status') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
  });
  const parts = [];
  while (walker.nextNode()) parts.push(walker.currentNode.data);
  return parts.join('');
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

window.updateReaderPreferences = function(preferences, preservePosition = true) {
  const styleKey = JSON.stringify([preferences.fontSize, preferences.width, preferences.appearance,
    preferences.language, preferences.strings]);
  if (styleKey === lastStyleKey) return;
  const position = preservePosition && content.childElementCount ? capturePosition() : null;
  const layoutChanged = document.documentElement.style.getPropertyValue('--size') !== preferences.fontSize + 'px' ||
    document.documentElement.style.getPropertyValue('--width') !== preferences.width + 'px';
  readerStrings = {...readerStrings, ...preferences.strings};
  document.documentElement.lang = preferences.language || 'zh-Hans';
  content.setAttribute('aria-label', readerStrings.content);
  document.documentElement.style.setProperty('--size', preferences.fontSize + 'px');
  document.documentElement.style.setProperty('--width', preferences.width + 'px');
  document.documentElement.dataset.appearance = preferences.appearance;
  lastStyleKey = styleKey;
  if (layoutChanged) invalidateReaderSearchIndex();
  if (position) {
    restorePosition(position);
    lastPosition = capturePosition();
    updateActiveHeading();
  }
};

window.updateDocument = function(text, kind, baseURL, preferences, savedPosition, suppliedTruncated = false) {
  const limit = 500000;
  const truncated = suppliedTruncated || text.length > limit;
  const source = text.length > limit ? text.slice(0, limit) : text;
  if (lastDocument && lastDocument.source === source && lastDocument.kind === kind &&
      lastDocument.baseURL === baseURL && lastDocument.remoteImages === preferences.remoteImages &&
      lastDocument.truncated === truncated) {
    window.updateReaderPreferences(preferences);
    return;
  }
  invalidateReaderSearch();
  const generation = ++renderGeneration;
  lastActiveHeading = undefined;
  const position = content.childElementCount ? capturePosition() : savedPosition;
  restoring = true;
  window.updateReaderPreferences(preferences, false);
  previewTruncated = truncated;
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
    const linksContext = JSON.stringify(tokens.links);
    const sameLinks = parseContext === linksContext;
    const matchesToken = (token, block) => block && token.type === block.type && token.raw === block.raw;
    let prefix = 0, suffix = 0;
    while (prefix < tokens.length && matchesToken(tokens[prefix], renderedBlocks[prefix])) prefix++;
    while (suffix < tokens.length - prefix && suffix < renderedBlocks.length - prefix &&
      matchesToken(tokens[tokens.length-suffix-1], renderedBlocks[renderedBlocks.length-suffix-1])) suffix++;
    const cache = new Map();
    for (let i = prefix; i < renderedBlocks.length - suffix; i++) {
      const block = renderedBlocks[i];
      const key = block.type + '\0' + block.raw;
      let matches = cache.get(key);
      if (!matches) { matches = {blocks:[], index:0}; cache.set(key, matches); }
      matches.blocks.push(block);
    }
    const next = [];
    let offset = 0;
    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      const start = originalOffset(offset);
      offset += token.raw.length;
      const single = [token];
      single.links = tokens.links;
      let previous;
      if (i < prefix) previous = renderedBlocks[i];
      else if (i >= tokens.length - suffix) previous = renderedBlocks[renderedBlocks.length - tokens.length + i];
      else {
        const matches = cache.get(token.type + '\0' + token.raw);
        previous = matches?.blocks[matches.index++];
      }
      const html = previous && sameLinks ? previous.html :
        marked.parser(single, {gfm:true, breaks:false});
      next.push({type:token.type, raw:token.raw, html, start, end:originalOffset(offset),
        nodes:previous && context === renderContext && previous.html === html ? previous.nodes : undefined});
    }
    const changed = next.filter(block => !block.nodes);
    if (changed.length) {
      const inertDocument = document.implementation.createHTMLDocument('');
      const staging = inertDocument.createElement('div');
      const template = inertDocument.createElement('template');
      for (const block of changed) {
        // Only changed blocks are parsed into new DOM nodes. They stay inert
        // until the entire changed tree has passed the same security filter.
        template.innerHTML = block.html;
        const group = inertDocument.createElement('section');
        group.append(template.content);
        block.group = group;
        staging.append(group);
      }
      DOMPurify.sanitize(staging, {
        IN_PLACE:true, ALLOW_DATA_ATTR:false,
        FORBID_TAGS:['script','style','iframe','object','embed','form','textarea','button','svg','math','video','audio','link','meta','base'],
        FORBID_ATTR:['style','srcset','autofocus','contenteditable','name']
      });
      DOMPurify.removed = [];
      for (const block of changed) {
        // Read back the sanitized children, including safe children unwrapped
        // from disallowed HTML. Never reattach the original unfiltered nodes.
        block.nodes = [...block.group.childNodes];
        delete block.group;
        changedElements.push(...block.nodes.filter(node => node.nodeType === Node.ELEMENT_NODE));
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
    parseContext = linksContext;
    nextContent = null;
  } else {
    renderedBlocks = []; renderContext = ''; parseContext = '';
    nextContent = document.createDocumentFragment();
    const pre = document.createElement('pre');
    pre.className = 'plain';
    const code = document.createElement('code');
    code.textContent = source;
    const language = {json:'json', xml:'xml', yaml:'yaml', toml:'ini', ini:'ini',
      configuration:'ini', environment:'ini', properties:'ini', jsonc:'json'}[kind];
    if (language && source.length < 150000) code.className = 'language-' + language;
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
    imageReplacements.set(img, readerImages.prepare(img, baseURL, preferences.remoteImages, readerStrings));
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
  readerImages.prune();
  const ids = new Set();
  const nextSuffix = new Map();
  const headings = [...content.querySelectorAll('h1,h2,h3,h4,h5,h6')].map(el => {
    let title = headingTitleCache.get(el);
    if (title === undefined) { title = readerText(el).trim(); headingTitleCache.set(el, title); }
    let slug = title.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu,'').replace(/\s+/g,'-') || 'section';
    const base = slug; let n = nextSuffix.get(base) || 1;
    while (ids.has(slug)) slug = base + '-' + n++;
    nextSuffix.set(base, n);
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
  const headingsPayload = JSON.stringify(headings);
  if (headingsPayload !== lastHeadingsPayload) {
    send('headings', headings);
    lastHeadingsPayload = headingsPayload;
  }
  lastDocument = {source, kind, baseURL, remoteImages:preferences.remoteImages, truncated};
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
addEventListener('resize', () => {
  invalidateReaderSearchIndex();
  if (!restoring) updateActiveHeading();
}, {passive:true});

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
content.addEventListener('toggle', invalidateReaderSearchIndex, true);
send('ready', true);
