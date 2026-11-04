/* One rendered-text index drives both the result count and navigation. */
let readerSearch = {query:'', generation:-1, request:0, offset:0, groups:[], count:0, index:-1, range:null, selection:false};

function clearReaderSearchHighlight() {
  globalThis.CSS?.highlights?.delete('reader-search-current');
  const selection = getSelection();
  if (readerSearch.selection && selection?.rangeCount && selection.getRangeAt(0) === readerSearch.range) {
    selection.removeAllRanges();
  }
  readerSearch.range = null;
  readerSearch.selection = false;
}

function invalidateReaderSearch() {
  clearReaderSearchHighlight();
  readerSearch.generation = -1;
  readerSearch.groups = [];
  readerSearch.count = 0;
  readerSearch.index = -1;
}

function searchableGroups() {
  const groups = [];
  let group;
  const flush = () => {
    if (group?.length) {
      group.text = group.parts.join('');
      delete group.parts;
      groups.push(group);
    }
    group = {parts:[], spans:[], length:0, endsInSpace:false};
  };
  flush();
  const append = (node, start, end, text, collapsed = false) => {
    group.spans.push({node, rawStart:start, rawEnd:end, start:group.length, end:group.length + text.length, collapsed});
    group.parts.push(text);
    group.length += text.length;
    group.endsInSpace = text.endsWith(' ');
  };
  const visit = (element, preserve = false) => {
    const style = getComputedStyle(element);
    if (element.matches('button,input,select,textarea,script,style,[hidden],.notice,.image-placeholder,.visually-hidden') ||
        style.display === 'none' || style.visibility !== 'visible' || style.opacity === '0' ||
        (style.display !== 'contents' && !element.getClientRects().length)) return;
    // Inline code has block styling for wrapping, but belongs to its paragraph.
    const inlineCode = element.matches('.code-copy-inline,.code-copy-inline>code');
    const boundary = !inlineCode && /^(block|list-item|table|table-row|table-cell|flex|grid|flow-root)$/.test(style.display);
    if (boundary || element.tagName === 'BR') flush();
    preserve = /^(pre|break-spaces)/.test(style.whiteSpace);
    for (const node of element.childNodes) {
      if (node.nodeType === Node.ELEMENT_NODE) visit(node, preserve);
      else if (node.nodeType === Node.TEXT_NODE && node.data) {
        if (preserve) append(node, 0, node.length, node.data);
        else {
          for (const part of node.data.matchAll(/[^\t\r\n\f ]+|[\t\r\n\f ]+/g)) {
            const space = /^[\t\r\n\f ]/.test(part[0]);
            if (space && (!group.length || group.endsInSpace)) continue;
            append(node, part.index, part.index + part[0].length, space ? ' ' : part[0], space);
          }
        }
      }
    }
    if (boundary) flush();
  };
  visit(content);
  flush();
  return groups;
}

function readerSearchRange(index) {
  const group = readerSearch.groups[lastAtOrBefore(readerSearch.groups, index, group => group.first)];
  const offset = (index - group.first) * 2;
  const start = group.matches[offset], end = group.matches[offset + 1];
  const first = group.spans[lastAtOrBefore(group.spans, start, span => span.start)];
  const last = group.spans[lastAtOrBefore(group.spans, end - 1, span => span.start)];
  const range = document.createRange();
  range.setStart(first.node, first.collapsed ? first.rawStart : first.rawStart + start - first.start);
  range.setEnd(last.node, last.collapsed ? last.rawEnd : last.rawStart + end - last.start);
  return range;
}

window.updateReaderSearch = function(query, backwards, request, offset) {
  const rebuild = query !== readerSearch.query || renderGeneration !== readerSearch.generation;
  if (rebuild) {
    invalidateReaderSearch();
    readerSearch.query = query;
    readerSearch.generation = renderGeneration;
    if (query) {
      // Escape regex syntax: the public search is always a literal search.
      const pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu');
      for (const group of searchableGroups()) {
        group.matches = [];
        group.first = readerSearch.count;
        for (const match of group.text.matchAll(pattern)) group.matches.push(match.index, match.index + match[0].length);
        if (!group.matches.length) continue;
        readerSearch.count += group.matches.length / 2;
        delete group.text;
        readerSearch.groups.push(group);
      }
      readerSearch.index = readerSearch.count ? 0 : -1;
    }
  } else if (readerSearch.count && request !== readerSearch.request) {
    // SwiftUI can coalesce several key presses; retain their net movement.
    const movement = offset === undefined ? (backwards ? -1 : 1) * (request - readerSearch.request) : offset - readerSearch.offset;
    readerSearch.index = ((readerSearch.index + movement) % readerSearch.count + readerSearch.count) % readerSearch.count;
  }
  readerSearch.request = request;
  readerSearch.offset = offset ?? 0;
  clearReaderSearchHighlight();
  if (readerSearch.index >= 0) {
    const range = readerSearchRange(readerSearch.index);
    readerSearch.range = range;
    if (globalThis.CSS?.highlights && globalThis.Highlight) {
      CSS.highlights.set('reader-search-current', new Highlight(range));
    } else {
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      readerSearch.selection = true;
    }
    // Reveal matches inside horizontally scrolling code/table containers too.
    range.startContainer.parentElement?.scrollIntoView({block:'nearest', inline:'nearest'});
    const rect = range.getBoundingClientRect();
    if (rect.top < 28 || rect.bottom > innerHeight - 28) scrollBy(0, rect.top - innerHeight / 2);
    const scroller = range.startContainer.parentElement?.closest('.code-copy-scroll,table');
    if (scroller) {
      const bounds = scroller.getBoundingClientRect();
      if (rect.left < bounds.left || rect.right > bounds.right) scroller.scrollLeft += rect.left - bounds.left - 20;
    }
  }
  return {query, count:readerSearch.count, index:readerSearch.index, generation:renderGeneration, truncated:previewTruncated};
};
