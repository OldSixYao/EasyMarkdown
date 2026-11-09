/* Every image source is admitted by the native resource budget before WebKit decodes it. */
class ReaderImages {
  constructor(send) {
    this.send = send;
    this.states = new Map();
    this.requests = new Map();
    this.nextRequest = 0;
    this.scheduled = false;
    this.strings = {};
    this.observer = new IntersectionObserver(entries => {
      for (const entry of entries) {
        const state = this.states.get(entry.target);
        if (!state) continue;
        state.near = entry.isIntersecting;
        if (!state.near) this.release(state);
      }
      this.schedule();
    }, {rootMargin:'350px 0px'});
    addEventListener('scroll', () => this.schedule(false, true), {passive:true});
    addEventListener('resize', () => this.schedule(false, true), {passive:true});
    this.refreshGeometry = false;
  }

  prepare(img, baseURL, remoteImages, strings) {
    this.strings = strings;
    const source = img.getAttribute('src') || '';
    img.removeAttribute('src');
    img.loading = 'eager';
    img.decoding = 'async';
    const frame = document.createElement('span');
    frame.className = 'reader-image-frame';
    const status = document.createElement('span');
    status.className = 'image-placeholder image-status';
    status.setAttribute('role', 'status');
    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'image-open';
    open.textContent = strings.openImage;
    status.append(open);
    img.replaceWith(frame);
    frame.append(img, status);
    let resolved;
    try { resolved = new URL(source, baseURL); } catch {}
    const allowed = resolved && ['file:','data:','http:','https:'].includes(resolved.protocol);
    const blocked = resolved && ['http:','https:'].includes(resolved.protocol) && !remoteImages;
    const state = {img, frame, status, source:resolved?.href || '', near:false, request:null,
      authorWidth:Number(img.getAttribute('width')) || 0, authorHeight:Number(img.getAttribute('height')) || 0,
      state:blocked ? 'blocked' : allowed ? 'idle' : 'unavailable', cooldown:false};
    open.hidden = !resolved || !['file:','http:','https:'].includes(resolved.protocol);
    open.addEventListener('click', event => {
      event.preventDefault(); event.stopPropagation();
      this.send('openImage', state.source);
    });
    this.states.set(frame, state);
    this.label(state, state.state);
    this.observer.observe(frame);
    return frame;
  }

  label(state, value) {
    state.state = value;
    state.frame.dataset.imageState = value;
    const text = value === 'blocked' ? this.strings.remoteImage : value === 'budget' ? this.strings.imageBudget :
      value === 'unavailable' ? this.strings.imageUnavailable : this.strings.imageLoading;
    state.status.dataset.imageLabel = text || '';
    state.status.setAttribute('aria-label', text || '');
  }

  release(state) {
    if (state.request !== null) {
      this.send('imageRelease', state.request);
      this.requests.delete(state.request);
      state.request = null;
    }
    state.img.onload = null;
    state.img.onerror = null;
    state.img.removeAttribute('src');
    if (['loading','loaded','budget'].includes(state.state)) this.label(state, 'idle');
  }

  prune() {
    for (const [frame, state] of this.states) {
      if (state.frame.isConnected) continue;
      this.release(state);
      this.observer.unobserve(frame);
      this.states.delete(frame);
    }
    this.schedule();
  }

  schedule(retry = false, refreshGeometry = false) {
    this.refreshGeometry ||= refreshGeometry;
    if (retry) for (const state of this.states.values()) if (state.state === 'budget') this.label(state, 'idle');
    if (this.scheduled) return;
    this.scheduled = true;
    const run = () => {
      if (!this.scheduled) return;
      this.scheduled = false;
      this.pump();
    };
    requestAnimationFrame(run);
    // Background WebKit windows can suspend animation and intersection updates.
    setTimeout(run, 30);
  }

  distance(state) {
    const rect = state.frame.getBoundingClientRect();
    return rect.bottom < 0 ? -rect.bottom : Math.max(0, rect.top - innerHeight);
  }

  pump() {
    if (this.refreshGeometry) {
      this.refreshGeometry = false;
      for (const state of this.states.values()) {
        if (!state.frame.isConnected) continue;
        state.near = this.distance(state) <= 350;
        if (!state.near) this.release(state);
      }
    } else {
      // Newly inserted/background pages may not have delivered intersections yet.
      for (const state of this.states.values()) {
        if (state.frame.isConnected && state.state === 'idle' && !state.near) state.near = this.distance(state) <= 350;
      }
    }
    const loading = [...this.states.values()].filter(state => state.state === 'loading').length;
    let slots = 2 - loading;
    const pending = [...this.states.values()].filter(state => state.near && state.state === 'idle' &&
      state.frame.isConnected && (!state.cooldown || this.distance(state) === 0));
    pending.sort((a,b) => this.distance(a) - this.distance(b));
    for (const state of pending) {
      if (slots-- <= 0) break;
      state.cooldown = false;
      const request = String(++this.nextRequest);
      state.request = request;
      this.requests.set(request, state);
      this.label(state, 'loading');
      this.send('imageRequest', {request, source:state.source});
    }
  }

  complete(request, result) {
    const state = this.requests.get(request);
    if (!state || state.request !== request || !state.frame.isConnected || !state.near) {
      this.send('imageRelease', request);
      return;
    }
    if (result.error) {
      this.requests.delete(request);
      state.request = null;
      this.label(state, result.error);
      if (result.error === 'budget') {
        for (const other of this.states.values()) {
          if (other.state === 'loaded' && this.distance(other) > 0) {
            this.release(other);
            other.cooldown = true;
          }
        }
      }
      this.schedule();
      return;
    }
    this.dimensions(state, result.width, result.height);
    state.img.onload = () => {
      this.requests.delete(request);
      this.dimensions(state, state.img.naturalWidth, state.img.naturalHeight);
      this.label(state, 'loaded');
      this.schedule();
    };
    state.img.onerror = () => {
      this.release(state);
      this.label(state, 'unavailable');
      this.schedule();
    };
    state.img.src = result.url;
  }

  dimensions(state, width, height) {
    if (!(width > 0 && height > 0)) return;
    const displayWidth = state.authorWidth || (state.authorHeight ? width * state.authorHeight / height : width);
    const displayHeight = state.authorHeight || (state.authorWidth ? height * state.authorWidth / width : height);
    state.img.width = Math.max(1, Math.round(displayWidth));
    state.img.height = Math.max(1, Math.round(displayHeight));
  }
}
